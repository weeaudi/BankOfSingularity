---@diagnostic disable: undefined-doc-name  -- Error type in shared protocol module
--- bank/server/src/services/cardService.lua
--- Business-logic layer for card management.
---
--- Wraps Card model operations with validation, account existence checks,
--- and ledger audit entries.  Called by handlers/req.lua for Card.* operations.
---
---   getByAccountId(accountId) — list all cards for an account
---   issueCard(accountId, uid, pinHash) — register a new card; logs CardIssue TX
---   revokeCard(uid)           — revoke a card by UID; logs CardRevoke TX

local CardModel  = require('src.models.Card')
local AccountModel = require('src.models.Account')
local LedgerMod  = require('src.models.Ledger')

local ledger = LedgerMod.instance
local TxType = LedgerMod.TransactionType

local Cards = {}

---@param accountId integer
---@return table|nil cardsList
---@return nil|Error
function Cards.getByAccountId(accountId)
    local cardsList = CardModel.getCardsByAccountId(accountId)

    if not cardsList or #cardsList == 0 then
        return nil, {
            code = 'CARD_NOT_FOUND',
            message = ('No cards found for account id %s'):format(accountId)
        }
    end

    return cardsList
end

---@param accountId integer
---@param uid string
---@param pinHash string
---@return {cardId: integer}|nil
---@return nil|Error
function Cards.issueCard(accountId, uid, pinHash)
    local acct = AccountModel.getById(accountId)
    if not acct then
        return nil, {code = 'ACC_NOT_FOUND', message = 'Account not found'}
    end

    local existing = CardModel.getCardByUid(uid)
    if existing then
        return nil, {code = 'CARD_EXISTS', message = 'Card UID already registered'}
    end

    local cardId = CardModel.issueCard({
        account_id = accountId,
        uid        = uid,
        pin_hash   = pinHash,
        status     = CardModel.CardStatus.Active,
        meta       = {}
    })

    ledger:append({
        accountId       = accountId,
        transactionType = TxType.CardIssue,
        amount          = 0,
        meta            = {cardId = cardId, uid = uid},
    })

    return {cardId = cardId}, nil
end

---@param uid string
---@return boolean ok
---@return string|nil err
function Cards.revokeCard(uid)
    local card = CardModel.getCardByUid(uid)
    if not card then return false, 'CARD_NOT_FOUND' end

    local ok, err = CardModel.revoke(uid)
    if not ok then return false, err end

    ledger:append({
        accountId       = card.account_id,
        transactionType = TxType.CardRevoke,
        amount          = 0,
        meta            = {uid = uid},
    })

    return true, nil
end

return Cards
