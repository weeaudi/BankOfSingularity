---@class Network
---@field modem table
---@field port number
local network = {}
network.__index = network

local event = require('event')

---@param modem table
---@param port number
---@return table
function network:init(modem, port)
    local obj = {}
    setmetatable(obj, network)
    obj.modem = modem
    obj.port = port
    if obj.modem.isOpen(port) == false then obj.modem.open(port) end
    if obj.modem.isOpen(port) == false then
        error("Failed to open port " .. tostring(port))
    end
    return obj
end

---@param address string
---@param message string
---@return nil
function network:send(address, message)
    self.modem.send(address, self.port, message)
end

---@param message string
---@return nil
function network:broadcast(message) self.modem.broadcast(self.port, message) end

---@param timeout number
---@return string|nil, string
function network:receive(timeout)
    local timestart = os.time()
    while (timestart + timeout > os.time()) or (timeout == 0) do
        local _, _, senderAddress, port, _, message
        if timeout == 0 then
            _, _, senderAddress, port, _, message = event.pull("modem_message")
        else
            _, _, senderAddress, port, _, message = event.pull(1,
                                                               "modem_message")
        end
        if senderAddress ~= nil and port == self.port then
            return senderAddress, message
        end
    end
    return nil, "timeout"
end

return network

