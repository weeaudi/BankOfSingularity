local ROOT = '/bank'
package.path = ROOT .. '/clients/atm/?.lua;' .. ROOT ..
    '/clients/atm/?/init.lua;' .. ROOT .. '/shared/?.lua;' ..
    ROOT .. '/shared/?/init.lua;' .. package.path

local component = require('component')
local serialization = require('serialization')

local modem = component.modem
local event = require('event')
local Protocol = require('src.net.protocol')
local RequestManager = require('src.net.requestManager')

local PORT = 100
local DISCOVERY_PORT = 999

local function ensureOpen(port)
  if not modem.isOpen(port) then modem.open(port) end
end

---@param toAddr string
---@param port integer
---@param req Request
---@param timeout number
---@param callback fun(res: Response|nil, err: Error|nil)
local function fetch(toAddr, port, req, timeout, callback)
  ensureOpen(port)
  modem.send(toAddr, port, Protocol.encode(req))
  RequestManager.register(req.id, timeout, callback)
end

local function discoverServer()
  modem.open(DISCOVERY_PORT)
  modem.broadcast(DISCOVERY_PORT, "DISCOVER_BANK")
  local _, _, serverAddr, port, _, msg = event.pull(2, 'modem_message')
  modem.close(DISCOVERY_PORT)
  if not serverAddr then
    return nil
  end

  if msg ~= 'BANK_HERE' then
    return nil
  end

  return serverAddr
end

local server

while not server do
  server = discoverServer()
end

local req = Protocol.makeRequest(
  'Card.GetCardsByAccountId',
  modem.address,
  server,
  { accountId = 42 },
  nil
)

fetch(server, PORT, req, 2.0, function(res, err)
  if not res and err then
    print(err.code, err.message)
    return
  end
  if not res then return end
  print('ok: ' .. res.ok)
  print('Total cards: ' .. serialization.serialize(res.data))
end)


-- local req = Protocol.makeRequest(
-- 'getCardsByAccountId',
--   modem.address,
--   SERVER,
--   { accountId = 42},
--   nil
-- )

-- modem.broadcast(123, req)
