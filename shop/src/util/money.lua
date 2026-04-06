-- Money utility: integer cents ↔ display strings.
-- All amounts in DB/RPC are integers representing cents.
-- 100 = $1.00,  50 = $0.50,  0 = FREE

local Money = {}

--- Format cents as a dollar string.  e.g. 150 → "$1.50", -50 → "-$0.50"
---@param cents number|nil
---@return string
function Money.fmt(cents)
    if cents == nil then return '$-.--' end
    local sign    = cents < 0 and '-' or ''
    local abs     = math.abs(math.floor(cents))
    local dollars = math.floor(abs / 100)
    local c       = abs % 100
    return sign .. '$' .. dollars .. '.' .. string.format('%02d', c)
end

--- Format cents compactly for tight spaces.  e.g. 150 → "$1.50", 0 → "FREE"
---@param cents number|nil
---@return string
function Money.short(cents)
    if cents == nil then return '?.??' end
    if cents == 0   then return 'FREE' end
    return Money.fmt(cents)
end

--- Parse a digit-only string (entered via numpad) as cents.
--- The string is always treated as a plain integer number of cents.
--- e.g. "150" → 150 cents ($1.50), "1000" → 1000 cents ($10.00)
---@param str string
---@return number|nil
function Money.parseCents(str)
    local n = tonumber(str)
    return n and math.floor(n) or nil
end

return Money
