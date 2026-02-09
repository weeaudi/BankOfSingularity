local ROOT = '/bank'
package.path =
    ROOT .. '/server/?.lua;' .. ROOT .. '/server/?/init.lua;' .. ROOT ..
        '/shared/?.lua;' .. ROOT .. '/shared/?/init.lua;' .. package.path

local component = require('component')
local event = require('event')

while not component.isAvailable('modem') do event.pull('component_added') end

local modem = component.modem

local Dispatch = require('src.dispatch')
local Protocol = require('src.net.protocol')

-- Config
local PORT = 100
local DISCOVERY_PORT = 999

---@class ExecutionContext
---@field resOk function
---@field resErr function
---@field makeError function
---@field fromAddr string
---@field localAddr string
---@field port integer
---@field receivedAt number

---@type ExecutionContext
local baseCtx = setmetatable({
    resOk = Protocol.resOk,
    resErr = Protocol.resErr,
    makeError = Protocol.makeError
}, {__newindex = function() error('baseCtx is read-only') end})

---@param toAddr any
---@param port any
---@param res any
local function sendResponse(toAddr, port, res)
    local payload = Protocol.encode(res)
    print('Sending response.. ' .. require('serialization').serialize(res))
    modem.send(toAddr, port, payload)
end

---@param localAddr string
---@param fromAddr string
---@param port integer
---@param payload string
local function handleRpc(localAddr, fromAddr, port, payload)
    print('Initiating RPC manager')
    local req, err = Protocol.decode(payload)
    if not req then
        print('There was an issue with the request')
        local pseudoReq = {
            v = Protocol.VERSION,
            kind = Protocol.kind.req,
            op = 'decode',
            id = '?',
            from = fromAddr,
            to = localAddr,
            ts = os.time(),
            data = {}
        }
        local res = Protocol.resErr(pseudoReq, err or
                                        Protocol.makeError('BAD_PACKET',
                                                           'decode failed due to bad request packet'))

        print(res.err)
        sendResponse(fromAddr, port, res)
        return
    end

    if req.to ~= localAddr then
        print('req.to does not match local address ' .. localAddr)
        return
    end

    local ctx = setmetatable({
        fromAddr = fromAddr,
        localAddr = localAddr,
        port = port,
        receivedAt = os.time()
    }, {__index = baseCtx})

    print('Sending req to Dispatch')
    -- Dispatch routes to handler; responses should be Response|nil, Error|nil
    local res = Dispatch.handle(req, ctx)
    if not res then
        res = ctx.resErr(req, ctx.makeError('HANDLER_ERROR', 'Handler failed'))
    end

    print('Sending response ' .. require('serialization').serialize(res))
    sendResponse(fromAddr, port, res)
end

local function handleDiscovery(fromAddr, replyPort, msg)
    print(('Sending reply to %s:%d'):format(fromAddr, replyPort))
    modem.send(fromAddr, replyPort, "BANK_HERE")
end

local function onModemMessage(_, localAddr, fromAddr, port, _, payload)
    print(('Received a message on port %d, %s'):format(port, payload))
    if port == DISCOVERY_PORT then
        return handleDiscovery(fromAddr, port, payload)
    end

    if port == PORT then return handleRpc(localAddr, fromAddr, port, payload) end
end

-- Boot
modem.open(PORT)
modem.open(DISCOVERY_PORT)
event.listen('modem_message', onModemMessage)

print(modem.isOpen(PORT))
print(('Server listening on port %d (rpc) and %d (discovery)'):format(PORT,
                                                                      DISCOVERY_PORT))
print(('Server address: %s'):format(modem.address))

while true do
    local e = {event.pull()}
    if e[1] == "interrupted" then break end
end

event.ignore('modem_message', onModemMessage)
