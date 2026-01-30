local protocol = require('src.protocol')

local M = {}

function M.resOk(req, data)
  return protocol.makeResponse(req, true, data or {}, nil)
end

function M.resErr(req, err)
  return M.makeResponse(req, false, nil, err)
end