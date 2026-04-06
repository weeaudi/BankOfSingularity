---@alias FilterOp
---| '"eq"'  -- ==
---| '"ne"'  -- ~=
---| '"gt"'  -- >
---| '"gte"' -- >=
---| '"lt"'  -- <
---| '"lte"' -- <=
---| '"in"'  -- value is in list (array)
---@class WhereClauseAtom
---@field field string
---@field op FilterOp
---@field value any
---Where can be:
---  nil                           -> always true
---  table<k,v>                    -> equality map (row[k] == v for all)
---  WhereClauseAtom               -> single atom
---  WhereClauseAtom[]             -> list of atoms (AND)
---@alias NetworkWhereClause nil|table|WhereClauseAtom|WhereClauseAtom[]
---Compile a WhereClause into a predicate function (row -> boolean).
---This is what you pass into the database filter.
---@param where NetworkWhereClause
---@return fun(row: table): boolean
local function compileWhere(where)
    if where == nil then return function(_) return true end end

    if type(where) ~= "table" then error("where must be nil, or table") end

    -- Helper: detect array-like tables (1..n)
    local function isArray(t)
        local n = #t
        if n == 0 then return false end
        for i = 1, n do if t[i] == nil then return false end end
        return true
    end

    -- Case A: single atom {field=..., op=..., value=...}
    if where.field ~= nil and where.op ~= nil then
        ---@cast where WhereClauseAtom
        local field = where.field
        local op = where.op
        local value = where.value

        if op == "eq" then
            return function(row) return row[field] == value end
        elseif op == "ne" then
            return function(row) return row[field] ~= value end
        elseif op == "gt" then
            return function(row) return row[field] > value end
        elseif op == "gte" then
            return function(row) return row[field] >= value end
        elseif op == "lt" then
            return function(row) return row[field] < value end
        elseif op == "lte" then
            return function(row) return row[field] <= value end
        elseif op == "in" then
            if type(value) ~= "table" then
                error('where.op "in" requires where.value to be a table (array)')
            end
            -- Prebuild a set for O(1) lookup (assumes primitive keys: string/number/boolean)
            local set = {}
            for _, v in ipairs(value) do set[v] = true end
            return function(row) return set[row[field]] == true end
        else
            error("unsupported where.op: " .. tostring(op))
        end
    end

    -- Case B: list of atoms (AND): { {field,op,value}, {field,op,value}, ... }
    if isArray(where) and type(where[1]) == "table" and where[1].field ~= nil and
        where[1].op ~= nil then
        ---@cast where WhereClauseAtom[]
        local preds = {}
        for i = 1, #where do preds[i] = compileWhere(where[i]) end
        return function(row)
            for i = 1, #preds do
                if not preds[i](row) then return false end
            end
            return true
        end
    end

    -- Case C: equality map: { k = v, ... } (AND)
    -- Example: { account_status = "ACTIVE", id = 5 }
    do
        local keys = {}
        for k, _ in pairs(where) do keys[#keys + 1] = k end
        return function(row)
            for i = 1, #keys do
                local k = keys[i]
                if row[k] ~= where[k] then return false end
            end
            return true
        end
    end
end

-- Example usage:
-- local where = {
--   { field = "account_status", op = "eq", value = "ACTIVE" },
--   { field = "balance", op = "gt", value = 0 },
-- }
-- local predicate = compileWhere(where)
-- db:list(predicate)

return {compileWhere = compileWhere}
