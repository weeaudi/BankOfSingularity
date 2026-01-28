local card = require('src.models.Card')
local protocol = require('shared.src.protocol')
local Services = {}

---@param accountId integer
---@return boolean success
---@return any
function Services.cards.getCardsByAccountId(accountId)
    local cardsList = card.getCardsByAccountId(accountId)
    if cardsList and #cardsList < 1 then return false, 'NO_CARDS_FOUND' end
    return true, cardsList
end

return Services
