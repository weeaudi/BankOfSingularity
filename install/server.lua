-- Bank of Singularity — Server installer
-- Run once on the bank server computer to download all server files.
-- Usage: lua /install/server.lua
local shell = require("shell")
local fs    = require("filesystem")

local function ensureDir(path)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDirectory(dir)
    end
end

local BASE =
    "https://raw.githubusercontent.com/weeaudi/BankOfSingularity/refs/heads/main"

local files = {
    -- Entry point
    ["/bank/server/main.lua"] = BASE .. "/bank/server/main.lua",
    ["/bank/server/admin.lua"] = BASE .. "/bank/server/admin.lua",

    -- Core server source
    ["/bank/server/src/dispatch.lua"] = BASE .. "/bank/server/src/dispatch.lua",
    ["/bank/server/src/admin.lua"] = BASE .. "/bank/server/src/admin.lua",
    ["/bank/server/src/adminUI.lua"] = BASE .. "/bank/server/src/adminUI.lua",

    -- Handlers
    ["/bank/server/src/handlers/req.lua"] = BASE ..
        "/bank/server/src/handlers/req.lua",
    ["/bank/server/src/handlers/init.lua"] = BASE ..
        "/bank/server/src/handlers/init.lua",

    -- Models
    ["/bank/server/src/models/Account.lua"] = BASE ..
        "/bank/server/src/models/Account.lua",
    ["/bank/server/src/models/Account_types.lua"] = BASE ..
        "/bank/server/src/models/Account_types.lua",
    ["/bank/server/src/models/Card.lua"] = BASE ..
        "/bank/server/src/models/Card.lua",
    ["/bank/server/src/models/Card_types.lua"] = BASE ..
        "/bank/server/src/models/Card_types.lua",
    ["/bank/server/src/models/Ledger.lua"] = BASE ..
        "/bank/server/src/models/Ledger.lua",
    ["/bank/server/src/models/Ledger_types.lua"] = BASE ..
        "/bank/server/src/models/Ledger_types.lua",

    -- Services
    ["/bank/server/src/services/authService.lua"] = BASE ..
        "/bank/server/src/services/authService.lua",
    ["/bank/server/src/services/accountService.lua"] = BASE ..
        "/bank/server/src/services/accountService.lua",
    ["/bank/server/src/services/cardService.lua"] = BASE ..
        "/bank/server/src/services/cardService.lua",
    ["/bank/server/src/services/ledgerService.lua"] = BASE ..
        "/bank/server/src/services/ledgerService.lua",
    ["/bank/server/src/services/deviceService.lua"] = BASE ..
        "/bank/server/src/services/deviceService.lua",

    -- Database
    ["/bank/server/src/db/database.lua"] = BASE ..
        "/bank/server/src/db/database.lua",
    ["/bank/server/src/db/init.lua"] = BASE .. "/bank/server/src/db/init.lua",

    -- Utilities
    ["/bank/server/src/util/whereClause.lua"] = BASE ..
        "/bank/server/src/util/whereClause.lua",
    ["/bank/server/src/util/log.lua"] = BASE .. "/bank/server/src/util/log.lua",

    -- Networking (server-side)
    ["/bank/server/src/net/handshakeServer.lua"] = BASE ..
        "/bank/server/src/net/handshakeServer.lua",

    -- Shared protocol / net layer
    ["/bank/shared/src/net/protocol.lua"] = BASE ..
        "/bank/shared/src/net/protocol.lua",
    ["/bank/shared/src/net/protocol_types.lua"] = BASE ..
        "/bank/shared/src/net/protocol_types.lua",
    ["/bank/shared/src/net/handshake.lua"] = BASE ..
        "/bank/shared/src/net/handshake.lua",
    ["/bank/shared/src/net/deviceKeys.lua"] = BASE ..
        "/bank/shared/src/net/deviceKeys.lua",
    ["/bank/shared/src/net/requestManager.lua"] = BASE ..
        "/bank/shared/src/net/requestManager.lua",

    -- Shared utilities
    ["/bank/shared/async.lua"] = BASE .. "/bank/shared/async.lua",
    ["/bank/shared/src/utils/index.lua"] = BASE ..
        "/bank/shared/src/utils/index.lua"
}

print("Bank of Singularity — Server installer")
print("Downloading " .. tostring(#files) .. " files...\n")

local ok, fail = 0, 0
for path, url in pairs(files) do
    io.write("  " .. path .. " ... ")
    ensureDir(path)
    local result = shell.execute("wget -f " .. url .. " " .. path)
    if result then
        print("ok")
        ok = ok + 1
    else
        print("FAILED")
        fail = fail + 1
    end
end

print(("\n%d downloaded, %d failed."):format(ok, fail))
if fail == 0 then
    print(
        "Done! Create /bank/server/config.lua then run: lua /bank/server/main.lua")
else
    print("Some files failed — check your internet card and try again.")
end
