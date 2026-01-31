local CardModel = require('src.models.Card')
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

return Cards
