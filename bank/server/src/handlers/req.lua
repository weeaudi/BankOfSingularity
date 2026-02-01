local card = require('src.services.cardService')
local Req = {}

---@alias RequestHandler fun(req: Request, ctx: ExecutionContext): Response
---@type table<string, RequestHandler>
Req.ops = {
    ['Card.GetByAccountId'] = function(req, ctx)
        local cards, err = card.getByAccountId(req.data.accountId)

        if not cards then return ctx.resErr(req, err) end

        return ctx.resOk(req, cards)
    end

    -- ['Accounts.CreateAccount'] = function (req, ctx)

    -- end
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
