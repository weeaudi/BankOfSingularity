package.loaded["src.models.Account"] = nil
package.loaded["src.models.Ledger"] = nil
package.loaded["src.models.database"] = nil

local account = require("src.models.Account")
local ledger = require('src.models.Ledger').Ledger
local db = require('src.db.database')
local computer = require('computer')
local serialize = require('serialization')

local tst1 = account.getOrCreate('Steven')
local tst2 = account.getOrCreate('Aidcraft')
local tst3 = account.getOrCreate('dos54')
---@type Account|nil
local res = db.select('accounts'):where({account_name = 'Aidcraft'}):first()
local res2 = db.select('accounts'):where({account_name = 'Steven'}):first()
local res3 = db.select('accounts'):where({account_name = 'dos54'}):first()

print(serialize.serialize(res))

local ldgr = ledger:new(db, '/bank/test')

if not res then return end
local tx = {
    accountId = res.id,
    playerName = 'Aidcraft',
    amount = 500,
    transactionType = 0
}

if not res2 then return end
local tx2 = {
    accountId = res2.id,
    playerName = 'Steven',
    amount = 500,
    transactionType = 0
}

if not res3 then return end
local tx3 = {
    accountId = res3.id,
    playerName = 'dos54',
    amount = 500,
    transactionType = 0
}

-- local i = 0
-- while i < 2 do
--     ldgr:append(tx)
--     ldgr:append(tx2)
--     ldgr:append(tx3)
--     i = i + 3
--     print('Appended tx #' .. i - 2 .. ', ' .. i - 1 .. ', ' .. i)
-- end

print('Rebuilding materialized data...')

---@diagnostic disable-next-line: undefined-field
local time = computer.uptime()
ldgr:rebuildMaterialized()
---@diagnostic disable-next-line: undefined-field
local dt = computer.uptime() - time
print('Rebuilding materialized took ' .. dt .. 'seconds')

local test3 = account.getWithBalance(res.id)
print(serialize.serialize(test3))
