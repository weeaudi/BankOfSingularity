---@diagnostic disable: undefined-field  -- component.gpu / component.beep are OC API extensions
--- casino/src/ui.lua
--- Full-colour slot machine renderer for a tier-3 GPU (160×50).
---
--- 5 reels.  Win condition: best consecutive run of identical symbols anywhere
--- across the reel strip (not just from the left):
---   5-in-a-row = SYM_MULT[sym] × costPerSpin         (full multiplier)
---   4-in-a-row = 25% of full, minimum 1× costPerSpin
---   3-in-a-row = 10% of full
---
--- Rigging: if the casino balance is below the cheapest possible win the
--- pre-roller re-rolls until no 3+ consecutive match exists, so the symbols
--- on screen literally never align when the house can't pay.
---
--- Public exports:
---   UI.new(config)   → UI instance
---   UI.SYM_MULT      → {100,50,25,10,5}  payout multiplier table (index = symbol rank)
---
--- Key UI states: idle → pin_entry → spin_select → waiting → spinning → results

---@class UIConfig
---@field costPerSpin integer  Cost per spin in cents
---@field maxSpins    integer  Max spins purchasable per session

---@class UI
---@field config        UIConfig
---@field state         string          Current UI state name
---@field selSpins      integer         Number of spins currently selected by player
---@field reelState     integer[]       Current symbol index shown on each reel (1–5)
---@field totalWon      integer         Running payout total for the current spin batch (cents)
---@field playerBalance integer|nil     Last known player balance (cents)
---@field statusMsg     string          Message shown in the "waiting" state
---@field buttons       table[]         Clickable button regions {x1,y1,x2,y2,tag}
---@field onButton      fun(tag:string)|nil   Called when a touch lands on a button
---@field onSessionDone fun()|nil             Called when the results screen auto-expires
local component = require('component')
local computer = require('computer')
local os = require('os')
local gpu = component.gpu
local common = require('common')

-- Optional beep card — gracefully absent if not installed.
local beepCard = nil
do
    local ok, bc = pcall(function() return component.beep end)
    if ok and bc then beepCard = bc end
end
local function beep(tbl) if beepCard then pcall(beepCard.beep, tbl) end end

-- ─── Sound effects ────────────────────────────────────────────────────────────
local function sndSpinStart() -- rising chirp before reels spin
    beep({[300] = 0.05});
    os.sleep(0.06)
    beep({[500] = 0.05});
    os.sleep(0.06)
    beep({[800] = 0.07});
    os.sleep(0.08)
end

local REEL_PITCHES = {660, 590, 520, 450, 390}
local function sndReelStop(r) -- clunk as each reel stops
    beep({[REEL_PITCHES[r] or 440] = 0.06});
    os.sleep(0.07)
end

local function sndWin(matchN)
    if matchN >= 5 then -- jackpot fanfare
        beep({[523] = 0.08, [659] = 0.08});
        os.sleep(0.09)
        beep({[784] = 0.08, [1047] = 0.08});
        os.sleep(0.09)
        beep({[523] = 0.07, [659] = 0.07, [784] = 0.07});
        os.sleep(0.08)
        beep({[1047] = 0.2, [1319] = 0.2});
        os.sleep(0.25)
    elseif matchN == 4 then -- 4-note ascending win
        beep({[523] = 0.07});
        os.sleep(0.08)
        beep({[659] = 0.07});
        os.sleep(0.08)
        beep({[784] = 0.07});
        os.sleep(0.08)
        beep({[1047] = 0.18});
        os.sleep(0.20)
    else -- 3-note mini win
        beep({[523] = 0.08});
        os.sleep(0.09)
        beep({[659] = 0.08});
        os.sleep(0.09)
        beep({[784] = 0.12});
        os.sleep(0.13)
    end
end

local function sndLose() -- wah-wah descend
    beep({[350] = 0.1});
    os.sleep(0.11)
    beep({[260] = 0.15});
    os.sleep(0.16)
end

local W, H = 160, 50
local NREELS = 5

-- Payout multiplier per symbol index (1 = rarest/best, 5 = commonest).
-- 5-in-a-row pays the full multiplier × costPerSpin; 4/3-in-a-row scale down.
local SYM_MULT = {100, 50, 25, 10, 5}

-- ─── Palette  (purple + green on pitch black) ────────────────────────────────
local C = {
    bg = 0x000000, -- pitch black
    hdrBg = 0x0d0022, -- deep purple header
    hdrFg = 0xCC44FF, -- vivid purple
    divFg = 0x440066, -- dark purple divider
    reelBg = 0x05000f, -- near-black with purple hint
    reelBdr = 0x7722BB, -- medium purple border
    reelFg = 0xDDDDDD, -- light symbol text
    winBg = 0x001a00, -- dark green win banner
    winFg = 0x00FF66, -- bright green win text
    lossFg = 0x664477, -- muted purple for no-match
    jackFg = 0xFF44FF, -- magenta/purple jackpot
    balFg = 0x00DD66, -- green balance
    infFg = 0x775588, -- muted purple-grey info
    btnBg = 0x0f0018, -- dark purple button bg
    btnFg = 0xAA77CC, -- light purple button text
    selBg = 0x00AA44, -- green selected
    selFg = 0x000000,
    playBg = 0x003322, -- dark green play button
    playFg = 0x88FF99, -- light green play text
    cancelBg = 0x1a0033, -- dark purple cancel button
    cancelFg = 0xDD88FF, -- light purple cancel text
    waitFg = 0xBB55FF, -- purple waiting
    white = 0xFFFFFF,
    mgray = 0x445544, -- slightly green-tinted grey
    red = 0xFF3333, -- errors only
    cyan = 0x00CC88, -- green-teal for balance display
    green = 0x00BB55, -- standard green
    orange = 0xBB44FF -- purple "break even"
}

-- ─── Layout ───────────────────────────────────────────────────────────────────
local SYM_W = 12
local SYM_H = 7
local REEL_W = SYM_W + 2 -- border cols
local REEL_H = SYM_H + 2 -- border rows
local GAP = 6
local REEL_Y = 4 -- top row of reel boxes (rows 4-12)

local REEL_X = {}
do
    local total = NREELS * REEL_W + (NREELS - 1) * GAP
    local sx = math.floor((W - total) / 2) + 1
    for r = 1, NREELS do REEL_X[r] = sx + (r - 1) * (REEL_W + GAP) end
end

local SPIN_ROW = REEL_Y + REEL_H + 1 -- row 15
local TOT_ROW = SPIN_ROW + 1 -- row 16
local CTX_Y = SPIN_ROW + 3 -- row 18

-- ─── Symbol metadata ─────────────────────────────────────────────────────────
-- Symbols are sorted ascending by weight in common.lua, so:
--   index 1 = rarest   (weight 1)
--   index 5 = commonest(weight 50)

-- Payout multipliers applied to costPerSpin:
--   5-in-a-row: SYM_MULT[sym] × costPerSpin   (full)
--   4-in-a-row: 25% of full,  min costPerSpin
--   3-in-a-row: 10% of full
local function payout(symIdx, matchCount, costPerSpin)
    local v = SYM_MULT[symIdx] or 1
    if matchCount >= 5 then
        return v * costPerSpin
    elseif matchCount == 4 then
        return math.max(costPerSpin, math.floor(v * costPerSpin * 0.25))
    elseif matchCount == 3 then
        return math.floor(v * costPerSpin * 0.10)
    end
    return 0
end

-- Find the best consecutive run of identical symbols anywhere across the reels.
-- Returns matchCount (0 if no win), symIdx of the winning symbol.
-- Tie-break: longer run wins; equal length → rarer symbol (lower index).
local function detectMatch(reels)
    local bestN, bestSym = 0, 0
    local i = 1
    while i <= #reels do
        local sym = reels[i]
        local n = 1
        while i + n <= #reels and reels[i + n] == sym do n = n + 1 end
        if n >= 3 then
            if n > bestN or (n == bestN and sym < bestSym) then
                bestN, bestSym = n, sym
            end
        end
        i = i + n
    end
    return bestN, bestSym
end

-- ─── GPU helpers ──────────────────────────────────────────────────────────────
local function fgbg(f, b)
    gpu.setForeground(f);
    gpu.setBackground(b)
end
local function at(x, y, s) gpu.set(x, y, s) end
local function fill(x, y, w, h, ch) gpu.fill(x, y, w, h, ch or ' ') end

local function ctr(s, y, f, b, width, x0)
    width = width or W;
    x0 = x0 or 1
    local x = x0 + math.max(0, math.floor((width - #s) / 2))
    if f then fgbg(f, b or C.bg) end
    at(x, y, s)
    return x
end

local function money(n)
    if n == nil then return '??' end
    local abs = math.abs(n)
    return (n < 0 and '-' or '') .. '$' ..
               string.format('%d.%02d', math.floor(abs / 100), abs % 100)
end

local function wrap(n, a, b) return ((n - a) % (b - a + 1)) + a end

-- ─── Reel rendering ───────────────────────────────────────────────────────────

local function drawReelBorders()
    fgbg(C.reelBdr, C.reelBg)
    for r = 1, NREELS do
        local x, y = REEL_X[r], REEL_Y
        at(x, y, '┌' .. string.rep('─', SYM_W) .. '┐')
        at(x, y + REEL_H - 1, '└' .. string.rep('─', SYM_W) .. '┘')
        for row = 1, SYM_H do
            at(x, y + row, '│')
            at(x + REEL_W - 1, y + row, '│')
        end
    end
end

local function drawSymLines(reel, symIdx, fromL, toL, screenY)
    local x = REEL_X[reel] + 1
    local sym = common.symbols[symIdx]
    fgbg(C.reelFg, C.reelBg)
    local off = 0
    for i = fromL, toL do
        if sym.image[i] then at(x, screenY + off, sym.image[i]) end
        off = off + 1
    end
end

local function clearReel(reel)
    fgbg(C.reelFg, C.reelBg)
    fill(REEL_X[reel] + 1, REEL_Y + 1, SYM_W, SYM_H)
end

local function drawReelSym(reel, symIdx)
    clearReel(reel)
    drawSymLines(reel, symIdx, 1, SYM_H, REEL_Y + 1)
end

-- Animate one symbol advance (old scrolls down, new enters from top).
local function advanceOne(reel, prevSym, nextSym)
    local y = REEL_Y + 1
    local x = REEL_X[reel] + 1
    for t = 1, SYM_H + 1 do
        if t <= SYM_H then
            fgbg(C.reelFg, C.reelBg);
            fill(x, y + t - 1, SYM_W, 1)
        end
        if SYM_H - t >= 1 then
            drawSymLines(reel, prevSym, 1, SYM_H - t, y + t)
        end
        if SYM_H - t + 2 <= SYM_H then
            drawSymLines(reel, nextSym, SYM_H - t + 2, SYM_H, y)
        end
        if t == SYM_H + 1 then drawSymLines(reel, nextSym, 1, SYM_H, y) end
        if t % 3 == 0 then os.sleep(1 / 15) end
    end
end

local function spinReelTo(reel, curSym, targetSym, minIter)
    local state, count = curSym, 0
    while count < minIter or state ~= targetSym do
        local nxt = wrap(state + 1, 1, #common.symbols)
        advanceOne(reel, state, nxt)
        state = nxt;
        count = count + 1
    end
    return state
end

-- ─── UI class ─────────────────────────────────────────────────────────────────

local UI = {}
UI.__index = UI

function UI.new(config)
    local self = setmetatable({}, UI)
    self.config = config
    self.state = 'idle'
    self.selSpins = math.min(5, config.maxSpins)
    self.reelState = {}
    for r = 1, NREELS do self.reelState[r] = r end
    self.totalWon = 0
    self.playerBalance = nil
    self.doneAt = nil
    self.statusMsg = ''
    self.buttons = {}
    self.onButton = nil
    self.onSessionDone = nil
    return self
end

-- ─── Public state transitions ─────────────────────────────────────────────────

function UI:showIdle()
    self.state = 'idle'
    self.totalWon = 0
    self.doneAt = nil
    self.playerBalance = nil
    self:draw()
end

function UI:showPinEntry()
    self.state = 'pin_entry'
    self:draw()
end

function UI:showSpinSelect(balance)
    self.state = 'spin_select'
    self.playerBalance = balance
    self:draw()
end

function UI:showWaiting(msg)
    self.state = 'waiting'
    self.statusMsg = msg or 'Please wait...'
    self:draw()
end

--- Run all spins (BLOCKING). Returns totalWon.
function UI:runSpins(spinCount, costPerSpin, casinoCanCover)
    self.state = 'spinning'
    self.totalWon = 0
    math.randomseed(os.time())

    -- Weighted sampler
    local function sample()
        local tot = 0
        for _, s in ipairs(common.symbols) do tot = tot + s.weight end
        local r = math.random() * tot
        for i, s in ipairs(common.symbols) do
            r = r - s.weight
            if r <= 0 then return i end
        end
        return #common.symbols
    end

    -- Pre-roll all results.
    -- If the casino can't afford even the cheapest win, force non-matching reels
    -- so the symbols on screen literally never align.
    local minAnyWin =
        math.floor((SYM_MULT[#SYM_MULT] or 1) * costPerSpin * 0.10)
    local results = {}
    local accWon = 0
    for i = 1, spinCount do
        local reels = {}
        local canWin = (casinoCanCover - accWon) >= minAnyWin
        if canWin then
            for r = 1, NREELS do reels[r] = sample() end
        else
            -- Keep re-rolling until no consecutive match exists
            local tries = 0
            repeat
                for r = 1, NREELS do reels[r] = sample() end
                tries = tries + 1
            until detectMatch(reels) == 0 or tries > 200
        end
        local matchN, matchSym = detectMatch(reels)
        local prize = 0
        if matchN >= 3 then
            prize = math.min(payout(matchSym, matchN, costPerSpin),
                             casinoCanCover - accWon)
        end
        accWon = accWon + prize
        results[i] = {
            reels = reels,
            matchN = matchN,
            matchSym = matchSym,
            prize = prize
        }
    end

    self:_drawHeader()
    self:_drawReelArea()
    self:_drawSpinCounter(0, spinCount)
    self:_drawTotals(spinCount, costPerSpin)
    self:_drawPaytableCtx()

    for i, res in ipairs(results) do
        self:_drawSpinCounter(i, spinCount)
        sndSpinStart()

        -- Staggered stop: reel 1 longest, reel 5 shortest
        local n = #common.symbols
        local minIters = {n * 2, n + n // 2, n, n // 2 + 2, n // 2}
        for r = 1, NREELS do
            self.reelState[r] = spinReelTo(r, self.reelState[r], res.reels[r],
                                           minIters[r])
            sndReelStop(r)
        end

        drawReelBorders() -- animation may nick border pixels

        local prize = res.prize -- already capped during pre-roll
        self.totalWon = self.totalWon + prize

        if res.matchN >= 3 and prize > 0 then
            self:_flashWin(res.matchN, prize)
        else
            self:_flashLose()
        end

        self:_drawTotals(spinCount, costPerSpin)
        os.sleep(0.8)
    end

    return self.totalWon
end

function UI:showResults(spinCount, costPerSpin, payoutAmt, payErr)
    self.state = 'results'
    self.doneAt = computer.uptime() + 8
    self:_drawResults(spinCount, costPerSpin, payoutAmt, payErr)
end

function UI:tick()
    if self.state == 'results' and self.doneAt and computer.uptime() >=
        self.doneAt then
        self.doneAt = nil
        if self.onSessionDone then self.onSessionDone() end
    end
end

-- ─── Touch handling ───────────────────────────────────────────────────────────

function UI:onTouch(x, y)
    for _, btn in ipairs(self.buttons) do
        if x >= btn.x1 and x <= btn.x2 and y >= btn.y1 and y <= btn.y2 then
            if self.onButton then self.onButton(btn.tag) end
            return
        end
    end
end

-- ─── Draw dispatch ────────────────────────────────────────────────────────────

function UI:_drawCredit()
    fgbg(C.infFg, C.bg)
    ctr('Made by Aidcraft & Dos54', H, C.infFg, C.bg)
end

function UI:draw()
    fgbg(C.white, C.bg);
    fill(1, 1, W, H)
    if self.state == 'idle' then
        self:_drawIdle()
    elseif self.state == 'pin_entry' then
        self:_drawPinEntry()
    elseif self.state == 'spin_select' then
        self:_drawSpinSelect()
    elseif self.state == 'waiting' then
        self:_drawWaiting()
    elseif self.state == 'spinning' then
        self:_drawSpinning()
    end
    self:_drawCredit()
end

-- ─── Shared sub-draws ─────────────────────────────────────────────────────────

function UI:_drawHeader(right)
    fgbg(C.hdrFg, C.hdrBg);
    fill(1, 1, W, 1)
    ctr('  ♦  Hecusino SLOTS  ♦  ', 1, C.hdrFg, C.hdrBg)
    if right and right ~= '' then
        fgbg(C.cyan, C.hdrBg);
        at(W - #right, 1, right)
    end
    fgbg(C.divFg, C.bg);
    at(1, 2, string.rep('═', W))
    fgbg(C.white, C.bg);
    fill(1, 3, W, 1)
end

function UI:_drawReelArea()
    fgbg(C.reelFg, C.reelBg)
    local rx1 = REEL_X[1] - 2
    local rw = REEL_X[NREELS] + REEL_W + 2 - rx1
    fill(rx1, REEL_Y - 1, rw, REEL_H + 2)
    drawReelBorders()
    for r = 1, NREELS do drawReelSym(r, self.reelState[r]) end
end

function UI:_drawSpinCounter(current, total)
    fgbg(C.infFg, C.bg);
    fill(1, SPIN_ROW, W, 1)
    if total > 0 then
        ctr('Spin ' .. current .. ' / ' .. total, SPIN_ROW, C.infFg, C.bg)
    end
end

function UI:_drawTotals(spinCount, costPerSpin)
    fgbg(C.white, C.bg);
    fill(1, TOT_ROW, W, 1)
    local cost = spinCount * costPerSpin
    local net = self.totalWon - cost
    local wonS = 'Won: ' .. money(self.totalWon)
    local cstS = '   Cost: ' .. money(cost) .. '   Net: '
    local netS = (net >= 0 and '+' or '') .. money(net)
    local full = wonS .. cstS .. netS
    local sx = math.floor((W - #full) / 2) + 1
    fgbg(C.green, C.bg);
    at(sx, TOT_ROW, wonS)
    fgbg(C.infFg, C.bg);
    at(sx + #wonS, TOT_ROW, cstS)
    fgbg(net >= 0 and C.green or C.red, C.bg)
    at(sx + #wonS + #cstS, TOT_ROW, netS)
end

function UI:_flashWin(matchN, prize)
    local tag = matchN == 5 and '★ JACKPOT! ' or (matchN .. '-in-a-row! ')
    local msg = '  ' .. tag .. '+' .. money(prize) .. '  '
    fgbg(C.winFg, C.winBg);
    fill(1, TOT_ROW + 1, W, 1)
    ctr(msg, TOT_ROW + 1, C.winFg, C.winBg)
    sndWin(matchN)
    os.sleep(0.3)
    fgbg(C.white, C.bg);
    fill(1, TOT_ROW + 1, W, 1)
end

function UI:_flashLose()
    ctr('no match', TOT_ROW + 1, C.lossFg, C.bg)
    sndLose()
    os.sleep(2.7)
    fgbg(C.white, C.bg);
    fill(1, TOT_ROW + 1, W, 1)
end

-- ─── Paytable helper + shared view ───────────────────────────────────────────

local function fmtMult(v, factor, cost)
    local m = (factor == 1) and (v * cost) or
                  math.max(0, math.floor(v * cost * factor))
    return string.format('%5dx', m // cost)
end

-- visual width of the paytable title (each ─ = 1 col, not 3 bytes)
local PTITLE =
    '─────────────────────  PAYTABLE  ─────────────────────'
local PTITLE_VW = 54 -- 21 + 12 + 21

-- Draws the paytable into the context area starting at CTX_Y.
function UI:_drawPaytableCtx()
    local y = CTX_Y
    local cost = self.config.costPerSpin
    fgbg(C.divFg, C.bg);
    fill(1, y, W, H - y + 1)

    local hdr = string.format('  %-3s  %-6s  %-14s  %-14s  %-14s', 'SYM',
                              'VALUE', '5 in a row', '4 in a row', '3 in a row')
    local tblX = math.floor((W - #hdr) / 2) + 1
    fgbg(C.hdrFg, C.bg);
    at(math.floor((W - PTITLE_VW) / 2) + 1, y, PTITLE)
    y = y + 1

    fgbg(C.infFg, C.bg);
    at(tblX, y, hdr)
    y = y + 1

    for i in ipairs(common.symbols) do
        local v = SYM_MULT[i] or 1
        local row = string.format('  %3s  %5dx  %14s  %14s  %14s',
                                  '[' .. i .. ']', v, fmtMult(v, 1, cost),
                                  fmtMult(v, 0.25, cost), fmtMult(v, 0.10, cost))
        local rowC = (i == 1) and C.jackFg or (i == 2) and C.hdrFg or C.infFg
        fgbg(rowC, C.bg)
        at(tblX, y, row)
        y = y + 1
    end
end

-- ─── Screen implementations ───────────────────────────────────────────────────

function UI:_drawIdle()
    self:_drawHeader()
    self:_drawReelArea()
    fgbg(C.white, C.bg);
    fill(1, SPIN_ROW, W, 2)

    local y = CTX_Y
    local cost = self.config.costPerSpin

    -- Paytable header
    local hdr = string.format('  %-3s  %-6s  %-14s  %-14s  %-14s', 'SYM',
                              'VALUE', '5 in a row', '4 in a row', '3 in a row')
    local tblX = math.floor((W - #hdr) / 2) + 1
    fgbg(C.hdrFg, C.bg);
    at(math.floor((W - PTITLE_VW) / 2) + 1, y, PTITLE)
    y = y + 1

    -- Column header
    fgbg(C.infFg, C.bg);
    at(tblX, y, hdr)
    y = y + 1

    for i in ipairs(common.symbols) do
        local v = SYM_MULT[i] or 1
        local row = string.format('  %3s  %5dx  %14s  %14s  %14s',
                                  '[' .. i .. ']', v, fmtMult(v, 1, cost),
                                  fmtMult(v, 0.25, cost), fmtMult(v, 0.10, cost))

        local rowC = (i == 1) and C.jackFg or (i == 2) and C.hdrFg or C.infFg
        fgbg(rowC, C.bg)
        at(tblX, y, row)
        y = y + 1
    end

    y = y + 1
    local sep56 = string.rep('─', 56)
    fgbg(C.divFg, C.bg);
    at(math.floor((W - 56) / 2) + 1, y, sep56)
    y = y + 2

    ctr('Swipe your bank card to begin', y, C.white, C.bg)
    fgbg(C.infFg, C.bg)
    ctr(money(cost) .. ' per spin  |  up to ' .. self.config.maxSpins ..
            ' spins', y + 2, C.infFg, C.bg)

    local jackMult = SYM_MULT[1]
    fgbg(C.jackFg, C.bg)
    ctr('JACKPOT  ' .. jackMult .. '× = ' .. money(jackMult * cost) ..
            ' per spin', y + 4, C.jackFg, C.bg)
end

function UI:_drawPinEntry()
    self:_drawHeader()
    self:_drawReelArea()
    ctr('Card detected — enter PIN on the keypad', CTX_Y + 3, C.white, C.bg)
    ctr('# = confirm     * = backspace / cancel', CTX_Y + 5, C.infFg, C.bg)
end

function UI:_drawSpinSelect()
    local bal = self.playerBalance or 0
    local right = ' Balance: ' .. money(bal) .. ' '
    self:_drawHeader(right)
    self:_drawReelArea()
    self.buttons = {}

    local y = CTX_Y
    local cost = self.config.costPerSpin
    ctr('How many spins?', y, C.white, C.bg)
    y = y + 2

    -- Spin-count picker
    local maxS = self.config.maxSpins
    local btnW = 6
    local total = maxS * btnW + (maxS - 1)
    local bx0 = math.floor((W - total) / 2) + 1
    for i = 1, maxS do
        local bx = bx0 + (i - 1) * (btnW + 1)
        local sel = (i == self.selSpins)
        fgbg(sel and C.selFg or C.btnFg, sel and C.selBg or C.btnBg)
        at(bx, y, string.format(' %-4d ', i))
        table.insert(self.buttons, {
            x1 = bx,
            y1 = y,
            x2 = bx + btnW - 1,
            y2 = y,
            tag = 'sel:' .. i
        })
    end
    y = y + 2

    local spinCost = self.selSpins * cost
    local maxPay = self.selSpins * SYM_MULT[1] * cost
    fgbg(C.cyan, C.bg);
    ctr('Cost: ' .. money(spinCost), y, C.cyan, C.bg)
    fgbg(C.infFg, C.bg);
    ctr('Max possible payout: ' .. money(maxPay), y + 1, C.infFg, C.bg)

    -- 5-reel payline reminder
    fgbg(C.mgray, C.bg)
    ctr(
        '3-in-a-row = 10%   4-in-a-row = 25%   5-in-a-row = 100% of symbol value',
        y + 2, C.mgray, C.bg)

    local canPlay = (bal >= spinCost)
    if not canPlay then ctr('Insufficient balance', y + 3, C.red, C.bg) end
    y = y + 5

    -- PLAY button
    local playLbl = '  PLAY  (' .. self.selSpins .. ' spins — ' ..
                        money(spinCost) .. ')  '
    local px = math.floor((W - #playLbl) / 2) + 1
    fgbg(canPlay and C.playFg or C.infFg, canPlay and C.playBg or C.mgray)
    at(px, y, playLbl)
    if canPlay then
        table.insert(self.buttons, {
            x1 = px,
            y1 = y,
            x2 = px + #playLbl - 1,
            y2 = y,
            tag = 'play'
        })
    end

    -- CANCEL button
    local clbl = '  Cancel  '
    local cx = math.floor((W - #clbl) / 2) + 1
    fgbg(C.cancelFg, C.cancelBg)
    at(cx, y + 2, clbl)
    table.insert(self.buttons, {
        x1 = cx,
        y1 = y + 2,
        x2 = cx + #clbl - 1,
        y2 = y + 2,
        tag = 'cancel'
    })
end

function UI:_drawWaiting()
    self:_drawHeader()
    self:_drawReelArea()
    ctr(self.statusMsg, CTX_Y + 3, C.waitFg, C.bg)
end

function UI:_drawSpinning()
    self:_drawHeader()
    self:_drawReelArea()
    self:_drawSpinCounter(0, 0)
    fgbg(C.white, C.bg);
    fill(1, TOT_ROW, W, 1)
    self:_drawPaytableCtx()
end

function UI:_drawResults(spinCount, costPerSpin, payoutAmt, payErr)
    local cost = spinCount * costPerSpin
    local net = payoutAmt - cost
    self:_drawHeader()
    self:_drawReelArea()
    fgbg(C.white, C.bg);
    fill(1, SPIN_ROW, W, H - SPIN_ROW + 1)

    local y = CTX_Y
    if net > 0 then
        fgbg(C.winFg, C.winBg);
        fill(1, y, W, 1)
        ctr('  ★  YOU WIN!   NET +' .. money(net) .. '  ★  ', y, C.winFg,
            C.winBg)
    elseif net == 0 then
        ctr('Break even!', y, C.orange, C.bg)
    else
        ctr('Better luck next time', y, C.infFg, C.bg)
        ctr('Net: ' .. money(net), y + 1, C.red, C.bg)
    end

    y = y + 3
    fgbg(C.infFg, C.bg)
    ctr(
        'Spins: ' .. spinCount .. '   Won: ' .. money(payoutAmt) .. '   Cost: ' ..
            money(cost), y, C.infFg, C.bg)

    y = y + 2
    if payErr then
        ctr('Payout error: ' .. tostring(payErr), y, C.red, C.bg)
    elseif payoutAmt > 0 then
        ctr('Winnings transferred to your account', y, C.cyan, C.bg)
    end

    fgbg(C.mgray, C.bg)
    ctr('Session ends in 8 seconds', y + 2, C.mgray, C.bg)
end

UI.SYM_MULT = SYM_MULT

return UI
