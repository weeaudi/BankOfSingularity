---@diagnostic disable: undefined-field  -- OC API extensions (gpu.*)
-- Config UI: owner-facing touchscreen frontend.
-- Browse all ME items, set/clear prices. Owner logs out to exit.

local Inventory = require('src.inventory')
local Money     = require('src.util.money')

-- ─── Colors ──────────────────────────────────────────────────────────────────
local C = {
    BG         = 0x111111,
    HEADER_BG  = 0x330033,
    HEADER_FG  = 0xFFFFFF,
    ITEM_BG    = 0x1a1a2e,
    ITEM_FG    = 0xDDDDDD,
    LISTED_FG  = 0x44FF44,   -- price >= 0
    UNSET_FG   = 0xFFAA00,   -- price == -1
    FREE_FG    = 0xFFFF44,   -- price == 0
    SOLD_FG    = 0x666666,
    BTN_BG     = 0x004488,
    BTN_FG     = 0xFFFFFF,
    LOGOUT_BG  = 0x882200,
    OVERLAY_BG = 0x000044,
    OVERLAY_FG = 0xFFFFFF,
    NUM_BG     = 0x222266,
    NUM_FG     = 0xFFFFFF,
    OK_BG      = 0x005522,
    CANCEL_BG  = 0x552200,
    UNLIST_BG  = 0x554400,
}

local COLS     = 3
local ITEM_H   = 4
local HEADER_H = 2
local NAV_H    = 2

local ConfigUI = {}
ConfigUI.__index = ConfigUI

---@param gpu table
---@param catalog table
---@param inventory table
---@param posCore table
function ConfigUI.new(gpu, catalog, inventory, posCore)
    local self      = setmetatable({}, ConfigUI)
    self.gpu        = gpu
    self.catalog    = catalog
    self.inv        = inventory
    self.posCore    = posCore

    local W, H      = gpu.getResolution()
    self.W          = W
    self.H          = H
    self.itemW      = math.floor(W / COLS)
    self.itemRows   = math.floor((H - HEADER_H - NAV_H) / ITEM_H)
    self.perPage    = self.itemRows * COLS

    self.visible    = false
    self.page       = 1
    self.items      = {}
    self.buttons    = {}

    -- Price input overlay state
    self.overlay    = false
    self.editItem   = nil   -- {key, label, price}
    self.priceInput = ''
    self.overlayBtns = {}

    return self
end

-- ─── Public API ───────────────────────────────────────────────────────────────

function ConfigUI:show()
    self.visible  = true
    self.page     = 1
    self.overlay  = false
    self:_refresh()
end

function ConfigUI:hide()
    self.visible = false
    local g      = self.gpu
    g.setBackground(0x000000)
    g.setForeground(0xFFFFFF)
    g.fill(1, 1, self.W, self.H, ' ')
end

function ConfigUI:onTouch(x, y)
    if not self.visible then return end

    if self.overlay then
        self:_handleOverlayTouch(x, y)
        return
    end

    local id = self:_hit(x, y)
    if not id then return end

    if id == 'logout' then
        self.posCore:logout()
    elseif id == 'prev' then
        if self.page > 1 then
            self.page = self.page - 1
            self:_draw()
        end
    elseif id == 'next' then
        local maxPage = math.max(1, math.ceil(#self.items / self.perPage))
        if self.page < maxPage then
            self.page = self.page + 1
            self:_draw()
        end
    elseif id == 'refresh' then
        self:_refresh()
    elseif type(id) == 'number' then
        self:_openOverlay(self.items[id])
    end
end

-- ─── Private: main view ───────────────────────────────────────────────────────

function ConfigUI:_refresh()
    self.items = Inventory.getAllWithPrices(self.catalog)
    self:_draw()
end

function ConfigUI:_draw()
    local g    = self.gpu
    local W, H = self.W, self.H
    self.buttons = {}

    -- Header
    g.setBackground(C.HEADER_BG)
    g.setForeground(C.HEADER_FG)
    g.fill(1, 1, W, HEADER_H, ' ')
    g.set(2, 1, 'CONFIG MODE  |  Tap item to set price  |  green=listed  orange=unset  yellow=free')

    local maxPage = math.max(1, math.ceil(#self.items / self.perPage))
    g.setForeground(0xAAAAAA)
    g.set(2, 2, ('Page %d / %d  (%d items in network)'):format(self.page, maxPage, #self.items))

    -- Credit (top-right row 2, left of logout area)
    local credit = 'Made by Aidcraft & Dos54'
    g.setBackground(C.HEADER_BG)
    g.setForeground(0x7799AA)
    g.set(W - #credit, 2, credit)

    -- Logout
    local logoutW = 10
    g.setBackground(C.LOGOUT_BG)
    g.setForeground(C.HEADER_FG)
    g.set(W - logoutW + 1, 1, '  LOGOUT  ')
    self:_addBtn(W - logoutW + 1, 1, logoutW, HEADER_H, 'logout')

    -- Items
    local startIdx = (self.page - 1) * self.perPage + 1
    local rowStart = HEADER_H + 1

    for row = 0, self.itemRows - 1 do
        for col = 0, COLS - 1 do
            local idx = startIdx + row * COLS + col
            local x   = col * self.itemW + 1
            local y   = rowStart + row * ITEM_H
            self:_drawItem(x, y, self.itemW, ITEM_H, idx)
        end
    end

    -- Nav bar
    local navY = H - NAV_H + 1
    g.setBackground(C.BTN_BG)
    g.setForeground(C.BTN_FG)
    g.fill(1, navY, W, NAV_H, ' ')
    g.set(2, navY, '< Prev')
    self:_addBtn(2, navY, 8, NAV_H, 'prev')
    g.set(W - 7, navY, 'Next >')
    self:_addBtn(W - 7, navY, 8, NAV_H, 'next')
    g.setBackground(0x224422)
    g.set(math.floor(W / 2) - 4, navY, ' Refresh ')
    self:_addBtn(math.floor(W / 2) - 4, navY, 10, NAV_H, 'refresh')
end

function ConfigUI:_drawItem(x, y, w, h, idx)
    local g    = self.gpu
    local item = self.items[idx]

    g.setBackground(C.ITEM_BG)
    g.fill(x, y, w, h, ' ')

    if not item then return end

    -- Name
    g.setForeground(C.ITEM_FG)
    g.set(x + 1, y, item.label:sub(1, w - 2))

    -- Price status
    local priceStr, pColor
    if item.price == -1 then
        priceStr = 'unset'
        pColor   = C.UNSET_FG
    elseif item.price == 0 then
        priceStr = 'FREE'
        pColor   = C.FREE_FG
    else
        priceStr = Money.fmt(item.price)
        pColor   = C.LISTED_FG
    end
    g.setForeground(pColor)
    g.set(x + 1, y + 1, priceStr)

    -- Stock
    g.setForeground(item.size > 0 and 0x448844 or C.SOLD_FG)
    g.set(x + 1, y + 2, 'Stock: ' .. tostring(item.size))

    self:_addBtn(x, y, w, h - 1, idx)
end

-- ─── Private: price overlay ───────────────────────────────────────────────────

function ConfigUI:_openOverlay(item)
    if not item then return end
    self.overlay    = true
    self.editItem   = item
    self.priceInput = item.price >= 0 and tostring(item.price) or ''
    self:_drawOverlay()
end

function ConfigUI:_drawOverlay()
    local g    = self.gpu
    local W, H = self.W, self.H
    self.overlayBtns = {}

    -- Dim overlay panel (centred, ~30x18)
    local ow = 32
    local oh = 18
    local ox = math.floor((W - ow) / 2) + 1
    local oy = math.floor((H - oh) / 2) + 1

    g.setBackground(C.OVERLAY_BG)
    g.fill(ox, oy, ow, oh, ' ')

    g.setForeground(C.OVERLAY_FG)
    g.set(ox + 1, oy + 1, 'Set price for:')
    g.set(ox + 1, oy + 2, self.editItem.label:sub(1, ow - 2))

    -- Show raw cents input alongside formatted preview
    local rawStr  = self.priceInput == '' and '_' or self.priceInput .. '_'
    local preview = self.priceInput ~= '' and ('  = ' .. Money.fmt(tonumber(self.priceInput) or 0)) or ''
    g.setForeground(C.LISTED_FG)
    g.set(ox + 1, oy + 3, 'Cents: ' .. rawStr .. preview)

    -- Numpad (3×4 grid)
    local numLabels = {
        {'7','8','9'},
        {'4','5','6'},
        {'1','2','3'},
        {'CLR','0','<'},
    }
    local btnW = 8
    local btnH = 2
    local padX = ox + 1
    local padY = oy + 5

    for row, rowBtns in ipairs(numLabels) do
        for col, lbl in ipairs(rowBtns) do
            local bx = padX + (col - 1) * (btnW + 1)
            local by = padY + (row - 1) * (btnH + 1)
            g.setBackground(C.NUM_BG)
            g.setForeground(C.NUM_FG)
            g.fill(bx, by, btnW, btnH, ' ')
            local centered = lbl:len() < btnW
                and string.rep(' ', math.floor((btnW - #lbl) / 2)) .. lbl
                or lbl
            g.set(bx, by, centered:sub(1, btnW))
            self:_addOvBtn(bx, by, btnW, btnH, lbl)
        end
    end

    -- OK button
    local okX = padX
    local okY = padY + 4 * (btnH + 1)
    g.setBackground(C.OK_BG)
    g.set(okX, okY, '   OK   ')
    self:_addOvBtn(okX, okY, 8, 2, 'OK')

    -- Unlist button
    g.setBackground(C.UNLIST_BG)
    g.set(okX + 9, okY, ' UNLIST ')
    self:_addOvBtn(okX + 9, okY, 8, 2, 'UNLIST')

    -- Cancel button
    g.setBackground(C.CANCEL_BG)
    g.set(okX + 18, okY, ' CANCEL ')
    self:_addOvBtn(okX + 18, okY, 8, 2, 'CANCEL')
end

function ConfigUI:_handleOverlayTouch(x, y)
    local id = self:_hitOv(x, y)
    if not id then return end

    if id == 'OK' then
        local price = tonumber(self.priceInput)
        if price and price >= 0 then
            self.catalog.setPrice(self.editItem.key, price, self.editItem.label)
        end
        self:_closeOverlay()

    elseif id == 'UNLIST' then
        self.catalog.setPrice(self.editItem.key, -1, self.editItem.label)
        self:_closeOverlay()

    elseif id == 'CANCEL' then
        self:_closeOverlay()

    elseif id == 'CLR' then
        self.priceInput = ''
        self:_drawOverlay()

    elseif id == '<' then
        if #self.priceInput > 0 then
            self.priceInput = self.priceInput:sub(1, -2)
            self:_drawOverlay()
        end

    elseif tonumber(id) then
        self.priceInput = self.priceInput .. id
        self:_drawOverlay()
    end
end

function ConfigUI:_closeOverlay()
    self.overlay  = false
    self.editItem = nil
    self:_refresh()
end

function ConfigUI:_addBtn(x, y, w, h, id)
    self.buttons[#self.buttons + 1] = {x=x, y=y, w=w, h=h, id=id}
end

function ConfigUI:_addOvBtn(x, y, w, h, id)
    self.overlayBtns[#self.overlayBtns + 1] = {x=x, y=y, w=w, h=h, id=id}
end

function ConfigUI:_hit(x, y)
    for _, b in ipairs(self.buttons) do
        if x >= b.x and x < b.x+b.w and y >= b.y and y < b.y+b.h then return b.id end
    end
end

function ConfigUI:_hitOv(x, y)
    for _, b in ipairs(self.overlayBtns) do
        if x >= b.x and x < b.x+b.w and y >= b.y and y < b.y+b.h then return b.id end
    end
end

return ConfigUI
