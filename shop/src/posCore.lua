---@diagnostic disable: undefined-field  -- OC API extensions (computer.uptime, keypad.setDisplay)
-- POS Core: card auth state machine + payment RPCs.
-- Completely UI-agnostic. Communicates with frontends via callbacks.
--
-- Keypad stays dedicated to card swipe + PIN only.
-- Frontends (store, casino, etc.) handle the touchscreen.
local computer = require('computer')

local SHORT_CODE = {
    AUTH_FAILED = 'DENIED',
    CARD_NOT_FOUND = 'NO CARD',
    CARD_NOT_ACTIVE = 'INACTIV',
    INSUFFICIENT_FUNDS = 'INSUFF',
    ACC_NOT_FOUND = 'NO ACC',
    UNAUTHORIZED = 'UNAUTH',
    FORBIDDEN = 'FORBID'
}

local STATE = {
    IDLE = 'IDLE',
    AWAIT_PIN = 'AWAIT_PIN',
    AUTHING = 'AUTHING',
    ACTIVE = 'ACTIVE'
}

local PosCore = {}
PosCore.__index = PosCore

---@param opts {fetch:function, dataComp:table, storeAccountId:integer, keypad:table}
function PosCore.new(opts)
    local self = setmetatable({}, PosCore)
    self.fetch = opts.fetch
    self.dataComp = opts.dataComp
    self.storeAccountId = opts.storeAccountId
    self.keypad = opts.keypad

    self.state = STATE.IDLE
    self.pinBuffer = ''
    self.pendingCard = nil -- {uid, salt}
    self.session = nil -- {token, accountId, balance}
    self.resetAt = nil

    -- ── Callbacks set by the active frontend ──────────────────────────────
    -- Called after a regular customer authenticates successfully.
    -- fn(token, accountId, balance)
    self.onCustomerAuth = nil

    -- Called after the store owner authenticates successfully.
    -- fn(token, accountId, balance)
    self.onOwnerAuth = nil

    -- Called when the session ends (logout or timeout).
    self.onLogout = nil

    -- Called when authentication fails.
    -- fn(code)
    self.onAuthFail = nil

    -- Called when a purchase RPC completes successfully.
    -- fn(newBalance)
    self.onPurchaseDone = nil

    -- Called when a purchase RPC fails.
    -- fn(code)
    self.onPurchaseFail = nil

    return self
end

--- True when a card session is active.
function PosCore:isActive() return self.session ~= nil end

--- Returns the current session table, or nil.
function PosCore:currentSession() return self.session end

-- ─── Keypad handlers (called by main event listener) ─────────────────────────

--- Handle a card swipe event (magData).
function PosCore:onCardSwipe(cardData, cardUid)
    if self.state ~= STATE.IDLE then return end
    if not cardUid or not cardData then return end

    self.pendingCard = {uid = cardUid, salt = cardData}
    self.pinBuffer = ''
    self.state = STATE.AWAIT_PIN
    self:_showPin()
end

--- Handle a keypad button press.
function PosCore:onKeypadPress(label)
    if self.state ~= STATE.AWAIT_PIN then return end

    if label == '*' then
        if #self.pinBuffer > 0 then
            self.pinBuffer = self.pinBuffer:sub(1, -2)
            self:_showPin()
        else
            -- Cancel PIN entry
            self.pendingCard = nil
            self.state = STATE.IDLE
            self:_showIdle()
        end

    elseif label == '#' then
        if #self.pinBuffer == 0 or not self.pendingCard then return end
        self:_doAuth()

    elseif label:match('%d') then
        self.pinBuffer = self.pinBuffer .. label
        self:_showPin()
    end
end

-- ─── Actions (called by frontends) ───────────────────────────────────────────

--- Debit the active session account by amount, credit the store account.
---@param amount number
function PosCore:purchase(amount)
    if not self.session then return end
    self.fetch('Ledger.Transfer', {
        token = self.session.token,
        toAccountId = self.storeAccountId,
        amount = amount
    }, 10.0, function(res, err)
        if err then
            if self.onPurchaseFail then
                self.onPurchaseFail('TIMEOUT')
            end
            return
        end
        if not res.ok then
            local code = res.err and res.err.code or 'ERR'
            if self.onPurchaseFail then self.onPurchaseFail(code) end
            return
        end
        if self.session then self.session.balance = res.data.fromBalance end
        if self.onPurchaseDone then
            self.onPurchaseDone(res.data.fromBalance)
        end
    end)
end

--- Place a hold for amount, auto-captured by the server after a delay.
--- callback(holdId, captureIn, errCode) — errCode nil on success.
---@param amount number
---@param callback function
function PosCore:hold(amount, callback)
    if not self.session then
        callback(nil, nil, 'NO_SESSION')
        return
    end
    if amount == 0 then
        callback(0, 0, nil)
        return
    end -- allow zero-amount holds for free reservations
    self.fetch('Ledger.Hold', {
        token = self.session.token,
        amount = amount,
        toAccountId = self.storeAccountId
    }, 10.0, function(res, err)
        if err then
            callback(nil, nil, 'TIMEOUT')
            return
        end
        if not res.ok then
            callback(nil, nil, res.err and res.err.code or 'ERR')
            return
        end
        if self.session then self.session.balance = res.data.balance end
        callback(res.data.holdId, res.data.captureIn, nil)
    end)
end

--- Adjust the hold amount down after partial dispense (releases the difference).
--- callback(errCode) — errCode nil on success.
---@param holdId integer
---@param actualAmount number
---@param callback function|nil
function PosCore:adjustHold(holdId, actualAmount, callback)
    if not self.session then
        if callback then callback('NO_SESSION') end
        return
    end
    self.fetch('Ledger.Adjust', {
        token = self.session.token,
        holdId = holdId,
        actualAmount = actualAmount
    }, 10.0, function(res, err)
        if err then
            if callback then callback('TIMEOUT') end
            return
        end
        if not res.ok then
            if callback then
                callback(res.err and res.err.code or 'ERR')
            end
            return
        end
        if self.session and res.data then
            self.session.balance = res.data.balance
        end
        if callback then callback(nil) end
    end)
end

--- Release a hold entirely — nothing dispensed, no charge.
---@param holdId integer
---@param callback function|nil
function PosCore:releaseHold(holdId, callback)
    if not self.session then
        if callback then callback() end
        return
    end
    self.fetch('Ledger.Release', {token = self.session.token, holdId = holdId},
               10.0, function(res, _)
        local bal = res and res.ok and res.data and res.data.balance
        if self.session and bal then self.session.balance = bal end
        if callback then callback() end
    end)
end

--- End the current session and return to IDLE.
function PosCore:logout()
    local tok = self.session and self.session.token
    self.session = nil
    self.state = STATE.IDLE
    self.pendingCard = nil
    self.pinBuffer = ''
    self.resetAt = nil
    self:_showIdle()
    if tok then
        self.fetch('Card.Deauthenticate', {token = tok}, 3.0, function() end)
    end
    if self.onLogout then self.onLogout() end
end

--- Tick: call once per main loop iteration.
function PosCore:tick()
    if self.resetAt and computer.uptime() >= self.resetAt then
        self.resetAt = nil
        if self.state == STATE.IDLE then self:_showIdle() end
    end
end

-- ─── Private ─────────────────────────────────────────────────────────────────

function PosCore:_showIdle() self.keypad.setDisplay('§aSwipe Card') end

function PosCore:_showPin()
    if #self.pinBuffer == 0 then
        self.keypad.setDisplay('§ePIN:')
    else
        self.keypad.setDisplay(string.rep('*', #self.pinBuffer))
    end
end

function PosCore:_flash(msg, delay)
    self.keypad.setDisplay(msg)
    self.resetAt = computer.uptime() + (delay or 2)
end

function PosCore:_doAuth()
    self.state = STATE.AUTHING
    self.keypad.setDisplay('§eVerify..')

    local salt = self.pendingCard.salt
    local uid = self.pendingCard.uid
    local pinHash = self.dataComp.encode64(
                        self.dataComp.sha256(self.pinBuffer .. salt))
    self.pinBuffer = ''
    self.pendingCard = nil

    self.fetch('Card.Authenticate', {cardUid = uid, pinHash = pinHash}, 5.0,
               function(res, err)
        if err then
            self.state = STATE.IDLE
            self:_flash('§cTimeout')
            return
        end
        if not res.ok then
            self.state = STATE.IDLE
            local code = res.err and res.err.code or '?'
            self:_flash('§c' .. (SHORT_CODE[code] or code))
            if self.onAuthFail then self.onAuthFail(code) end
            return
        end

        self.session = {
            token = res.data.token,
            accountId = res.data.accountId,
            balance = nil
        }
        self.state = STATE.ACTIVE

        local isOwner = (res.data.accountId == self.storeAccountId)
        self.keypad.setDisplay(isOwner and '§aOWNER' or '§aACTIVE')

        -- Fetch balance, then fire the appropriate callback
        self.fetch('Ledger.GetBalance', {token = self.session.token}, 5.0,
                   function(bres, berr)
            local balance = nil
            if not berr and bres.ok and self.session then
                balance = bres.data.balance
                self.session.balance = balance
            end
            if isOwner then
                if self.onOwnerAuth then
                    self.onOwnerAuth(self.session and self.session.token,
                                     self.session and self.session.accountId,
                                     balance)
                end
            else
                if self.onCustomerAuth then
                    self.onCustomerAuth(self.session and self.session.token,
                                        self.session and self.session.accountId,
                                        balance)
                end
            end
        end)
    end)
end

return PosCore
