local modem = require('component').modem
local Dispatch = require('server.src.dispatch')
local Protocol = require('server.src.protocol')

local baseCtx = setmetatable({
    resOk = Protocol.resOk,
    resErr = Protocol.resErr,
    makeError = Protocol.makeError
}, {__newindex = function() error('baseCtx is read-only') end})

local function handleMessage(_, _, fromAddr, port, _, payload)
    local req = Protocol.decode(payload)

    local ctx = setmetatable({
        fromAddr = fromAddr,
        port = port,
        receivedAt = os.time()
    }, {__index = baseCtx})
end

