---@diagnostic disable: undefined-field, undefined-doc-name  -- computer.uptime() OC ext; Error type in shared protocol module
--- bank/server/src/services/authService.lua
--- Session authentication service.
---
--- Manages an in-memory session table keyed by UUID token.
--- Session TTL = 300 s (computer uptime — resets on reboot).
---
--- Flow:
---   authenticate(cardUid, pinHash) — verifies PIN against card record,
---     logs LoginFail or LoginOk to ledger, returns {token, accountId}.
---   validate(token)                — returns session or nil if expired.
---   invalidate(token)              — explicit logout / token revocation.
---
--- Sessions are pruned lazily on each authenticate() call.

local computer = require('computer')
local uuid = require('uuid')
local Card = require('src.models.Card')
local LedgerMod = require('src.models.Ledger')

local ledger = LedgerMod.instance
local TxType = LedgerMod.TransactionType

local SESSION_TTL = 300 -- seconds (computer uptime)
---@type table<string, {accountId: integer, cardUid: string, expiresAt: number}>
local sessions = {}

local Auth = {}

local function pruneExpired()
    local now = computer.uptime()
    for token, s in pairs(sessions) do
        if s.expiresAt < now then sessions[token] = nil end
    end
end

---@param cardUid string
---@param pinHash string Base64-encoded sha256(pin..salt) computed client-side
---@return {token: string, accountId: integer}|nil
---@return nil|Error
function Auth.authenticate(cardUid, pinHash)
    local card = Card.getCardByUid(cardUid)
    if not card then
        return nil, {code = 'CARD_NOT_FOUND', message = 'Card not found'}
    end

    if card.status ~= Card.CardStatus.Active then
        return nil, {code = 'CARD_NOT_ACTIVE', message = 'Card is not active'}
    end

    if not card.pin_hash then
        return nil, {code = 'CARD_NO_PIN', message = 'No PIN set on this card'}
    end

    if card.pin_hash ~= pinHash then
        ledger:append({
            accountId = card.account_id,
            transactionType = TxType.LoginFail,
            amount = 0,
            meta = {cardUid = cardUid}
        })
        return nil, {code = 'AUTH_FAILED', message = 'Invalid PIN'}
    end

    ledger:append({
        accountId = card.account_id,
        transactionType = TxType.LoginOk,
        amount = 0,
        meta = {cardUid = cardUid}
    })

    pruneExpired()

    local token = uuid.next()
    sessions[token] = {
        accountId = card.account_id,
        cardUid = cardUid,
        expiresAt = computer.uptime() + SESSION_TTL
    }

    return {token = token, accountId = card.account_id}, nil
end

--- Validate a session token. Returns the session or nil if missing/expired.
---@param token string
---@return {accountId: integer, cardUid: string, expiresAt: number}|nil
function Auth.validate(token)
    if not token then return nil end
    local s = sessions[token]
    if not s then return nil end
    if s.expiresAt < computer.uptime() then
        sessions[token] = nil
        return nil
    end
    return s
end

--- Invalidate a session token (logout).
---@param token string
function Auth.invalidate(token)
    sessions[token] = nil
end

return Auth