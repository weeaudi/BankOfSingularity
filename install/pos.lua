-- Bank of Singularity — POS Client installer
-- Run once on the POS computer to download all client files.
-- Usage: lua /install/pos.lua
local shell = require("shell")

local BASE =
    "https://raw.githubusercontent.com/weeaudi/BankOfSingularity/refs/heads/main"

local files = {
    -- Entry point
    ["/shop/main.lua"] = BASE .. "/shop/main.lua",

    -- POS core
    ["/shop/src/posCore.lua"] = BASE .. "/shop/src/posCore.lua",
    ["/shop/src/catalog.lua"] = BASE .. "/shop/src/catalog.lua",
    ["/shop/src/inventory.lua"] = BASE .. "/shop/src/inventory.lua",

    -- UI
    ["/shop/src/ui/store.lua"] = BASE .. "/shop/src/ui/store.lua",
    ["/shop/src/ui/stockPage.lua"] = BASE .. "/shop/src/ui/stockPage.lua",
    ["/shop/src/ui/configMode.lua"] = BASE .. "/shop/src/ui/configMode.lua",

    -- Utilities
    ["/shop/src/util/money.lua"] = BASE .. "/shop/src/util/money.lua",

    -- Shared protocol / net layer
    ["/shop/shared/src/net/protocol.lua"] = BASE ..
        "/shop/shared/src/net/protocol.lua",
    ["/shop/shared/src/net/protocol_types.lua"] = BASE ..
        "/shop/shared/src/net/protocol_types.lua",
    ["/shop/shared/src/net/handshake.lua"] = BASE ..
        "/shop/shared/src/net/handshake.lua",
    ["/shop/shared/src/net/deviceKeys.lua"] = BASE ..
        "/shop/shared/src/net/deviceKeys.lua",
    ["/shop/shared/src/net/requestManager.lua"] = BASE ..
        "/shop/shared/src/net/requestManager.lua",

    -- Shared utilities
    ["/shop/shared/async.lua"] = BASE .. "/shop/shared/async.lua",
    ["/shop/shared/src/utils/index.lua"] = BASE ..
        "/shop/shared/src/utils/index.lua"
}

print("Bank of Singularity — POS Client installer")
print("Downloading " .. tostring(#files) .. " files...\n")

local ok, fail = 0, 0
for path, url in pairs(files) do
    io.write("  " .. path .. " ... ")
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
    print("Done! Create /shop/config.lua then run: lua /shop/main.lua")
else
    print("Some files failed — check your internet card and try again.")
end
