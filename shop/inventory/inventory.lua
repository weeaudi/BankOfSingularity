---@diagnostic disable: undefined-field  -- OC API extensions (component.*, sides.*, os.sleep)
local component = require("component")
local sides = require("sides")
local computer = require("computer")
local serialize = require("serialization").serialize

local interface = component.me_interface
local database = component.database
local transposer = component.transposer

local tIn = sides.north
local tOut = sides.south

local restockAmount = 10 -- number of stacks to restock to

local function itemKey(item) return item.name .. "#" .. item.damage end

local function snapshotInventory()
    local inv = {}
    for _, item in ipairs(interface.getItemsInNetwork() or {}) do
        local k = itemKey(item)
        inv[k] = {
            item = item,
            size = (item.size or 0),
            maxSize = item.maxSize or 64
        }
    end
    return inv
end

local function configInterface(itemDesc)
    itemDesc = {name = itemDesc.name, damage = itemDesc.damage}
    interface.store(itemDesc, database.address, 1)
    interface.setInterfaceConfiguration(1, database.address, 1, 64)
end

local function clearInterface()
    database.clear(1)
    interface.setInterfaceConfiguration(1, database.address, 1, 0)
end

--- Transfers item from storage to output
---@param key string
---@param count number
---@return number|nil, string|nil
local function transferItem(key, count)
    if type(key) ~= "string" or type(count) ~= "number" or count <= 0 then
        return nil, "Bad Args"
    end

    local inventory = snapshotInventory()

    local item = inventory[key]

    if not item then return nil, "Not found in storage" end
    if item.size <= 0 then return nil, "No more stock in storage" end

    configInterface(item.item)

    local toTransfer = math.min(item.size, count)

    local slot = 1
    local max = transposer.getInventorySize(tOut)
    local transfered = 0
    local timeout = 0
    while toTransfer - transfered > 0 and timeout < 20 do
        local inputStack = transposer.getStackInSlot(tIn, 1)
        if slot > max then
            clearInterface()
            return transfered, "Output blocked/full"
        end
        if inputStack then
            timeout = 0
            transfered = transfered +
                             transposer.transferItem(tIn, tOut, math.min(
                                                         toTransfer - transfered,
                                                         64), 1, slot)
            slot = slot + 1
        else
            os.sleep(0.2)
            timeout = timeout + 1
        end

    end

    if (toTransfer - transfered) > 0 then
        return transfered, "Input timeout (interface empty)"
    end

    clearInterface()

    return transfered, nil

end

local f = assert(io.open("/out.log", "w"))
f:write(serialize(snapshotInventory()))
f:close()

