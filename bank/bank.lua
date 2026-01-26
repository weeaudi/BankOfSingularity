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
local serialization = require('serialization')

local network = devRequire('src.network.Network')
local secureNetworking = devRequire('src.network.SecureNetwork')

local modem = component.modem
local net = network:init(modem, 12345)
local secNet = secureNetworking:init('/bank/keys/enc_keys.dat', net, "BANK001",
                                     component.data)

print(component.modem.isOpen(12345))

---@alias MessageHandler fun(bank: Bank, sender: string, message: string): boolean

---@class Bank
---@field public secureNetwork SecureNetwork
---@field public bankId string
---@field public handlers table<string, MessageHandler>\
---@field public connections table<string, EncryptedConnection>
local Bank = {}
Bank.__index = Bank

---@param secureNetwork SecureNetwork
---@param bankId string
---@return Bank
function Bank:new(secureNetwork, bankId)
    local obj = {}
    setmetatable(obj, Bank)
    obj.secureNetwork = secureNetwork
    obj.bankId = bankId
    obj.handlers = {}
    obj.connections = {}
    return obj
end

---@param handle string
---@param handler MessageHandler
function Bank:registerHandler(handle, handler) self.handlers[handle] = handler end

---@param handle string
---@param sender string
---@param message string
function Bank:handle(handle, sender, message)
    local h = self.handlers[handle]
    if h then return h(self, sender, message) end
    return false
end

local bank = Bank:new(secNet, "BANK001")

while true do
    local sender, message = bank.secureNetwork:receive(0)
    if sender ~= nil then
        local con = bank.secureNetwork:handleIncoming(bank, sender, message)
        if type(con) == "table" then bank.connections[sender] = con end
    end
end

print(net)
