local Handlers = require('src.handlers')

local Dispatch = {}

Dispatch.byKind = {req = Handlers.req, res = Handlers.res, evt = Handlers.evt}

---@param p table Packet
---@return boolean ok
---@return string|nil msg error message
function Dispatch.handle(p, ctx)
    local fn = Dispatch.byKind[p.kind]
    if not fn then return false, 'unknown kind' end
    return fn(p, ctx)
end
