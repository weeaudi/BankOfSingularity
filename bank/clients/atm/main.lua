local ROOT = '/bank'
package.path =
    ROOT .. '/clients/atm/?.lua;' ..
    ROOT .. '/clients/atm/?/init.lua;' ..
    ROOT .. '/shared/?.lua;' ..
    ROOT .. '/shared/?/init.lua;' ..
    package.path

local component = require('component')
local event = require('event')
local serialization = require('serialization')

local modem = component.modem
local event = require('event')
local Protocol = require('src.protocol')

local PORT = 100
local DISCOVERY_PORT = 999

local function fetch(toAddr, port, packet)
  modem.open(port)
  modem.send(toAddr, port, packet)

  ::pullevent::
  local _, _, serverAddr, serverPort, _, msg = event.pull('modem_message')

  if serverAddr ~= toAddr or serverPort ~= port then
    goto pullevent
  end

  return Protocol.decode(msg)
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
  'GetCardsByAccountId',
  modem.address,
  server,
  { accountId = 42 },
  nil
)

local res, err = fetch(server, PORT, req)

print(serialization.serialize(res))


-- local req = Protocol.makeRequest(
-- 'getCardsByAccountId',
--   modem.address,
--   SERVER,
--   { accountId = 42},
--   nil
-- )

-- modem.broadcast(123, req)
