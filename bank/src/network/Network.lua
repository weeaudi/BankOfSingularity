--- Module handling network communications using an OC modem component
---@class Network
---@field modem table OC modem component
---@field port number port number used for communications
local network = {}
network.__index = network

local event = require('event')

--- initializes a network instance and opens the specified port
---@param modem table OC modem component
---@param port number port number to use
---@return Network network instance 
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

--- Sends a message to the specified address using the newtork's port
---@param address string OC modem address to send to
---@param message string message to send
---@return nil
function network:send(address, message)
    self.modem.send(address, self.port, message)
end

--- Sends a broadcast message on the network's port
---@param message string message to broadcast
---@return nil
function network:broadcast(message) self.modem.broadcast(self.port, message) end

--- Receives a message on the network's port
---@param timeout number timeout in seconds; 0 for no timeout
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

