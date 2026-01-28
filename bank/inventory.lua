local component = require("component")
local sides = require("sides")
local computer = require("computer")
local serialize = require("serialization").serialize

local transposers = {}
local inventory = {}

local configDB = component.database
local restockAmount = 10 -- number of stacks to restock to

local tConfig = {
    output = {
        h8 = "0dacce11",
        outputSide = sides.south,
        inputSide = sides.north
    },
    buffer = {
        h8 = "527288da",
        outputSide = sides.south,
        inputSide = sides.north,
        overflowSide = sides.west
    },
    default = {outputSide = sides.west, inputSide = sides.east}
}

local function iterateTransposers()
    local componentList = component.list("transposer")
    for address in componentList do
        local transposer = component.proxy(address)
        if address:sub(1, 8) == tConfig.output.h8:sub(1, 8) then
            transposers.output = transposer
            goto eloop
        elseif address:sub(1, 8) == tConfig.buffer.h8:sub(1, 8) then
            transposers.buffer = transposer
            goto eloop
        end

        local item = transposer.getStackInSlot(tConfig.default.inputSide, 2)
        if item then
            transposers[item.name .. "#" .. item.damage] = transposer
        end
        ::eloop::
    end
end

local function findFirstEmptyOrMatchingSlot(transposer, item, side, startSlot)
    local start = startSlot or 1
    for slot = start, transposer.getInventorySize(side) do
        local stack = transposer.getStackInSlot(side, slot)
        if not stack then
            return slot
        elseif stack.name == item.name and stack.damage == item.damage then
            if stack.size < stack.maxSize then return slot end
        end
    end
    return nil
end

local function moveItemToBuffer(bufferTransposer, item, fromSide, toSide, slot,
                                itemCache)
    local remaining = item.size
    itemCache = itemCache or {}
    while remaining > 0 do
        local startSlot = 1
        if itemCache[item.name .. "#" .. item.damage] then
            startSlot = itemCache[item.name .. "#" .. item.damage]
        end
        local emptySlot = findFirstEmptyOrMatchingSlot(bufferTransposer, item,
                                                       toSide, startSlot)
        if not emptySlot then
            print("No empty slot found in buffer, dumping buffer")
            ---@diagnostic disable-next-line: undefined-field
            -- for overSlot = 1, bufferTransposer.getInventorySize(fromSide) do
            --     bufferTransposer.transferItem(tConfig.buffer.inputSide,
            --                                   tConfig.buffer.overflowSide,
            --                                   bufferTransposer.getStackInSlot(
            --                                       tConfig.buffer.inputSide).size,
            --                                   overSlot, overSlot)
            -- end
            goto loop
        end

        itemCache[item.name .. "#" .. item.damage] = emptySlot

        local transferSize = math.min(remaining, item.size)
        local transfered = bufferTransposer.transferItem(fromSide, toSide,
                                                         transferSize, slot,
                                                         emptySlot)
        remaining = remaining - transfered
        ::loop::
    end
end

function QueryAndCleanBuffer()
    local bufferTransposer = transposers.buffer
    local numSlots =
        bufferTransposer.getInventorySize(tConfig.buffer.outputSide)
    local itemCache = {}
    -- every 10 slots is a row. each entry in the db determines a row.
    for slot = 1, numSlots do
        print("Checking slot " .. slot .. "/" .. numSlots)
        local item = bufferTransposer.getStackInSlot(tConfig.buffer.outputSide,
                                                     slot)
        if item then
            local rowID = math.floor((slot - 1) / 10) + 1
            local dbEntry = configDB.get(rowID)
            if not dbEntry then
                moveItemToBuffer(bufferTransposer, item,
                                 tConfig.buffer.outputSide,
                                 tConfig.buffer.inputSide, slot, itemCache)
                goto eloop
            end
            local entryName = dbEntry.name .. "#" .. dbEntry.damage
            local itemName = item.name .. "#" .. item.damage
            if itemName ~= entryName then
                moveItemToBuffer(bufferTransposer, item,
                                 tConfig.buffer.outputSide,
                                 tConfig.buffer.inputSide, slot, itemCache)
                goto eloop
            else
                if not inventory[entryName] then
                    inventory[entryName] = {
                        count = 0,
                        name = "",
                        hasStock = false
                    }
                end
                inventory[entryName] = {
                    count = (inventory[entryName].count) + item.size,
                    name = item.label,
                    hasStock = inventory[entryName].hasStock
                }
            end
        end
        ::eloop::
    end
end

local function flushBuffer()
    local bufferTransposer = transposers.buffer
    local numRows = math.ceil(bufferTransposer.getInventorySize(tConfig.buffer
                                                                    .outputSide) /
                                  10)
    local numSlots = bufferTransposer.getInventorySize(tConfig.buffer.inputSide)
    local rowCache = {}
    local slotCache = {}
    local overflowCache = {}
    for slot = 1, numSlots do
        print("Flushing slot " .. slot .. "/" .. numSlots)
        local item = bufferTransposer.getStackInSlot(tConfig.buffer.inputSide,
                                                     slot)

        if item then

            local accountedFor = false
            local row = nil

            if overflowCache[item.name .. "#" .. item.damage] then
                goto overflow
            end

            if rowCache[item.name .. "#" .. item.damage] then
                row = rowCache[item.name .. "#" .. item.damage]
            end

            if row then
                local startSlot =
                    (slotCache[item.name .. "#" .. item.damage]) or
                        ((row - 1) * 10 + 1)
                local endSlot = math.min(startSlot + 9,
                                         bufferTransposer.getInventorySize(
                                             tConfig.buffer.outputSide))
                local remaining = item.size
                while remaining > 0 do
                    local emptySlot = findFirstEmptyOrMatchingSlot(
                                          bufferTransposer, item,
                                          tConfig.buffer.outputSide, startSlot)
                    if not emptySlot then break end
                    slotCache[item.name .. "#" .. item.damage] = emptySlot
                    if emptySlot and emptySlot <= endSlot then
                        print("transfering from row " .. row .. "to slot " ..
                                  emptySlot)
                        local transferSize = math.min(remaining, item.size)
                        local transfered =
                            bufferTransposer.transferItem(tConfig.buffer
                                                              .inputSide,
                                                          tConfig.buffer
                                                              .outputSide,
                                                          transferSize, slot,
                                                          emptySlot)
                        if not inventory[item.name .. "#" .. item.damage] then
                            inventory[item.name .. "#" .. item.damage] = {
                                count = 0,
                                name = "",
                                hasStock = false
                            }
                        end
                        inventory[item.name .. "#" .. item.damage] = {
                            count = (inventory[item.name .. "#" .. item.damage]
                                .count) + transfered,
                            name = item.label,
                            hasStock = inventory[item.name .. "#" .. item.damage]
                        }
                        remaining = remaining - transfered
                    end
                    if remaining <= 0 then break end
                    if emptySlot and emptySlot > endSlot then
                        break
                    end
                end
                goto slotLoop
            end

            for row = 1, numRows do
                local transferedAll = false
                local dbEntry = configDB.get(row)
                if dbEntry then
                    local entryName = dbEntry.name .. "#" .. dbEntry.damage
                    local itemName = item.name .. "#" .. item.damage
                    if itemName == entryName then
                        accountedFor = true
                        rowCache[item.name .. "#" .. item.damage] = row
                        local startSlot = (row - 1) * 10 + 1
                        local endSlot = math.min(startSlot + 9,
                                                 bufferTransposer.getInventorySize(
                                                     tConfig.buffer.outputSide))
                        local remaining = item.size
                        while remaining > 0 do
                            local emptySlot =
                                findFirstEmptyOrMatchingSlot(bufferTransposer,
                                                             item,
                                                             tConfig.buffer
                                                                 .outputSide,
                                                             startSlot)
                            if not emptySlot then
                                break
                            end
                            if emptySlot and emptySlot <= endSlot then
                                local transferSize = math.min(remaining,
                                                              item.size)
                                local transfered =
                                    bufferTransposer.transferItem(
                                        tConfig.buffer.inputSide,
                                        tConfig.buffer.outputSide, transferSize,
                                        slot, emptySlot)
                                if not inventory[item.name .. "#" .. item.damage] then
                                    inventory[item.name .. "#" .. item.damage] =
                                        {count = 0, name = "", hasStock = false}
                                end
                                inventory[item.name .. "#" .. item.damage] = {
                                    count = (inventory[item.name .. "#" ..
                                        item.damage].count) + transfered,
                                    name = item.label,
                                    hasStock = inventory[item.name .. "#" ..
                                        item.damage].hasStock
                                }
                                remaining = remaining - transfered
                            end
                            if remaining <= 0 then
                                transferedAll = true
                                break
                            end
                            if emptySlot and emptySlot > endSlot then
                                break
                            end
                        end
                    end
                end
                if transferedAll then break end
            end
            ::overflow::
            if not accountedFor then

                local toTransfer = item.size
                while toTransfer > 0 do

                    local startSlot = 1
                    if overflowCache[item.name .. "#" .. item.damage] then
                        startSlot = overflowCache[item.name .. "#" ..
                                        item.damage]
                    end
                    local emptySlot = findFirstEmptyOrMatchingSlot(
                                          bufferTransposer, item,
                                          tConfig.buffer.overflowSide, startSlot)
                    if not emptySlot then
                        error("ERROR: Buffer is full and overflow is full")
                    end

                    overflowCache[item.name .. "#" .. item.damage] = emptySlot

                    local transfered = bufferTransposer.transferItem(
                                           tConfig.buffer.inputSide,
                                           tConfig.buffer.overflowSide,
                                           toTransfer, slot, emptySlot)

                    toTransfer = toTransfer - transfered

                end
            end

            ::slotLoop::
        end
    end
end

local function restock()
    local bufferTransposer = transposers.buffer
    local numRows = math.ceil(bufferTransposer.getInventorySize(tConfig.buffer
                                                                    .outputSide) /
                                  10)

    local didRestock = false
    local restocked = {}

    for row = 1, numRows - 1 do
        local dbEntry = configDB.get(row)
        if dbEntry then
            local entryName = dbEntry.name .. "#" .. dbEntry.damage
            print("Checking restock for " .. entryName)
            local itemCount = 0
            if inventory[entryName] then
                itemCount = inventory[entryName].count
            end
            local desiredCount = restockAmount * dbEntry.maxSize
            if itemCount < desiredCount then
                local toRestock = desiredCount - itemCount
                print("Restocking " .. entryName .. " x" .. toRestock)
                local startSlot = (row - 1) * 10 + 1
                local endSlot = math.min(startSlot + 9,
                                         bufferTransposer.getInventorySize(
                                             tConfig.buffer.outputSide))

                local stockTransposer = transposers[entryName]
                if stockTransposer then
                    local remaining = toRestock
                    while remaining > 0 do
                        local stockEntry =
                            stockTransposer.getStackInSlot(tConfig.default
                                                               .inputSide, 2)
                        if not stockEntry then
                            print("No more stock for " .. entryName)
                            break
                        end
                        local transfered =
                            stockTransposer.transferItem(tConfig.default
                                                             .inputSide,
                                                         tConfig.default
                                                             .outputSide,
                                                         math.min(remaining,
                                                                  stockEntry.size),
                                                         2, 1)
                        if transfered == 0 then
                            print("Failed to transfer from stock for " ..
                                      entryName .. ". Waiting...")
                            os.sleep(1)
                        end
                        remaining = remaining - transfered
                    end
                end
                didRestock = true
                restocked[entryName] = stockTransposer
            end
        end
    end

    -- wait for restock to flush to buffer before flushing buffer to main compartment
    for k, v in pairs(restocked) do
        local transposer = v
        while true do
            local item =
                transposer.getStackInSlot(tConfig.default.outputSide, 2)
            if not item then break end
            if not bufferTransposer.getStackInSlot(tConfig.buffer.inputSide,
                                                   bufferTransposer.getInventorySize(
                                                       tConfig.buffer.inputSide)) then
                os.sleep(1)
            else
                break
            end
        end
    end

    if didRestock then flushBuffer() end

end

local function boot()
    iterateTransposers()
    QueryAndCleanBuffer()
    flushBuffer()
    restock()

    for slot = 1, 39 do
        local dbEntry = configDB.get(slot)
        if dbEntry then
            if inventory[dbEntry.name .. "#" .. dbEntry.damage] then
                if transposers[dbEntry.name .. "#" .. dbEntry.damage] then
                    local itemTransposer =
                        transposers[dbEntry.name .. "#" .. dbEntry.damage]
                    local inputStack = itemTransposer.getStackInSlot(
                                           tConfig.default.inputSide, 2)
                    if inputStack then
                        if inputStack.size == inputStack.maxSize then
                            inventory[dbEntry.name .. "#" .. dbEntry.damage]
                                .hasStock = true
                        end
                        inventory[dbEntry.name .. "#" .. dbEntry.damage].count =
                            inventory[dbEntry.name .. "#" .. dbEntry.damage]
                                .count + inputStack.size
                    end
                end
            end
        end
    end

end

boot()

io.open("/out.log", "w"):write(serialize(inventory)):close()

for id, data in pairs(inventory) do
    local stacks = math.floor(data.count / 64)
    local rem = data.count % 64
    print(string.format("%s (%s) = %d items (%d stacks + %d) (has more: %q)",
                        data.name, id, data.count, stacks, rem, data.hasStock))
end

