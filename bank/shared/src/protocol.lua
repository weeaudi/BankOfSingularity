local M = {}

M.VERSION = 1

M.Kind = {req = 'req', res = 'res', evt = 'evt'}

M.ErrorCode = {
    NOT_FOUND = "NOT_FOUND",
    BAD_REQUEST = "BAD_REQUEST",
    UNAUTHORIZED = "UNAUTHORIZED",
    INTERNAL = "INTERNAL"
}

M.Ops = {}

local _seq = 0
---@param prefix string
---@return string
function M.newId(prefix)
    _seq = _seq + 1
    prefix = prefix or "r"
    return ("%s-%d-%d"):format(prefix, os.time(), _seq)
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
---@param data table
---@param err Error
function M.makeResponse(req, ok, data, err)
    return {
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
end

function M.makeError(code, message) return {code = code, message = message} end

---@return boolean ok
---@return string|nil error Error message
function M.validatePacket(p)
    if type(p) ~= 'table' then return false, 'packet not table' end
    if p.v ~= M.VERSION then return false, 'bad version' end
    if not M.Kind[p.kind] then return false, 'bad kind' end
    if type(p.op) ~= 'string' then return false, 'op missing' end
    if type(p.from) ~= 'string' then return false, 'from missing' end
    if p.kind ~= "evt" and type(p.id) ~= "string" then
        return false, "id missing"
    end
    if p.kind == "res" and type(p.ok) ~= "boolean" then
        return false, "ok missing"
    end
    return true
end

local okSer, ser = pcall(require, 'serialization')
---@param pkt table Table to serialize
---@return string
function M.encode(pkt)
    if not okSer then error('serialization not available') end
    return ser.serialize(pkt)
end

---@param s string Decodeable table as string
---@return table t
function M.decode(s)
    if not okSer then return nil, 'serialization not available' end
    local t = ser.unserialize(s)
    if type(t) ~= 'table' then return nil, 'decode failed' end
    return t
end

return M
