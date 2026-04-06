---@diagnostic disable: unused-local  -- reason/newCardUid are intentional stub params
--- bank/server/src/models/Card.lua
--- Low-level data-access layer for the `cards` table.
---
--- A Card is a physical payment card linked to one Account.  Statuses:
---   Active   (0) — can be used for authentication and transactions
---   Inactive (1) — issued but not yet activated (unused in current flow)
---   Revoked  (2) — permanently blocked; cannot be reactivated
---
--- PIN security: the card row stores `pin_hash` = base64(sha256(pin..salt))
--- where the salt is derived from the card's OC reader data at issue time.
--- The raw PIN is never stored server-side.

---@class Card
---@field id?        integer     Auto-assigned primary key (nil before DB insert)
---@field account_id integer     FK → Account.id
---@field uid        string      Unique OC card reader identifier (physical card UID)
---@field pin_hash   string      base64-encoded sha256(pin..salt)
---@field status     CardStatus  Current card status (Active=0, Inactive=1, Revoked=2)
---@field meta       table       Arbitrary metadata (e.g. last_used_at timestamp)

local db = require('src.db')

local Card = {}
Card.__index = Card
Card._tableName = 'cards'

---@enum CardStatus
Card.CardStatus = {Active = 0, Inactive = 1, Revoked = 2}

--- Insert a new card into the database
---@param card Card
---@return integer cardId
function Card.issueCard(card)
    local cardId = db.database.insert(Card._tableName, card)
    return cardId
end

--- Get a list of cards associated with an account id
---@param accountId integer The ID of the account being searched for
---@return Card[] An unordered list of Card objects
function Card.getCardsByAccountId(accountId)
    ---@type Card[]
    local cardsList = db.database.select(Card._tableName):where({
        account_id = accountId
    }):all()
    return cardsList
end

--- Set the status of a card
---@param cardUid string the Unique Identifier associated with the card
---@param newStatus CardStatus The new card status
---@return boolean ok
---@return string|nil error
function Card.setCardStatus(cardUid, newStatus)
    local numUpdated = db.database.update(Card._tableName, {uid = cardUid},
                                          {status = newStatus})
    if numUpdated == 0 then
        return false, 'Nothing was updated. Card UID may be incorrect.'
    end

    return true
end

---@param cardUid string
---@return Card|nil
function Card.getCardByUid(cardUid)
    return db.database.select(Card._tableName):where({uid = cardUid}):first()
end

---@param cardUid string
---@param reason string|nil The reason for revoking the card
---@return boolean success
---@return string|nil error 
function Card.revoke(cardUid, reason)
    return Card.setCardStatus(cardUid, Card.CardStatus.Revoked)
end

function Card.replaceCard(oldCardUid, newCardUid)

    Card.revoke(oldCardUid, 'Issued replacement card')
end

--- Check if the card associated with cardUid is usable or not
---@param cardUid string
---@return boolean|nil isUsable
---@return string|nil error
function Card.isUsable(cardUid)
    ---@type Card|nil
    local card = Card.getCardByUid(cardUid)
    if not card then return false, 'CARD_NOT_FOUND' end

    return card.status == Card.CardStatus.Active
end

---@param cardUid string
---@param pinHash string New base64-encoded SHA256(pin..salt)
---@return boolean success
---@return string|nil error
function Card.updatePin(cardUid, pinHash)
    local updated = db.database.update(Card._tableName, {uid = cardUid},
                                       {pin_hash = pinHash})
    if updated == 0 then return false, 'CARD_NOT_FOUND' end
    return true
end

--- Update meta.last_used_at for monitoring
---@param cardUid string
---@return boolean success
---@return string|nil error 
function Card.touchLastUsed(cardUid)
    local card = Card.getCardByUid(cardUid)

    if not card then return false, 'CARD_NOT_FOUND' end

    local meta = card.meta or {}
    local now = os.time()
    meta.last_used_at = now

    local updated = db.database.update(Card._tableName, {uid = cardUid},
                                       {meta = meta})
    if updated == 0 then return false, 'CARD_UPDATE_FAILED' end

    return true
end

return Card
