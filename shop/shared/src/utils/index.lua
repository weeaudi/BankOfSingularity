local M = {}

---@param t table
---@param value any
---@return boolean
function M.arrayIncludes(t, value)
    for i = 1, #t do if t[i] == value then return true end end
    return false
end

---@param t table
---@param value any
---@return boolean
function M.tableIncludes(t, value)
    for _, v in pairs(t) do if v == value then return true end end
    return false
end

local NIL = {}

--- Take an array-like table, perform function fn on each item, and map it to a new table.
---@param t table
---@param fn function
---@return table A mapped array
function M.map(t, fn)
    local out = {}
    for i = 1, #t do
        local v = fn(t[i], i, t)
        if v == nil then
            out[i] = NIL
        else
            out[i] = v
        end
    end
    return out
end

--- Take an array-like table and filter it using a filter function
---@param t table
---@param pred function filter function
---@return table out filtered table
function M.filter(t, pred)
    local out = {}
    for i = 1, #t do if pred(t[i], i, t) then out[#out + 1] = t[i] end end
    return out
end

return M
