---@diagnostic disable: undefined-field, unused-local  -- OC API extensions (computer.uptime, dataComp.*); dataComp unused in announce() by design
local serialization = require('serialization')
local event         = require('event')
local computer      = require('computer')

local ANNOUNCE_PORT  = 102
local HANDSHAKE_PORT = 101

local Handshake = {}

-- Derive AES-128 key from ECDH shared secret.
-- IMPORTANT: sha256() returns raw bytes. Do NOT encode64 before sub() —
-- that would collapse the key space to printable ASCII.
local function deriveAesKey(dataComp, sharedSecret)
    return dataComp.sha256(sharedSecret):sub(1, 16)
end

--- Announce this device to the server and return the current status.
--- Uses positional event.pull filters to reject spoofed responses.
---@param dataComp table
---@param modem table
---@param serverAddr string
---@param deviceId string
---@param deviceType string
---@param keys table  {publicSerialized, ...}
---@return string|nil status  "active"|"pending"|"revoked"|"suspended"
---@return string|nil err
function Handshake.announce(dataComp, modem, serverAddr, deviceId, deviceType, keys)
    if not modem.isOpen(ANNOUNCE_PORT) then modem.open(ANNOUNCE_PORT) end

    modem.send(serverAddr, ANNOUNCE_PORT, serialization.serialize({
        type       = 'device_announce',
        deviceId   = deviceId,
        deviceType = deviceType,
        publicKey  = keys.publicSerialized,
    }))

    local deadline = computer.uptime() + 5
    while computer.uptime() < deadline do
        -- Positional filters: nil=any localAddr, serverAddr=remoteAddr, ANNOUNCE_PORT=port
        -- This prevents a spoofed announce_ack from a different address being accepted.
        local ev = {event.pull(1, 'modem_message', nil, serverAddr, ANNOUNCE_PORT)}
        if ev[1] then
            local payload = ev[6]
            if payload then
                local res = serialization.unserialize(payload)
                if type(res) == 'table' and res.type == 'announce_ack' then
                    return res.status, nil
                end
            end
        end
    end

    return nil, 'timeout'
end

--- Perform ECDH handshake with the server, returning a 16-byte AES session key.
---@param dataComp table
---@param modem table
---@param serverAddr string
---@param deviceId string
---@param keys table  {private, publicSerialized}
---@return string|nil aesKey  16-byte raw AES key
---@return string|nil err
function Handshake.doHandshake(dataComp, modem, serverAddr, deviceId, keys)
    if not modem.isOpen(HANDSHAKE_PORT) then modem.open(HANDSHAKE_PORT) end

    -- Generate ephemeral session key pair for this handshake only
    local ephPub, ephPriv = dataComp.generateKeyPair(384)
    local ephPubSer       = ephPub.serialize()

    -- Include os.time() in signature to prevent replay DoS on the server
    local ts      = tostring(os.time())
    local sigData = 'hs1:' .. deviceId .. ':' .. ephPubSer .. ':' .. ts
    local sig     = dataComp.encode64(dataComp.ecdsa(sigData, keys.private))

    modem.send(serverAddr, HANDSHAKE_PORT, serialization.serialize({
        type          = 'handshake_init',
        deviceId      = deviceId,
        sessionPubKey = ephPubSer,
        sig           = sig,
        ts            = tonumber(ts),
    }))

    local deadline = computer.uptime() + 10
    while computer.uptime() < deadline do
        local ev = {event.pull(1, 'modem_message', nil, serverAddr, HANDSHAKE_PORT)}
        if ev[1] then
            local payload = ev[6]
            if payload then
                local res = serialization.unserialize(payload)
                if type(res) == 'table' then
                    if res.type == 'handshake_err' then
                        return nil, res.code or 'HANDSHAKE_ERROR'
                    end
                    if res.type == 'handshake_ok' then
                        local serverEphPub = dataComp.deserializeKey(res.sessionPubKey, 'ec-public')
                        local sharedSecret = dataComp.ecdh(ephPriv, serverEphPub)
                        return deriveAesKey(dataComp, sharedSecret), nil
                    end
                end
            end
        end
    end

    return nil, 'timeout'
end

--- Encrypt plaintext with AES-128-CBC. Returns "ivB64:ciphertextB64".
--- A fresh random IV is generated for every call to prevent CBC prefix leakage.
---@param dataComp table
---@param aesKey string  16-byte raw key
---@param plaintext string
---@return string
function Handshake.encrypt(dataComp, aesKey, plaintext)
    local iv         = dataComp.random(16)
    local ciphertext = dataComp.encrypt(plaintext, aesKey, iv)
    return dataComp.encode64(iv) .. ':' .. dataComp.encode64(ciphertext)
end

--- Decrypt a "ivB64:ciphertextB64" packet. Returns nil on any failure.
---@param dataComp table
---@param aesKey string
---@param packet string
---@return string|nil plaintext
function Handshake.decrypt(dataComp, aesKey, packet)
    local ivB64, ctB64 = packet:match('^([^:]+):(.+)$')
    if not ivB64 or not ctB64 then return nil end

    local ok, result = pcall(function()
        local iv = dataComp.decode64(ivB64)
        local ct = dataComp.decode64(ctB64)
        return dataComp.decrypt(ct, aesKey, iv)
    end)

    return ok and result or nil
end

return Handshake
