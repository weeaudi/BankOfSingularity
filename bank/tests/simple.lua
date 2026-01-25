package.loaded["src.models.Account"] = nil
package.loaded["src.models.Ledger"] = nil
package.loaded["src.models.database"] = nil

local account = require("src.models.Account")
local ledger = require('src.models.Ledger').Ledger
local db = require('src.db.database')
local serialize = require('serialization')

local tst1 = account.getOrCreate('Steven')
---@type Account|nil
local res = db.select('accounts'):where({ account_name = 'Steven' }):first()
if not res then print('Account not created or found') return end
print(serialize.serialize(res))

local ldgr = ledger:new(db, '/bank/test')
local tx = {
  accountId = res.id,
  playerName = 'dos54',
  amount = 500,
  transactionType = 0,
}
local test2 = ldgr:append(tx)
print(test2)

local test3 = account.getWithBalance(res.id)
print(serialize.serialize(test3))