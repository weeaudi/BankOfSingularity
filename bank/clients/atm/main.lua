local ROOT = '/bank'
package.path =
    ROOT .. '/clients/atm/?.lua;' ..
    ROOT .. '/clients/atm/?/init.lua;' ..
    ROOT .. '/shared/?.lua;' ..
    ROOT .. '/shared/?/init.lua;' ..
    package.path

local component = require('component')
local event = require('event')

local modem = component.modem
local event = require('event')
local Protocol = require('src.protocol')

local DISCOVERY_PORT = 999
modem.open(DISCOVERY_PORT)
modem.broadcast(DISCOVERY_PORT, "DISCOVER_BANK")

local _, _, serverAddr, port, _, msg = event.pull('modem_message')

local SERVER = ''

if msg then
  print('Found bank server:', serverAddr)
  SERVER = serverAddr
end


-- local req = Protocol.makeRequest(
-- 'getCardsByAccountId',
--   modem.address,
--   SERVER,
--   { accountId = 42},
--   nil
-- )

-- modem.broadcast(123, req)
