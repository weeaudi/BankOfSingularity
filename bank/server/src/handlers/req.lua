---@diagnostic disable: undefined-doc-name  -- Request/Response/Error types in shared protocol module
--- bank/server/src/handlers/req.lua
--- Request handler table — third stage of the server request pipeline.
---
--- `Req.ops` maps every supported operation name to a handler function.
--- `Req.handle(req, ctx)` does the op-name lookup and delegates.
---
--- Supported operations:
---   Card.*          — Card.GetByAccountId, Card.Authenticate, Card.Deauthenticate,
---                     Card.IssueCard
---   Accounts.*      — Accounts.CreateAccount, Accounts.GetByName, Accounts.GetById
---   Ledger.*        — Ledger.GetBalance, Ledger.Deposit, Ledger.Withdraw,
---                     Ledger.Transfer, Ledger.Mint, Ledger.Burn,
---                     Ledger.Freeze, Ledger.Unfreeze,
---                     Ledger.Hold, Ledger.Adjust, Ledger.Release
---
--- Each handler receives `(req, ctx)` and returns a Response built with
--- `ctx.resOk(req, data)` or `ctx.resErr(req, err)`.

local card    = require('src.services.cardService')
local account = require('src.services.accountService')
local auth    = require('src.services.authService')
local ledger  = require('src.services.ledgerService')
local Req = {}

---@alias RequestHandler fun(req: Request, ctx: ExecutionContext): Response
---@type table<string, RequestHandler>
Req.ops = {
    ['Card.GetByAccountId'] = function(req, ctx)
        local cards, err = card.getByAccountId(req.data.accountId)

        if not cards then return ctx.resErr(req, err) end

        return ctx.resOk(req, cards)
    end,

    ['Accounts.CreateAccount'] = function(req, ctx)

        local accountid, err = account.createAccount(req.data.accountName)

        if not accountid then return ctx.resErr(req, err) end

        return ctx.resOk(req, accountid)

    end,

    ['Accounts.GetByName'] = function(req, ctx)
        local accountTable, err = account.getByName(req.data.accountName)

        if not accountTable then return ctx.resErr(req, err) end

        return ctx.resOk(req, accountTable)

    end,

    ['Accounts.GetById'] = function(req, ctx)
        local accountTable, err = account.getById(req.data.accountId)

        if not accountTable then return ctx.resErr(req, err) end

        return ctx.resOk(req, accountTable)
    end,

    ['Card.Authenticate'] = function(req, ctx)
        local result, err = auth.authenticate(req.data.cardUid, req.data.pinHash)

        if not result then return ctx.resErr(req, err) end

        return ctx.resOk(req, result)
    end,

    ['Card.Deauthenticate'] = function(req, ctx)
        auth.invalidate(req.data.token)

        return ctx.resOk(req, {})
    end,

    ['Ledger.GetBalance'] = function(req, ctx)
        local result, err = ledger.getBalance(req.data.token)

        if not result then return ctx.resErr(req, err) end

        return ctx.resOk(req, result)
    end,

    ['Ledger.Deposit'] = function(req, ctx)
        local result, err = ledger.deposit(req.data.token, req.data.amount)

        if not result then return ctx.resErr(req, err) end

        return ctx.resOk(req, result)
    end,

    ['Ledger.Withdraw'] = function(req, ctx)
        local result, err = ledger.withdraw(req.data.token, req.data.amount)

        if not result then return ctx.resErr(req, err) end

        return ctx.resOk(req, result)
    end,

    ['Ledger.Transfer'] = function(req, ctx)
        local result, err = ledger.transfer(req.data.token, req.data.toAccountId, req.data.amount)

        if not result then return ctx.resErr(req, err) end

        return ctx.resOk(req, result)
    end,

    ['Ledger.Mint'] = function(req, ctx)
        local result, err = ledger.mint(req.data.accountId, req.data.amount)

        if not result then return ctx.resErr(req, err) end

        return ctx.resOk(req, result)
    end,

    ['Ledger.Burn'] = function(req, ctx)
        local result, err = ledger.burn(req.data.accountId, req.data.amount)

        if not result then return ctx.resErr(req, err) end

        return ctx.resOk(req, result)
    end,

    ['Ledger.Freeze'] = function(req, ctx)
        local result, err = ledger.freezeAccount(req.data.accountId)
        if not result then return ctx.resErr(req, err) end
        return ctx.resOk(req, result)
    end,

    ['Ledger.Unfreeze'] = function(req, ctx)
        local result, err = ledger.unfreezeAccount(req.data.accountId)
        if not result then return ctx.resErr(req, err) end
        return ctx.resOk(req, result)
    end,

    ['Card.IssueCard'] = function(req, ctx)
        local result, err = card.issueCard(req.data.accountId, req.data.uid, req.data.pinHash)

        if not result then return ctx.resErr(req, err) end

        return ctx.resOk(req, result)
    end,

    ['Ledger.Hold'] = function(req, ctx)
        local result, err = ledger.hold(
            req.data.token, req.data.amount, req.data.toAccountId)
        if not result then return ctx.resErr(req, err) end
        return ctx.resOk(req, result)
    end,

    ['Ledger.Adjust'] = function(req, ctx)
        local result, err = ledger.adjustHold(
            req.data.token, req.data.holdId, req.data.actualAmount)
        if not result then return ctx.resErr(req, err) end
        return ctx.resOk(req, result)
    end,

    ['Ledger.Release'] = function(req, ctx)
        local result, err = ledger.releaseHold(req.data.token, req.data.holdId)
        if not result then return ctx.resErr(req, err) end
        return ctx.resOk(req, result)
    end,
}

---@param req Request
---@param ctx ExecutionContext
---@return Response
function Req.handle(req, ctx)
    local fn = Req.ops[req.op]
    if not fn then
        return ctx.resErr(req, ctx.makeError('BAD_REQ_OP',
                                             'unknown request operation'))
    end
    return fn(req, ctx)
end

return Req
