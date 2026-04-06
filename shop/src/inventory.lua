---@diagnostic disable: undefined-field, cast-local-type  -- OC API extensions (component.me_interface, component.transposer, sides.*, os.sleep)
-- Inventory module: ME network snapshot + item dispensing
-- Replaces bank/inventory/inventory.lua

local component = require('component')
local sides     = require('sides')

local Inventory = {}

-- Side names → side constants (configured via config.lua, passed in at init)
local tIn  = sides.north
local tOut = sides.south

--- Configure which transposer sides to use.
---@param inputSide string e.g. 'north'
---@param outputSide string e.g. 'south'
function Inventory.setSides(inputSide, outputSide)
    tIn  = sides[inputSide]  or sides.north
    tOut = sides[outputSide] or sides.south
end

local function itemKey(item)
    return item.name .. '#' .. item.damage .. '#' .. (item.label or '')
end

--- Snapshot all items currently in the ME network.
--- Returns table keyed by item key.
---@return table<string, {key:string, item:table, size:number, label:string}>
function Inventory.snapshot()
    local ifc = component.me_interface
    local inv = {}
    for _, item in ipairs(ifc.getItemsInNetwork() or {}) do
        local k = itemKey(item)
        inv[k] = {
            key   = k,
            item  = item,
            size  = item.size or 0,
            label = item.label or item.name,
        }
    end
    return inv
end

local function configInterface(itemDesc)
    local db  = component.database
    local ifc = component.me_interface
    db.clear(1)
    ifc.store({name = itemDesc.name, damage = itemDesc.damage}, db.address, 1)
    ifc.setInterfaceConfiguration(1, db.address, 1, 64)
end

local function clearInterface()
    local db  = component.database
    local ifc = component.me_interface
    db.clear(1)
    ifc.setInterfaceConfiguration(1, db.address, 1, 0)
end

--- Transfer items from ME storage to the output inventory.
---@param key string  Item key (name#damage)
---@param count number  How many to transfer
---@return number|nil transferred
---@return string|nil error
function Inventory.transfer(key, count)
    if type(key) ~= 'string' or type(count) ~= 'number' or count <= 0 then
        return nil, 'bad args'
    end

    local inv  = Inventory.snapshot()
    local slot = inv[key]
    if not slot then return nil, 'not in network' end
    if slot.size <= 0 then return nil, 'out of stock' end

    local tp = component.transposer
    configInterface(slot.item)

    local toTransfer  = math.min(slot.size, count)
    local transferred = 0
    local outSlot     = 1
    local maxOut      = tp.getInventorySize(tOut)
    local timeout     = 0

    while toTransfer - transferred > 0 and timeout < 20 do
        if outSlot > maxOut then
            clearInterface()
            return transferred, 'output full'
        end
        local stack = tp.getStackInSlot(tIn, 1)
        if stack then
            timeout      = 0
            transferred  = transferred + tp.transferItem(
                tIn, tOut, math.min(toTransfer - transferred, 64), 1, outSlot)
            outSlot = outSlot + 1
        else
            os.sleep(0.2)
            timeout = timeout + 1
        end
    end

    clearInterface()

    if toTransfer - transferred > 0 then
        return transferred, 'input timeout'
    end
    return transferred, nil
end

--- Pre-flight check before checkout.
--- Returns feasible items (what can actually be dispensed) and any warnings.
--- Checks ME stock and available output slots.
---@param cart {key:string, label:string, quantity:number, unitPrice:number}[]
---@return {key:string, label:string, qty:number, unitPrice:number}[] feasible
---@return {label:string, reason:string, requested:number, canGive:number}[] warnings
function Inventory.preflightCart(cart)
    local inv = Inventory.snapshot()
    local tp  = component.transposer

    -- Count free output slots and existing stack space per item key
    local totalSlots  = tp.getInventorySize(tOut)
    local freeSlots   = 0
    local slotExtra   = {}   -- key -> extra capacity in existing output stacks

    for i = 1, totalSlots do
        local stack = tp.getStackInSlot(tOut, i)
        if not stack then
            freeSlots = freeSlots + 1
        else
            local k      = stack.name .. '#' .. (stack.damage or 0)
            local space  = (stack.maxSize or 64) - (stack.size or 0)
            if space > 0 then
                slotExtra[k] = (slotExtra[k] or 0) + space
            end
        end
    end

    local feasible    = {}
    local warnings    = {}
    local slotsNeeded = 0

    for _, entry in ipairs(cart) do
        local stock   = inv[entry.key]
        local meQty   = stock and stock.size or 0
        local maxSize = (stock and stock.item and stock.item.maxSize) or 64
        local extra   = slotExtra[entry.key] or 0

        -- Clamp to ME stock
        local canGive = math.min(entry.quantity, meQty)

        if canGive <= 0 then
            warnings[#warnings + 1] = {
                label     = entry.label,
                reason    = 'out of stock',
                requested = entry.quantity,
                canGive   = 0,
            }
        else
            -- Stacks this item will need beyond what already fits in existing output stacks
            local remaining   = math.max(0, canGive - extra)
            local stacksNeeded = remaining > 0 and math.ceil(remaining / maxSize) or 0
            slotsNeeded = slotsNeeded + stacksNeeded

            if canGive < entry.quantity then
                warnings[#warnings + 1] = {
                    label     = entry.label,
                    reason    = 'partial stock',
                    requested = entry.quantity,
                    canGive   = canGive,
                }
            end

            feasible[#feasible + 1] = {
                key       = entry.key,
                label     = entry.label,
                qty       = canGive,
                unitPrice = entry.unitPrice,
            }
        end
    end

    -- If output doesn't have enough free slots, warn (but still try — transfer handles it)
    if slotsNeeded > freeSlots then
        warnings[#warnings + 1] = {
            label     = 'Output chest',
            reason    = 'may be full (' .. freeSlots .. ' free, ~' .. slotsNeeded .. ' needed)',
            requested = slotsNeeded,
            canGive   = freeSlots,
        }
    end

    return feasible, warnings
end

--- Dispense all items in a feasible list and return what was actually transferred.
--- Returns a list of {key, label, qty, unitPrice, transferred} and any errors.
---@param feasible {key:string, label:string, qty:number, unitPrice:number}[]
---@return {key:string, label:string, qty:number, unitPrice:number, transferred:number}[]
---@return string[] errors
function Inventory.dispenseCart(feasible)
    local results = {}
    local errors  = {}

    for _, item in ipairs(feasible) do
        local transferred, err = Inventory.transfer(item.key, item.qty)
        transferred = transferred or 0

        results[#results + 1] = {
            key          = item.key,
            label        = item.label,
            qty          = item.qty,
            unitPrice    = item.unitPrice,
            transferred  = transferred,
        }

        if err and transferred < item.qty then
            errors[#errors + 1] = item.label .. ': ' .. err
                .. ' (got ' .. transferred .. '/' .. item.qty .. ')'
        end
    end

    return results, errors
end

--- Merge ME inventory snapshot with catalog prices.
--- Returns only items with price >= 0, sorted by label.
--- Items with stock = 0 are included (shown as out of stock).
---@param catalog table  The catalog module
---@return {key:string, label:string, size:number, price:number}[]
function Inventory.getListedWithStock(catalog)
    local inv    = Inventory.snapshot()
    local listed = catalog.getListed()
    local result = {}

    for key, price in pairs(listed) do
        local stock = inv[key]
        if stock and stock.label then
            catalog.setLabel(key, stock.label)  -- keep label fresh while in stock
        end
        result[#result + 1] = {
            key   = key,
            label = (stock and stock.label) or catalog.getLabel(key) or key,
            size  = stock and stock.size or 0,
            price = price,
        }
    end

    table.sort(result, function(a, b) return a.label < b.label end)
    return result
end

--- Merge ME snapshot with catalog for config view.
--- Returns ALL items in ME, annotated with their catalog price (-1 if unset).
---@param catalog table
---@return {key:string, label:string, size:number, price:number}[]
function Inventory.getAllWithPrices(catalog)
    local inv    = Inventory.snapshot()
    local result = {}
    local seen   = {}

    -- Items currently in ME
    for key, entry in pairs(inv) do
        seen[key] = true
        if entry.label then
            catalog.setLabel(key, entry.label)  -- keep label fresh while in stock
        end
        result[#result + 1] = {
            key   = key,
            label = entry.label,
            size  = entry.size,
            price = catalog.getPrice(key),
        }
    end

    -- Catalog entries not currently in ME (out of stock / depleted)
    -- Only show if price is set (>= 0); unset + out of stock = nothing to manage
    for key, _ in pairs(catalog.getAll()) do
        if not seen[key] and catalog.getPrice(key) >= 0 then
            result[#result + 1] = {
                key   = key,
                label = catalog.getLabel(key) or key,
                size  = 0,
                price = catalog.getPrice(key),
            }
        end
    end

    table.sort(result, function(a, b) return a.label < b.label end)
    return result
end

return Inventory
