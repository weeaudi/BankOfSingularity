local ROOT = '/bank'
package.path =
    ROOT .. '/server/?.lua;' .. ROOT .. '/server/?/init.lua;' ..
    ROOT .. '/shared/?.lua;'  .. ROOT .. '/shared/?/init.lua;' .. package.path

local db            = require('src.db').database
local DeviceService = require('src.services.deviceService')

db.createTable('accounts', {indexed = {'account_name'}, unique = {account_name = true}})
db.createTable('cards',    {indexed = {'account_id', 'uid'}, unique = {uid = true}})
DeviceService.ensureTable()

require('src.admin').run()
