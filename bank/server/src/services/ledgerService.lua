---@diagnostic disable: undefined-doc-name  -- Error type in shared protocol module
--- bank/server/src/services/ledgerService.lua
--- Business-logic layer for all ledger / balance operations.
---
--- All monetary amounts are in cents (integers).
---
--- Token-gated operations (require a valid card session token):
---   getBalance(token)                          → {accountId, balance}
---   deposit(token, amount)                     → {balance}
---   withdraw(token, amount)                    → {balance}
---   transfer(token, toAccountId, amount)       → {fromBalance, toBalance}
---   hold(token, amount, toAccountId)           → {holdId, balance, captureIn}
---   adjustHold(token, holdId, actualAmount)    → {balance}
---   releaseHold(token, holdId)                 → {balance}
---
--- Admin operations (no session token required):
---   mint(accountId, amount)                    → {balance}
---   burn(accountId, amount)                    → {balance}
---   freezeAccount(accountId)                   → {balance}
---   unfreezeAccount(accountId)                 → {balance}
---   adminTransfer(from, to, amount)            → {fromBalance, toBalance}
---   refund(from, to, amount)                   → {fromBalance, toBalance}
---   chargeback(from, to, amount)               → {fromBalance, toBalance}
---   adminCaptureHold(holdId)                   → boolean
---   adminReleaseHold(holdId)                   → boolean
---   listHolds()                                → table[]
---   pinChange(accountId, cardUid)              → (audit log only, no return value)
---
--- Hold lifecycle:
---   hold()         — debit player immediately; schedule auto-capture timer
---   adjustHold()   — reduce held amount; credit difference back to player
---   releaseHold()  — cancel hold entirely; credit full amount back to player
---   auto-capture   — fires after CAPTURE_DAYS (3 IRL days); credits the store

local Config        = require('config')
local event         = require('event')
local serialization = require('serialization')
local fs            = require('filesystem')
local LedgerMod     = require('src.models.Ledger')
local Account       = require('src.models.Account')
local Log           = require('src.util.log')
local auth          = require('src.services.authService')
local db            = require('src.db').database

local ledger = LedgerMod.instance
local TxType = LedgerMod.TransactionType

-- Fraud review window: 3 IRL days.
-- os.time() is in in-game seconds and persists across reboots (world time).
-- event.timer uses real seconds. Conversion: 1 IRL day = 86400 real seconds.
-- In-game runs 72× faster: 1 IRL day = 72 × 86400 = 6,220,800 in-game seconds.
local MC_SPEED          = 72        -- in-game seconds per real second
local CAPTURE_DAYS      = 3
local CAPTURE_REAL_SEC  = CAPTURE_DAYS * 86400                    -- 259200 real seconds
local CAPTURE_INGAME    = CAPTURE_REAL_SEC * MC_SPEED             -- in-game seconds offset

local HOLDS_PATH = Config.DB_ROOT .. '/holds.dat'

-- Holds table. Persisted to disk; timers re-registered on load.
-- [holdId] = {accountId, amount, toAccountId, captureAt, timerId}
-- captureAt is os.time() in-game seconds — survives reboots.
local holds = {}

local function persistHolds()
    local toSave = {}
    for id, h in pairs(holds) do
        toSave[id] = {
            accountId   = h.accountId,
            amount      = h.amount,
            toAccountId = h.toAccountId,
            captureAt   = h.captureAt,  -- timerId is not serialisable; omit
        }
    end
    local dir = HOLDS_PATH:match('^(.*)/[^/]+$')
    if dir and not fs.exists(dir) then fs.makeDirectory(dir) end
    local f = io.open(HOLDS_PATH, 'w')
    if f then f:write(serialization.serialize(toSave)) f:close() end
end

local LedgerService = {}

-- ─── Internal helpers ─────────────────────────────────────────────────────────

local function requireSession(token)
    local session = auth.validate(token)
    if not session then
        return nil, {code = 'UNAUTHORIZED', message = 'Invalid or expired session'}
    end
    return session, nil
end

local function requireActiveAccount(accountId)
    local acct = Account.getById(accountId)
    if not acct then
        return nil, {code = 'ACC_NOT_FOUND', message = 'Account not found'}
    end
    if acct.account_status ~= Account.Status.Active then
        return nil, {code = 'ACC_NOT_ACTIVE', message = 'Account is not active'}
    end
    return acct, nil
end

local function currentBalance(accountId)
    local row = db.select('account_balance'):where({accountId = accountId}):first()
    return (row and row.balance) or 0
end

-- ─── Public API ───────────────────────────────────────────────────────────────

---@param token string
---@return {accountId: integer, balance: number}|nil
---@return nil|Error
function LedgerService.getBalance(token)
    local session, err = requireSession(token)
    if not session then return nil, err end

    return {accountId = session.accountId, balance = currentBalance(session.accountId)}, nil
end

---@param token string
---@param amount number
---@return {balance: number}|nil
---@return nil|Error
function LedgerService.deposit(token, amount)
    local session, err = requireSession(token)
    if not session then return nil, err end

    if type(amount) ~= 'number' or amount <= 0 then
        return nil, {code = 'BAD_AMOUNT', message = 'Amount must be a positive number'}
    end

    local _, aerr = requireActiveAccount(session.accountId)
    if aerr then return nil, aerr end

    ledger:append({
        accountId       = session.accountId,
        transactionType = TxType.Deposit,
        amount          = amount,
        meta            = {}
    })

    return {balance = currentBalance(session.accountId)}, nil
end

---@param token string
---@param amount number
---@return {balance: number}|nil
---@return nil|Error
function LedgerService.withdraw(token, amount)
    local session, err = requireSession(token)
    if not session then return nil, err end

    if type(amount) ~= 'number' or amount <= 0 then
        return nil, {code = 'BAD_AMOUNT', message = 'Amount must be a positive number'}
    end

    local _, aerr = requireActiveAccount(session.accountId)
    if aerr then return nil, aerr end

    if currentBalance(session.accountId) < amount then
        return nil, {code = 'INSUFFICIENT_FUNDS', message = 'Insufficient funds'}
    end

    ledger:append({
        accountId       = session.accountId,
        transactionType = TxType.Withdraw,
        amount          = -amount,
        meta            = {}
    })

    return {balance = currentBalance(session.accountId)}, nil
end

---@param token string
---@param toAccountId integer
---@param amount number
---@return {fromBalance: number, toBalance: number}|nil
---@return nil|Error
function LedgerService.transfer(token, toAccountId, amount)
    local session, err = requireSession(token)
    if not session then return nil, err end

    if type(amount) ~= 'number' or amount <= 0 then
        return nil, {code = 'BAD_AMOUNT', message = 'Amount must be a positive number'}
    end

    if session.accountId == toAccountId then
        return nil, {code = 'SAME_ACCOUNT', message = 'Cannot transfer to the same account'}
    end

    local _, aerr = requireActiveAccount(session.accountId)
    if aerr then return nil, aerr end

    local _, terr = requireActiveAccount(toAccountId)
    if terr then return nil, terr end

    if currentBalance(session.accountId) < amount then
        return nil, {code = 'INSUFFICIENT_FUNDS', message = 'Insufficient funds'}
    end

    ledger:append({
        accountId       = session.accountId,
        transactionType = TxType.Transfer,
        amount          = -amount,
        meta            = {toAccountId = toAccountId}
    })

    ledger:append({
        accountId       = toAccountId,
        transactionType = TxType.Transfer,
        amount          = amount,
        meta            = {fromAccountId = session.accountId}
    })

    return {
        fromBalance = currentBalance(session.accountId),
        toBalance   = currentBalance(toAccountId)
    }, nil
end

---@param accountId integer
---@param amount number
---@return {balance: number}|nil
---@return nil|Error
function LedgerService.mint(accountId, amount)
    if type(amount) ~= 'number' or amount <= 0 then
        return nil, {code = 'BAD_AMOUNT', message = 'Amount must be a positive number'}
    end

    local _, aerr = requireActiveAccount(accountId)
    if aerr then return nil, aerr end

    ledger:append({
        accountId       = accountId,
        transactionType = TxType.Mint,
        amount          = amount,
        meta            = {}
    })

    return {balance = currentBalance(accountId)}, nil
end

---@param accountId integer
---@param amount number
---@return {balance: number}|nil
---@return nil|Error
function LedgerService.burn(accountId, amount)
    if type(amount) ~= 'number' or amount <= 0 then
        return nil, {code = 'BAD_AMOUNT', message = 'Amount must be a positive number'}
    end

    local _, aerr = requireActiveAccount(accountId)
    if aerr then return nil, aerr end

    ledger:append({
        accountId       = accountId,
        transactionType = TxType.Burn,
        amount          = -amount,
        meta            = {}
    })

    return {balance = currentBalance(accountId)}, nil
end

---@param accountId integer
---@param cardUid string
function LedgerService.pinChange(accountId, cardUid)
    ledger:append({
        accountId       = accountId,
        transactionType = TxType.PinChange,
        amount          = 0,
        meta            = {cardUid = cardUid},
    })
end

---@param accountId integer
---@return {balance: number}|nil
---@return nil|Error
function LedgerService.freezeAccount(accountId)
    local acct = Account.getById(accountId)
    if not acct then
        return nil, {code = 'ACC_NOT_FOUND', message = 'Account not found'}
    end
    if acct.account_status == Account.Status.Frozen then
        return nil, {code = 'ACC_ALREADY_FROZEN', message = 'Account is already frozen'}
    end

    Account.setStatus(accountId, Account.Status.Frozen)

    ledger:append({
        accountId       = accountId,
        transactionType = TxType.Freeze,
        amount          = 0,
        meta            = {},
    })

    return {balance = currentBalance(accountId)}, nil
end

---@param accountId integer
---@return {balance: number}|nil
---@return nil|Error
function LedgerService.unfreezeAccount(accountId)
    local acct = Account.getById(accountId)
    if not acct then
        return nil, {code = 'ACC_NOT_FOUND', message = 'Account not found'}
    end
    if acct.account_status ~= Account.Status.Frozen then
        return nil, {code = 'ACC_NOT_FROZEN', message = 'Account is not frozen'}
    end

    Account.setStatus(accountId, Account.Status.Active)

    ledger:append({
        accountId       = accountId,
        transactionType = TxType.Unfreeze,
        amount          = 0,
        meta            = {},
    })

    return {balance = currentBalance(accountId)}, nil
end

--- Admin: move funds between two accounts without a session token.
---@param fromAccountId integer
---@param toAccountId integer
---@param amount number
---@return {fromBalance: number, toBalance: number}|nil
---@return nil|Error
function LedgerService.adminTransfer(fromAccountId, toAccountId, amount)
    if type(amount) ~= 'number' or amount <= 0 then
        return nil, {code = 'BAD_AMOUNT', message = 'Amount must be a positive number'}
    end
    if fromAccountId == toAccountId then
        return nil, {code = 'SAME_ACCOUNT', message = 'Cannot transfer to the same account'}
    end

    local _, ferr = requireActiveAccount(fromAccountId)
    if ferr then return nil, ferr end

    local _, terr = requireActiveAccount(toAccountId)
    if terr then return nil, terr end

    if currentBalance(fromAccountId) < amount then
        return nil, {code = 'INSUFFICIENT_FUNDS', message = 'Insufficient funds'}
    end

    ledger:append({
        accountId       = fromAccountId,
        transactionType = TxType.Transfer,
        amount          = -amount,
        meta            = {toAccountId = toAccountId, admin = true},
    })
    ledger:append({
        accountId       = toAccountId,
        transactionType = TxType.Transfer,
        amount          = amount,
        meta            = {fromAccountId = fromAccountId, admin = true},
    })

    return {
        fromBalance = currentBalance(fromAccountId),
        toBalance   = currentBalance(toAccountId),
    }, nil
end

--- Admin: credit toAccountId from fromAccountId (e.g. store refunds customer).
---@param fromAccountId integer
---@param toAccountId integer
---@param amount number
---@return {fromBalance: number, toBalance: number}|nil
---@return nil|Error
function LedgerService.refund(fromAccountId, toAccountId, amount)
    if type(amount) ~= 'number' or amount <= 0 then
        return nil, {code = 'BAD_AMOUNT', message = 'Amount must be a positive number'}
    end
    if fromAccountId == toAccountId then
        return nil, {code = 'SAME_ACCOUNT', message = 'Cannot refund to the same account'}
    end
    ledger:append({
        accountId       = fromAccountId,
        transactionType = TxType.Refund,
        amount          = -amount,
        meta            = {toAccountId = toAccountId},
    })
    ledger:append({
        accountId       = toAccountId,
        transactionType = TxType.Refund,
        amount          = amount,
        meta            = {fromAccountId = fromAccountId},
    })

    return {
        fromBalance = currentBalance(fromAccountId),
        toBalance   = currentBalance(toAccountId),
    }, nil
end

--- Admin: bank-initiated reversal (e.g. fraud recovery). Debits fromAccountId, credits toAccountId.
---@param fromAccountId integer
---@param toAccountId integer
---@param amount number
---@return {fromBalance: number, toBalance: number}|nil
---@return nil|Error
function LedgerService.chargeback(fromAccountId, toAccountId, amount)
    if type(amount) ~= 'number' or amount <= 0 then
        return nil, {code = 'BAD_AMOUNT', message = 'Amount must be a positive number'}
    end
    if fromAccountId == toAccountId then
        return nil, {code = 'SAME_ACCOUNT', message = 'Cannot chargeback to the same account'}
    end
    ledger:append({
        accountId       = fromAccountId,
        transactionType = TxType.Chargeback,
        amount          = -amount,
        meta            = {toAccountId = toAccountId},
    })
    ledger:append({
        accountId       = toAccountId,
        transactionType = TxType.Chargeback,
        amount          = amount,
        meta            = {fromAccountId = fromAccountId},
    })

    return {
        fromBalance = currentBalance(fromAccountId),
        toBalance   = currentBalance(toAccountId),
    }, nil
end

-- ─── Internal: auto-capture ───────────────────────────────────────────────────

local function doCapture(holdId)
    local h = holds[holdId]
    if not h then return end  -- already released
    holds[holdId] = nil
    persistHolds()

    Log.info(('[Hold] Auto-capture holdId=%d  amount=%d  to=%s'):format(
        holdId, h.amount, tostring(h.toAccountId)))

    -- Release difference if amount was adjusted below original
    -- (amount field already reflects any prior adjustment)

    -- Audit on customer side (balance already debited at hold time)
    ledger:append({
        accountId       = h.accountId,
        transactionType = TxType.Commit,
        amount          = 0,
        meta            = {holdId = holdId, captured = true, toAccountId = h.toAccountId},
    })

    -- Credit the store
    ledger:append({
        accountId       = h.toAccountId,
        transactionType = TxType.Commit,
        amount          = h.amount,
        meta            = {holdId = holdId, fromAccountId = h.accountId},
    })
end

-- ─── Hold / Adjust / Release ─────────────────────────────────────────────────

--- Place a hold. Debits balance immediately; auto-captures after CAPTURE_DELAY seconds.
---@param token string
---@param amount number
---@param toAccountId integer  store account to credit on capture
---@return {holdId:integer, balance:number, captureIn:number}|nil
---@return nil|Error
function LedgerService.hold(token, amount, toAccountId)
    local session, err = requireSession(token)
    if not session then return nil, err end

    if type(amount) ~= 'number' or amount <= 0 then
        return nil, {code = 'BAD_AMOUNT', message = 'Amount must be positive'}
    end

    local _, aerr = requireActiveAccount(session.accountId)
    if aerr then return nil, aerr end

    if currentBalance(session.accountId) < amount then
        return nil, {code = 'INSUFFICIENT_FUNDS', message = 'Insufficient funds'}
    end

    local _, terr = requireActiveAccount(toAccountId)
    if terr then return nil, terr end

    local holdId = ledger:append({
        accountId       = session.accountId,
        transactionType = TxType.Hold,
        amount          = -amount,
        meta            = {toAccountId = toAccountId},
    })

    local captureAt = os.time() + CAPTURE_INGAME
    local timerId   = event.timer(CAPTURE_REAL_SEC, function() doCapture(holdId) end, 1)

    holds[holdId] = {
        accountId   = session.accountId,
        amount      = amount,
        toAccountId = toAccountId,
        captureAt   = captureAt,  -- in-game seconds; persistent across reboots
        timerId     = timerId,
    }
    persistHolds()

    Log.info(('[Hold] Placed holdId=%d  amount=%d  captureIn=%d days'):format(
        holdId, amount, CAPTURE_DAYS))

    return {
        holdId    = holdId,
        balance   = currentBalance(session.accountId),
        captureIn = CAPTURE_DAYS,  -- days, for client display
    }, nil
end

--- Adjust the held amount after partial dispense (must be <= original).
--- Immediately releases the difference back to the customer.
---@param token string
---@param holdId integer
---@param actualAmount number
---@return {balance:number}|nil
---@return nil|Error
function LedgerService.adjustHold(token, holdId, actualAmount)
    local session, err = requireSession(token)
    if not session then return nil, err end

    local h = holds[holdId]
    if not h then
        return nil, {code = 'HOLD_NOT_FOUND', message = 'Hold not found or already settled'}
    end
    if h.accountId ~= session.accountId then
        return nil, {code = 'FORBIDDEN', message = 'Hold belongs to a different account'}
    end
    if type(actualAmount) ~= 'number' or actualAmount < 0 or actualAmount > h.amount then
        return nil, {code = 'BAD_AMOUNT', message = 'Invalid adjustment amount'}
    end

    local diff = h.amount - actualAmount
    if diff > 0 then
        ledger:append({
            accountId       = h.accountId,
            transactionType = TxType.Adjust,
            amount          = diff,
            meta            = {holdId = holdId, previousAmount = h.amount, adjustedTo = actualAmount},
        })
    end

    h.amount = actualAmount  -- capture will use this adjusted amount
    persistHolds()
    return {balance = currentBalance(h.accountId)}, nil
end

--- Release a hold entirely (no charge). Cancels the auto-capture timer.
--- Called by the client when nothing was dispensed.
---@param token string
---@param holdId integer
---@return {balance:number}|nil
---@return nil|Error
function LedgerService.releaseHold(token, holdId)
    local session, err = requireSession(token)
    if not session then return nil, err end

    local h = holds[holdId]
    if not h then
        return nil, {code = 'HOLD_NOT_FOUND', message = 'Hold not found or already settled'}
    end
    if h.accountId ~= session.accountId then
        return nil, {code = 'FORBIDDEN', message = 'Hold belongs to a different account'}
    end

    event.cancel(h.timerId)
    holds[holdId] = nil
    persistHolds()

    ledger:append({
        accountId       = h.accountId,
        transactionType = TxType.Release,
        amount          = h.amount,
        meta            = {holdId = holdId, reason = 'client_release'},
    })

    Log.info(('[Hold] Released holdId=%d  amount=%d'):format(holdId, h.amount))
    return {balance = currentBalance(h.accountId)}, nil
end

--- Admin: immediately capture a hold (charge the customer now, credit the store).
---@param holdId integer
---@return boolean ok
---@return string|nil err
function LedgerService.adminCaptureHold(holdId)
    local h = holds[holdId]
    if not h then return false, 'Hold not found or already settled' end
    event.cancel(h.timerId)
    doCapture(holdId)
    Log.info(('[Hold] Admin-captured holdId=%d  amount=%d'):format(holdId, h.amount))
    return true, nil
end

--- Admin: release a hold by ID (fraud / error override). No session required.
---@param holdId integer
---@return boolean ok
---@return string|nil err
function LedgerService.adminReleaseHold(holdId)
    local h = holds[holdId]
    if not h then return false, 'Hold not found or already settled' end

    event.cancel(h.timerId)
    holds[holdId] = nil
    persistHolds()

    ledger:append({
        accountId       = h.accountId,
        transactionType = TxType.Release,
        amount          = h.amount,
        meta            = {holdId = holdId, reason = 'admin_release'},
    })

    Log.info(('[Hold] Admin-released holdId=%d  amount=%d'):format(holdId, h.amount))
    return true, nil
end

--- Admin: list all pending holds.
---@return table[]
function LedgerService.listHolds()
    local now    = os.time()
    local result = {}
    for id, h in pairs(holds) do
        -- captureAt is in-game seconds; convert remainder to real days
        local remainIngame = math.max(0, h.captureAt - now)
        local remainDays   = (remainIngame / MC_SPEED) / 86400
        result[#result + 1] = {
            holdId      = id,
            accountId   = h.accountId,
            amount      = h.amount,
            toAccountId = h.toAccountId,
            capturesIn  = remainDays,  -- real days remaining (decimal)
        }
    end
    return result
end

-- ─── Startup: load persisted holds and re-register timers ────────────────────

local function loadHolds()
    if not fs.exists(HOLDS_PATH) then return end
    local f = io.open(HOLDS_PATH, 'r')
    if not f then return end
    local content = f:read('*a')
    f:close()

    local ok, data = pcall(serialization.unserialize, content)
    if not ok or type(data) ~= 'table' then
        Log.warn('[Hold] Failed to load holds.dat — starting fresh')
        return
    end

    local now       = os.time()
    local recovered = 0
    local captured  = 0

    for id, h in pairs(data) do
        holds[id] = h
        local remainIngame = h.captureAt - now
        if remainIngame <= 0 then
            -- Expired while server was down — capture on next event loop tick
            h.timerId = event.timer(0.5, function() doCapture(id) end, 1)
            captured  = captured + 1
        else
            local remainReal = remainIngame / MC_SPEED
            h.timerId = event.timer(remainReal, function() doCapture(id) end, 1)
            recovered = recovered + 1
        end
    end

    if recovered + captured > 0 then
        Log.info(('[Hold] Loaded %d hold(s): %d active, %d expired (will capture)'):format(
            recovered + captured, recovered, captured))
    end
end

loadHolds()

return LedgerService