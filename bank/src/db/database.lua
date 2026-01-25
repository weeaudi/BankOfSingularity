local fs = require('filesystem')
local serialization = require('serialization')

---@class DB
---@field root string
local DB = {}
DB.root = '/bank/db'

---@param tableName string
---@return string tablePath
local function pathFor(tableName) return DB.root .. '/' .. tableName .. '.tmpdat' end

---@return nil
local function ensureRoot()
---@diagnostic disable-next-line: undefined-field
    if not fs.exists(DB.root) then fs.makeDirectory(DB.root) end
end

---@alias WhereClause table|fun(row: table): boolean|nil

---@param tableName string
---@return table rows
---@return number lastId
local function loadTable(tableName)
    ensureRoot()
    local p = pathFor(tableName)
---@diagnostic disable-next-line: undefined-field
    if not fs.exists(p) then return {}, 0 end

    local h = assert(io.open(p, 'r'))
    local data = h:read('*a')
    h:close()

    local t = serialization.unserialize(data)
    if type(t) ~= 'table' then return {}, 0 end

    return t.rows or {}, t.lastId or 0
end

---@param tableName string
---@param rows table
---@param lastId number
---@return nil
local function saveTable(tableName, rows, lastId)
    ensureRoot()
    local p = pathFor(tableName)
    local h = assert(io.open(p, 'w'))
    h:write(serialization.serialize({rows = rows, lastId = lastId}))
    h:close()
end

---@param row table
---@param where WhereClause
---@return boolean|nil
local function matches(row, where)
    if where == nil then return true end
    if type(where) == 'function' then return where(row) end
    if type(where) == 'table' then
        for k, v in pairs(where) do if row[k] ~= v then return false end end
        return true
    end
    error('where must be nil, table, or function')
end

---@param tableName string
---@param row table
---@return number id
function DB.insert(tableName, row)
    local rows, lastId = loadTable(tableName)

    if row.id ~= nil then
        for i = 1, #rows do
            if rows[i].id == row.id then
                error(('Duplicate id %s in table %s'):format(tostring(row.id), tableName))
            end
        end
    else
        lastId = lastId + 1
        row.id = lastId
    end

    rows[#rows + 1] = row
    saveTable(tableName, rows, lastId)
    return row.id
end

function DB.upsert(tableName, where, createRow, patch)
    local existing = DB.select(tableName):where(where):first()
    if existing then
        DB.update(tableName, where, patch)
        return existing.id
    else
        return DB.insert(tableName, createRow)
    end
end

---@param tableName string
---@param where WhereClause
---@param patch table
---@return number changed
function DB.update(tableName, where, patch)
    local rows, lastId = loadTable(tableName)
    local changed = 0

    for i = 1, #rows do
        local r = rows[i]
        if matches(r, where) then
            for k, v in pairs(patch) do r[k] = v end
            changed = changed + 1
        end
    end

    if changed > 0 then saveTable(tableName, rows, lastId) end

    return changed
end

function DB.truncate(tableName)
    saveTable(tableName, {}, 0)
end

---@param tableName string
---@param where WhereClause
---@return number deleted
function DB.delete(tableName, where)
    local rows, lastId = loadTable(tableName)
    local out = {}
    local deleted = 0

    for i = 1, #rows do
        if matches(rows[i], where) then
            deleted = deleted + 1
        else
            out[#out + 1] = rows[i]
        end
    end

    if deleted > 0 then saveTable(tableName, out, lastId) end

    return deleted
end

-- Query builder

---@class Query
---@field tableName string
---@field _where WhereClause
---@field _orderKey string|nil
---@field _orderDir '"asc"'|'"desc"'
---@field _limit integer|nil
---@field _offset integer
local Query = {}
Query.__index = Query

---@param tableName string
---@return Query
function DB.select(tableName)
    return setmetatable({
        tableName = tableName,
        _where = nil,
        _orderKey = nil,
        _orderDir = 'asc',
        _limit = nil,
        _offset = 0
    }, Query)
end

---@param w WhereClause
---@return Query self
function Query:where(w)
    self._where = w
    return self
end

---@param key string
---@param dir '"asc"'|'"desc"'|nil
---@return Query self
function Query:orderBy(key, dir)
    self._orderKey = key
    self._orderDir = (dir == 'desc') and 'desc' or 'asc'
    return self
end

---@param n integer
---@return Query self
function Query:limit(n)
    self._limit = n
    return self
end

---@param n integer
---@return Query self
function Query:offset(n)
    self._offset = n or 0
    return self
end

---@return table rows
function Query:all()
    local rows, _ = loadTable(self.tableName)

    local filtered = {}
    for i = 1, #rows do
        if matches(rows[i], self._where) then
            filtered[#filtered + 1] = rows[i]
        end
    end

    if self._orderKey then
        local key = self._orderKey
        local desc = self._orderDir == 'desc'
        table.sort(filtered, function(a, b)
            if desc then return a[key] > b[key] end
            return a[key] < b[key]
        end)
    end

    local start = self._offset + 1
    local stop = #filtered
    if self._limit then stop = math.min(stop, start + self._limit - 1) end

    local out = {}
    for i = start, stop do out[#out + 1] = filtered[i] end
    return out
end

---@return table|nil row
function Query:first()
    self:limit(1)
    local rows = self:all()
    return rows[1]
end

return DB
