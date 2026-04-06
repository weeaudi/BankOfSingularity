-- Price catalog: maps ME item key (name#damage) → price + label
-- -1 = unset (not listed), 0 = free, >0 = price in cents
-- Label is stored when a price is set so out-of-stock items still show their name.
local serialization = require('serialization')

local CATALOG_PATH = '/shop/catalog.dat'

local Catalog = {}

local prices = {}
local labels = {}

local function persist()
    local f = io.open(CATALOG_PATH, 'w')
    if f then
        f:write(serialization.serialize({prices = prices, labels = labels}))
        f:close()
    end
end

function Catalog.load()
    local f = io.open(CATALOG_PATH, 'r')
    if not f then
        prices = {}
        labels = {}
        return
    end
    local content = f:read('*a')
    f:close()
    local ok, data = pcall(serialization.unserialize, content)
    if not ok or type(data) ~= 'table' then
        prices = {}
        labels = {}
        return
    end
    -- New format: {prices={...}, labels={...}}
    if data.prices then
        prices = data.prices
        labels = data.labels or {}
    else
        -- Old format: plain prices table (backwards compat)
        prices = data
        labels = {}
    end
end

--- Get the price for an item key. Returns -1 if not set.
---@param key string
---@return number
function Catalog.getPrice(key) return prices[key] or -1 end

--- Get the stored display label for an item key. Returns nil if unknown.
---@param key string
---@return string|nil
function Catalog.getLabel(key) return labels[key] end

--- Set the price (and optionally cache the label) for an item key.
--- Pass price = -1 to unlist. Label is kept even when unlisted.
---@param key string
---@param price number
---@param label string|nil
function Catalog.setPrice(key, price, label)
    prices[key] = price
    if label then labels[key] = label end
    persist()
end

--- Cache a display label for a key without changing its price.
--- Called opportunistically when an item is seen in the ME network.
---@param key string
---@param label string
function Catalog.setLabel(key, label)
    if labels[key] == label then return end -- no-op if unchanged
    labels[key] = label
    persist()
end

--- Returns all items with price >= 0 (listed for sale).
---@return table<string, number>
function Catalog.getListed()
    local result = {}
    for key, price in pairs(prices) do
        if price >= 0 then result[key] = price end
    end
    return result
end

--- Returns all price entries including unset (-1) ones.
---@return table<string, number>
function Catalog.getAll()
    local copy = {}
    for k, v in pairs(prices) do copy[k] = v end
    return copy
end

Catalog.load()

return Catalog
