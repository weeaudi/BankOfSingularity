local db = require('src.db.database')

---@enum CardStatus
local CardStatus = {Active = 0, Inactive = 1, Revoked = 2}

---@class Card
---@field uid string
---@field cardData string
---@field accountId integer
---@field status CardStatus

local Card = {}
Card.__index = Card

---@param card Card
function Card.issueCard(card) end

return Card
