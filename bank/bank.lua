local json = require('src.utils.json')
print(package.path)
local test = json.encode('{ 1, 2, 3, { x = 10} }')
print(test)
local decoded = json.decode(test)
print(decoded)

local network = require('src.network.net')
local modem = component.modem
local net = network:init(modem, 12345)

print(net)
