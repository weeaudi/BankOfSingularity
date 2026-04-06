local component     = require('component')
local event         = require('event')

-- Use touchscreen GUI when gpu+screen are available, fall back to text CLI.
local AdminUI = require('src.adminUI')
if AdminUI and AdminUI.run then
    local Admin = {}
    function Admin.run() AdminUI.run() end
    return Admin
end

local db            = require('src.db').database
local Account       = require('src.models.Account')
local Card          = require('src.models.Card')
local accountService = require('src.services.accountService')
local cardService    = require('src.services.cardService')
local ledgerService  = require('src.services.ledgerService')
local LedgerMod      = require('src.models.Ledger')
local DeviceService  = require('src.services.deviceService')

local Admin = {}

local function prompt(msg)
    io.write(msg)
    return io.read()
end

local function createAccount()
    local name = prompt('Account name: ')
    if not name or name == '' then print('Cancelled.') return end

    local id, err = accountService.createAccount(name)
    if err then
        print('Error: ' .. err.message)
    else
        print(('Created account "%s"  id=%d'):format(name, id))
    end
end

local function createCard()
    if not component.isAvailable('os_cardwriter') then
        print('Error: no card writer found.') return
    end
    if not component.isAvailable('data') then
        print('Error: data component required.') return
    end

    local displayName = prompt('Card display name: ')
    if not displayName or displayName == '' then print('Cancelled.') return end

    local dataComp = component.data
    local salt = dataComp.encode64(dataComp.random(16))
    component.os_cardwriter.write(salt, displayName, true)
    print('Card written. Salt stored on card.')
end

local function issueCard()
    if not component.isAvailable('os_magreader') then
        print('Error: no card reader found.') return
    end
    if not component.isAvailable('data') then
        print('Error: data component required.') return
    end

    local name = prompt('Account name: ')
    local account = Account.get(name)
    if not account then print('Account not found.') return end

    print('Swipe card now (5s timeout)...')
    local _, _, _, salt, uid = event.pull(5, 'magData')
    if not uid then print('No card detected.') return end
    print('Card read. UID: ' .. uid)

    local pin = prompt('PIN: ')
    if not pin or pin == '' then print('Cancelled.') return end

    local dataComp = component.data
    local pin_hash = dataComp.encode64(dataComp.sha256(pin .. salt))

    local result, err = cardService.issueCard(account.id, uid, pin_hash)
    if not result then
        print('Error: ' .. (err and err.message or 'unknown')) return
    end
    local cardId = result.cardId

    print(('Issued card id=%d  uid=%s  account="%s" (id=%d)'):format(
        cardId, uid, name, account.id))
end

local function listAccounts()
    local rows = db.select('accounts'):all()
    if #rows == 0 then print('No accounts.') return end
    print(('%-6s %-24s %s'):format('ID', 'Name', 'Status'))
    for _, a in ipairs(rows) do
        local status = ({[0]='Active',[1]='Frozen',[2]='Closed'})[a.account_status] or '?'
        print(('%-6d %-24s %s'):format(a.id, a.account_name, status))
    end
end

local function listCards()
    local name = prompt('Account name (blank = all): ')
    local rows
    if name and name ~= '' then
        local account = Account.get(name)
        if not account then print('Account not found.') return end
        rows = db.select('cards'):where({account_id = account.id}):all()
    else
        rows = db.select('cards'):all()
    end
    if #rows == 0 then print('No cards.') return end
    print(('%-6s %-10s %-36s %s'):format('ID', 'Acct ID', 'UID', 'Status'))
    for _, c in ipairs(rows) do
        local status = ({[0]='Active',[1]='Inactive',[2]='Revoked'})[c.status] or '?'
        print(('%-6d %-10d %-36s %s'):format(c.id, c.account_id, tostring(c.uid), status))
    end
end

local function revokeCard()
    local name = prompt('Account name: ')
    if not name or name == '' then print('Cancelled.') return end

    local account = Account.get(name)
    if not account then print('Account not found.') return end

    local cards = db.select('cards'):where({account_id = account.id}):all()
    if not cards or #cards == 0 then print('No cards for this account.') return end

    local statusLabel = {[0]='Active',[1]='Inactive',[2]='Revoked'}
    for i, c in ipairs(cards) do
        print(('%d) uid=%-36s  %s'):format(i, tostring(c.uid), statusLabel[c.status] or '?'))
    end

    local choice = prompt('Revoke which card (number): ')
    local n = tonumber(choice)
    if not n or not cards[n] then print('Cancelled.') return end

    local ok, err = cardService.revokeCard(cards[n].uid)
    if not ok then
        print('Error: ' .. (err or 'unknown'))
    else
        print('Card revoked.')
    end
end

local function mintFunds()
    local name = prompt('Account name: ')
    if not name or name == '' then print('Cancelled.') return end

    local account = Account.get(name)
    if not account then print('Account not found.') return end

    local amountStr = prompt('Amount in dollars (e.g. 150 or 1.50): ')
    if not amountStr or amountStr == '' then print('Cancelled.') return end
    local dollars = tonumber(amountStr)
    if not dollars then print('Invalid amount.') return end
    local amount = math.floor(dollars * 100 + 0.5)
    if not amount or amount <= 0 then print('Invalid amount.') return end

    local result, err = ledgerService.mint(account.id, amount)
    if err then
        print('Error: ' .. err.message)
    else
        print(('Minted %d cents ($%.2f) into "%s" (id=%d) — new balance: %d cents'):format(
            amount, amount / 100, name, account.id, result.balance))
    end
end

local function updatePin()
    if not component.isAvailable('os_magreader') then
        print('Error: no card reader found.') return
    end
    if not component.isAvailable('data') then
        print('Error: data component required.') return
    end

    local name = prompt('Account name: ')
    if not name or name == '' then print('Cancelled.') return end

    local account = Account.get(name)
    if not account then print('Account not found.') return end

    local cards = db.select('cards'):where({account_id = account.id}):all()
    if not cards or #cards == 0 then print('No cards for this account.') return end

    local statusLabel = {[0]='Active',[1]='Inactive',[2]='Revoked'}
    for i, c in ipairs(cards) do
        print(('%d) uid=%-36s  %s'):format(i, tostring(c.uid), statusLabel[c.status] or '?'))
    end
    local choice = prompt('Update PIN on which card (number): ')
    local n = tonumber(choice)
    if not n or not cards[n] then print('Cancelled.') return end
    local targetUid = cards[n].uid

    print('Swipe the card now to read its salt (5s timeout)...')
    local _, _, _, salt, uid = event.pull(5, 'magData')
    if not uid then print('No card detected.') return end
    if uid ~= targetUid then print('Wrong card swiped.') return end

    local pin = prompt('New PIN: ')
    if not pin or pin == '' then print('Cancelled.') return end

    local dataComp = component.data
    local pinHash = dataComp.encode64(dataComp.sha256(pin .. salt))

    local ok, err = Card.updatePin(targetUid, pinHash)
    if not ok then
        print('Error: ' .. (err or 'unknown'))
    else
        ledgerService.pinChange(account.id, targetUid)
        print('PIN updated.')
    end
end

local function transferFunds()
    local fromName = prompt('Transfer FROM account: ')
    if not fromName or fromName == '' then print('Cancelled.') return end
    local fromAcct = Account.get(fromName)
    if not fromAcct then print('Account not found.') return end

    local toName = prompt('Transfer TO account: ')
    if not toName or toName == '' then print('Cancelled.') return end
    local toAcct = Account.get(toName)
    if not toAcct then print('Account not found.') return end

    local amountStr = prompt('Amount in dollars (e.g. 10 or 1.50): ')
    local dollars = tonumber(amountStr)
    if not dollars or dollars <= 0 then print('Invalid amount.') return end
    local amount = math.floor(dollars * 100 + 0.5)

    local result, err = ledgerService.adminTransfer(fromAcct.id, toAcct.id, amount)
    if err then
        print('Error: ' .. err.message)
    elseif result then
        print(('Transferred $%.2f from "%s" ($%.2f left) to "%s" ($%.2f balance)'):format(
            amount / 100, fromName, result.fromBalance / 100,
            toName, result.toBalance / 100))
    end
end

local function burnFunds()
    local name = prompt('Account name: ')
    if not name or name == '' then print('Cancelled.') return end

    local account = Account.get(name)
    if not account then print('Account not found.') return end

    local amountStr = prompt('Amount in dollars to remove (e.g. 50 or 0.99): ')
    if not amountStr or amountStr == '' then print('Cancelled.') return end
    local dollars = tonumber(amountStr)
    if not dollars then print('Invalid amount.') return end
    local amount = math.floor(dollars * 100 + 0.5)
    if amount <= 0 then print('Invalid amount.') return end

    local result, err = ledgerService.burn(account.id, amount)
    if err then
        print('Error: ' .. err.message)
    else
        print(('Burned %d cents ($%.2f) from "%s" (id=%d) — new balance: %d cents'):format(
            amount, amount / 100, name, account.id, result.balance))
    end
end

local function freezeAccount()
    local name = prompt('Account name: ')
    if not name or name == '' then print('Cancelled.') return end
    local account = Account.get(name)
    if not account then print('Account not found.') return end
    local _, err = ledgerService.freezeAccount(account.id)
    if err then print('Error: ' .. err.message) else print(('Account "%s" frozen.'):format(name)) end
end

local function unfreezeAccount()
    local name = prompt('Account name: ')
    if not name or name == '' then print('Cancelled.') return end
    local account = Account.get(name)
    if not account then print('Account not found.') return end
    local _, err = ledgerService.unfreezeAccount(account.id)
    if err then print('Error: ' .. err.message) else print(('Account "%s" unfrozen.'):format(name)) end
end

local function refundFunds()
    local fromName = prompt('Refund FROM account (e.g. store): ')
    if not fromName or fromName == '' then print('Cancelled.') return end
    local fromAcct = Account.get(fromName)
    if not fromAcct then print('Account not found.') return end

    local toName = prompt('Refund TO account (e.g. customer): ')
    if not toName or toName == '' then print('Cancelled.') return end
    local toAcct = Account.get(toName)
    if not toAcct then print('Account not found.') return end

    local amountStr = prompt('Amount in dollars (e.g. 5.00): ')
    local dollars = tonumber(amountStr)
    if not dollars or dollars <= 0 then print('Invalid amount.') return end
    local amount = math.floor(dollars * 100 + 0.5)

    local _, err = ledgerService.refund(fromAcct.id, toAcct.id, amount)
    if err then
        print('Error: ' .. err.message)
    else
        print(('Refunded $%.2f from "%s" to "%s".'):format(amount / 100, fromName, toName))
    end
end

local function chargebackFunds()
    local fromName = prompt('Chargeback FROM account: ')
    if not fromName or fromName == '' then print('Cancelled.') return end
    local fromAcct = Account.get(fromName)
    if not fromAcct then print('Account not found.') return end

    local toName = prompt('Chargeback TO account: ')
    if not toName or toName == '' then print('Cancelled.') return end
    local toAcct = Account.get(toName)
    if not toAcct then print('Account not found.') return end

    local amountStr = prompt('Amount in dollars (e.g. 5.00): ')
    local dollars = tonumber(amountStr)
    if not dollars or dollars <= 0 then print('Invalid amount.') return end
    local amount = math.floor(dollars * 100 + 0.5)

    local _, err = ledgerService.chargeback(fromAcct.id, toAcct.id, amount)
    if err then
        print('Error: ' .. err.message)
    else
        print(('Chargeback $%.2f from "%s" to "%s".'):format(amount / 100, fromName, toName))
    end
end

local function rebuildLedger()
    local ledger = LedgerMod.Ledger:new(db)
    print('Rebuilding materialized views from ledger...')
    ledger:rebuildMaterialized()
    print('Done.')
end

local STATUS_LABEL = {[0]='pending',[1]='active',[2]='suspended',[3]='revoked'}

local function listDevices()
    local rows = DeviceService.list()
    if #rows == 0 then print('No devices.') return end
    print(('%-16s %-10s %-10s %s'):format('Device ID', 'Type', 'Status', 'Registered'))
    for _, d in ipairs(rows) do
        local status = STATUS_LABEL[d.status] or '?'
        print(('%-16s %-10s %-10s %s'):format(
            d.device_id, d.device_type or '?', status,
            os.date('%Y-%m-%d', d.registered_at or 0)))
    end
end

local function pendingDevices()
    local rows = DeviceService.list({status = 0})
    if #rows == 0 then print('No pending devices.') return end
    print(('%-16s %-10s  Public key (first 40 chars)'):format('Device ID', 'Type'))
    for _, d in ipairs(rows) do
        print(('%-16s %-10s  %s...'):format(
            d.device_id, d.device_type or '?', (d.public_key or ''):sub(1, 40)))
    end
end

local function trustDevice()
    local rows = DeviceService.list({status = 0})
    if #rows == 0 then print('No pending devices.') return end
    for i, d in ipairs(rows) do
        print(('%d) %s (%s)'):format(i, d.device_id, d.device_type or '?'))
    end
    local choice = prompt('Trust which device (number): ')
    local n = tonumber(choice)
    if not n or not rows[n] then print('Cancelled.') return end

    local override = prompt(('Device type override (blank = keep "%s"): '):format(rows[n].device_type or '?'))
    local ok = DeviceService.trust(rows[n].device_id, override ~= '' and override or nil)
    if ok then
        print(('Trusted "%s".'):format(rows[n].device_id))
    else
        print('Failed.')
    end
end

local function revokeDevice()
    local rows = DeviceService.list()
    if #rows == 0 then print('No devices.') return end
    for i, d in ipairs(rows) do
        print(('%d) %s (%s) [%s]'):format(
            i, d.device_id, d.device_type or '?', STATUS_LABEL[d.status] or '?'))
    end
    local choice = prompt('Revoke which device (number): ')
    local n = tonumber(choice)
    if not n or not rows[n] then print('Cancelled.') return end
    DeviceService.revoke(rows[n].device_id)
    print(('Revoked "%s".'):format(rows[n].device_id))
end

local function listHolds()
    local holds = ledgerService.listHolds()
    if #holds == 0 then print('No active holds.') return end
    print(('\n%-6s  %-10s  %-10s  %s'):format('ID', 'Amount', 'AccountId', 'Captures in'))
    for _, h in ipairs(holds) do
        local days  = math.floor(h.capturesIn)
        local hours = math.floor((h.capturesIn - days) * 24)
        local timeStr = ('%dd %dh'):format(days, hours)
        print(('%-6d  %-10d  %-10s  %s'):format(
            h.holdId, h.amount, tostring(h.accountId), timeStr))
    end
end

local function releaseHold()
    listHolds()
    local idStr = prompt('Hold ID to release (blank=cancel): ')
    if not idStr or idStr == '' then print('Cancelled.') return end
    local holdId = tonumber(idStr)
    if not holdId then print('Invalid ID.') return end
    local ok, err = ledgerService.adminReleaseHold(holdId)
    if ok then
        print(('Hold %d released — funds returned to customer.'):format(holdId))
    else
        print('Error: ' .. tostring(err))
    end
end

local menu = {
    {'Create account',  createAccount},
    {'Create card',     createCard},
    {'Issue card',      issueCard},
    {'List accounts',   listAccounts},
    {'List cards',      listCards},
    {'Revoke card',     revokeCard},
    {'Update PIN',      updatePin},
    {'Mint funds',      mintFunds},
    {'Burn funds',      burnFunds},
    {'Transfer funds',  transferFunds},
    {'Refund funds',    refundFunds},
    {'Chargeback',      chargebackFunds},
    {'Freeze account',  freezeAccount},
    {'Unfreeze account',unfreezeAccount},
    {'Rebuild ledger',  rebuildLedger},
    {'Pending devices', pendingDevices},
    {'Trust device',    trustDevice},
    {'List devices',    listDevices},
    {'Revoke device',   revokeDevice},
    {'List holds',      listHolds},
    {'Release hold',    releaseHold},
}

function Admin.run()
    while true do
        print('\n=== Bank Admin ===')
        for i, entry in ipairs(menu) do
            print(('%d) %s'):format(i, entry[1]))
        end
        print('q) Quit')

        local choice = prompt('> ')
        if choice == 'q' or choice == nil then break end

        local n = tonumber(choice)
        if n and menu[n] then
            menu[n][2]()
        else
            print('Unknown option.')
        end
    end
end

return Admin
