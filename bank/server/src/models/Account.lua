--- bank/server/src/models/Account.lua
--- Low-level data-access layer for the `accounts` and related tables.
---
--- An Account is a named wallet.  Statuses:
---   Active (0) — normal operation
---   Frozen (1) — no debits allowed; admin-only override
---   Closed (2) — permanently deactivated
---
--- Balances are NOT stored on the account row.  They live in the materialized
--- `account_balance` table and are updated by the Ledger on every append.

---@class Account
---@field id             integer       Auto-assigned primary key
---@field account_name   string        Human-readable account name (unique)
---@field account_status AccountStatus Current status (Active=0, Frozen=1, Closed=2)

---@class AccountBalance
---@field id        integer  Mirrors accountId (used as primary key)
---@field accountId integer  FK → Account.id
---@field balance   number   Current balance in cents (materialized view)

---@class AccountWithBalance : Account
---@field balance number  Current balance in cents

local db = require('src.db')
db = db.database

local Account = {}
Account.__index = Account

---@enum AccountStatus
Account.Status = {Active = 0, Frozen = 1, Closed = 2}

---@param name string
---@return integer accountId
function Account.getOrCreate(name)
    local acct = db.select('accounts'):where({account_name = name}):first()
    if acct and acct.id then return acct.id end

    return db.insert('accounts', {
        account_name = name,
        account_status = Account.Status.Active
    })
end

---@param name string
---@return Account|nil
function Account.get(name)
    local acct = db.select('accounts'):where({account_name = name}):first()
    if acct then return acct end
    return nil
end

---@param id integer
---@return Account|nil
function Account.getById(id)
    ---@type Account|nil
    local acct = db.select('accounts'):where({id = id}):first()
    return acct
end

---@param account Account
---@param balance number
---@return AccountWithBalance
local function appendBalanceToAccount(account, balance)
    ---@type AccountWithBalance
    local out = {
        id = account.id,
        account_name = account.account_name,
        account_status = account.account_status,
        balance = balance
    }
    return out
end

---@param id integer
---@param status AccountStatus
---@return boolean
function Account.setStatus(id, status)
    local updated = db.update('accounts', {id = id}, {account_status = status})
    return updated > 0
end

---@param id integer
---@return AccountWithBalance|nil
function Account.getWithBalance(id)
    ---@type Account|nil
    local acct = Account.getById(id)
    if not acct or not acct.id then return end
    ---@type AccountBalance|nil
    local bal = db.select('account_balance'):where({accountId = id}):first()
    if not bal then return appendBalanceToAccount(acct, 0) end

    return appendBalanceToAccount(acct, bal.balance)

end

return Account
