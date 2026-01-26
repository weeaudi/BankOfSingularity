local function devRequire(name)
    package.loaded[name] = nil
    return require(name)
end

local serialization = devRequire("serialization")
local fs = require("filesystem")
local db = require("src.db.database")

---@class EncryptionKeys
---@field public public table
---@field public private table

---@class SecureNetwork
---@field private trustedKeys table
---@field private _encryptionKeys EncryptionKeys
---@field private _clientId string
---@field private _network Network
---@field public dataCard table
local SecureNetwork = {}
SecureNetwork.__index = SecureNetwork

---@param dataCard table
---@return EncryptionKeys
local function generateEncryptionKeys(dataCard)
    local publicKey, privateKey = dataCard.generateKeyPair(384)
    return {public = publicKey, private = privateKey}
end

---@param dataCard table unused
---@param encryptionKeys EncryptionKeys
---@return string
local function serializeEncryptionKeys(dataCard, encryptionKeys)
    return serialization.serialize({
        public = encryptionKeys.public.serialize(),
        private = encryptionKeys.private.serialize()
    })
end

---@param dataCard table
---@param data string
---@return EncryptionKeys
local function deserializeEncryptionKeys(dataCard, data)
    local tbl = serialization.unserialize(data)
    return {
        public = dataCard.deserializeKey(tbl.public, "ec-public"),
        private = dataCard.deserializeKey(tbl.private, "ec-private")
    }
end

---@param path string
---@return nil
local function ensureDirectory(path)
    ---@diagnostic disable-next-line: undefined-field
    if not fs.exists(path) then fs.makeDirectory(path) end
end

---@param encryptionKeyFile string
---@param network Network
---@param dataCard table
---@param clientId string
---@return SecureNetwork
function SecureNetwork:init(encryptionKeyFile, network, clientId, dataCard)
    local obj = {}
    setmetatable(obj, SecureNetwork)

    ---@diagnostic disable-next-line: undefined-field
    if fs.exists(encryptionKeyFile) then
        local h = assert(io.open(encryptionKeyFile, "r"))
        local keys = h:read("*a")
        h:close()
        obj._encryptionKeys = deserializeEncryptionKeys(dataCard, keys)
    else
        ensureDirectory(encryptionKeyFile:match("^(.*)/[^/]+$") or "/")
        obj._encryptionKeys = generateEncryptionKeys(dataCard)
        local h = assert(io.open(encryptionKeyFile, "w"))
        h:write(serializeEncryptionKeys(dataCard, obj._encryptionKeys))
        h:close()
    end

    obj._network = network
    obj._clientId = clientId
    obj.dataCard = dataCard
    return obj
end

---@param timeout integer
---@return string|nil, string
function SecureNetwork:receive(timeout) return self._network:receive(timeout) end

---@param address string
---@param message string
---@return nil
function SecureNetwork:send(address, message)
    self._network:send(address, message)
end

---@param data string
---@return string
function SecureNetwork:sign(data)
    return self.dataCard.ecdsa(data, self._encryptionKeys.private)
end

---@param clientId string
---@param publicKey string
---@param publicId string
---@param address string
---@param nonce integer
---@param bankId string
---@return string
function SecureNetwork:generateSignature(clientId, publicKey, publicId, address,
                                         nonce, bankId)
    return self:sign("BV1." .. bankId .. ":" .. tostring(nonce) .. ":" ..
                         address .. ":" .. clientId .. ":" .. publicKey .. ":" ..
                         publicId)
end

---@param clientId string
---@param publicKey string
---@param publicId string
---@param address string
---@param nonce integer
---@param bankId string
---@param signature string
---@return boolean
function SecureNetwork:verifySignature(clientId, publicKey, publicId, address,
                                       nonce, bankId, signature)
    local data = "BV1." .. bankId .. ":" .. tostring(nonce) .. ":" .. address ..
                     ":" .. clientId .. ":" .. publicKey .. ":" .. publicId
    return self.dataCard.ecdsa(data, self.dataCard
                                   .deserializeKey(publicId, "ec-public"),
                               signature)
end

---@class EncryptedConnection
---@field address string
---@field secureNetwork SecureNetwork
---@field remotePublicKey table
---@field sessionKey EncryptionKeys
---@field sharedKey string
local EncryptedConnection = {}
EncryptedConnection.__index = EncryptedConnection

---@param address string
---@return EncryptedConnection
function SecureNetwork:connect(address)
    local obj = {}
    setmetatable(obj, EncryptedConnection)
    obj.address = address
    obj.secureNetwork = self

    local sPublickey, sPrivateKey = self.dataCard.generateKeyPair(384)
    obj.sessionKey = {public = sPublickey, private = sPrivateKey}

    local clientId = self._clientId
    local publicKey = sPublickey.serialize()
    local publicId = self._encryptionKeys.public.serialize()
    local localAddress = self._network.modem.address
    local nonce = 0
    local bankId = nil
    local startTime = os.time()

    self._network:send(address, serialization.serialize({
        type = "key_exchange_challenge_request",
        clientId = clientId
    }))

    while (nonce == 0 or bankId == nil) and os.time() - startTime < 10 do
        local returnAddress, message = self._network:receive(2)
        if returnAddress == address then
            local msg = serialization.unserialize(message)
            if type(msg) == "table" and msg.type == "key_exchange_challenge" then
                nonce = msg.nonce
                bankId = msg.bankId
            end
        end
    end

    if nonce == 0 or bankId == nil then
        error("Failed to receive key exchange challenge from " .. address)
    end

    self._network:send(address, serialization.serialize({
        type = "key_exchange",
        clientId = clientId,
        publicKey = publicKey,
        publicId = publicId,
        nonce = nonce,
        sig = self:generateSignature(clientId, publicKey, publicId,
                                     localAddress, nonce, bankId)
    }))

    startTime = os.time()
    while os.time() - startTime < 10 * 20 do
        local returnAddress, message = self._network:receive(3)
        if returnAddress == address then
            local msg = serialization.unserialize(message)
            if type(msg) == "table" and msg.type == "key_exchange_response" then
                if not self:verifySignature(msg.clientId, msg.publicKey,
                                            msg.publicId, address, nonce,
                                            bankId, msg.sig) then
                    error("Failed to verify signature from " ..
                              tostring(address))
                end
                obj.remotePublicKey = self.dataCard.deserializeKey(
                                          msg.publicKey, "ec-public")
                obj.sharedKey = self.dataCard.ecdh(obj.sessionKey.private,
                                                   obj.remotePublicKey)
                break
            end
        end
    end

    if not obj.remotePublicKey then
        error("Failed to establish secure connection with " .. tostring(address))
    end

    return obj
end

-- ---@class Client
-- ---@field id string
-- ---@field trusted boolean

-- ---@param 
-- ---@return Client|false
-- local function getTrustedOrCreateUntrusted() end

NonceTable = {}

---@param bank Bank
---@param senderAddress string
---@param message string
---@return EncryptedConnection|nil
function SecureNetwork:handleIncoming(bank, senderAddress, message)
    local msg = serialization.unserialize(message)
    if type(msg) ~= "table" or msg.type == nil then return nil end
    if msg.type == "key_exchange" then

        if not NonceTable[msg.clientId] or NonceTable[msg.clientId] ~= msg.nonce then
            return nil
        end

        NonceTable[msg.clientId] = nil

        if not self:verifySignature(msg.clientId, msg.publicKey, msg.publicId,
                                    senderAddress, msg.nonce, bank.bankId,
                                    msg.sig) then return nil end

        local conn = setmetatable({
            address = senderAddress,
            secureNetwork = self,
            remotePublicKey = nil,
            sessionKey = nil
        }, EncryptedConnection)

        local sPublickey, sPrivateKey = self.dataCard.generateKeyPair(384)
        conn.sessionKey = {public = sPublickey, private = sPrivateKey}

        conn.remotePublicKey = self.dataCard.deserializeKey(msg.publicKey,
                                                            "ec-public")

        local clientId = bank.bankId
        local publicKey = conn.sessionKey.public.serialize()
        local publicId = self._encryptionKeys.public.serialize()
        local localAddress = self._network.modem.address

        self:send(senderAddress, serialization.serialize({
            type = "key_exchange_response",
            publicKey = publicKey,
            publicId = publicId,
            clientId = clientId,
            nonce = msg.nonce,
            sig = self:generateSignature(clientId, publicKey, publicId,
                                         localAddress, msg.nonce, bank.bankId)
        }))
        conn.sharedKey = self.dataCard.ecdh(conn.sessionKey.private,
                                            conn.remotePublicKey)

        print(
            "Established secure connection with " .. tostring(senderAddress) ..
                " using shared key " .. tostring(conn.sharedKey))

        return conn
    end

    if msg.type == "key_exchange_challenge_request" then
        local challenge = {
            type = "key_exchange_challenge",
            nonce = math.random(100000, 999999),
            bankId = bank.bankId
        }
        self:send(senderAddress, serialization.serialize(challenge))

        NonceTable[msg.clientId] = challenge.nonce

        return nil
    end

    return nil
end

return SecureNetwork
