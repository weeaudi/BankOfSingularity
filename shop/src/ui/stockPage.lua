---@diagnostic disable: undefined-field  -- OC API extensions (gpu.*)
-- Stock Page: idle display showing all listed items + current stock.
-- Visible when no customer is logged in. Touch scrolls pages.

local Inventory = require('src.inventory')
local Money     = require('src.util.money')

local C = {
    BG        = 0x0a0a0a,
    HEADER_BG = 0x001133,
    HEADER_FG = 0xFFFFFF,
    COL_HDR   = 0x334455,
    COL_FG    = 0xAAAAAA,
    ITEM_BG   = 0x111122,
    ITEM_ALT  = 0x0d0d1a,
    ITEM_FG   = 0xDDDDDD,
    PRICE_FG  = 0x44FF44,
    FREE_FG   = 0xFFFF44,
    SOLD_FG   = 0x444444,
    SOLD_BG   = 0x0d0d0d,
    NAV_BG    = 0x003366,
    NAV_FG    = 0xFFFFFF,
    STOCK_OK  = 0x44AA44,
    STOCK_LOW = 0xFFAA00,  -- <= 5
    STOCK_OUT = 0x663333,
}

local HEADER_H   = 3
local NAV_H      = 2
local REFRESH_S  = 15   -- auto-refresh interval (seconds)

local StockPage = {}
StockPage.__index = StockPage

function StockPage.new(gpu, catalog, inventory)
    local self      = setmetatable({}, StockPage)
    self.gpu        = gpu
    self.catalog    = catalog
    self.inv        = inventory

    local W, H      = gpu.getResolution()
    self.W          = W
    self.H          = H
    self.rowsPerPage = H - HEADER_H - NAV_H
    self.perPage    = self.rowsPerPage

    self.visible    = false
    self.page       = 1
    self.items      = {}
    self.lastRefresh = 0
    self.buttons    = {}

    return self
end

-- ─── Public API ───────────────────────────────────────────────────────────────

function StockPage:show()
    self.visible = true
    self.page    = 1
    self:_refresh()
end

function StockPage:hide()
    self.visible = false
    local g      = self.gpu
    g.setBackground(0x000000)
    g.setForeground(0xFFFFFF)
    g.fill(1, 1, self.W, self.H, ' ')
end

--- Call from main loop — handles auto-refresh.
function StockPage:tick(uptime)
    if not self.visible then return end
    if uptime - self.lastRefresh >= REFRESH_S then
        self:_refresh()
    end
end

function StockPage:onTouch(x, y)
    if not self.visible then return end
    local id = self:_hit(x, y)
    if id == 'prev' then
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
    end
end

-- ─── Private ─────────────────────────────────────────────────────────────────

function StockPage:_refresh()
    self.items       = Inventory.getListedWithStock(self.catalog)
    self.lastRefresh = os.time and os.time() or 0
    self:_draw()
end

function StockPage:_draw()
    local g    = self.gpu
    local W, H = self.W, self.H
    self.buttons = {}

    -- Header
    g.setBackground(C.HEADER_BG)
    g.setForeground(C.HEADER_FG)
    g.fill(1, 1, W, HEADER_H, ' ')
    g.set(2, 1, 'Bank of Singularity  —  Store Stock')

    local maxPage = math.max(1, math.ceil(#self.items / self.perPage))
    g.setForeground(0x8888AA)
    g.set(2, 2, ('Page %d / %d  |  %d items listed  |  Swipe card to purchase'):format(
        self.page, maxPage, #self.items))

    -- Refresh time
    g.setForeground(0x446688)
    local timeStr = self.lastRefresh > 0 and os.date('%H:%M:%S', self.lastRefresh) or '...'
    g.set(W - 18, 2, 'Updated: ' .. timeStr)

    -- Credit (top-right, row 1)
    local credit = 'Made by Aidcraft & Dos54'
    g.setForeground(0x7799AA)
    g.set(W - #credit, 1, credit)

    -- Column headers
    g.setBackground(C.COL_HDR)
    g.setForeground(C.COL_FG)
    g.fill(1, HEADER_H, W, 1, ' ')
    local nameW  = math.floor(W * 0.55)
    local priceX = nameW + 2
    local stockX = priceX + 12
    g.set(2,       HEADER_H, 'Item')
    g.set(priceX,  HEADER_H, 'Price')
    g.set(stockX,  HEADER_H, 'Stock')

    -- Rows
    local startIdx = (self.page - 1) * self.perPage + 1
    for i = 0, self.perPage - 1 do
        local idx  = startIdx + i
        local item = self.items[idx]
        local y    = HEADER_H + 1 + i
        if y > H - NAV_H then break end

        local bg = (i % 2 == 0) and C.ITEM_BG or C.ITEM_ALT
        if item and item.size == 0 then bg = C.SOLD_BG end

        g.setBackground(bg)
        g.fill(1, y, W, 1, ' ')

        if item then
            -- Name
            g.setForeground(item.size > 0 and C.ITEM_FG or C.SOLD_FG)
            g.set(2, y, item.label:sub(1, nameW - 2))

            -- Price
            if item.price == 0 then
                g.setForeground(C.FREE_FG)
                g.set(priceX, y, 'FREE        ')
            else
                g.setForeground(item.size > 0 and C.PRICE_FG or C.SOLD_FG)
                g.set(priceX, y, ('%-11s'):format(Money.fmt(item.price)))
            end

            -- Stock
            local stockFg
            if item.size == 0 then
                stockFg = C.STOCK_OUT
            elseif item.size <= 5 then
                stockFg = C.STOCK_LOW
            else
                stockFg = C.STOCK_OK
            end
            g.setForeground(stockFg)
            local stockStr = item.size == 0 and 'OUT OF STOCK' or tostring(item.size)
            g.set(stockX, y, stockStr)
        end
    end

    -- Nav bar
    local navY = H - NAV_H + 1
    g.setBackground(C.NAV_BG)
    g.setForeground(C.NAV_FG)
    g.fill(1, navY, W, NAV_H, ' ')
    g.set(2, navY, '< Prev')
    self:_addBtn(2, navY, 8, NAV_H, 'prev')
    g.set(W - 7, navY, 'Next >')
    self:_addBtn(W - 7, navY, 8, NAV_H, 'next')
    g.setBackground(0x224422)
    local rX = math.floor(W / 2) - 5
    g.set(rX, navY, ' Refresh ')
    self:_addBtn(rX, navY, 10, NAV_H, 'refresh')
end

function StockPage:_addBtn(x, y, w, h, id)
    self.buttons[#self.buttons + 1] = {x=x, y=y, w=w, h=h, id=id}
end

function StockPage:_hit(x, y)
    for _, b in ipairs(self.buttons) do
        if x >= b.x and x < b.x+b.w and y >= b.y and y < b.y+b.h then return b.id end
    end
end

return StockPage
