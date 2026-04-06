--- casino/src/net/protocol.lua
--- Wire-protocol definitions shared by casino client and bank server.
---
--- Message format (all fields serialized via OC `serialization`):
---
---   Request  { v, kind="req", op, id, from, to, ts, data }
---   Response { v, kind="res", op, id, from, to, ok, ts, data|nil, err|nil }
---   Event    { v, kind="evt", op, from, ts, data }
---
--- All monetary amounts are in cents (integer). Tokens are UUID strings.

---@class Request
---@field v    integer   Protocol version (must equal M.VERSION)
---@field kind string    "req"
---@field op   string    Operation name e.g. "Card.Authenticate"
---@field id   string    Unique request ID (used to match responses)
---@field from string    Sender modem address
---@field to   string    Recipient modem address
---@field ts   number    os.time() at send
---@field data table     Operation-specific payload

---@class Response
---@field v    integer
---@field kind string    "res"
---@field op   string    Mirrors the request op
---@field id   string    Mirrors the request id
---@field from string    Server address
---@field to   string    Client address
---@field ok   boolean   true = success, false = error
---@field ts   number
---@field data table|nil Present when ok=true
---@field err  Error|nil Present when ok=false

---@class Error
---@field code    string  Short machine-readable error code
---@field message string  Human-readable description

local M = {}

M.VERSION = 1

M.Kind = { req = 'req', res = 'res', evt = 'evt' }

M.ErrorCode = {
    NOT_FOUND = "NOT_FOUND",
    BAD_REQUEST = "BAD_REQUEST",
    UNAUTHORIZED = "UNAUTHORIZED",
    INTERNAL = "INTERNAL"
}

M.Ops = {}

local _seq = 0
---@param prefix string|nil
---@return string
function M.newId(prefix)
    _seq = _seq + 1
    prefix = prefix or "r"
    return ("%s-%s-%d"):format(prefix, os.time(), _seq)
end

---@class MakeRequestOps
---@field ts number timestamp

---@param op string
---@param from string
---@param to string
---@param data table
---@param opts table|nil
---@return Request
function M.makeRequest(op, from, to, data, opts)
    opts = opts or {}
    return {
        v = M.VERSION,
        kind = M.Kind.req,
        op = op,
        id = opts.id or M.newId('req'),
        from = from,
        to = to,
        ts = opts.ts or os.time(),
        data = data or {}
    }
end

---@param req Request
---@param ok boolean
---@param data table|nil
---@param err Error|nil
---@return Response res
function M.makeResponse(req, ok, data, err)
    local res = {
        v = M.VERSION,
        kind = M.Kind.res,
        op = req.op,
        id = req.id,
        from = req.to,
        to = req.from,
        ok = ok and true or false,
        ts = os.time(),
        data = ok and (data or {}) or nil,
        err = ok and nil or err
    }
    return res
end

function M.makeError(code, message) return { code = code, message = message } end

---@return true|nil ok
---@return Error|nil err
function M.validatePacket(p)
    if type(p) ~= 'table' then
        return nil, M.makeError('BAD_PACKET', 'Packet is not a table')
    end
    if p.v ~= M.VERSION then
        return nil, M.makeError('VERSION_MISMATCH', 'Invalid packet version')
    end
    if not M.Kind[p.kind] then
        return nil, M.makeError('BAD_KIND', 'invalid kind')
    end
    if type(p.op) ~= 'string' then
        return nil, M.makeError('BAD_OP', 'Requested invalid op')
    end
    if type(p.from) ~= 'string' then
        return nil, M.makeError('BAD_FROM', 'Packet missing from address')
    end
    if p.kind ~= "evt" and type(p.id) ~= "string" then
        return nil, M.makeError('BAD_ID', 'EVT Packet ID missing')
    end
    if p.kind == "res" and type(p.ok) ~= "boolean" then
        return nil, M.makeError('BAD_OK', 'Res OK missing')
    end
    return true
end

local okSer, ser = pcall(require, 'serialization')

---@param pkt table Table to serialize
---@return string|nil s
---@return Error|nil err
function M.encode(pkt)
    if not okSer then
        return nil, M.makeError('SERIALIZATION_MISSING',
            'Serialization not available')
    end

    if type(pkt) ~= "table" then
        return nil, M.makeError('BAD_PACKET', 'Packet not table')
    end
    local ok, s = pcall(ser.serialize, pkt)
    if not ok or type(s) ~= 'string' then
        return nil, M.makeError('ENCODE_FAILED', 'Unable to encode packet')
    end

    return s
end

---@param s string Decodeable table as string
---@return table|nil pkt
---@return Error|nil err
function M.decode(s)
    if not okSer then
        return nil, M.makeError('SERIALIZATION_MISSING',
            'Serialization not available')
    end
    if type(s) ~= 'string' then
        return nil, M.makeError('BAD_PAYLOAD', 'Payload not string')
    end

    local ok, pkt = pcall(ser.unserialize, s)
    if not ok or type(pkt) ~= 'table' then
        return nil, M.makeError('DECODE_FAILED', 'Unable to decode string')
    end

    local vok, verr = M.validatePacket(pkt)
    if not vok then return nil, verr end

    return pkt
end

---@param req Request
---@param data table|nil
---@return Response res
function M.resOk(req, data) return M.makeResponse(req, true, data or {}, nil) end

---@param req Request
---@param err Error
---@return Response
function M.resErr(req, err)
    return M.makeResponse(req, false, nil, err)
end

return M
