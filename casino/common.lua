--- casino/common.lua
--- Shared asset and symbol data for the slot machine.
---
--- Contains:
---   - `background`  ASCII art backdrop string (used by the legacy slots.lua renderer)
---   - `symbol`      Layout constants (width, height, screen position, padding)
---   - `symbols`     Ordered array of reel symbols, sorted ascending by weight
---                   (index 1 = rarest, index N = most common)
---
--- Symbol fields:
---   image   {string[]}  Pre-split array of display lines (processed from raw block string)
---   value   number      Base multiplier used by the paytable (before match-count scaling)
---   weight  number      Relative probability of landing on this symbol (lower = rarer)
---
--- NOTE: symbols are sorted by weight at load time so callers can rely on
---       index 1 always being the jackpot symbol.

---@class Symbol
---@field image  string[]  Display lines for the GPU renderer
---@field value  number    Base payout multiplier
---@field weight number    Spawn weight (lower = rarer)

---@class SymbolLayout
---@field width   integer  Character width of one symbol cell
---@field height  integer  Character height of one symbol cell
---@field x       integer  Left column where symbols are drawn on screen
---@field y       integer  Top row where symbols are drawn on screen
---@field padding integer  Gap between adjacent symbol cells

---@class CommonModule
---@field background string      Raw ASCII art backdrop (newline-separated)
---@field symbol     SymbolLayout Layout constants
---@field symbols    Symbol[]    Reel symbol definitions, sorted by weight ascending

local module = {
    background = [[
 /‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\
/               AAAAAAAA TEXT AREA               \
|             I LOVE GAMBLING!!!!!!!             |
|                                                |
| ______________________________________________ |
||               |              |               ||
||               |              |               ||
||               |              |               ||
||               |              |               ||
||               |              |               ||
||               |              |               ||
||               |              |               ||
||‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾||
||\ /\ /\ /\ /\ /\ /\ /\||/\ /\ /\ /\ /\ /\ /\ /||
|| X  X  X  X  X  X  X  ||  X  X  X  X  X  X  X ||
||/ \/ \/ \/ \/ \/ \/ \/||\/ \/ \/ \/ \/ \/ \/ \||
]],
    symbol = {width = 12, height = 7, x = 5, y = 6, padding = 3},
    symbols = {
        {
            image = [[
############
#          #
#     |    #
#     |    #
#     |    #
#          #
############
]],
            value = 999,
            weight = 1
        }, {
            image = [[
############
#    _     #
#   / \    #
#    _/    #
#   |__    #
#          #
############
]],
            value = 99,
            weight = 6
        }, {
            image = [[
############
#          #
#   ---    #
#    _|    #
#   __|    #
#          #
############
]],
            value = 25,
            weight = 14.794
        }, {
            image = [[
############
#          #
#  |  |    #
#   --|    #
#     |    #
#          #
############
]],
            value = 10,
            weight = 35
        }, {
            image = [[
############
#          #
#   ---    #
#   |_     #
#   __|    #
#          #
############
]],
            value = 5,
            weight = 50
        }
    }
}

-- Sort ascending by weight so index 1 is always the rarest (jackpot) symbol.
table.sort(module.symbols, function(a, b) return a.weight < b.weight end)

--- Strip leading/trailing newlines from a block string.
---@param s string
---@return string
local function strip(s) return (s:gsub("^\n*(.-)\n*$", "%1")) end

--- Split a newline-delimited string into an array of lines.
---@param s string
---@return string[]
local function toLines(s)
    local icon = {}
    for line in s:gmatch("%s*([^\n]+)\n?") do table.insert(icon, line) end
    return icon
end

module.background = strip(module.background)

-- Convert each symbol's raw block string image into a pre-split line array.
for _, symbol in pairs(module.symbols) do
    symbol.image = toLines(strip(symbol.image --[[@as string]]))
end

return module
