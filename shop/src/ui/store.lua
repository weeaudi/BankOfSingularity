---@diagnostic disable: undefined-field  -- OC API extensions (gpu.*, computer.uptime)
-- Store UI: customer-facing touchscreen frontend.
-- Displays catalog items, manages a cart, handles checkout + dispensing.
local computer = require('computer')
local Inventory = require('src.inventory')
local Money = require('src.util.money')

-- ─── Colors ──────────────────────────────────────────────────────────────────
local C = {
    BG = 0x111111,
    HEADER_BG = 0x003366,
    HEADER_FG = 0xFFFFFF,
    ITEM_BG = 0x1a1a2e,
    ITEM_FG = 0xDDDDDD,
    ITEM_SEL = 0x0055AA,
    PRICE_FG = 0x44FF44,
    FREE_FG = 0xFFFF44,
    SOLD_FG = 0x666666,
    BTN_BG = 0x004488,
    BTN_FG = 0xFFFFFF,
    LOGOUT_BG = 0x882200,
    CHECKOUT_BG = 0x005522,
    CART_BG = 0x222233,
    CART_FG = 0xCCCCCC,
    TOTAL_FG = 0x44FF44,
    OV_BG = 0x000033,
    OV_FG = 0xFFFFFF,
    NUM_BG = 0x222266,
    NUM_FG = 0xFFFFFF,
    OK_BG = 0x005522,
    CANCEL_BG = 0x552200
}

-- ─── Layout constants ─────────────────────────────────────────────────────────
local COLS = 3 -- item columns
local ITEM_H = 4 -- rows per item cell (name + price + stock + gap)
local HEADER_H = 2 -- header rows
local FOOTER_H = 4 -- cart + checkout rows

local StoreUI = {}
StoreUI.__index = StoreUI

---@param gpu table
---@param catalog table  catalog module
---@param inventory table  inventory module
---@param posCore table  PosCore instance
function StoreUI.new(gpu, catalog, inventory, posCore)
    local self = setmetatable({}, StoreUI)
    self.gpu = gpu
    self.catalog = catalog
    self.inv = inventory
    self.posCore = posCore

    local W, H = gpu.getResolution()
    self.W = W
    self.H = H
    self.itemW = math.floor(W / COLS)
    self.itemRows = math.floor((H - HEADER_H - FOOTER_H) / ITEM_H)
    self.perPage = self.itemRows * COLS

    self.visible = false
    self.page = 1
    self.items = {} -- cached {key, label, size, price}
    self.cart = {} -- {key, label, quantity, unitPrice}
    self.buttons = {} -- hit-test regions: {x,y,w,h,id}

    -- Overlay state (qty input / cart management / checkout status)
    self.overlay = false
    self.overlayMode = nil -- 'qty' | 'cart' | 'status'
    self.qtyItem = nil
    self.qtyInput = ''
    self.overlayBtns = {}

    -- Auto-logout timer (set after successful purchase)
    self.logoutAt = nil

    return self
end

-- ─── Public API ───────────────────────────────────────────────────────────────

function StoreUI:show(balance)
    self.visible = true
    self.page = 1
    self.cart = {}
    self.balance = balance
    self.overlay = false
    self.overlayMode = nil
    self.logoutAt = nil
    self:_refresh()
end

--- Called each main loop iteration when this UI is active.
function StoreUI:tick(uptime)
    if self.logoutAt and uptime >= self.logoutAt then
        self.logoutAt = nil
        self.posCore:logout()
    end
end

function StoreUI:hide()
    self.visible = false
    self.cart = {}
    local g = self.gpu
    g.setBackground(0x000000)
    g.setForeground(0xFFFFFF)
    g.fill(1, 1, self.W, self.H, ' ')
end

function StoreUI:onTouch(x, y)
    if not self.visible then return end

    if self.overlay then
        if self.overlayMode == 'qty' then
            self:_handleQtyTouch(x, y)
        elseif self.overlayMode == 'warn' then
            self:_handleWarnTouch(x, y)
        elseif self.overlayMode == 'cart' then
            self:_handleCartTouch(x, y)
        elseif self.overlayMode == 'status' then -- tap to dismiss early
            self.logoutAt = computer.uptime() + 0.1
        end
        return
    end

    local id = self:_hit(x, y)
    if not id then return end

    if id == 'logout' then
        self.posCore:logout()

    elseif id == 'cart' then
        self:_openCartOverlay()

    elseif id == 'checkout' then
        self:_doCheckout()

    elseif id == 'prev' then
        if self.page > 1 then
            self.page = self.page - 1
            self:_draw()
        end

    elseif id == 'next' then
        local maxPage = math.ceil(#self.items / self.perPage)
        if self.page < maxPage then
            self.page = self.page + 1
            self:_draw()
        end

    elseif type(id) == 'number' then
        local item = self.items[id]
        if item and item.size > 0 then self:_openQtyOverlay(item) end
    end
end

--- Called by posCore.onPurchaseDone — update balance and handle dispensing.
--- Called by posCore.onPurchaseDone after the bank transfer succeeds.
--- newBalance is the customer's balance after the charge.
function StoreUI:onPurchaseDone(newBalance)
    self.balance = newBalance
    self.cart = {}
    self:_showStatusOverlay('Purchase complete!\nBalance: ' ..
                                Money.fmt(newBalance), 0x44FF44,
                            'Logging out in 3s...')
    self.logoutAt = computer.uptime() + 3
end

--- Called by posCore.onPurchaseFail.
function StoreUI:onPurchaseFail(code)
    self:_showStatusOverlay('Payment failed\n' .. code, 0xFF3300,
                            'Items dispensed — alert staff!')
    -- No auto-logout on failure so staff can investigate
end

-- ─── Private ─────────────────────────────────────────────────────────────────

function StoreUI:_refresh()
    self.items = Inventory.getListedWithStock(self.catalog)
    self:_draw()
end

function StoreUI:_draw()
    local g = self.gpu
    local W = self.W
    self.buttons = {}

    -- Header
    g.setBackground(C.HEADER_BG)
    g.setForeground(C.HEADER_FG)
    g.fill(1, 1, W, HEADER_H, ' ')
    local balStr = self.balance ~= nil and
                       ('Balance: ' .. Money.fmt(self.balance)) or
                       'Balance: ...'
    g.set(2, 1, 'Bank of Singularity  |  ' .. balStr)

    -- Logout button (top-right)
    local logoutW = 10
    local logoutX = W - logoutW + 1
    g.setBackground(C.LOGOUT_BG)
    g.set(logoutX, 1, '  LOGOUT  ')
    self:_addBtn(logoutX, 1, logoutW, HEADER_H, 'logout')

    -- Page indicator
    local maxPage = math.max(1, math.ceil(#self.items / self.perPage))
    g.setBackground(C.HEADER_BG)
    g.setForeground(0xAAAAAA)
    g.set(2, 2, ('Page %d / %d'):format(self.page, maxPage))

    -- Credit (top-right, row 2)
    local credit = 'Made by Aidcraft & Dos54'
    g.setForeground(0x7799AA)
    g.set(W - #credit, 2, credit)

    -- Item grid
    local startIdx = (self.page - 1) * self.perPage + 1
    local rowStart = HEADER_H + 1

    for row = 0, self.itemRows - 1 do
        for col = 0, COLS - 1 do
            local idx = startIdx + row * COLS + col
            local x = col * self.itemW + 1
            local y = rowStart + row * ITEM_H
            self:_drawItem(x, y, self.itemW, ITEM_H, idx)
        end
    end

    -- Cart / footer
    self:_drawFooter()
end

function StoreUI:_drawItem(x, y, w, h, idx)
    local g = self.gpu
    local item = self.items[idx]

    -- Background
    g.setBackground(item and C.ITEM_BG or C.BG)
    g.fill(x, y, w, h, ' ')

    if not item then return end

    local inStock = item.size > 0

    -- Name (line 1)
    g.setForeground(inStock and C.ITEM_FG or C.SOLD_FG)
    g.set(x + 1, y, item.label:sub(1, w - 2))

    -- Price (line 2)
    local priceStr
    if item.price == 0 then
        g.setForeground(C.FREE_FG)
        priceStr = 'FREE'
    else
        g.setForeground(inStock and C.PRICE_FG or C.SOLD_FG)
        priceStr = Money.fmt(item.price)
    end
    g.set(x + 1, y + 1, priceStr)

    -- Stock (line 3)
    if not inStock then
        g.setForeground(C.SOLD_FG)
        g.set(x + 1, y + 2, 'OUT OF STOCK')
    else
        g.setForeground(0x448844)
        g.set(x + 1, y + 2, 'Stock: ' .. tostring(item.size))
    end

    if inStock then self:_addBtn(x, y, w, h - 1, idx) end
end

function StoreUI:_drawFooter()
    local g = self.gpu
    local W, H = self.W, self.H
    local y = H - FOOTER_H + 1

    -- Cart background
    g.setBackground(C.CART_BG)
    g.setForeground(C.CART_FG)
    g.fill(1, y, W, FOOTER_H, ' ')

    -- Cart contents (line 1-2)
    local total = 0
    local parts = {}
    for _, e in ipairs(self.cart) do
        total = total + e.unitPrice * e.quantity
        parts[#parts + 1] = e.label:sub(1, 12) .. ' x' .. e.quantity
    end
    local cartStr = #parts > 0 and table.concat(parts, ', ') or 'Cart empty'
    g.set(2, y, cartStr:sub(1, W - 2))

    -- Total (line 2)
    g.setForeground(C.TOTAL_FG)
    g.set(2, y + 1, 'Total: ' .. Money.fmt(total))

    -- Prev button
    local navW = 8
    g.setBackground(C.BTN_BG)
    g.setForeground(C.BTN_FG)
    g.set(2, y + 2, '< Prev  ')
    self:_addBtn(2, y + 2, navW, 2, 'prev')

    -- Next button
    g.set(W - navW - 1, y + 2, '  Next >')
    self:_addBtn(W - navW - 1, y + 2, navW, 2, 'next')

    -- Cart / Checkout buttons
    if #self.cart > 0 then
        -- CART button (left-centre area)
        local cartBtnW = 8
        local cartBtnX = math.floor(W / 4) - math.floor(cartBtnW / 2) + 1
        g.setBackground(0x443300)
        g.setForeground(0xFFFF44)
        g.set(cartBtnX, y + 2, '  CART  ')
        self:_addBtn(cartBtnX, y + 2, cartBtnW, 2, 'cart')

        -- CHECKOUT button (right-centre area)
        local checkW = 16
        local checkX = math.floor((W - checkW) / 2) + 1
        g.setBackground(C.CHECKOUT_BG)
        g.setForeground(0xFFFFFF)
        g.set(checkX, y + 2, ' CHECKOUT ' .. Money.fmt(total) .. ' ')
        self:_addBtn(checkX, y + 2, checkW, 2, 'checkout')
    end
end

function StoreUI:_showCartMsg(msg, color)
    local g = self.gpu
    local y = self.H - FOOTER_H + 1
    g.setBackground(C.CART_BG)
    g.setForeground(color or C.CART_FG)
    g.fill(1, y, self.W, 2, ' ')
    g.set(2, y, msg:sub(1, self.W - 2))
end

function StoreUI:_openQtyOverlay(item)
    self.overlay = true
    self.overlayMode = 'qty'
    self.qtyItem = item
    self.qtyInput = ''
    self:_drawQtyOverlay()
end

function StoreUI:_drawQtyOverlay()
    local g = self.gpu
    local W, H = self.W, self.H
    self.overlayBtns = {}

    local ow = 30
    local oh = 17
    local ox = math.floor((W - ow) / 2) + 1
    local oy = math.floor((H - oh) / 2) + 1

    local item = self.qtyItem
    local qty = tonumber(self.qtyInput) or 0
    local total = qty * item.price

    g.setBackground(C.OV_BG)
    g.fill(ox, oy, ow, oh, ' ')
    g.setForeground(C.OV_FG)
    g.set(ox + 1, oy + 1, item.label:sub(1, ow - 2))

    local priceStr = Money.short(item.price) ..
                         (item.price ~= 0 and ' each' or '')
    g.setForeground(C.PRICE_FG)
    g.set(ox + 1, oy + 2, priceStr)

    g.setForeground(0xAAAAAA)
    g.set(ox + 1, oy + 3, 'Stock: ' .. tostring(item.size))

    g.setForeground(C.OV_FG)
    local qStr = (self.qtyInput == '' and '_' or self.qtyInput .. '_')
    g.set(ox + 1, oy + 4, 'Qty: ' .. qStr)

    g.setForeground(C.TOTAL_FG)
    g.set(ox + 1, oy + 5, 'Total: ' .. Money.short(total))

    -- Numpad
    local numLabels = {
        {'7', '8', '9'}, {'4', '5', '6'}, {'1', '2', '3'}, {'CLR', '0', '<'}
    }
    local btnW = 7
    local btnH = 2
    local padX = ox + 1
    local padY = oy + 7

    for row, rowBtns in ipairs(numLabels) do
        for col, lbl in ipairs(rowBtns) do
            local bx = padX + (col - 1) * (btnW + 1)
            local by = padY + (row - 1) * (btnH + 1)
            g.setBackground(C.NUM_BG)
            g.setForeground(C.NUM_FG)
            g.fill(bx, by, btnW, btnH, ' ')
            local pad = math.floor((btnW - #lbl) / 2)
            g.set(bx + pad, by, lbl)
            self:_addOvBtn(bx, by, btnW, btnH, lbl)
        end
    end

    local botY = padY + 4 * (btnH + 1)
    g.setBackground(C.OK_BG)
    g.setForeground(C.OV_FG)
    g.set(ox + 1, botY, '  ADD TO CART  ')
    self:_addOvBtn(ox + 1, botY, 15, 2, 'ADD')

    g.setBackground(C.CANCEL_BG)
    g.set(ox + 17, botY, '   CANCEL   ')
    self:_addOvBtn(ox + 17, botY, 12, 2, 'CANCEL')
end

function StoreUI:_handleQtyTouch(x, y)
    local id = self:_hitOv(x, y)
    if not id then return end

    if id == 'ADD' then
        local qty = tonumber(self.qtyInput)
        if qty and qty > 0 then self:_addToCart(self.qtyItem, qty) end
        self:_closeOverlay()

    elseif id == 'CANCEL' then
        self:_closeOverlay()

    elseif id == 'CLR' then
        self.qtyInput = ''
        self:_drawQtyOverlay()

    elseif id == '<' then
        if #self.qtyInput > 0 then
            self.qtyInput = self.qtyInput:sub(1, -2)
            self:_drawQtyOverlay()
        end

    elseif tonumber(id) then
        self.qtyInput = self.qtyInput .. id
        self:_drawQtyOverlay()
    end
end

function StoreUI:_handleWarnTouch(x, y)
    local id = self:_hitOv(x, y)
    if not id then return end

    if id == 'WARN_OK' then
        local feasible = self._warnFeasible
        self._warnFeasible = nil
        self:_closeOverlay()
        self:_dispenseThenCharge(feasible)

    elseif id == 'WARN_CANCEL' then
        self._warnFeasible = nil
        self:_closeOverlay()
    end
end

function StoreUI:_closeOverlay()
    self.overlay = false
    self.overlayMode = nil
    self.qtyItem = nil
    self:_draw()
end

function StoreUI:_addOvBtn(x, y, w, h, id)
    self.overlayBtns[#self.overlayBtns + 1] = {
        x = x,
        y = y,
        w = w,
        h = h,
        id = id
    }
end

function StoreUI:_hitOv(x, y)
    for _, b in ipairs(self.overlayBtns) do
        if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
            return b.id
        end
    end
end

function StoreUI:_addToCart(item, qty)
    qty = qty or 1
    for _, e in ipairs(self.cart) do
        if e.key == item.key then
            e.quantity = e.quantity + qty
            self:_drawFooter()
            return
        end
    end
    self.cart[#self.cart + 1] = {
        key = item.key,
        label = item.label,
        quantity = qty,
        unitPrice = item.price
    }
    self:_drawFooter()
end

function StoreUI:_doCheckout()
    if #self.cart == 0 then return end

    self:_showStatusOverlay('Checking stock...', 0x003366, 'Please wait')

    -- Pre-flight: check stock and output space before touching anything
    local feasible, warnings = Inventory.preflightCart(self.cart)

    if #feasible == 0 then
        -- Nothing can be dispensed at all
        local reason = #warnings > 0 and warnings[1].reason or 'unknown'
        self:_showCartMsg('Cannot dispense: ' .. reason, 0xFF3300)
        return
    end

    if #warnings > 0 then
        -- Some items have issues — show warning overlay and let user decide
        self:_showWarnOverlay(feasible, warnings)
    else
        -- All clear — proceed immediately
        self:_dispenseThenCharge(feasible)
    end
end

--- Show a warning overlay listing issues, with Proceed / Cancel buttons.
function StoreUI:_showWarnOverlay(feasible, warnings)
    local g = self.gpu
    local W, H = self.W, self.H
    self.overlayBtns = {}

    local ow = math.min(W - 4, 60)
    local oh = math.min(H - 4, 6 + #warnings)
    local ox = math.floor((W - ow) / 2) + 1
    local oy = math.floor((H - oh) / 2) + 1

    g.setBackground(0x220000)
    g.fill(ox, oy, ow, oh, ' ')
    g.setForeground(0xFF6600)
    g.set(ox + 1, oy + 1, 'Warning: some items cannot be fully dispensed')

    for i, w in ipairs(warnings) do
        local line = ('  %s: %s'):format(w.label:sub(1, 20), w.reason)
        if w.canGive and w.canGive > 0 and w.canGive < w.requested then
            line = line .. (' (%d/%d)'):format(w.canGive, w.requested)
        end
        g.setForeground(0xFFAAAA)
        g.set(ox + 1, oy + 1 + i, line:sub(1, ow - 2))
    end

    -- Calculate what will actually be charged
    local actualTotal = 0
    for _, f in ipairs(feasible) do
        actualTotal = actualTotal + f.unitPrice * f.qty
    end
    g.setForeground(0xFFFF44)
    g.set(ox + 1, oy + oh - 3, ('Proceed with %s for %d item(s)?'):format(
              Money.fmt(actualTotal), #feasible))

    -- Buttons
    local btnY = oy + oh - 2
    g.setBackground(0x005522)
    g.setForeground(0xFFFFFF)
    g.set(ox + 1, btnY, '  PROCEED  ')
    self:_addOvBtn(ox + 1, btnY, 11, 2, 'WARN_OK')

    g.setBackground(0x552200)
    g.set(ox + 14, btnY, '  CANCEL  ')
    self:_addOvBtn(ox + 14, btnY, 10, 2, 'WARN_CANCEL')

    -- Stash feasible for when user confirms
    self._warnFeasible = feasible
    self.overlay = true
    self.overlayMode = 'warn'
end

--- Draw a full-screen centred status panel (processing / success / failure).
function StoreUI:_showStatusOverlay(msg, color, subtext)
    local g = self.gpu
    local W, H = self.W, self.H

    local ow = math.min(W - 4, 50)
    local oh = 7
    local ox = math.floor((W - ow) / 2) + 1
    local oy = math.floor((H - oh) / 2) + 1

    g.setBackground(0x000022)
    g.fill(ox, oy, ow, oh, ' ')

    -- Coloured top bar
    g.setBackground(color or 0x003366)
    g.fill(ox, oy, ow, 1, ' ')

    -- Main message (may contain '\n' — split manually)
    local lines = {}
    for line in (msg .. '\n'):gmatch('([^\n]*)\n') do
        lines[#lines + 1] = line
    end

    g.setBackground(0x000022)
    g.setForeground(0xFFFFFF)
    for i, line in ipairs(lines) do
        local cx = ox + math.floor((ow - #line) / 2)
        g.set(cx, oy + 1 + (i - 1), line:sub(1, ow - 2))
    end

    if subtext and subtext ~= '' then
        g.setForeground(0x888888)
        local sx = ox + math.floor((ow - #subtext) / 2)
        g.set(sx, oy + oh - 2, subtext:sub(1, ow - 2))
    end

    self.overlay = true
    self.overlayMode = 'status'
    self.overlayBtns = {}
end

--- Show cart management overlay: list items with remove buttons.
function StoreUI:_openCartOverlay()
    self.overlay = true
    self.overlayMode = 'cart'
    self:_drawCartOverlay()
end

function StoreUI:_drawCartOverlay()
    local g = self.gpu
    local W, H = self.W, self.H
    self.overlayBtns = {}

    local ow = math.min(W - 4, 55)
    local oh = math.min(H - 4, 4 + #self.cart + 3)
    local ox = math.floor((W - ow) / 2) + 1
    local oy = math.floor((H - oh) / 2) + 1

    g.setBackground(0x111133)
    g.fill(ox, oy, ow, oh, ' ')
    g.setBackground(0x002266)
    g.fill(ox, oy, ow, 1, ' ')
    g.setForeground(0xFFFFFF)
    g.set(ox + 1, oy, 'Cart  (tap [X] to remove)')

    local total = 0
    for i, e in ipairs(self.cart) do
        local lineY = oy + i
        local unitStr = e.unitPrice == 0 and 'FREE' or Money.fmt(e.unitPrice)
        local line = ('%s x%d  @ %s'):format(e.label:sub(1, 18), e.quantity,
                                             unitStr)
        g.setBackground(0x111133)
        g.setForeground(0xDDDDDD)
        g.fill(ox, lineY, ow, 1, ' ')
        g.set(ox + 1, lineY, line:sub(1, ow - 6))
        -- [X] button
        g.setBackground(0x660000)
        g.setForeground(0xFF4444)
        g.set(ox + ow - 4, lineY, '[X] ')
        self:_addOvBtn(ox + ow - 4, lineY, 4, 1, 'REMOVE_' .. i)
        total = total + e.unitPrice * e.quantity
    end

    -- Total
    local totY = oy + #self.cart + 2
    g.setBackground(0x111133)
    g.setForeground(0x44FF44)
    g.set(ox + 1, totY, 'Total: ' .. Money.fmt(total))

    -- Close button
    g.setBackground(0x004488)
    g.setForeground(0xFFFFFF)
    g.set(ox + 1, oy + oh - 1, '    CLOSE    ')
    self:_addOvBtn(ox + 1, oy + oh - 1, 13, 1, 'CART_CLOSE')
end

function StoreUI:_handleCartTouch(x, y)
    local id = self:_hitOv(x, y)
    if not id then return end

    if id == 'CART_CLOSE' then
        self:_closeOverlay()

    elseif id:sub(1, 7) == 'REMOVE_' then
        local idx = tonumber(id:sub(8))
        if idx and self.cart[idx] then table.remove(self.cart, idx) end
        if #self.cart == 0 then
            self:_closeOverlay()
        else
            self:_drawCartOverlay()
        end
    end
end

--- Hold → Dispense → Adjust/Release. Server auto-captures after fraud review window.
function StoreUI:_dispenseThenCharge(feasible)
    local feasibleTotal = 0
    for _, f in ipairs(feasible) do
        feasibleTotal = feasibleTotal + f.unitPrice * f.qty
    end

    -- ── 1. Place hold (server debits balance, starts capture timer) ───────
    self:_showStatusOverlay('Authorising payment...', 0x003366, 'Please wait')

    self.posCore:hold(feasibleTotal, function(holdId, captureIn, holdErr)
        if holdErr then
            self:_showStatusOverlay('Payment denied\n' .. holdErr, 0xFF3300,
                                    'Tap to dismiss')
            return
        end

        -- ── 2. Dispense ───────────────────────────────────────────────────
        self:_showStatusOverlay('Dispensing items...', 0x444400, 'Please wait')
        local results, _ = Inventory.dispenseCart(feasible)

        -- ── 3. Tally actual transferred ───────────────────────────────────
        local actualTotal = 0
        for _, r in ipairs(results) do
            if r.transferred > 0 then
                actualTotal = actualTotal + r.unitPrice * r.transferred
            end
        end

        if actualTotal == 0 and actualTotal ~= feasibleTotal then
            -- Nothing dispensed — cancel hold entirely
            self:_showStatusOverlay('Releasing hold...', 0x443300, 'Please wait')
            self.posCore:releaseHold(holdId, function()
                self.cart = {}
                self:_closeOverlay()
                self:_showCartMsg('Nothing dispensed. No charge.', 0xFF6600)
            end)
            return
        end

        -- ── 4. Adjust if partial, then show success ───────────────────────
        local function showSuccess(balance)
            self.cart = {}
            self:_showStatusOverlay('Payment held!\nBalance: ' ..
                                        Money.fmt(balance), 0x44FF44,
                                    'Auto-captures in ' ..
                                        tostring(captureIn or '?') ..
                                        's — logging out')
            self.logoutAt = computer.uptime() + 3
        end

        if actualTotal < feasibleTotal then
            -- Partial dispense — adjust hold down to what was actually dispensed
            self:_showStatusOverlay('Adjusting hold...', 0x003366, 'Please wait')
            self.posCore:adjustHold(holdId, actualTotal, function(adjErr)
                if adjErr then
                    -- Adjustment failed — release the hold entirely to avoid overcharge
                    self:_showStatusOverlay('Releasing hold...', 0x443300,
                                            'Please wait')
                    self.posCore:releaseHold(holdId, function()
                        self.cart = {}
                        self:_showStatusOverlay(
                            'Partial dispense\nHold released — no charge',
                            0xFF6600,
                            'Contact staff to process payment manually')
                        self.logoutAt = computer.uptime() + 5
                    end)
                    return
                end
                showSuccess(self.posCore.session and
                                self.posCore.session.balance or 0)
            end)
        else
            showSuccess(self.posCore.session and self.posCore.session.balance or
                            0)
        end
    end)
end

function StoreUI:_addBtn(x, y, w, h, id)
    self.buttons[#self.buttons + 1] = {x = x, y = y, w = w, h = h, id = id}
end

function StoreUI:_hit(x, y)
    for _, b in ipairs(self.buttons) do
        if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
            return b.id
        end
    end
    return nil
end

return StoreUI
