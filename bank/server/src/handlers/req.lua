local card = require('src.services.cardService')
local Req = {}

Req.ops = {
    ['Card.GetByAccountId'] = function(req, ctx)
        local cards, err = card.getByAccountId(req.data.accountId)

        if not cards then
            return ctx.resErr(req, err)
        end

        return ctx.resOk(req, cards)
    end
}

function Req.handle(p, ctx)
    local fn = Req.ops[p.op]
    if not fn then return nil, { code = 'BAD_REQ_OP', message = 'unknow request operation' } end
    return fn(p, ctx)
end

return Req.handle
