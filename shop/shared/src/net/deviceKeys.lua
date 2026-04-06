---@diagnostic disable: undefined-field  -- OC API extensions (fs.exists, fs.makeDirectory, dataComp.*)
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
