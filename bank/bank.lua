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

local network = devRequire('src.network.Network')
local secureNetwork = devRequire('src.network.SecureNetwork')

local modem = component.modem
local net = network:init(modem, 12345)
local secNet = secureNetwork:init('/bank/keys/enc_keys.dat', net,
                                 component.data)

print(component.modem.isOpen(12345))

while true do
    local sender, message = secNet:receive(0)
    secNet:handleIncoming(sender, message)
end

print(net)
