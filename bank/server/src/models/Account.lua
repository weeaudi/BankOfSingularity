local db = require('src.db')

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

---@param id integer
---@return Account|nil
function Account.getById(id)
    print('Running getById: ' .. id)
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
---@return AccountWithBalance|nil
function Account.getWithBalance(id)
    print('Running getWithBalance: ' .. id)
    ---@type Account|nil
    local acct = Account.getById(id)
    if not acct or not acct.id then return end
    print('Account found: ' .. acct.id)
    ---@type AccountBalance|nil
    local bal = db.select('account_balance'):where({accountId = id}):first()
    if not bal then return appendBalanceToAccount(acct, 0) end
    print('balance: ' .. bal.balance)

    return appendBalanceToAccount(acct, bal.balance)

end

return Account
