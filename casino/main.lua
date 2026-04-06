---@diagnostic disable: undefined-field, need-check-nil  -- OC API extensions; ui/core nil-typed from initial declaration but always set before callbacks fire
--- casino/main.lua  —  Bank of Singularity Slot Machine
--- Entry point and top-level orchestrator for the casino computer.
---
--- Boot sequence:
---   1. Load (or wizard-create) casino card credentials from disk.
---   2. Discover the bank server via UDP broadcast on port 999.
---   3. Announce device identity and wait for admin approval (port 102).
---   4. ECDH key exchange to establish an AES-128 session (port 101).
---   5. Resolve the casino's own bank account ID by name.
---   6. Authenticate the casino's card so it can pay out winnings.
---   7. Enter the main event loop: card swipes → PIN → spins → payout.
---
--- Device type: pos  (holds + transfers + balance checks; no new type needed)
local ROOT = '/casino'
package.path = ROOT .. '/?.lua;' .. ROOT .. '/?/init.lua;' .. package.path

local component = require('component')
local event = require('event')
local computer = require('computer')
local serialization = require('serialization')

local Protocol = require('src.net.protocol')
local RM = require('src.net.requestManager')
local DeviceKeys = require('src.net.deviceKeys')
local Handshake = require('src.net.handshake')
local config = require('config')
local CasinoCore = require('src.casinoCore')
local UI = require('src.ui')

local modem = component.modem
local keypad = component.os_keypad
local dataComp = component.data
local gpu = component.gpu
local screen = component.screen

local PORT = 100
local DISCOVERY_PORT = 999
local KEY_PATH = ROOT .. '/keys/identity.key'
local CARD_FILE = ROOT .. '/casino_card.dat'

-- ─── Casino card setup (first-boot) ──────────────────────────────────────────

local fs = require('filesystem')

--- Load previously saved casino card credentials from CARD_FILE.
--- Returns the deserialized table {uid, salt, pin}, or nil if the file is
--- missing or corrupt.
---@return {uid:string, salt:string, pin:string}|nil
local function loadCasinoCard()
    if not fs.exists(CARD_FILE) then return nil end
    local f = io.open(CARD_FILE, 'r')
    if not f then return nil end
    local raw = f:read('*a');
    f:close()
    local ok, tbl = pcall(serialization.unserialize, raw)
    return (ok and type(tbl) == 'table') and tbl or nil
end

--- Persist casino card credentials to CARD_FILE so they survive reboots.
---@param uid  string  Card UID (from magData event field 5)
---@param salt string  Card salt (from magData event field 4)
---@param pin  string  Plain PIN digits (never transmitted over wire)
local function saveCasinoCard(uid, salt, pin)
    local f = assert(io.open(CARD_FILE, 'w'))
    f:write(serialization.serialize({uid = uid, salt = salt, pin = pin}))
    f:close()
end

-- Run on first boot when no card file exists.
-- Blocks until the operator swipes the casino card and enters its PIN.
local function setupCasinoCard()
    -- Need gpu/screen available for this, but a print fallback works too.
    local W, H = 160, 50
    local ok, _ = pcall(function()
        gpu.bind(screen.address);
        gpu.setResolution(W, H)
    end)

    local function scr(y, msg, f, b)
        if ok then
            gpu.setForeground(f or 0xFFD700)
            gpu.setBackground(b or 0x000000)
            local pad = math.max(0, math.floor((W - #msg) / 2))
            gpu.set(1 + pad, y, msg)
        else
            print(msg)
        end
    end

    if ok then
        gpu.setBackground(0x000000);
        gpu.fill(1, 1, W, H, ' ')
        gpu.setForeground(0x444400)
        gpu.set(1, 2, string.rep('═', W))
    end

    print('[SETUP] Casino card not configured — running first-boot setup.')
    scr(1, '  ♦  BANK OF SINGULARITY SLOTS — FIRST-TIME SETUP  ♦  ',
        0xFFD700, 0x110d00)
    scr(H, '  Swipe the casino card into the card reader to begin  ', 0x888888,
        0x000000)

    -- Step 1: wait for card swipe
    keypad.setDisplay('§eSwipe Card')
    scr(22, 'Swipe the CASINO card into the reader now', 0xFFFFFF, 0x000000)
    scr(24, '(This card will be used to pay out player winnings)', 0x888888,
        0x000000)

    local uid, salt
    repeat
        local e = {event.pull(120, 'magData')}
        if not e[1] then
            scr(26, 'Timed out. Reboot and try again.', 0xFF3333, 0x000000)
            error('[SETUP] Timed out waiting for casino card swipe')
        end
        salt = e[4]
        uid = e[5]
    until uid and salt

    keypad.setDisplay('§aPIN:')
    if ok then
        gpu.setBackground(0x000000);
        gpu.fill(1, 22, W, 5, ' ')
    end
    scr(22, 'Card read!  UID: ' .. uid, 0x00CC44, 0x000000)
    scr(24,
        'Now enter the PIN for this card on the keypad  (#=confirm  *=back)',
        0xFFFFFF, 0x000000)

    -- Step 2: collect PIN on keypad
    local pin = ''
    while true do
        local e = {event.pull(120, 'keypad')}
        if not e[1] then error('[SETUP] Timed out waiting for PIN entry') end
        local lbl = e[4]
        if lbl == '#' then
            if #pin > 0 then break end
        elseif lbl == '*' then
            if #pin > 0 then
                pin = pin:sub(1, -2)
                keypad.setDisplay(#pin > 0 and string.rep('*', #pin) or
                                      '§ePIN:')
            end
        elseif lbl:match('%d') and #pin < 6 then
            pin = pin .. lbl
            keypad.setDisplay(string.rep('*', #pin))
        end
    end

    saveCasinoCard(uid, salt, pin)
    keypad.setDisplay('§aSaved!')

    if ok then
        gpu.setBackground(0x000000);
        gpu.fill(1, 22, W, 5, ' ')
    end
    scr(22, 'Casino card saved!  Continuing boot...', 0x00CC44, 0x000000)
    print('[SETUP] Casino card saved: uid=' .. uid)

    -- Brief pause so the operator can read the confirmation
    local dl = computer.uptime() + 2
    repeat event.pull(0.2) until computer.uptime() >= dl

    return {uid = uid, salt = salt, pin = pin}
end

-- ─── Networking ───────────────────────────────────────────────────────────────

local server
local identityKeys
local aesKey = nil
local needsReauth = false

local function ensureOpen(port)
    if not modem.isOpen(port) then modem.open(port) end
end

--- Encrypt and send an RPC request to the bank server; register the callback
--- with the RequestManager so the response is delivered asynchronously.
--- No-ops silently if the AES session key is not yet established.
---@param op       string   Operation name (e.g. "Card.Authenticate")
---@param data     table    Request payload
---@param timeout  number   Seconds to wait before the RM fires a TIMEOUT callback
---@param callback fun(res:table|nil, err:table|nil)
local function fetch(op, data, timeout, callback)
    if not aesKey then return end
    local req = Protocol.makeRequest(op, modem.address, server, data, nil)
    ensureOpen(PORT)
    local plain = Protocol.encode(req)
    if not plain then return end
    local encrypted = Handshake.encrypt(dataComp, aesKey, plain)
    modem.send(server, PORT, encrypted)
    RM.register(req.id, timeout, callback)
end

--- Broadcast on DISCOVERY_PORT and wait up to 5 s for a "BANK_HERE" reply.
--- Returns the server modem address, or nil on timeout.
---@return string|nil serverAddr
local function discoverServer()
    modem.open(DISCOVERY_PORT)
    modem.broadcast(DISCOVERY_PORT, 'DISCOVER_BANK')
    local _, _, addr, _, _, msg = event.pull(5, 'modem_message')
    modem.close(DISCOVERY_PORT)
    if addr and msg == 'BANK_HERE' then return addr end
    return nil
end

local onModemMessage -- forward declaration

local function doReauth()
    needsReauth = false
    aesKey = nil
    event.ignore('modem_message', onModemMessage)

    local status
    repeat
        local err
        status, err = Handshake.announce(dataComp, modem, server,
                                         config.deviceId, config.deviceType,
                                         identityKeys)
        if err then status = nil end
        if status == 'revoked' or status == 'suspended' then
            event.listen('modem_message', onModemMessage)
            return
        end
        if status ~= 'active' then
            local dl = computer.uptime() + 5
            repeat event.pull(0.5) until computer.uptime() >= dl
        end
    until status == 'active'

    local key = Handshake.doHandshake(dataComp, modem, server, config.deviceId,
                                      identityKeys)
    if key then aesKey = key end
    event.listen('modem_message', onModemMessage)
end

-- ─── Casino & UI objects ──────────────────────────────────────────────────────

local core = nil
local ui = nil

-- ─── Play session ─────────────────────────────────────────────────────────────

local function startPlaySession()
    local spinCount = ui.selSpins
    local cost = spinCount * config.costPerSpin

    ui:showWaiting('Checking casino funds...')

    -- 1. Verify casino can cover worst-case payout
    core:getCasinoBalance(function(casinoBal, err)
        if err or casinoBal == nil then
            ui:showSpinSelect(core.playerSession and core.playerSession.balance)
            return
        end

        local maxPossible = spinCount * require('src.ui').SYM_MULT[1] *
                                config.costPerSpin
        -- canCover caps payouts; if casino is low on funds the results are silently
        -- biased in the house's favour (prizes capped to whatever balance exists).
        local canCover = math.min(math.max(casinoBal, 0), maxPossible)

        -- 2. Place hold from player to casino
        ui:showWaiting('Processing payment...')
        core:holdSpinCost(cost, function(_, holdErr)
            if holdErr then
                ui:showSpinSelect(core.playerSession and
                                      core.playerSession.balance)
                return
            end

            -- 3. Run spins (BLOCKING — os.sleep animation)
            local payout = ui:runSpins(spinCount, config.costPerSpin, canCover)

            -- 4. Pay out winnings (if any)
            if payout > 0 then
                ui:showWaiting('Paying out $' ..
                                   string.format('%d.%02d',
                                                 math.floor(payout / 100),
                                                 payout % 100) .. '...')
                local playerAccountId = core.playerSession and
                                            core.playerSession.accountId
                core:payPlayer(playerAccountId, payout, function(payErr)
                    ui:showResults(spinCount, config.costPerSpin, payout, payErr)
                end)
            else
                ui:showResults(spinCount, config.costPerSpin, 0, nil)
            end
        end)
    end)
end

-- ─── Event handlers ───────────────────────────────────────────────────────────

local function onCardSwipe(_, _, _, cardData, cardUid)
    if core then core:onCardSwipe(cardData, cardUid) end
end

local function onKeypadBtn(_, _, _, label)
    if core then core:onKeypadPress(label) end
end

local function onTouch(_, addr, x, y)
    if addr ~= screen.address then return end
    if ui then ui:onTouch(x, y) end
end

function onModemMessage(_, _, _, port, _, payload)
    if port ~= PORT then return end
    if not aesKey then return end

    local plain = Handshake.decrypt(dataComp, aesKey, payload)
    if not plain then
        local ok, msg = pcall(serialization.unserialize, payload)
        if ok and type(msg) == 'table' and msg.type == 'reauth_required' then
            needsReauth = true
        end
        return
    end
    RM.onPacket(plain)
end

-- ─── Boot ─────────────────────────────────────────────────────────────────────

gpu.bind(screen.address)
gpu.setResolution(gpu.maxResolution())

-- Load saved casino card credentials, or run first-boot setup wizard
local cardData = loadCasinoCard()
if not cardData then cardData = setupCasinoCard() end
config.casinoCardUid = cardData.uid
config.casinoCardSalt = cardData.salt
config.casinoPin = cardData.pin

print('[CASINO] Discovering bank server...')
repeat server = discoverServer() until server
---@cast server string  -- guaranteed non-nil by the repeat…until above
print('[CASINO] Server: ' .. server)

identityKeys = DeviceKeys.load(dataComp, KEY_PATH)
print('[CASINO] Device: ' .. config.deviceId .. ' (' .. config.deviceType .. ')')

print('[CASINO] Registering with server...')
repeat
    local status, err = Handshake.announce(dataComp, modem, server,
                                           config.deviceId, config.deviceType,
                                           identityKeys)
    if err then
        print('[CASINO] Announce error: ' .. tostring(err))
    elseif status == 'revoked' then
        error('Device revoked. Contact admin.')
    elseif status == 'suspended' then
        error('Device suspended. Contact admin.')
    elseif status ~= 'active' then
        print('[CASINO] Awaiting admin approval...')
        local dl = computer.uptime() + 10
        repeat event.pull(0.5) until computer.uptime() >= dl
    end
until status == 'active'
print('[CASINO] Approved.')

print('[CASINO] Key exchange...')
repeat
    local key, err = Handshake.doHandshake(dataComp, modem, server,
                                           config.deviceId, identityKeys)
    if key then
        aesKey = key
    else
        print('[CASINO] Handshake failed: ' .. tostring(err) .. ', retrying...')
        local dl = computer.uptime() + 3
        repeat event.pull(0.5) until computer.uptime() >= dl
    end
until aesKey ~= nil
print('[CASINO] Secure session established.')

event.listen('modem_message', onModemMessage)

-- Resolve casino account ID
local casinoAccountId = nil ---@type integer|nil
print('[CASINO] Resolving casino account "' .. config.casinoAccountName ..
          '"...')
local resolved = false
local req = Protocol.makeRequest('Accounts.GetByName', modem.address, server,
                                 {accountName = config.casinoAccountName}, nil)
ensureOpen(PORT)
local encoded = assert(Protocol.encode(req))
if not aesKey then error('AES key not established') end
modem.send(server, PORT, Handshake.encrypt(dataComp, aesKey, encoded))
RM.register(req.id, 8.0, function(res, err)
    if err or not res or not res.ok then
        error('[CASINO] Cannot resolve casino account "' ..
                  config.casinoAccountName .. '"')
    end
    casinoAccountId = res.data.id
    resolved = true
end)
local dl = computer.uptime() + 10
repeat
    RM.tick();
    event.pull(0.1)
until resolved or computer.uptime() > dl
if not resolved then error('[CASINO] Timed out resolving casino account') end
print('[CASINO] Casino account #' .. tostring(casinoAccountId))

-- Build core and UI
assert(casinoAccountId, 'casinoAccountId not resolved')
core = CasinoCore.new({
    fetch = fetch,
    dataComp = dataComp,
    keypad = keypad,
    casinoAccountId = casinoAccountId,
    casinoCardUid = config.casinoCardUid,
    casinoCardSalt = config.casinoCardSalt,
    casinoPin = config.casinoPin
})

ui = UI.new(config)

-- Wire callbacks
core.onPlayerAuth = function(_, balance) ui:showSpinSelect(balance) end

core.onPlayerLogout = function() ui:showIdle() end

core.onAuthFail = function(_) ui:showIdle() end

ui.onButton = function(tag)
    if tag == 'play' then
        startPlaySession()
    elseif tag == 'cancel' then
        core:logout()
    elseif tag:sub(1, 4) == 'sel:' then
        local n = tonumber(tag:sub(5))
        if n then
            ui.selSpins = n
            ui:draw()
        end
    end
end

ui.onSessionDone = function() core:logout() end

-- Authenticate casino's own card
print('[CASINO] Authenticating casino card...')
local authed = false
core:authCasino(function(_, err)
    if err then
        print('[CASINO] Warning: casino card auth failed (' .. tostring(err) ..
                  ')')
        print('[CASINO] Delete ' .. CARD_FILE ..
                  ' and reboot to re-run card setup.')
    else
        print('[CASINO] Casino session active.')
        authed = true
    end
end)
local dl2 = computer.uptime() + 10
repeat
    RM.tick();
    event.pull(0.1)
until authed or computer.uptime() > dl2

if not authed then error('[CASINO] Failed to authenticate casino card') end

-- Register input listeners
event.listen('magData', onCardSwipe)
event.listen('keypad', onKeypadBtn)
event.listen('touch', onTouch)
ensureOpen(PORT)

keypad.setDisplay('§aSwipe Card')
ui:showIdle()

-- ─── Main loop ────────────────────────────────────────────────────────────────

while true do
    local e = {event.pull(0.5)}
    if e[1] == 'interrupted' then break end
    if needsReauth then doReauth() end
    if core then core:tick() end
    if ui then ui:tick() end
    RM.tick()
end

event.ignore('modem_message', onModemMessage)
event.ignore('magData', onCardSwipe)
event.ignore('keypad', onKeypadBtn)
event.ignore('touch', onTouch)
