---@diagnostic disable: undefined-field  -- OC API extensions (component.*, computer.uptime, etc.)
local ROOT = '/shop'
package.path = ROOT .. '/?.lua;' .. ROOT .. '/?/init.lua;' .. ROOT ..
                   '/shared/?.lua;' .. ROOT .. '/shared/?/init.lua;' ..
                   package.path

local myPaks = {
    'src.net.protocol', 'src.net.requestManager', 'src.net.deviceKeys',
    'src.net.handshake'
}
for _, pak in pairs(myPaks) do package.loaded[pak] = nil end

local component = require('component')
local event = require('event')
local computer = require('computer')
local serialization = require('serialization')
local Protocol = require('src.net.protocol')
local RM = require('src.net.requestManager')
local DeviceKeys = require('src.net.deviceKeys')
local Handshake = require('src.net.handshake')
local config = require('config')

local PosCore = require('src.posCore')
local Catalog = require('src.catalog')
local Inventory = require('src.inventory')
local StoreUI = require('src.ui.store')
local ConfigUI = require('src.ui.configMode')
local StockPage = require('src.ui.stockPage')

local modem = component.modem
local keypad = component.os_keypad
local dataComp = component.data
local gpu = component.gpu
local screen = component.screen

local PORT = 100
local DISCOVERY_PORT = 999
local KEY_PATH = '/shop/keys/identity.key'

local deviceId = config.deviceId
local deviceType = config.deviceType

-- ─── Networking ──────────────────────────────────────────────────────────────

local server
local identityKeys
local aesKey = nil

local function ensureOpen(port)
    if not modem.isOpen(port) then modem.open(port) end
end

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

local function discoverServer()
    modem.open(DISCOVERY_PORT)
    modem.broadcast(DISCOVERY_PORT, 'DISCOVER_BANK')
    local _, _, addr, _, _, msg = event.pull(5, 'modem_message')
    modem.close(DISCOVERY_PORT)
    if addr and msg == 'BANK_HERE' then return addr end
    return nil
end

-- ─── Re-authentication ───────────────────────────────────────────────────────

local onModemMessage -- forward declaration
local needsReauth = false

local function doReauth()
    needsReauth = false
    aesKey = nil
    event.ignore('modem_message', onModemMessage)

    local status
    repeat
        local err
        status, err = Handshake.announce(dataComp, modem, server, deviceId,
                                         deviceType, identityKeys)
        if err then
            status = nil
        elseif status == 'revoked' or status == 'suspended' then
            event.listen('modem_message', onModemMessage)
            return
        end
        if status ~= 'active' then
            local deadline = computer.uptime() + 5
            repeat event.pull(0.5) until computer.uptime() >= deadline
        end
    until status == 'active'

    local key, _ = Handshake.doHandshake(dataComp, modem, server, deviceId,
                                         identityKeys)
    if key then aesKey = key end

    event.listen('modem_message', onModemMessage)
end

-- ─── Store account resolution ─────────────────────────────────────────────────

local storeAccountId = nil

local function resolveStoreAccount(callback)
    fetch('Accounts.GetByName', {accountName = config.storeAccountName}, 5.0,
          function(res, err)
        if err or not res.ok then
            error('Cannot resolve store account "' .. config.storeAccountName ..
                      '"')
        end
        storeAccountId = res.data.id
        callback()
    end)
end

-- ─── POS core + frontends ────────────────────────────────────────────────────

local pos = nil
local storeUI = nil
local configUI = nil
local stockPage = nil
local activeUI = nil -- currently visible frontend (or nil = stock page shown)

local function initPos()
    gpu.bind(screen.address)
    gpu.setResolution(gpu.maxResolution())

    Inventory.setSides(config.inventoryInput or 'north',
                       config.inventoryOutput or 'south')

    if not storeAccountId then error('Store account ID not resolved') end

    pos = PosCore.new({
        fetch = fetch,
        dataComp = dataComp,
        storeAccountId = storeAccountId,
        keypad = keypad
    })

    storeUI = StoreUI.new(gpu, Catalog, Inventory, pos)
    configUI = ConfigUI.new(gpu, Catalog, Inventory, pos)
    stockPage = StockPage.new(gpu, Catalog, Inventory)

    -- ── Callbacks ──────────────────────────────────────────────────────────

    pos.onCustomerAuth = function(_, _, balance)
        stockPage:hide()
        activeUI = storeUI
        storeUI:show(balance)
    end

    pos.onOwnerAuth = function(_, _, _)
        stockPage:hide()
        activeUI = configUI
        configUI:show()
    end

    pos.onLogout = function()
        if activeUI then activeUI:hide() end
        activeUI = nil
        stockPage:show()
    end

    pos.onPurchaseDone = function(newBalance)
        if activeUI == storeUI then storeUI:onPurchaseDone(newBalance) end
    end

    pos.onPurchaseFail = function(code)
        if activeUI == storeUI then storeUI:onPurchaseFail(code) end
    end
end

-- ─── Event handlers ──────────────────────────────────────────────────────────

local function onCardSwipe(_, _, _, cardData, cardUid)
    if pos then pos:onCardSwipe(cardData, cardUid) end
end

local function onKeypadBtn(_, _, _, label)
    if pos then pos:onKeypadPress(label) end
end

local function onTouch(_, addr, x, y)
    if addr ~= screen.address then return end
    if activeUI then
        activeUI:onTouch(x, y)
    elseif stockPage then
        stockPage:onTouch(x, y)
    end
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

-- ─── Boot ────────────────────────────────────────────────────────────────────

print('Discovering bank server...')
repeat server = discoverServer() until server
print('Server: ' .. server)

identityKeys = DeviceKeys.load(dataComp, KEY_PATH)
print('Device: ' .. deviceId .. ' (' .. deviceType .. ')')

print('Registering with server...')
repeat
    if not server then error('Server address not set') end
    local status, err = Handshake.announce(dataComp, modem, server, deviceId,
                                           deviceType, identityKeys)
    if err then
        print('Announce error: ' .. tostring(err))
    elseif status == 'revoked' then
        error('Device is revoked. Contact admin.')
    elseif status == 'suspended' then
        error('Device is suspended. Contact admin.')
    elseif status ~= 'active' then
        print('Awaiting admin approval...')
        local deadline = computer.uptime() + 10
        repeat event.pull(0.5) until computer.uptime() >= deadline
    end
until status == 'active'
print('Device approved.')

print('Performing key exchange...')
repeat
    local key, err = Handshake.doHandshake(dataComp, modem, server, deviceId,
                                           identityKeys)
    if key then
        aesKey = key
    else
        print('Handshake failed: ' .. tostring(err) .. ', retrying...')
        local deadline = computer.uptime() + 3
        repeat event.pull(0.5) until computer.uptime() >= deadline
    end
until aesKey ~= nil
print('Secure session established.')

event.listen('modem_message', onModemMessage)

print('Resolving store account...')
-- resolveStoreAccount is async; wait for it via a tiny blocking loop
local storeResolved = false
resolveStoreAccount(function() storeResolved = true end)
local deadline = computer.uptime() + 10
repeat
    RM.tick()
    event.pull(0.1)
until storeResolved or computer.uptime() > deadline
if not storeResolved then
    error('Could not resolve store account "' .. config.storeAccountName .. '"')
end
print('Store account: #' .. tostring(storeAccountId))

initPos()

event.listen('magData', onCardSwipe)
event.listen('keypad', onKeypadBtn)
event.listen('touch', onTouch)

ensureOpen(PORT)
keypad.setDisplay('§aSwipe Card')
if stockPage then stockPage:show() end
print('POS ready.')

-- ─── Main loop ───────────────────────────────────────────────────────────────

while true do
    local e = {event.pull(0.5)}
    if e[1] == 'interrupted' then break end
    if needsReauth then doReauth() end
    if pos then pos:tick() end
    if activeUI and activeUI.tick then activeUI:tick(computer.uptime()) end
    if not activeUI and stockPage then stockPage:tick(computer.uptime()) end
    RM.tick()
end

event.ignore('modem_message', onModemMessage)
event.ignore('magData', onCardSwipe)
event.ignore('keypad', onKeypadBtn)
event.ignore('touch', onTouch)
