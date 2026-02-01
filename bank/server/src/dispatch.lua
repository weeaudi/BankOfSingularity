local Handlers = require('src.handlers')

local Dispatch = {}

Dispatch.byKind = {
    req = Handlers.req.handle,
    -- res = Handlers.res.handle,
    -- evt = Handlers.evt.handle
}

---@param req Request
---@param ctx ExecutionContext
---@return Response|nil
function Dispatch.handle(req, ctx)
    local fn = Dispatch.byKind[req.kind]
    if not fn then
        print('unable to find function in dispatch')
        return ctx.resErr(req, ctx.makeError('HANDLER_NOT_FOUND', 'Invalid handler function'))
    end
    local res = fn(req, ctx)
    print('Returning response object.. ' .. require('serialization').serialize(res))
    return res
end

return Dispatch
