local db = require('src.db.database')
local ENV = require('env')

---@enum CardStatus
local CardStatus = {Active = 0, Inactive = 1, Revoked = 2}

---@class Card
---@field uid string
---@field card_data string
---@field account_id integer
---@field meta CardMetadata|nil
---@field status CardStatus

---@class CardMetadata
---@field revoked_reason string
---@field last_used_at number

local Card = {}
Card.__index = Card
Card._tableName = 'cards'

--- Insert a new card into the database
---@param card Card
---@return integer cardId
function Card.issueCard(card)
    local cardId = db.insert(Card._tableName, card)
    return cardId
end

--- Get a list of cards associated with an account id
---@param accountId integer The ID of the account being searched for
---@return Card[] An unordered list of Card objects
function Card.getCardsByAccountId(accountId)
    ---@type Card[]
    local cardsList = db.select(Card._tableName):where({account_id = accountId})
                          :all()
    return cardsList
end

--- Set the status of a card
---@param cardUid string the Unique Identifier associated with the card
---@param newStatus CardStatus The new card status
---@return boolean ok
---@return string|nil error
function Card.setCardStatus(cardUid, newStatus)
    local numUpdated = db.update(Card._tableName, {uid = cardUid},
                                 {status = newStatus})
    if numUpdated == 0 then
        return false, 'Nothing was updated. Card UID may be incorrect.'
    end

    return true
end

---@param cardUid string
---@return Card|nil
function Card.getCardByUid(cardUid)
    return db.select(Card._tableName):where({uid = cardUid}):first()
end

---@param cardUid string
---@param reason string|nil The reason for revoking the card
---@return boolean success
---@return string|nil error 
function Card.revoke(cardUid, reason)
    return Card.setCardStatus(cardUid, CardStatus.Revoked)
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

    return card.status == CardStatus.Active
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

    local updated = db.update(Card._tableName, {uid = cardUid}, {meta = meta})
    if updated == 0 then return false, 'CARD_UPDATE_FAILED' end

    return true
end

return Card
