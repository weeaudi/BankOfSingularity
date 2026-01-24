---@enum AccountStatus
local AccountStatus = {
  Active = 0,
  Frozen = 1,
  Closed = 2
}

---@class Account
---@field id integer
---@field accountname string
---@field name string
---@field balance number
---@field accountStatus AccountStatus

---@param name string
---@param balance number
---@return Account
local function newAccount(name, balance)
  return { id=0, name = name, balance = balance, accountStatus = AccountStatus.Active }
end

