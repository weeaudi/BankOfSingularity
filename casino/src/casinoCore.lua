---@diagnostic disable: undefined-field  -- computer.uptime() is an OC API extension
--- casino/src/casinoCore.lua
--- Bank-integration layer for the slot machine.
---
--- Manages two independent bank sessions:
---
---   casinoSession — authenticated with the casino's own card on boot.
---                   Used exclusively for `Ledger.Transfer` payouts to players.
---                   Auto-refreshed every 260 s (token TTL = 300 s).
---
---   playerSession — created when a customer swipes their card and enters PIN.
---                   Used for `Ledger.GetBalance` and `Ledger.Hold` (spin cost).
---
--- Player state machine:
---   IDLE → (card swipe) → AWAIT_PIN → (# pressed) → AUTHING → ACTIVE
---   ACTIVE → (logout / session end) → IDLE
---
--- Hold flow:   `hold(playerToken, cost, casinoAccountId)` debits the player
---              immediately; auto-captures to the casino after the fraud window.
--- Payout flow: `transfer(casinoToken, playerAccountId, amount)` moves money
---              from the casino account to the player immediately.

---@class CasinoSession
---@field token string  Active session token for the casino card

---@class PlayerSession
---@field token     string   Active session token for the authenticated player
---@field accountId integer  Player's bank account ID
---@field balance   number|nil Last known balance (cents), updated after hold

local computer = require('computer')

local SHORT_CODE = {
    AUTH_FAILED        = 'DENIED',
    CARD_NOT_FOUND     = 'NO CARD',
    CARD_NOT_ACTIVE    = 'INACTIV',
    INSUFFICIENT_FUNDS = 'INSUFF',
    ACC_NOT_FOUND      = 'NO ACC',
    UNAUTHORIZED       = 'UNAUTH',
}

local STATE = { IDLE = 'IDLE', AWAIT_PIN = 'AWAIT_PIN', AUTHING = 'AUTHING', ACTIVE = 'ACTIVE' }

local CasinoCore = {}
CasinoCore.__index = CasinoCore

---@param opts {fetch:function, dataComp:table, keypad:table, casinoAccountId:integer, casinoCardUid:string, casinoCardSalt:string, casinoPin:string}
function CasinoCore.new(opts)
    local self = setmetatable({}, CasinoCore)
    self.fetch           = opts.fetch
    self.dataComp        = opts.dataComp
    self.keypad          = opts.keypad
    self.casinoAccountId = opts.casinoAccountId
    self.casinoCardUid   = opts.casinoCardUid
    self.casinoCardSalt  = opts.casinoCardSalt
    self.casinoPin       = opts.casinoPin

    self.state         = STATE.IDLE
    self.pinBuffer     = ''
    self.pendingCard   = nil
    self.playerSession = nil   -- {token, accountId, balance}
    self.casinoSession = nil   -- {token}
    self.casinoAuthAt  = nil   -- uptime when casino session was created
    self.resetAt       = nil

    -- Callbacks set by main
    self.onPlayerAuth   = nil  -- fn(accountId, balance)
    self.onPlayerLogout = nil  -- fn()
    self.onAuthFail     = nil  -- fn(code)

    return self
end

-- ─── Casino session ───────────────────────────────────────────────────────────

--- Authenticate the casino's own card. Call on boot and when session expires.
--- callback(token|nil, err|nil)
function CasinoCore:authCasino(callback)
    local pinHash = self.dataComp.encode64(
        self.dataComp.sha256(self.casinoPin .. self.casinoCardSalt))
    self.fetch('Card.Authenticate',
        {cardUid = self.casinoCardUid, pinHash = pinHash}, 8.0,
        function(res, err)
            if err or not res or not res.ok then
                if callback then callback(nil, 'CASINO_AUTH_FAILED') end
                return
            end
            self.casinoSession = {token = res.data.token}
            self.casinoAuthAt  = computer.uptime()
            if callback then callback(res.data.token, nil) end
        end)
end

--- Re-auth casino session if it is near expiry (token TTL = 300s, refresh at 260s).
function CasinoCore:tickCasinoAuth()
    if not self.casinoAuthAt then return end
    if computer.uptime() - self.casinoAuthAt >= 260 then
        self.casinoAuthAt = nil   -- prevent re-entry
        self:authCasino(function() end)
    end
end

-- ─── Bank RPCs ────────────────────────────────────────────────────────────────

--- Check the casino account's current balance.
--- callback(balance|nil, err|nil)
function CasinoCore:getCasinoBalance(callback)
    if not self.casinoSession then callback(nil, 'NO_CASINO_SESSION') return end
    self.fetch('Ledger.GetBalance', {token = self.casinoSession.token}, 5.0,
        function(res, err)
            if err or not res or not res.ok then callback(nil, 'ERR') return end
            callback(res.data.balance, nil)
        end)
end

--- Hold spinCost from the player, earmarked for the casino account.
--- callback(holdId|nil, errCode|nil)
function CasinoCore:holdSpinCost(spinCost, callback)
    if not self.playerSession then callback(nil, 'NO_SESSION') return end
    self.fetch('Ledger.Hold',
        {token = self.playerSession.token, amount = spinCost, toAccountId = self.casinoAccountId},
        10.0,
        function(res, err)
            if err then callback(nil, 'TIMEOUT') return end
            if not res or not res.ok then
                callback(nil, res and res.err and res.err.code or 'ERR')
                return
            end
            if self.playerSession then self.playerSession.balance = res.data.balance end
            callback(res.data.holdId, nil)
        end)
end

--- Transfer payout from casino to the player.
--- Retries once if casino session token has expired.
--- callback(errCode|nil)
function CasinoCore:payPlayer(playerAccountId, amount, callback)
    if amount <= 0 then callback(nil) return end
    if not self.casinoSession then callback('NO_CASINO_SESSION') return end
    local function doTransfer()
        self.fetch('Ledger.Transfer',
            {token = self.casinoSession.token, toAccountId = playerAccountId, amount = amount},
            10.0,
            function(res, err)
                if err then callback('TIMEOUT') return end
                if not res or not res.ok then
                    local code = res and res.err and res.err.code or 'ERR'
                    if code == 'UNAUTHORIZED' then
                        self:authCasino(function(tok, aerr)
                            if aerr or not tok then callback('CASINO_AUTH_FAILED') return end
                            doTransfer()
                        end)
                    else
                        callback(code)
                    end
                    return
                end
                callback(nil)
            end)
    end
    doTransfer()
end

-- ─── Keypad / card swipe ──────────────────────────────────────────────────────

function CasinoCore:onCardSwipe(cardData, cardUid)
    if self.state ~= STATE.IDLE then return end
    if not cardUid or not cardData then return end
    if cardUid == self.casinoCardUid then return end   -- ignore casino's own card

    self.pendingCard = {uid = cardUid, salt = cardData}
    self.pinBuffer   = ''
    self.state       = STATE.AWAIT_PIN
    self:_showPin()
end

function CasinoCore:onKeypadPress(label)
    if self.state ~= STATE.AWAIT_PIN then return end

    if label == '*' then
        if #self.pinBuffer > 0 then
            self.pinBuffer = self.pinBuffer:sub(1, -2)
            self:_showPin()
        else
            self.pendingCard = nil
            self.state       = STATE.IDLE
            self:_showIdle()
        end
    elseif label == '#' then
        if #self.pinBuffer == 0 or not self.pendingCard then return end
        self:_doAuth()
    elseif label:match('%d') then
        if #self.pinBuffer < 6 then
            self.pinBuffer = self.pinBuffer .. label
            self:_showPin()
        end
    end
end

function CasinoCore:logout()
    local tok = self.playerSession and self.playerSession.token
    self.playerSession = nil
    self.state         = STATE.IDLE
    self.pendingCard   = nil
    self.pinBuffer     = ''
    self.resetAt       = nil
    self:_showIdle()
    if tok then
        self.fetch('Card.Deauthenticate', {token = tok}, 3.0, function() end)
    end
    if self.onPlayerLogout then self.onPlayerLogout() end
end

function CasinoCore:tick()
    self:tickCasinoAuth()
    if self.resetAt and computer.uptime() >= self.resetAt then
        self.resetAt = nil
        if self.state == STATE.IDLE then self:_showIdle() end
    end
end

-- ─── Private ─────────────────────────────────────────────────────────────────

function CasinoCore:_showIdle()
    self.keypad.setDisplay('§aSwipe Card')
end

function CasinoCore:_showPin()
    if #self.pinBuffer == 0 then
        self.keypad.setDisplay('§ePIN:')
    else
        self.keypad.setDisplay(string.rep('*', #self.pinBuffer))
    end
end

function CasinoCore:_flash(msg, delay)
    self.keypad.setDisplay(msg)
    self.resetAt = computer.uptime() + (delay or 2)
end

function CasinoCore:_doAuth()
    self.state = STATE.AUTHING
    self.keypad.setDisplay('§eVerify..')

    local salt    = self.pendingCard.salt
    local uid     = self.pendingCard.uid
    local pinHash = self.dataComp.encode64(self.dataComp.sha256(self.pinBuffer .. salt))
    self.pinBuffer   = ''
    self.pendingCard = nil

    self.fetch('Card.Authenticate', {cardUid = uid, pinHash = pinHash}, 5.0,
        function(res, err)
            if err then
                self.state = STATE.IDLE
                self:_flash('§cTimeout')
                return
            end
            if not res or not res.ok then
                self.state = STATE.IDLE
                local code = res and res.err and res.err.code or '?'
                self:_flash('§c' .. (SHORT_CODE[code] or code))
                if self.onAuthFail then self.onAuthFail(code) end
                return
            end

            self.playerSession = {token = res.data.token, accountId = res.data.accountId, balance = nil}
            self.state = STATE.ACTIVE
            self.keypad.setDisplay('§aACTIVE')

            self.fetch('Ledger.GetBalance', {token = self.playerSession.token}, 5.0,
                function(bres, berr)
                    local balance = nil
                    if not berr and bres and bres.ok and self.playerSession then
                        balance                    = bres.data.balance
                        self.playerSession.balance = balance
                    end
                    if self.onPlayerAuth then
                        self.onPlayerAuth(
                            self.playerSession and self.playerSession.accountId,
                            balance)
                    end
                end)
        end)
end

return CasinoCore