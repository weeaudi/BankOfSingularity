local function devRequire(name)
    package.loaded[name] = nil
    return require(name)
end

local json = require('src.utils.json')
print(package.path)
local test = json.encode('{ 1, 2, 3, { x = 10} }')
print(test)
local decoded = json.decode(test)
print(decoded)

local component = require('component')

local network = devRequire('src.network.net')
local modem = component.modem
local net = network:init(modem, 12345)

net:broadcast("Hello, Network!")

local sender, message = net:recive(3)

print("Received message from " .. tostring(sender) .. ": " .. tostring(message))

print(net)
