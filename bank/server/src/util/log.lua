local LOG_PATH = '/bank/server.log'
local MAX_BYTES = 64 * 1024  -- 64 KB, then rotate

local Log = {}

local function timestamp()
    return os.date('%Y-%m-%d %H:%M:%S')
end

local function write(level, msg)
    local line = ('[%s] [%s] %s\n'):format(timestamp(), level, tostring(msg))

    -- Rotate if oversized
    local f = io.open(LOG_PATH, 'rb')
    if f then
        local size = f:seek('end')
        f:close()
        if size >= MAX_BYTES then
            os.rename(LOG_PATH, LOG_PATH .. '.old')
        end
    end

    local out = io.open(LOG_PATH, 'a')
    if out then
        out:write(line)
        out:close()
    end
end

function Log.info(msg)  write('INFO',  msg) end
function Log.warn(msg)  write('WARN',  msg) end
function Log.error(msg) write('ERROR', msg) end

return Log
