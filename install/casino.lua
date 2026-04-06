-- Bank of Singularity — Casino installer
-- Run once on the casino computer to download all casino files.
-- Usage: lua /install/casino.lua
local shell = require("shell")

local BASE =
    "https://raw.githubusercontent.com/weeaudi/BankOfSingularity/refs/heads/main"

local files = {
    -- Entry point
    ["/casino/main.lua"] = BASE .. "/casino/main.lua",

    -- Core
    ["/casino/src/casinoCore.lua"] = BASE .. "/casino/src/casinoCore.lua",
    ["/casino/src/ui.lua"] = BASE .. "/casino/src/ui.lua",

    -- Networking
    ["/casino/src/net/protocol.lua"] = BASE .. "/casino/src/net/protocol.lua",
    ["/casino/src/net/handshake.lua"] = BASE .. "/casino/src/net/handshake.lua",
    ["/casino/src/net/deviceKeys.lua"] = BASE ..
        "/casino/src/net/deviceKeys.lua",
    ["/casino/src/net/requestManager.lua"] = BASE ..
        "/casino/src/net/requestManager.lua"
}

print("Bank of Singularity — Casino installer")
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
    print("Done! Create /casino/config.lua then run: lua /casino/main.lua")
else
    print("Some files failed — check your internet card and try again.")
end
