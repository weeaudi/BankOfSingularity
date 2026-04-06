---@diagnostic disable: undefined-field  -- OC API extensions (gpu.*)
--- casino/slots.lua
--- Legacy standalone slot machine — 3 reels, no bank integration.
---
--- This is the original prototype renderer. It runs directly on a GPU/screen
--- without any network calls. Kept for reference; the live machine uses
--- main.lua + src/ui.lua instead.
---
--- Controls: just run the file — it loops until a winning spin lands.

local comp = require("component")
local gpu = comp.gpu

local ROOT = '/casino'
package.path = ROOT .. '/?.lua;' .. package.path

local common = require("common")

--- Set to false to suppress all GPU draw calls (useful for headless testing).
local DRAW = true

--- Pick a random symbol index weighted by each symbol's `weight` field.
--- Higher weight = more likely to be chosen.
---@return integer symIdx  1-based index into common.symbols
local function sampleWeighted()
    local entries = {}

    for i, v in pairs(common.symbols) do
        table.insert(entries, {index = i, value = v})
    end

    table.sort(entries,
               function(a, b) return a.value.weight < b.value.weight end)

    local sum = 0

    for i = 1, #common.symbols do sum = sum + common.symbols[i].weight end

    local r = math.random() * sum

    for i, entry in pairs(common.symbols) do
        sum = sum - entry.weight

        if r >= sum then return i end
    end

    error("Error getting weighted roll")
end

--- Render the static ASCII backdrop to the GPU.
local function drawBackground()
    if DRAW then
        local i = 1

        for line in string.gmatch(common.background, "([^\n]+)\n?") do
            gpu.set(0, i, line)
            i = i + 1
        end
    end
end

--- Print a centred status string in the text area row.
---@param s string
local function drawText(s)
    if DRAW then gpu.set(math.floor((52 - s:len()) / 2), 15, s) end
end

--- Draw a subset of symbol lines at (x, y).
--- `from`/`to` default to the full symbol height and are used during scroll
--- animation to render only the visible portion of a symbol.
---@param x     integer  Left column
---@param y     integer  Top row
---@param image string[] Pre-split line array from common.symbols[i].image
---@param from  integer|nil  First line index to draw (default 1)
---@param to    integer|nil  Last line index to draw (default symbol height)
local function drawSymbol(x, y, image, from, to)
    if DRAW then
        from = from or 1
        to = to or common.symbol.height

        local offset = 0

        for i = from, to do
            gpu.set(x, y + offset, image[i])
            offset = offset + 1
        end
    end
end

local function wrap(n, a, b) return ((n - a) % (b - a + 1)) + a end

local function playWinAnimation(states, flashCount)
    local foreground = gpu.getForeground()
    local background = gpu.getBackground()

    local increment = common.symbol.width + common.symbol.padding

    for _ = 1, flashCount or 3 do
        gpu.setForeground(0x00)
        gpu.setBackground(0xff)

        for reel = 1, #states do
            drawSymbol(common.symbol.x + ((reel - 1) * increment),
                       common.symbol.y, common.symbols[states[reel]].image)
        end

        os.sleep(1 / 10)

        gpu.setForeground(0xff)
        gpu.setBackground(0x00)

        for reel = 1, #states do
            drawSymbol(common.symbol.x + ((reel - 1) * increment),
                       common.symbol.y, common.symbols[states[reel]].image)
        end

        os.sleep(1 / 10)
    end

    gpu.setForeground(foreground)
    gpu.setBackground(background)
end

local function advanceReel(states, frameCount, startReel)
    frameCount = frameCount or 0
    startReel = startReel or 1

    for reel = startReel, 3 do
        states[reel] = wrap(states[reel] + 1, 1, #common.symbols)
    end

    for t = 1, common.symbol.height + 1 do
        local doRenderFrame = (frameCount % 3 == 0)

        for reel = startReel, 3 do
            if doRenderFrame or t > common.symbol.height then
                local i = wrap(states[reel] - 1, 1, #common.symbols)
                local j = states[reel]

                local x = common.symbol.x +
                              ((reel - 1) *
                                  (common.symbol.width + common.symbol.padding))

                if t > 0 and t < common.symbol.height + 1 then
                    gpu.fill(x, common.symbol.y + t - 1, common.symbol.width, 1,
                             " ")
                end

                ---@diagnostic disable-next-line: param-type-mismatch
                drawSymbol(x, common.symbol.y + t, common.symbols[i].image,
                           nil, common.symbol.height - t)
                ---@diagnostic disable-next-line: param-type-mismatch
                drawSymbol(x, common.symbol.y, common.symbols[j].image,
                           common.symbol.height - t + 2, nil)
            end
        end

        if doRenderFrame then os.sleep(1 / 12) end

        frameCount = frameCount + 1
    end

    return frameCount
end

local function roll()
    local results = {}
    local states = {}
    local isWin = true

    for i = 1, 3 do
        results[i] = sampleWeighted()
        states[i] = math.random(1, #common.symbols)

        if i ~= 1 and results[1] ~= results[i] then isWin = false end
    end

    local frameCount = 0

    for reel = 1, 3 do
        local currentRollIteration = 0
        local stopAfterIteration = #common.symbols

        if reel == 1 then
            stopAfterIteration = stopAfterIteration * 2
        else
            stopAfterIteration = stopAfterIteration / 2
        end

        while currentRollIteration < stopAfterIteration or states[reel] ~=
            results[reel] do
            frameCount = advanceReel(states, frameCount, reel)
            currentRollIteration = currentRollIteration + 1
        end
    end

    if isWin then
        local multiplier = common.symbols[results[1]].value

        drawText(string.format("You won %dx your bet!", multiplier))
        playWinAnimation(states, 5)

        return multiplier
    else
        drawText("Loser!")
        return nil
    end
end

local function main()
    drawBackground()

    while not roll() do end
end

main()
