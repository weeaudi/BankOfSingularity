local Req = {}

Req.ops = {
    -- Card.getCardsByAccountId = 
}

function Req.handle(p)
    local fn = Req.ops[p.op]
    if not fn then return false, 'unknown req op' end
    return fn(p)
end

return Req.handle
