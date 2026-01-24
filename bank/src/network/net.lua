network = {}
network.__index = network

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

return network
