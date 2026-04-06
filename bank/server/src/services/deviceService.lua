--- bank/server/src/services/deviceService.lua
--- Device registry — manages approved clients that may connect to the server.
---
--- Device lifecycle:
---   announce()  — called when a device sends its public key on port 102.
---                 New devices start as Pending; existing devices are no-ops
---                 unless the public key changed (key rotation → reset to Pending).
---   trust()     — admin approves a Pending device; sets status to Active.
---   revoke()    — admin permanently blocks a device.
---   list()      — returns all device records (optionally filtered).
---
--- Statuses (DeviceStatus enum):
---   Pending   (0) — registered but not yet approved by admin
---   Active    (1) — trusted; can complete handshake and send RPC
---   Suspended (2) — temporarily blocked
---   Revoked   (3) — permanently blocked

local db  = require('src.db').database
local Log = require('src.util.log')

---@enum DeviceStatus
local DeviceStatus = {Pending = 0, Active = 1, Suspended = 2, Revoked = 3}
local STATUS_LABEL = {[0] = 'pending', [1] = 'active', [2] = 'suspended', [3] = 'revoked'}

local DeviceService = {}
DeviceService.Status      = DeviceStatus
DeviceService.StatusLabel = STATUS_LABEL

function DeviceService.ensureTable()
    db.createTable('devices', {
        indexed = {'device_id'},
        unique  = {device_id = true},
    })
end

--- Register a new device announcement, or update an existing one.
--- If the device already exists: no-op unless the public key changed, in which
--- case the device is reset to pending (key rotation requires re-approval).
---@param deviceId string
---@param deviceType string
---@param publicKey string  serialized EC public key
---@return boolean isNew
function DeviceService.announce(deviceId, deviceType, publicKey)
    local existing = db.select('devices'):where({device_id = deviceId}):first()

    if existing then
        if existing.public_key ~= publicKey then
            db.update('devices', {device_id = deviceId}, {
                public_key = publicKey,
                status     = DeviceStatus.Pending,
            })
            Log.warn(('[Device] Key rotation for "%s" — reset to pending'):format(deviceId))
        end
        return false
    end

    db.insert('devices', {
        device_id     = deviceId,
        device_type   = deviceType,
        public_key    = publicKey,
        status        = DeviceStatus.Pending,
        registered_at = os.time(),
    })
    return true
end

---@param deviceId string
---@return table|nil
function DeviceService.getById(deviceId)
    return db.select('devices'):where({device_id = deviceId}):first()
end

--- Trust a pending device, optionally overriding its type.
---@param deviceId string
---@param deviceType string|nil
---@return boolean ok
function DeviceService.trust(deviceId, deviceType)
    local patch = {status = DeviceStatus.Active}
    if deviceType and deviceType ~= '' then patch.device_type = deviceType end
    return db.update('devices', {device_id = deviceId}, patch) > 0
end

---@param deviceId string
function DeviceService.revoke(deviceId)
    db.update('devices', {device_id = deviceId}, {status = DeviceStatus.Revoked})
end

---@param where table|nil
---@return table[]
function DeviceService.list(where)
    return db.select('devices'):where(where):all()
end

return DeviceService
