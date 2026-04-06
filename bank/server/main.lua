---@diagnostic disable: undefined-doc-name  -- Response/Request types defined in shared protocol module
--- bank/server/main.lua
--- Bank of Singularity — server boot entry point.
---
--- Listens on four modem ports:
---   100 (PORT)           — encrypted RPC traffic (AES-128-CBC)
---   101 (HANDSHAKE_PORT) — ECDH key exchange (establishes per-device AES key)
---   102 (ANNOUNCE_PORT)  — device registration / public-key upload
---   999 (DISCOVERY_PORT) — LAN discovery ping; replies "BANK_HERE"
---
--- Boot sequence:
---   1. Wait for modem + data components.
---   2. Initialize the device registry table (first-boot only).
---   3. Open all four ports and register the modem_message listener.
---   4. Start the Admin thread (GPU/screen UI or text CLI fallback).
---   5. Block in an event loop until interrupted or the admin thread dies.
---   6. Tear down listener and kill admin thread on exit.
---
--- Per-request flow (port 100):
---   onModemMessage → handleRpc → HS.getSession (AES key lookup) →
---   decrypt → Protocol.decode → Dispatch.handle → encrypt response → send

local ROOT = '/bank'
package.path =
    ROOT .. '/server/?.lua;' .. ROOT .. '/server/?/init.lua;' ..
    ROOT .. '/shared/?.lua;' .. ROOT .. '/shared/?/init.lua;' .. package.path

local component = require('component')
local event     = require('event')
local thread    = require('thread')

while not component.isAvailable('modem') do event.pull('component_added') end
while not component.isAvailable('data')  do event.pull('component_added') end

local modem    = component.modem
local dataComp = component.data

local Dispatch      = require('src.dispatch')
local Protocol      = require('src.net.protocol')
local HS            = require('src.net.handshakeServer')
local DeviceService = require('src.services.deviceService')
local Admin         = require('src.admin')
local Log           = require('src.util.log')
local serialization = require('serialization')

local PORT           = 100
local HANDSHAKE_PORT = 101
local ANNOUNCE_PORT  = 102
local DISCOVERY_PORT = 999

-- Ensure devices table exists on first boot
DeviceService.ensureTable()

local baseCtx = setmetatable({
    resOk     = Protocol.resOk,
    resErr    = Protocol.resErr,
    makeError = Protocol.makeError,
}, {__newindex = function() error('baseCtx is read-only') end})

--- Encrypt `res` with `aesKey` (AES-128-CBC, random IV) and send to `toAddr`.
---@param toAddr  string   Destination modem address
---@param port    integer  Destination port
---@param res     Response Encoded response table (will be serialized by Protocol.encode)
---@param aesKey  string   16-byte raw AES session key
local function sendEncrypted(toAddr, port, res, aesKey)
    local plain = Protocol.encode(res)
    local iv    = dataComp.random(16)
    local ct    = dataComp.encrypt(plain, aesKey, iv)
    modem.send(toAddr, port, dataComp.encode64(iv) .. ':' .. dataComp.encode64(ct))
end

local function handleRpc(localAddr, fromAddr, port, payload)
    local session = HS.getSession(fromAddr)
    if not session then
        -- No session: signal the client to re-authenticate (sent plain, unencrypted)
        modem.send(fromAddr, port, serialization.serialize({type = 'reauth_required'}))
        return
    end

    -- Decrypt payload
    local ivB64, ctB64 = payload:match('^([^:]+):(.+)$')
    if not ivB64 then
        Log.warn(('[RPC] Malformed packet from %s'):format(fromAddr))
        return
    end

    local ok, plain = pcall(function()
        local iv = dataComp.decode64(ivB64)
        local ct = dataComp.decode64(ctB64)
        return dataComp.decrypt(ct, session.aesKey, iv)
    end)

    if not ok or not plain then
        -- Decrypt failed — likely the client has a stale key; ask it to re-auth
        modem.send(fromAddr, port, serialization.serialize({type = 'reauth_required'}))
        return
    end

    local req, err = Protocol.decode(plain)
    if not req then
        local pseudoReq = {
            v = Protocol.VERSION, kind = Protocol.Kind.req,
            op = 'decode', id = '?',
            from = fromAddr, to = localAddr,
            ts = os.time(), data = {}
        }
        sendEncrypted(fromAddr, port,
            Protocol.resErr(pseudoReq, err or
                Protocol.makeError('BAD_PACKET', 'decode failed')),
            session.aesKey)
        return
    end

    if req.to ~= localAddr then return end

    local ctx = setmetatable({
        fromAddr   = fromAddr,
        localAddr  = localAddr,
        port       = port,
        receivedAt = os.time(),
        deviceId   = session.deviceId,
        deviceType = session.deviceType,
    }, {__index = baseCtx})

    local res = Dispatch.handle(req, ctx)
    if not res then
        res = ctx.resErr(req, ctx.makeError('HANDLER_ERROR', 'Handler failed'))
    end
    ---@cast res Response  -- guaranteed non-nil: fallback assigned above
    sendEncrypted(fromAddr, port, res, session.aesKey)
end

local function onModemMessage(_, localAddr, fromAddr, port, _, payload)
    if port == DISCOVERY_PORT then
        modem.send(fromAddr, port, 'BANK_HERE')
    elseif port == ANNOUNCE_PORT then
        HS.handleAnnounce(modem, fromAddr, payload)
    elseif port == HANDSHAKE_PORT then
        HS.handleHandshake(dataComp, modem, fromAddr, payload)
    elseif port == PORT then
        handleRpc(localAddr, fromAddr, port, payload)
    end
end

-- Boot
modem.open(PORT)
modem.open(HANDSHAKE_PORT)
modem.open(ANNOUNCE_PORT)
modem.open(DISCOVERY_PORT)
event.listen('modem_message', onModemMessage)

Log.info(('Server up — RPC:%d  HS:%d  Reg:%d  Discovery:%d'):format(
    PORT, HANDSHAKE_PORT, ANNOUNCE_PORT, DISCOVERY_PORT))
Log.info(('Address: %s'):format(modem.address))

local adminThread = thread.create(Admin.run)

while true do
    local e = {event.pull()}
    if e[1] == 'interrupted' then break end
    if adminThread:status() == 'dead' then break end
end

adminThread:kill()
event.ignore('modem_message', onModemMessage)
