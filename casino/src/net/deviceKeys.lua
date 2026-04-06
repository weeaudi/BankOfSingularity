---@diagnostic disable: undefined-field  -- OC API extensions (fs.exists, fs.makeDirectory, dataComp.*)
--- casino/src/net/deviceKeys.lua
--- Persistent EC-384 identity key pair for this casino device.
---
--- On first run the key pair is generated and written to `path` in binary mode.
--- On subsequent runs the serialized pair is loaded from disk and deserialized
--- back into OC key objects.
---
--- The public key is sent to the bank server during device announce so the
--- server can verify ECDSA signatures in the handshake.

-- LuaLS treats "public"/"private" as access modifiers inside @field, so the
-- fields are described in plain comments to avoid false duplicate/undefined warnings.
--
---@class DeviceKeyPair
-- .public           (userdata)  OC EC-384 public key object (dataComp.deserializeKey result)
-- .private          (userdata)  OC EC-384 private key object
---@field publicSerialized string  Serialized public key string sent to the server during announce

local fs            = require('filesystem')
local serialization = require('serialization')

local DeviceKeys = {}

local function ensureDir(path)
    local parent = path:match('^(.*)/[^/]+$')
    if parent and parent ~= '' and not fs.exists(parent) then
        fs.makeDirectory(parent)
    end
end

--- Load or generate a persistent EC-384 identity key pair.
--- Key file is opened in binary mode to avoid filesystem text-mode corruption.
---@param dataComp table  OC data component
---@param path string     path to key file
---@return table keys  {public, private, publicSerialized}
function DeviceKeys.load(dataComp, path)
    if fs.exists(path) then
        local h   = assert(io.open(path, 'rb'))
        local raw = h:read('*a')
        h:close()
        local tbl = serialization.unserialize(raw)
        assert(type(tbl) == 'table', 'corrupt key file: ' .. path)
        return {
            public           = dataComp.deserializeKey(tbl.public,  'ec-public'),
            private          = dataComp.deserializeKey(tbl.private, 'ec-private'),
            publicSerialized = tbl.public,
        }
    end

    ensureDir(path)
    local pub, priv = dataComp.generateKeyPair(384)
    local pubSer    = pub.serialize()
    local privSer   = priv.serialize()
    local h = assert(io.open(path, 'wb'))
    h:write(serialization.serialize({public = pubSer, private = privSer}))
    h:close()

    print('[DeviceKeys] Generated new identity key pair at ' .. path)
    return {public = pub, private = priv, publicSerialized = pubSer}
end

return DeviceKeys
