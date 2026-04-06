---@diagnostic disable: undefined-doc-name  -- Error type in shared protocol module
--- bank/server/src/services/accountService.lua
--- Business-logic layer for account management.
---
--- Wraps Account model operations with validation and error responses.
--- Called by handlers/req.lua for Accounts.* operations.
---
---   createAccount(name)   — create a new account; errors if name already taken
---   getByName(name)       — look up account by name; errors if not found
---   getById(id)           — look up account by ID; errors if not found
---   list(where)           — return all accounts matching an optional filter

local AccountModel = require('src.models.Account')
local db = require('src.db').database
local whereCompiler = require('src.util.whereClause')
local Accounts = {}

---@param accountName string
---@return number|nil accountId
---@return nil|Error
function Accounts.createAccount(accountName)

    local account = AccountModel.get(accountName)

    if account then
        return nil, {
            code = "ACC_EXSIST",
            message = ("Account with name %s already exsists"):format(
                accountName)
        }
    end

    local accountId = AccountModel.getOrCreate(accountName)

    if accountId == -1 then
        return nil, {
            code = "ACC_CREATE_FAILED",
            message = ("Failed to create account with name %s"):format(
                accountName)
        }
    end

    return accountId, nil

end

---@param accountName string
---@return Account|nil
---@return nil|Error
function Accounts.getByName(accountName)
    local account = AccountModel.get(accountName)

    if not account then
        return nil, {
            code = "ACC_NOT_FOUND",
            message = ("Account with name %s not found"):format(accountName)
        }
    end

    return account, nil
end

---@param accountId integer
---@return Account|nil
---@return nil|Error
function Accounts.getById(accountId)
    local account = AccountModel.getById(accountId)

    if not account then
        return nil, {
            code = "ACC_NOT_FOUND",
            message = ("Account with id %s not found"):format(accountId)
        }
    end

    return account, nil

end

---@param where table|nil  Optional filter table (field=value pairs)
---@return Account[]
function Accounts.list(where)

    local compiledWhere = whereCompiler.compileWhere(where)

    local accounts = db.select('accounts'):where(compiledWhere):all()

    return accounts
end

return Accounts
