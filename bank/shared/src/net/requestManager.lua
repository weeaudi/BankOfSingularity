local Protocol = require("src.net.protocol")
local computer = require("computer")

local RM = {}

---@class PendingRequest
---@field callback fun(res: Response|nil, err: Error|nil)
---@field deadline number

---@type table<string, PendingRequest>
local pending = {}

--- Register a request to the pending table
---@param id string
---@param timeoutSec number|nil
---@param callback fun(res: Response|nil, err: Error|nil)
function RM.register(id, timeoutSec, callback)
  pending[id] = {
    callback = callback,
    deadline = computer.uptime() + (timeoutSec or 2.0),
  }
end

--- Advance a tick
function RM.tick()
  local now = computer.uptime()
  for id, w in pairs(pending) do
    if now >= w.deadline then
      pending[id] = nil
      w.callback(nil, { code = "TIMEOUT", message = "Request timed out" })
    end
  end
end

--- Handle an incoming packet payload
---@param payload string
---@return boolean success, Error|nil
function RM.onPacket(payload)
  local pkt, err = Protocol.decode(payload)
  if not pkt then return false, err end

  if pkt.kind == Protocol.Kind.res then
    local w = pending[pkt.id]
    if w then
      pending[pkt.id] = nil
      w.callback(pkt, nil)
    end
  end

  return true, nil
end

return RM
