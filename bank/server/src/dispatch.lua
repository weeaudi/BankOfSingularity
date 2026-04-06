---@diagnostic disable: undefined-doc-name  -- Request/Response types in shared protocol module
--- bank/server/src/dispatch.lua
--- Operation dispatcher — second stage of the server request pipeline.
---
--- After `main.lua` decrypts and decodes an incoming packet it calls
--- `Dispatch.handle(req, ctx)`.  The dispatcher does two things:
---
---   1. Device-type gate: checks whether the authenticated device's type
---      is allowed to call the requested operation (DEVICE_OPS table).
---      Devices with no type entry (admin/nil) are unrestricted.
---
---   2. Kind routing: looks up the handler for `req.kind` in `byKind`
---      and delegates.  Currently only `"req"` is wired in.
---
--- Device permission map (DEVICE_OPS):
---   pos — Card auth/deauth, balance check, hold, adjust, release, transfer,
---          account lookup by name.
---   atm — Card auth/deauth, balance check, withdraw, deposit.
---   nil — unrestricted (admin / trusted server devices).

---@class ExecutionContext
---@field fromAddr   string   Modem address of the calling device
---@field localAddr  string   This server's modem address
---@field port       integer  Port the message arrived on
---@field receivedAt integer  os.time() stamp at message receipt
---@field deviceId   string   Authenticated device ID (from session)
---@field deviceType string|nil Device role: "pos", "atm", or nil (unrestricted)
---@field resOk      fun(req: Request, data: any): Response          Build a success response
---@field resErr     fun(req: Request, err: Error|nil): Response     Build an error response
---@field makeError  fun(code: string, msg: string): Error          Build an Error value

local Handlers = require('src.handlers')
local Dispatch = {}

--- Allowed operations per device type. nil = unrestricted (e.g. admin devices).
---@type table<string, table<string, boolean>>
local DEVICE_OPS = {
    pos = {
        ['Card.Authenticate'] = true,
        ['Card.Deauthenticate'] = true,
        ['Ledger.GetBalance'] = true,
        ['Ledger.Hold'] = true,
        ['Ledger.Adjust'] = true,
        ['Ledger.Release'] = true,
        ['Ledger.Transfer'] = true,
        ['Accounts.GetByName'] = true
    },
    atm = {
        ['Card.Authenticate'] = true,
        ['Card.Deauthenticate'] = true,
        ['Ledger.GetBalance'] = true,
        ['Ledger.Withdraw'] = true,
        ['Ledger.Deposit'] = true
    }
}

Dispatch.byKind = {req = Handlers.req.handle}

---@param req Request
---@param ctx ExecutionContext
---@return Response|nil
function Dispatch.handle(req, ctx)
    local fn = Dispatch.byKind[req.kind]
    if not fn then
        return ctx.resErr(req,
                          ctx.makeError('HANDLER_NOT_FOUND', 'Invalid handler'))
    end

    -- Device type op restriction. nil deviceType = unrestricted.
    local allowed = ctx.deviceType and DEVICE_OPS[ctx.deviceType]
    if allowed ~= nil and not allowed[req.op] then
        return ctx.resErr(req,
                          ctx.makeError('FORBIDDEN',
                                        ('Device type "%s" cannot call "%s"'):format(
                                            ctx.deviceType, req.op)))
    end

    return fn(req, ctx)
end

return Dispatch
