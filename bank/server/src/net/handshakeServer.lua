local serialization = require('serialization')
local computer      = require('computer')
local DeviceService = require('src.services.deviceService')
local Log           = require('src.util.log')

local HANDSHAKE_PORT = 101
local ANNOUNCE_PORT  = 102
local SESSION_TTL    = 3600  -- uptime seconds (1 hour)
local MAX_TS_DRIFT   = 60    -- reject handshakes with |os.time() - msg.ts| > 60s

---@type table<string, {deviceId:string, deviceType:string, aesKey:string, expiresAt:number}>
local sessions = {}

local HS = {}

-- IMPORTANT: sha256() returns raw bytes. Do NOT encode64 before sub() —
-- that would collapse the key space to printable ASCII.
local function deriveAesKey(dataComp, sharedSecret)
    return dataComp.sha256(sharedSecret):sub(1, 16)
end

local function pruneExpired()
    local now = computer.uptime()
    for addr, s in pairs(sessions) do
        if s.expiresAt < now then sessions[addr] = nil end
    end
end

--- Handle a device_announce message arriving on port 102.
---@param modem table
---@param fromAddr string
---@param payload string
function HS.handleAnnounce(modem, fromAddr, payload)
    local msg = serialization.unserialize(payload)
    if type(msg) ~= 'table' or msg.type ~= 'device_announce' then return end
    if type(msg.deviceId)  ~= 'string' then return end
    if type(msg.publicKey) ~= 'string' then return end

    local isNew = DeviceService.announce(
        msg.deviceId, msg.deviceType or 'unknown', msg.publicKey)

    local device = DeviceService.getById(msg.deviceId)
    local status = device and DeviceService.StatusLabel[device.status] or 'pending'

    modem.send(fromAddr, ANNOUNCE_PORT, serialization.serialize({
        type   = 'announce_ack',
        status = status,
    }))

    Log.info(('[Device] Announce: %s (%s) status=%s new=%s'):format(
        msg.deviceId, msg.deviceType or '?', status, tostring(isNew)))
end

--- Handle a handshake_init message arriving on port 101.
---@param dataComp table
---@param modem table
---@param fromAddr string
---@param payload string
function HS.handleHandshake(dataComp, modem, fromAddr, payload)
    local msg = serialization.unserialize(payload)
    if type(msg) ~= 'table' or msg.type ~= 'handshake_init' then return end

    local function reject(code)
        modem.send(fromAddr, HANDSHAKE_PORT, serialization.serialize({
            type = 'handshake_err', code = code,
        }))
    end

    -- Timestamp anti-replay: reject stale handshake requests
    if type(msg.ts) ~= 'number' or math.abs(os.time() - msg.ts) > MAX_TS_DRIFT then
        return reject('STALE_HANDSHAKE')
    end

    local device = DeviceService.getById(msg.deviceId)
    if not device                                       then return reject('DEVICE_NOT_REGISTERED') end
    if device.status == DeviceService.Status.Pending   then return reject('DEVICE_NOT_TRUSTED')    end
    if device.status == DeviceService.Status.Revoked   then return reject('DEVICE_REVOKED')        end
    if device.status == DeviceService.Status.Suspended then return reject('DEVICE_SUSPENDED')      end

    -- Verify ECDSA signature: "hs1:<deviceId>:<sessionPubKey>:<ts>"
    local sigData   = 'hs1:' .. msg.deviceId .. ':' .. msg.sessionPubKey .. ':' .. tostring(msg.ts)
    local sig       = dataComp.decode64(msg.sig)
    local clientPub = dataComp.deserializeKey(device.public_key, 'ec-public')

    local verified  = false
    pcall(function() verified = dataComp.ecdsa(sigData, clientPub, sig) end)
    if not verified then return reject('BAD_SIGNATURE') end

    -- ECDH key exchange with fresh ephemeral keys
    local serverEphPub, serverEphPriv = dataComp.generateKeyPair(384)
    local clientEphPub = dataComp.deserializeKey(msg.sessionPubKey, 'ec-public')
    local sharedSecret = dataComp.ecdh(serverEphPriv, clientEphPub)
    local aesKey       = deriveAesKey(dataComp, sharedSecret)

    pruneExpired()
    sessions[fromAddr] = {
        deviceId   = msg.deviceId,
        deviceType = device.device_type,
        aesKey     = aesKey,
        expiresAt  = computer.uptime() + SESSION_TTL,
    }

    modem.send(fromAddr, HANDSHAKE_PORT, serialization.serialize({
        type          = 'handshake_ok',
        sessionPubKey = serverEphPub.serialize(),
    }))

    Log.info(('[Device] Handshake OK: %s (%s) from %s'):format(
        msg.deviceId, device.device_type, fromAddr))
end

--- Get a valid session for a modem address, or nil if missing/expired.
---@param addr string
---@return table|nil session  {deviceId, deviceType, aesKey}
function HS.getSession(addr)
    local s = sessions[addr]
    if not s then return nil end
    if s.expiresAt < computer.uptime() then
        sessions[addr] = nil
        return nil
    end
    return s
end

return HS
