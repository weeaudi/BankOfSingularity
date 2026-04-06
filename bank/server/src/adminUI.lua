-- Bank of Singularity — Admin GUI
-- Touchscreen + keyboard admin panel.  Requires gpu + screen on the server.
-- Returns false when hardware is absent so caller falls back to text CLI.
local component = require('component')
local event = require('event')
local computer = require('computer')
local colors = require('colors')

if not component.isAvailable('gpu') or not component.isAvailable('screen') then
    return false
end

local gpu = component.gpu
local screen = component.screen
gpu.bind(screen.address)
local W, H = gpu.getResolution()

local db = require('src.db').database
local Account = require('src.models.Account')
local Card = require('src.models.Card')
local accountService = require('src.services.accountService')
local cardService = require('src.services.cardService')
local ledgerService = require('src.services.ledgerService')
local DeviceService = require('src.services.deviceService')

local dataComp = component.isAvailable('data') and component.data or nil
local keypad   = component.isAvailable('os_keypad') and component.os_keypad or nil

-- ─── Palette ─────────────────────────────────────────────────────────────────
local C = {
    BG = 0x0d0d0d,
    HDR_BG = 0x3d0000,
    HDR_FG = 0xFFFFFF,
    TAB_BG = 0x1a0000,
    TAB_FG = 0x888888,
    TAB_ON = 0x660000,
    TAB_ON_FG = 0xFFFFFF,
    COL_BG = 0x2a0000,
    COL_FG = 0xFFAAAA,
    ROW_A = 0x161616,
    ROW_B = 0x111111,
    ROW_SEL = 0x661100,
    FG = 0xDDDDDD,
    DIM = 0x444444,
    GREEN = 0x44FF44,
    YELLOW = 0xFFAA00,
    RED = 0xFF4444,
    BTN = 0x550000,
    BTN_FG = 0xFFFFFF,
    BTN_OK = 0x005522,
    BTN_WARN = 0x554400,
    BTN_NEG = 0x550000,
    BTN_ACT = 0x004466,
    BTN_DIM = 0x222222,
    OV_BG = 0x050510,
    OV_HDR = 0x440000,
    NUM_BG = 0x222244,
    FOOT_BG = 0x0a0000,
    ST_OK = 0x002200,
    ST_ERR = 0x330000
}

-- ─── Layout ──────────────────────────────────────────────────────────────────
local HDR_Y = 1
local TAB_Y = 2
local LIST_Y = 3 -- column-header row
local DATA_Y = 4 -- first data row
local FOOT_Y = H - 1
local ACT_Y = H
local DATA_H = FOOT_Y - DATA_Y -- usable data rows

-- ─── State ───────────────────────────────────────────────────────────────────
local TABS = {'Accounts', 'Cards', 'Money', 'Devices', 'Holds'}
local tab = 1
local rows = {}
local selRow = nil
local page = 1
local perPage = DATA_H
local btns = {}
local ov = nil -- overlay: {type, ...}
local cardWaitCb = nil -- function(salt, uid) — set while waiting for magData
local cardWaitExpires = nil -- computer.uptime() deadline
local pinCb = nil -- function(pin) — set while waiting for keypad PIN entry
local pinBuf = '' -- digits accumulated from keypad
local running = true
local statusMsg = ''
local statusBg = C.ST_OK

-- ─── GPU helpers ─────────────────────────────────────────────────────────────

local function cls()
    gpu.setBackground(C.BG)
    gpu.fill(1, 1, W, H, ' ')
end

local function reg(x, y, w, h, id)
    btns[#btns + 1] = {x = x, y = y, w = w, h = h, id = id}
end

local function hit(x, y)
    for i = #btns, 1, -1 do
        local b = btns[i]
        if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
            return b.id
        end
    end
end

local function drawBtn(x, y, w, lbl, bg, fg)
    gpu.setBackground(bg)
    gpu.setForeground(fg or C.BTN_FG)
    gpu.fill(x, y, w, 1, ' ')
    local lx = x + math.max(0, math.floor((w - #lbl) / 2))
    gpu.set(lx, y, lbl:sub(1, w))
end

local function centerText(x, y, w, text, fg, bg)
    if bg then gpu.setBackground(bg) end
    if fg then gpu.setForeground(fg) end
    local cx = x + math.max(0, math.floor((w - #text) / 2))
    gpu.set(cx, y, text:sub(1, w))
end

local function setStatus(msg, isErr)
    statusMsg = msg
    statusBg = isErr and C.ST_ERR or C.ST_OK
end

-- ─── Header, tabs, footer ────────────────────────────────────────────────────

local function drawHeader()
    gpu.setBackground(C.HDR_BG)
    gpu.setForeground(C.HDR_FG)
    gpu.fill(1, HDR_Y, W, 1, ' ')
    gpu.set(2, HDR_Y, 'Bank of Singularity  ─  Admin Panel')
    local t = os.date('%H:%M:%S')
    local credit = 'Made by Aidcraft & Dos54'
    gpu.setForeground(0xAA6655)
    gpu.set(W - #t - #credit - 2, HDR_Y, credit)
    gpu.setForeground(C.HDR_FG)
    gpu.set(W - #t - 1, HDR_Y, t)
end

local function drawTabs()
    local tw = math.floor(W / #TABS)
    for i, name in ipairs(TABS) do
        local x = (i - 1) * tw + 1
        local w = (i == #TABS) and (W - x + 1) or tw
        local on = (i == tab)
        gpu.setBackground(on and C.TAB_ON or C.TAB_BG)
        gpu.setForeground(on and C.TAB_ON_FG or C.TAB_FG)
        gpu.fill(x, TAB_Y, w, 1, ' ')
        centerText(x, TAB_Y, w, name)
        reg(x, TAB_Y, w, 1, 'TAB_' .. i)
    end
end

local function drawFooter(actions)
    gpu.setBackground(statusBg)
    gpu.setForeground(0xCCCCCC)
    gpu.fill(1, FOOT_Y, W, 1, ' ')
    if #statusMsg > 0 then gpu.set(2, FOOT_Y, statusMsg:sub(1, W - 2)) end
    gpu.setBackground(C.FOOT_BG)
    gpu.fill(1, ACT_Y, W, 1, ' ')
    if not actions or #actions == 0 then return end
    local aw = math.floor(W / #actions)
    for i, a in ipairs(actions) do
        local x = (i - 1) * aw + 1
        local w = (i == #actions) and (W - x + 1) or aw
        drawBtn(x, ACT_Y, w, a[1], a[3] or C.BTN)
        reg(x, ACT_Y, w, 1, a[2])
    end
end

-- ─── List renderer ───────────────────────────────────────────────────────────
-- cols = {{header, rowKey, width[, colorFn(row)]}, ...}

local function drawList(cols)
    gpu.setBackground(C.COL_BG)
    gpu.setForeground(C.COL_FG)
    gpu.fill(1, LIST_Y, W, 1, ' ')
    local x = 1
    for _, c in ipairs(cols) do
        gpu.set(x + 1, LIST_Y, c[1]:sub(1, c[3] - 1))
        x = x + c[3]
    end

    local start = (page - 1) * perPage + 1
    for i = 0, perPage - 1 do
        local idx = start + i
        local row = rows[idx]
        local ry = DATA_Y + i
        if ry >= FOOT_Y then break end
        local sel = (selRow == idx)
        gpu.setBackground(sel and C.ROW_SEL or
                              (i % 2 == 0 and C.ROW_A or C.ROW_B))
        gpu.setForeground(C.FG)
        gpu.fill(1, ry, W, 1, ' ')
        if row then
            x = 1
            for _, c in ipairs(cols) do
                local val = tostring(row[c[2]] or '')
                gpu.setForeground(c[4] and c[4](row) or C.FG)
                gpu.set(x + 1, ry, val:sub(1, c[3] - 1))
                x = x + c[3]
            end
            reg(1, ry, W, 1, 'ROW_' .. idx)
        end
    end
end

-- ─── Overlays ────────────────────────────────────────────────────────────────

local function showText(title, hint, onOk)
    ov = {type = 'text', title = title, hint = hint, val = '', onOk = onOk}
end

local function showNum(title, onOk)
    ov = {type = 'num', title = title, val = '', onOk = onOk}
end

--- Begin keypad PIN entry. Shows a waiting overlay; keypad handles input.
--- Caller must check keypad ~= nil before calling.
local function showPin(title, onOk)
    if not keypad then return end
    pinBuf = ''
    pinCb  = onOk
    keypad.setDisplay('PIN:') ---@diagnostic disable-line: undefined-field
    ov = {type = 'pinwait', title = title}
end

local function showConfirm(msg, onOk)
    ov = {type = 'confirm', msg = msg, onOk = onOk}
end

local function showStatus(msg, isErr)
    ov = {type = 'status', msg = msg, err = isErr}
end

local function drawTextOv()
    local title = tostring(ov and ov.title or '')
    local hint = ov and ov.hint
    local val = tostring(ov and ov.val or '')
    local ow = math.min(W - 4, 48)
    local oh = 7
    local ox = math.floor((W - ow) / 2) + 1
    local oy = math.floor((H - oh) / 2) + 1
    gpu.setBackground(C.OV_BG)
    gpu.fill(ox, oy, ow, oh, ' ')
    gpu.setBackground(C.OV_HDR)
    gpu.fill(ox, oy, ow, 1, ' ')
    gpu.setForeground(C.HDR_FG)
    centerText(ox, oy, ow, title)
    if hint then
        gpu.setBackground(C.OV_BG)
        gpu.setForeground(C.DIM)
        gpu.set(ox + 1, oy + 1, hint:sub(1, ow - 2))
    end
    gpu.setBackground(0x1a1a2e)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(ox + 1, oy + 3, ow - 2, 1, ' ')
    gpu.set(ox + 2, oy + 3, val .. '_')
    local half = math.floor(ow / 2)
    drawBtn(ox + 1, oy + 5, half - 2, 'OK', C.BTN_OK)
    reg(ox + 1, oy + 5, half - 2, 1, 'OV_OK')
    drawBtn(ox + half, oy + 5, ow - half - 1, 'Cancel', C.BTN_DIM)
    reg(ox + half, oy + 5, ow - half - 1, 1, 'OV_CANCEL')
end

--- Waiting overlay shown while the physical keypad is collecting a PIN.
local function drawPinWaitOv()
    local title = tostring(ov and ov.title or '')
    local ow = math.min(W - 4, 44)
    local oh = 6
    local ox = math.floor((W - ow) / 2) + 1
    local oy = math.floor((H - oh) / 2) + 1
    gpu.setBackground(C.OV_BG)
    gpu.fill(ox, oy, ow, oh, ' ')
    gpu.setBackground(C.OV_HDR)
    gpu.fill(ox, oy, ow, 1, ' ')
    gpu.setForeground(C.HDR_FG)
    centerText(ox, oy, ow, title)
    gpu.setBackground(C.OV_BG)
    gpu.setForeground(C.DIM)
    centerText(ox, oy + 2, ow, 'Enter PIN on the keypad')
    centerText(ox, oy + 3, ow, string.rep('*', #pinBuf) .. (pinBuf == '' and '_' or ''))
    gpu.setForeground(C.DIM)
    centerText(ox, oy + 4, ow, '# = confirm   * = backspace/cancel')
    drawBtn(ox + math.floor(ow / 2) - 4, oy + oh - 1, 8, 'Cancel', C.BTN_DIM)
    reg(ox + math.floor(ow / 2) - 4, oy + oh - 1, 8, 1, 'OV_CANCEL')
end

local NUM_PAD = {
    {'7', '8', '9'}, {'4', '5', '6'}, {'1', '2', '3'}, {'.', '0', '<'}
}

local function drawNumOv()
    local title = tostring(ov and ov.title or '')
    local val = tostring(ov and ov.val or '')
    local bw, bh = 7, 2
    local ow = 3 * (bw + 1) + 2
    local oh = 4 * (bh + 1) + 7
    local ox = math.floor((W - ow) / 2) + 1
    local oy = math.floor((H - oh) / 2) + 1
    gpu.setBackground(C.OV_BG)
    gpu.fill(ox, oy, ow, oh, ' ')
    gpu.setBackground(C.OV_HDR)
    gpu.fill(ox, oy, ow, 1, ' ')
    gpu.setForeground(C.HDR_FG)
    centerText(ox, oy, ow, title)
    gpu.setBackground(0x1a1a2e)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(ox + 1, oy + 2, ow - 2, 1, ' ')
    local disp = val == '' and '$0.00' or '$' .. val
    gpu.set(ox + 2, oy + 2, disp)
    local padX, padY = ox + 1, oy + 4
    for r, row in ipairs(NUM_PAD) do
        for c, lbl in ipairs(row) do
            local bx = padX + (c - 1) * (bw + 1)
            local by = padY + (r - 1) * (bh + 1)
            local bg = lbl == '<' and 0x443300 or C.NUM_BG
            gpu.setBackground(bg)
            gpu.setForeground(0xFFFFFF)
            gpu.fill(bx, by, bw, bh, ' ')
            centerText(bx, by, bw, lbl)
            reg(bx, by, bw, bh, 'N_' .. lbl)
        end
    end
    local clrY = padY + 4 * (bh + 1)
    drawBtn(ox + 1, clrY, ow - 2, 'CLEAR', 0x443300)
    reg(ox + 1, clrY, ow - 2, 1, 'N_CLR')
    local okY = clrY + 2
    local half = math.floor(ow / 2)
    drawBtn(ox + 1, okY, half - 2, 'OK', C.BTN_OK)
    reg(ox + 1, okY, half - 2, 1, 'OV_OK')
    drawBtn(ox + half, okY, ow - half - 1, 'Cancel', C.BTN_DIM)
    reg(ox + half, okY, ow - half - 1, 1, 'OV_CANCEL')
end

local function drawConfirmOv()
    local msg = tostring(ov and ov.msg or '')
    local ow = math.min(W - 4, 50)
    local oh = 5
    local ox = math.floor((W - ow) / 2) + 1
    local oy = math.floor((H - oh) / 2) + 1
    gpu.setBackground(0x1a0a00)
    gpu.fill(ox, oy, ow, oh, ' ')
    gpu.setBackground(C.BTN_WARN)
    gpu.fill(ox, oy, ow, 1, ' ')
    gpu.setForeground(0xFFFFFF)
    centerText(ox, oy, ow, 'Confirm')
    gpu.setBackground(0x1a0a00)
    gpu.setForeground(C.FG)
    centerText(ox, oy + 2, ow, msg)
    local half = math.floor(ow / 2)
    drawBtn(ox + 1, oy + 4, half - 2, 'OK', C.BTN_OK)
    reg(ox + 1, oy + 4, half - 2, 1, 'OV_OK')
    drawBtn(ox + half, oy + 4, ow - half - 1, 'Cancel', C.BTN_DIM)
    reg(ox + half, oy + 4, ow - half - 1, 1, 'OV_CANCEL')
end

-- {displayRGB, label, colors.X value}
local COLOR_SWATCHES = {
    {0xF9FFFE, 'White', colors.white}, {0xF9801D, 'Orange', colors.orange},
    {0xC74EBD, 'Magenta', colors.magenta},
    {0x3AB3DA, 'Light Blue', colors.lightBlue},
    {0xFED83D, 'Yellow', colors.yellow}, {0x00FF00, 'Lime', colors.lime},
    {0xF38BAA, 'Pink', colors.pink}, {0x474F52, 'Gray', colors.gray},
    {0x9D9D97, 'Light Gray', colors.lightGray}, {0x169C9C, 'Cyan', colors.cyan},
    {0x8932B8, 'Purple', colors.purple}, {0x3C44AA, 'Blue', colors.blue},
    {0x5e2f00, 'Brown', colors.brown}, {0x008000, 'Green', colors.green},
    {0xFF0000, 'Red', colors.red}, {0x1D1D21, 'Black', colors.black}
}

local function drawColorPickOv()
    local cols, rows_n = 4, 4
    local sw, sh = 14, 2
    local ow = cols * sw + 2
    local oh = rows_n * (sh + 1) + 4
    local ox = math.floor((W - ow) / 2) + 1
    local oy = math.floor((H - oh) / 2) + 1

    gpu.setBackground(C.OV_BG)
    gpu.fill(ox, oy, ow, oh, ' ')
    gpu.setBackground(C.OV_HDR)
    gpu.fill(ox, oy, ow, 1, ' ')
    gpu.setForeground(C.HDR_FG)
    centerText(ox, oy, ow, 'Card Colour')

    for i, swatch in ipairs(COLOR_SWATCHES) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local sx = ox + 1 + col * sw
        local sy = oy + 2 + row * (sh + 1)
        local dispRGB = swatch[1]
        local label = swatch[2]
        local fg = (dispRGB < 0x888888) and 0xFFFFFF or 0x000000
        gpu.setBackground(dispRGB)
        gpu.setForeground(fg)
        gpu.fill(sx, sy, sw, sh, ' ')
        centerText(sx, sy, sw, label)
        reg(sx, sy, sw, sh, 'CLR_' .. i)
    end

    drawBtn(ox + 1, oy + oh - 2, ow - 2, 'Cancel', C.BTN_DIM)
    reg(ox + 1, oy + oh - 2, ow - 2, 1, 'OV_CANCEL')
end

local function showColorPick(onOk) ov = {type = 'colorpick', onOk = onOk} end

local function drawSwipeOv()
    local msg = tostring(ov and ov.msg or 'Swipe card now...')
    local ow = math.min(W - 4, 44)
    local oh = 6
    local ox = math.floor((W - ow) / 2) + 1
    local oy = math.floor((H - oh) / 2) + 1
    gpu.setBackground(0x001a33)
    gpu.fill(ox, oy, ow, oh, ' ')
    gpu.setBackground(0x003366)
    gpu.fill(ox, oy, ow, 1, ' ')
    gpu.setForeground(0xFFFFFF)
    centerText(ox, oy, ow, 'Waiting for Card')
    gpu.setBackground(0x001a33)
    gpu.setForeground(0xCCCCCC)
    centerText(ox, oy + 2, ow, msg)
    gpu.setForeground(C.DIM)
    centerText(ox, oy + 3, ow, 'Swipe card through reader...')
    drawBtn(ox + math.floor(ow / 2) - 4, oy + 5, 8, 'Cancel', C.BTN_DIM)
    reg(ox + math.floor(ow / 2) - 4, oy + 5, 8, 1, 'OV_CANCEL')
end

local function drawStatusOv()
    local isErr = ov and ov.err
    local msg = tostring(ov and ov.msg or '')
    local ow = math.min(W - 4, 52)
    local oh = 5
    local ox = math.floor((W - ow) / 2) + 1
    local oy = math.floor((H - oh) / 2) + 1
    gpu.setBackground(0x0a0a0a)
    gpu.fill(ox, oy, ow, oh, ' ')
    gpu.setBackground(isErr and 0x550000 or 0x005500)
    gpu.fill(ox, oy, ow, 1, ' ')
    gpu.setForeground(0xFFFFFF)
    centerText(ox, oy, ow, isErr and 'Error' or 'Done')
    gpu.setBackground(0x0a0a0a)
    gpu.setForeground(C.FG)
    centerText(ox, oy + 2, ow, msg:sub(1, ow - 2))
    drawBtn(ox + math.floor(ow / 2) - 3, oy + 4, 6, 'OK', C.BTN)
    reg(ox + math.floor(ow / 2) - 3, oy + 4, 6, 1, 'OV_DISMISS')
end

-- ─── Tab content ─────────────────────────────────────────────────────────────

local ACCT_STATUS = {[0] = 'Active', [1] = 'Frozen', [2] = 'Closed'}

local function loadTab()
    if tab == 1 then
        rows = {}
        for _, a in ipairs(db.select('accounts'):all()) do
            local bal = (db.select('account_balance'):where({accountId = a.id})
                            :first() or {}).balance or 0
            rows[#rows + 1] = {
                id = a.id,
                name = a.account_name,
                status = ACCT_STATUS[a.account_status] or '?',
                balance = ('$%.2f'):format(bal / 100),
                _status = a.account_status
            }
        end
    elseif tab == 2 then
        rows = {}
        local statusLabel = {[0] = 'Active', [1] = 'Inactive', [2] = 'Revoked'}
        for _, c in ipairs(db.select('cards'):all()) do
            local acct = Account.getById(c.account_id)
            rows[#rows + 1] = {
                id = c.id,
                account = acct and acct.account_name or ('id=' .. c.account_id),
                uid = tostring(c.uid or ''):sub(1, 20),
                status = statusLabel[c.status] or '?',
                _status = c.status,
                _uid = c.uid,
                _acct_id = c.account_id
            }
        end
    elseif tab == 3 then
        rows = {} -- Money tab has no list
    elseif tab == 4 then
        rows = {}
        local devStatus = {
            [0] = 'pending',
            [1] = 'active',
            [2] = 'suspended',
            [3] = 'revoked'
        }
        for _, d in ipairs(DeviceService.list()) do
            rows[#rows + 1] = {
                device_id = d.device_id,
                dtype = d.device_type or '?',
                status = devStatus[d.status] or '?',
                reg = os.date('%m-%d %H:%M', d.registered_at or 0),
                _status = d.status,
                _did = d.device_id
            }
        end
    elseif tab == 5 then
        rows = {}
        for _, h in ipairs(ledgerService.listHolds()) do
            local days = math.floor(h.capturesIn)
            local hours = math.floor((h.capturesIn - days) * 24)
            rows[#rows + 1] = {
                id = h.holdId,
                acct = tostring(h.accountId),
                amount = ('$%.2f'):format(h.amount / 100),
                capIn = ('%dd %dh'):format(days, hours),
                _id = h.holdId
            }
        end
    end
    selRow = nil
    page = 1
end

local ACCT_COLS = {
    {'ID', 'id', 6}, {'Name', 'name', 22}, {
        'Status', 'status', 10, function(r)
            return r._status == 0 and C.GREEN or r._status == 1 and C.YELLOW or
                       C.DIM
        end
    }, {'Balance', 'balance', 12, function() return C.GREEN end}
}

local CARD_COLS = {
    {'ID', 'id', 6}, {'Account', 'account', 20}, {'UID', 'uid', 22}, {
        'Status', 'status', 10, function(r)
            return r._status == 0 and C.GREEN or r._status == 2 and C.RED or
                       C.YELLOW
        end
    }
}

local DEV_COLS = {
    {'Device ID', 'device_id', 20}, {'Type', 'dtype', 12}, {
        'Status', 'status', 12, function(r)
            return r._status == 1 and C.GREEN or r._status == 0 and C.YELLOW or
                       C.RED
        end
    }, {'Registered', 'reg', 18}
}

local HOLD_COLS = {
    {'Hold ID', 'id', 10}, {'Account ID', 'acct', 14},
    {'Amount', 'amount', 12, function() return C.GREEN end},
    {'Captures In', 'capIn', 14}
}

local function drawContent()
    if tab == 1 then
        drawList(ACCT_COLS)
        local sel = selRow and rows[selRow]
        local frozen = sel and sel._status == 1
        drawFooter({
            {'New Account', 'ACT_NEW_ACCT', C.BTN_ACT}, {
                frozen and 'Unfreeze' or 'Freeze',
                frozen and 'ACT_UNFREEZE' or 'ACT_FREEZE',
                sel and (frozen and C.BTN_ACT or C.BTN_WARN) or C.BTN_DIM
            }, {'Refresh', 'ACT_REFRESH', C.BTN}
        })
    elseif tab == 2 then
        drawList(CARD_COLS)
        local sel = selRow and rows[selRow]
        drawFooter({
            {'Create Card', 'ACT_CREATE_CARD', C.BTN_ACT},
            {'Issue Card', 'ACT_ISSUE_CARD', C.BTN_ACT}, {
                'Revoke Card', 'ACT_REVOKE_CARD',
                sel and sel._status ~= 2 and C.BTN_WARN or C.BTN_DIM
            }, {
                'Update PIN', 'ACT_UPDATE_PIN',
                sel and sel._status == 0 and C.BTN or C.BTN_DIM
            }, {'Refresh', 'ACT_REFRESH', C.BTN}
        })
    elseif tab == 3 then
        -- Money tab: operation tiles
        gpu.setBackground(C.BG)
        gpu.fill(1, LIST_Y, W, FOOT_Y - LIST_Y, ' ')
        local ops = {
            {'Mint Funds', 'ACT_MINT', C.BTN_OK},
            {'Burn Funds', 'ACT_BURN', C.BTN_NEG},
            {'Transfer', 'ACT_TRANSFER', C.BTN_ACT},
            {'Refund', 'ACT_REFUND', C.BTN_WARN},
            {'Chargeback', 'ACT_CHARGEBACK', 0x443300}
        }
        local tileW = math.floor(W / 3)
        local tileH = 4
        local startY = LIST_Y + 2
        for i, op in ipairs(ops) do
            local col = (i - 1) % 3
            local row_i = math.floor((i - 1) / 3)
            local x = col * tileW + 1
            local y = startY + row_i * (tileH + 2)
            local w = (col == 2) and (W - x + 1) or tileW
            gpu.setBackground(op[3])
            gpu.setForeground(C.BTN_FG)
            gpu.fill(x + 1, y, w - 2, tileH, ' ')
            centerText(x + 1, y + math.floor(tileH / 2), w - 2, op[1])
            reg(x + 1, y, w - 2, tileH, op[2])
        end
        drawFooter(nil)
    elseif tab == 4 then
        drawList(DEV_COLS)
        local sel = selRow and rows[selRow]
        drawFooter({
            {
                'Trust Device', 'ACT_TRUST_DEV',
                sel and sel._status == 0 and C.BTN_OK or C.BTN_DIM
            }, {
                'Revoke Device', 'ACT_REVOKE_DEV',
                sel and sel._status ~= 3 and C.BTN_WARN or C.BTN_DIM
            }, {'Refresh', 'ACT_REFRESH', C.BTN}
        })
    elseif tab == 5 then
        drawList(HOLD_COLS)
        local sel = selRow and rows[selRow]
        drawFooter({
            {'Capture Now', 'ACT_CAPTURE_HOLD', sel and C.BTN_OK or C.BTN_DIM},
            {
                'Release Hold', 'ACT_RELEASE_HOLD',
                sel and C.BTN_WARN or C.BTN_DIM
            }, {'Refresh', 'ACT_REFRESH', C.BTN}
        })
    end
end

-- ─── Full redraw ─────────────────────────────────────────────────────────────

local function redraw()
    btns = {}
    drawHeader()
    drawTabs()
    drawContent()
    if ov then
        if ov.type == 'text' then
            drawTextOv()
        elseif ov.type == 'num' then
            drawNumOv()
        elseif ov.type == 'confirm' then
            drawConfirmOv()
        elseif ov.type == 'status' then
            drawStatusOv()
        elseif ov.type == 'swipe' then
            drawSwipeOv()
        elseif ov.type == 'colorpick' then
            drawColorPickOv()
        elseif ov.type == 'pinwait' then
            drawPinWaitOv()
        end
    end
end

-- ─── Dollar amount helper ────────────────────────────────────────────────────

local function parseDollars(s)
    local d = tonumber(s)
    if not d or d <= 0 then return nil end
    return math.floor(d * 100 + 0.5)
end

local function fmtDollars(cents) return ('$%.2f'):format(cents / 100) end

-- ─── Account lookup helper ───────────────────────────────────────────────────

local function lookupAcct(name, cb)
    local a = Account.get(name)
    if not a then
        showStatus('Account "' .. name .. '" not found', true)
        redraw()
        return
    end
    cb(a)
end

-- ─── Action handlers ─────────────────────────────────────────────────────────

local function actNewAcct()
    showText('New Account', 'Enter account name:', function(name)
        if name == '' then
            ov = nil;
            redraw();
            return
        end
        local id, err = accountService.createAccount(name)
        if err then
            showStatus(err.message, true)
        else
            setStatus(('Created "%s"  id=%d'):format(name, id))
            loadTab()
            ov = nil
        end
        redraw()
    end)
    redraw()
end

local function actFreeze()
    local sel = selRow and rows[selRow]
    if not sel then return end
    showConfirm('Freeze account "' .. sel.name .. '"?', function()
        local _, err = ledgerService.freezeAccount(sel.id)
        if err then
            showStatus(err.message, true)
        else
            setStatus('Account "' .. sel.name .. '" frozen.');
            loadTab()
        end
        ov = nil;
        redraw()
    end)
    redraw()
end

local function actUnfreeze()
    local sel = selRow and rows[selRow]
    if not sel then return end
    showConfirm('Unfreeze account "' .. sel.name .. '"?', function()
        local _, err = ledgerService.unfreezeAccount(sel.id)
        if err then
            showStatus(err.message, true)
        else
            setStatus('Account "' .. sel.name .. '" unfrozen.');
            loadTab()
        end
        ov = nil;
        redraw()
    end)
    redraw()
end

local function actRevokeCard()
    local sel = selRow and rows[selRow]
    if not sel or sel._status == 2 then return end
    showConfirm('Revoke card uid=' .. tostring(sel._uid):sub(1, 16) .. '?',
                function()
        local ok, err = cardService.revokeCard(sel._uid)
        if not ok then
            showStatus(tostring(err), true)
        else
            setStatus('Card revoked.');
            loadTab()
        end
        ov = nil;
        redraw()
    end)
    redraw()
end

local function actMint()
    showText('Mint Funds', 'Account name:', function(name)
        lookupAcct(name, function(acct)
            showNum(('Mint into "%s":'):format(acct.account_name),
                    function(amtStr)
                local cents = parseDollars(amtStr)
                if not cents then
                    showStatus('Invalid amount', true);
                    redraw();
                    return
                end
                local _, err = ledgerService.mint(acct.id, cents)
                if err then
                    showStatus(err.message, true)
                else
                    setStatus(('Minted %s into "%s"'):format(fmtDollars(cents),
                                                             acct.account_name));
                    loadTab()
                end
                ov = nil;
                redraw()
            end)
            redraw()
        end)
        redraw()
    end)
    redraw()
end

local function actBurn()
    showText('Burn Funds', 'Account name:', function(name)
        lookupAcct(name, function(acct)
            showNum(('Burn from "%s":'):format(acct.account_name),
                    function(amtStr)
                local cents = parseDollars(amtStr)
                if not cents then
                    showStatus('Invalid amount', true);
                    redraw();
                    return
                end
                local _, err = ledgerService.burn(acct.id, cents)
                if err then
                    showStatus(err.message, true)
                else
                    setStatus(('Burned %s from "%s"'):format(fmtDollars(cents),
                                                             acct.account_name));
                    loadTab()
                end
                ov = nil;
                redraw()
            end)
            redraw()
        end)
        redraw()
    end)
    redraw()
end

local function actTransfer()
    showText('Transfer: From', 'Source account name:', function(fromName)
        lookupAcct(fromName, function(fromAcct)
            showText('Transfer: To', 'Destination account name:',
                     function(toName)
                lookupAcct(toName, function(toAcct)
                    showNum(('Transfer %s → %s:'):format(
                                fromAcct.account_name, toAcct.account_name),
                            function(amtStr)
                        local cents = parseDollars(amtStr)
                        if not cents then
                            showStatus('Invalid amount', true);
                            redraw();
                            return
                        end
                        local _, err = ledgerService.adminTransfer(fromAcct.id,
                                                                   toAcct.id,
                                                                   cents)
                        if err then
                            showStatus(err.message, true)
                        else
                            setStatus(
                                ('Transferred %s from "%s" to "%s"'):format(
                                    fmtDollars(cents), fromAcct.account_name,
                                    toAcct.account_name))
                        end
                        ov = nil;
                        redraw()
                    end)
                    redraw()
                end)
                redraw()
            end)
            redraw()
        end)
        redraw()
    end)
    redraw()
end

local function actRefund()
    showText('Refund: Debit From', 'Account to debit (e.g. store):',
             function(fromName)
        lookupAcct(fromName, function(fromAcct)
            showText('Refund: Credit To', 'Account to credit (e.g. customer):',
                     function(toName)
                lookupAcct(toName, function(toAcct)
                    showNum('Refund Amount:', function(amtStr)
                        local cents = parseDollars(amtStr)
                        if not cents then
                            showStatus('Invalid amount', true);
                            redraw();
                            return
                        end
                        local _, err = ledgerService.refund(fromAcct.id,
                                                            toAcct.id, cents)
                        if err then
                            showStatus(err.message, true)
                        else
                            setStatus(('Refunded %s from "%s" to "%s"'):format(
                                          fmtDollars(cents),
                                          fromAcct.account_name,
                                          toAcct.account_name))
                        end
                        ov = nil;
                        redraw()
                    end)
                    redraw()
                end)
                redraw()
            end)
            redraw()
        end)
        redraw()
    end)
    redraw()
end

local function actChargeback()
    showText('Chargeback: Debit From', 'Account to debit:', function(fromName)
        lookupAcct(fromName, function(fromAcct)
            showText('Chargeback: Credit To', 'Account to credit:',
                     function(toName)
                lookupAcct(toName, function(toAcct)
                    showNum('Chargeback Amount:', function(amtStr)
                        local cents = parseDollars(amtStr)
                        if not cents then
                            showStatus('Invalid amount', true);
                            redraw();
                            return
                        end
                        local _, err = ledgerService.chargeback(fromAcct.id,
                                                                toAcct.id, cents)
                        if err then
                            showStatus(err.message, true)
                        else
                            setStatus(
                                ('Chargeback %s from "%s" to "%s"'):format(
                                    fmtDollars(cents), fromAcct.account_name,
                                    toAcct.account_name))
                        end
                        ov = nil;
                        redraw()
                    end)
                    redraw()
                end)
                redraw()
            end)
            redraw()
        end)
        redraw()
    end)
    redraw()
end

local function actTrustDevice()
    local sel = selRow and rows[selRow]
    if not sel or sel._status ~= 0 then return end
    showConfirm('Trust device "' .. sel.device_id .. '"?', function()
        local ok = DeviceService.trust(sel._did, nil)
        if ok then
            setStatus('Trusted "' .. sel.device_id .. '"');
            loadTab()
        else
            showStatus('Trust failed', true)
        end
        ov = nil;
        redraw()
    end)
    redraw()
end

local function actRevokeDevice()
    local sel = selRow and rows[selRow]
    if not sel or sel._status == 3 then return end
    showConfirm('Revoke device "' .. sel.device_id .. '"?', function()
        DeviceService.revoke(sel._did)
        setStatus('Revoked "' .. sel.device_id .. '"')
        loadTab();
        ov = nil;
        redraw()
    end)
    redraw()
end

local function actCaptureHold()
    local sel = selRow and rows[selRow]
    if not sel then return end
    showConfirm(('Capture hold #%d (%s) now?'):format(sel.id, sel.amount),
                function()
        local ok, err = ledgerService.adminCaptureHold(sel._id)
        if ok then
            setStatus(('Hold #%d captured — store credited.'):format(sel.id));
            loadTab()
        else
            showStatus(tostring(err), true)
        end
        ov = nil;
        redraw()
    end)
    redraw()
end

local function actReleaseHold()
    local sel = selRow and rows[selRow]
    if not sel then return end
    showConfirm(('Release hold #%d (%s)?'):format(sel.id, sel.amount),
                function()
        local ok, err = ledgerService.adminReleaseHold(sel._id)
        if ok then
            setStatus(('Hold #%d released.'):format(sel.id));
            loadTab()
        else
            showStatus(tostring(err), true)
        end
        ov = nil;
        redraw()
    end)
    redraw()
end

--- Show the "swipe card" overlay and fire cb(salt, uid) when magData arrives.
local function waitForCard(msg, cb)
    cardWaitCb = cb
    cardWaitExpires = computer.uptime() + 10
    ov = {type = 'swipe', msg = msg}
    redraw()
end

local function actCreateCard()
    if not dataComp then
        showStatus('No data component available', true);
        redraw();
        return
    end
    if not component.isAvailable('os_cardwriter') then
        showStatus('No card writer attached', true);
        redraw();
        return
    end
    showText('Create Card', 'Display name for the card:', function(displayName)
        if displayName == '' then
            ov = nil;
            redraw();
            return
        end
        showColorPick(function(colorVal)
            local salt = dataComp.encode64(dataComp.random(16))
            local ok, err = pcall(function()
                component.os_cardwriter.write(salt, displayName, true, colorVal)
            end)
            if not ok then
                showStatus('Card writer error: ' .. tostring(err), true)
            else
                setStatus(
                    ('Card written: "%s"  —  salt saved to card'):format(
                        displayName))
                ov = nil
            end
            redraw()
        end)
        redraw()
    end)
    redraw()
end

local function actIssueCard()
    if not dataComp then
        showStatus('No data component available', true);
        redraw();
        return
    end
    if not component.isAvailable('os_magreader') then
        showStatus('No card reader attached', true);
        redraw();
        return
    end
    if not keypad then
        showStatus('No keypad attached', true);
        redraw();
        return
    end
    showText('Issue Card: Account', 'Account name to link card to:',
             function(name)
        lookupAcct(name, function(acct)
            waitForCard(('Issuing to "%s" — swipe card:'):format(
                            acct.account_name), function(salt, uid)
                if not salt or not uid then
                    showStatus('Card read failed', true);
                    redraw();
                    return
                end
                showPin('Issue Card: PIN', function(pinStr)
                    local pin = pinStr ~= '' and pinStr or '0000'
                    local pinHash = dataComp.encode64(
                                        dataComp.sha256(pin .. salt))
                    local result, err = cardService.issueCard(acct.id, uid,
                                                              pinHash)
                    if err then
                        showStatus(err.message, true)
                    else
                        setStatus(('Card issued id=%d to "%s"'):format(
                                      result.cardId, acct.account_name))
                        loadTab();
                        ov = nil
                    end
                    redraw()
                end)
                redraw()
            end)
        end)
        redraw()
    end)
    redraw()
end

local function actUpdatePin()
    local sel = selRow and rows[selRow]
    if not sel or sel._status ~= 0 then return end
    if not dataComp then
        showStatus('No data component available', true);
        redraw();
        return
    end
    if not component.isAvailable('os_magreader') then
        showStatus('No card reader attached', true);
        redraw();
        return
    end
    if not keypad then
        showStatus('No keypad attached', true);
        redraw();
        return
    end
    waitForCard(('Swipe card to read salt (uid=%s):'):format(
                    tostring(sel._uid):sub(1, 16)), function(salt, uid)
        if not salt or not uid then
            showStatus('Card read failed', true);
            redraw();
            return
        end
        if uid ~= sel._uid then
            showStatus('Wrong card swiped', true);
            redraw();
            return
        end
        showPin('Update PIN: New PIN', function(pinStr)
            local pin = pinStr ~= '' and pinStr or '0000'
            local pinHash = dataComp.encode64(dataComp.sha256(pin .. salt))
            local ok, err = Card.updatePin(sel._uid, pinHash)
            if not ok then
                showStatus(tostring(err), true)
            else
                ledgerService.pinChange(sel._acct_id, sel._uid)
                setStatus('PIN updated for uid=' ..
                              tostring(sel._uid):sub(1, 20))
                loadTab()
                ov = nil
            end
            redraw()
        end)
        redraw()
    end)
end

local ACTIONS = {
    ACT_REFRESH = function()
        loadTab();
        redraw()
    end,
    ACT_NEW_ACCT = actNewAcct,
    ACT_FREEZE = actFreeze,
    ACT_UNFREEZE = actUnfreeze,
    ACT_CREATE_CARD = actCreateCard,
    ACT_ISSUE_CARD = actIssueCard,
    ACT_UPDATE_PIN = actUpdatePin,
    ACT_REVOKE_CARD = actRevokeCard,
    ACT_MINT = actMint,
    ACT_BURN = actBurn,
    ACT_TRANSFER = actTransfer,
    ACT_REFUND = actRefund,
    ACT_CHARGEBACK = actChargeback,
    ACT_TRUST_DEV = actTrustDevice,
    ACT_REVOKE_DEV = actRevokeDevice,
    ACT_CAPTURE_HOLD = actCaptureHold,
    ACT_RELEASE_HOLD = actReleaseHold
}

-- ─── Touch handler ───────────────────────────────────────────────────────────

local function onTouch(x, y)
    local id = hit(x, y)
    if not id then return end

    -- Overlay buttons
    if id == 'OV_OK' then
        if ov then
            local t, cb, val = ov.type, ov.onOk, ov.val
            if t == 'status' then
                ov = nil;
                redraw()
            elseif t == 'confirm' or t == 'text' or t == 'num' then
                ov = nil
                if cb then cb(val) end
            end
        end
        return
    elseif id == 'OV_CANCEL' then
        cardWaitCb = nil;
        cardWaitExpires = nil
        pinCb = nil;
        pinBuf = ''
        if keypad and ov and ov.type == 'pinwait' then
            keypad.setDisplay('§aReady') ---@diagnostic disable-line: undefined-field
        end
        ov = nil;
        redraw();
        return
    elseif id == 'OV_DISMISS' then
        ov = nil;
        redraw();
        return
    end

    -- Numpad buttons
    if ov and ov.type == 'num' then
        local lbl = id:match('^N_(.+)$')
        if lbl then
            if lbl == 'CLR' then
                ov.val = ''
            elseif lbl == '<' then
                ov.val = ov.val:sub(1, -2)
            elseif lbl == '.' then
                if not ov.val:find('%.') then
                    ov.val = ov.val .. '.'
                end
            else
                -- Limit to 2 decimal places
                local dotPos = ov.val:find('%.')
                if dotPos and #ov.val - dotPos >= 2 then
                    -- at max decimals, ignore
                else
                    ov.val = ov.val .. lbl
                end
            end
            redraw()
        end
        return
    end

    -- Color picker swatch
    local clrIdx = id:match('^CLR_(%d+)$')
    if clrIdx and ov and ov.type == 'colorpick' then
        local n = tonumber(clrIdx)
        local cb = ov.onOk
        ov = nil
        if cb and n and COLOR_SWATCHES[n] then cb(COLOR_SWATCHES[n][3]) end
        return
    end

    -- Tab buttons
    local tabIdx = id:match('^TAB_(%d+)$')
    if tabIdx then
        local n = tonumber(tabIdx)
        if n and n ~= tab then
            tab = n;
            loadTab();
            redraw()
        end
        return
    end

    -- Row selection
    local rowIdx = id:match('^ROW_(%d+)$')
    if rowIdx then
        local n = tonumber(rowIdx)
        selRow = (selRow == n) and nil or n
        redraw()
        return
    end

    -- Action buttons
    if ACTIONS[id] then
        ACTIONS[id]()
        return
    end
end

-- ─── Keyboard handler ────────────────────────────────────────────────────────

local function onKey(char, code)
    if not ov or (ov.type ~= 'text' and ov.type ~= 'num') then return end

    if code == 28 then -- Enter
        local cb, val = ov.onOk, ov.val
        ov = nil
        if cb then cb(val) end
        return
    elseif code == 1 then -- Escape
        ov = nil;
        redraw();
        return
    elseif code == 14 then -- Backspace
        ov.val = ov.val:sub(1, -2)
        redraw();
        return
    end

    if char and char > 31 and char < 127 then
        local ch = string.char(char)
        if ov.type == 'num' then
            if ch:match('[0-9]') then
                local dotPos = ov.val:find('%.')
                if not dotPos or #ov.val - dotPos < 2 then
                    ov.val = ov.val .. ch
                end
            elseif ch == '.' and not ov.val:find('%.') then
                ov.val = ov.val .. '.'
            end
        else
            ov.val = ov.val .. ch
        end
        redraw()
    end
end

-- ─── Main ────────────────────────────────────────────────────────────────────

local AdminUI = {}

function AdminUI.run()
    cls()
    loadTab()
    redraw()

    while running do
        local e = {event.pull(1)}
        local typ = e[1]
        if typ == 'interrupted' then
            break
        elseif typ == 'touch' and e[2] == screen.address then
            onTouch(e[3], e[4])
        elseif typ == 'key_down' then
            onKey(e[3], e[4])
        elseif typ == 'keypad' and pinCb and keypad then
            -- e[4] is the button label from os_keypad
            local lbl = e[4]
            if lbl == '*' then
                if #pinBuf > 0 then
                    pinBuf = pinBuf:sub(1, -2)
                    keypad.setDisplay(#pinBuf == 0 and 'PIN:' or string.rep('*', #pinBuf)) ---@diagnostic disable-line: undefined-field
                else
                    -- * on empty = cancel
                    pinCb  = nil
                    pinBuf = ''
                    keypad.setDisplay('§aReady') ---@diagnostic disable-line: undefined-field
                    ov = nil
                end
                redraw()
            elseif lbl == '#' then
                if #pinBuf > 0 then
                    local cb = pinCb
                    local pin = pinBuf
                    pinCb  = nil
                    pinBuf = ''
                    keypad.setDisplay('§aReady') ---@diagnostic disable-line: undefined-field
                    ov = nil
                    cb(pin)
                end
            elseif lbl:match('%d') and #pinBuf < 6 then
                pinBuf = pinBuf .. lbl
                keypad.setDisplay(string.rep('*', #pinBuf)) ---@diagnostic disable-line: undefined-field
                redraw()
            end
        elseif typ == 'magData' and cardWaitCb then
            local cb = cardWaitCb
            cardWaitCb = nil;
            cardWaitExpires = nil
            ov = nil
            cb(e[4], e[5]) -- salt, uid
        else
            -- Tick — update clock and check card-wait timeout
            if cardWaitCb and cardWaitExpires and computer.uptime() >
                cardWaitExpires then
                cardWaitCb = nil;
                cardWaitExpires = nil
                showStatus('Card swipe timed out', true)
                ov = nil;
                redraw()
            else
                drawHeader()
            end
        end
    end

    cls()
end

return AdminUI
