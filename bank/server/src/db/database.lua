local fs = require('filesystem')
local serialization = require('serialization')

local Config = require('config')

local DB = {}
DB.root = Config.DB_ROOT

---@class DbTable
---@field rows table
---@field meta table|nil
---@class DB
---@field root string
---@class DbUpdateOptions
---@field rebuildIndex boolean|nil

---@param tableName string
---@return string tablePath
local function pathFor(tableName) return DB.root .. '/' .. tableName .. '.dat' end

---@return nil
local function ensureRoot()
    ---@diagnostic disable-next-line: undefined-field
    if not fs.exists(DB.root) then fs.makeDirectory(DB.root) end
end

---@param meta table
---@return nil
local function normalizeMeta(meta)
    meta.primaryKey = meta.primaryKey or 'id'
    meta.unique = meta.unique or {}
    meta.indexed = meta.indexed or {}
    meta.index = meta.index or {}

    -- Ensure all unique fields are indexed (prevents silent uniqueness failures)
    local indexedSet = {}
    for _, f in ipairs(meta.indexed) do indexedSet[f] = true end
    for f, _ in pairs(meta.unique) do
        if not indexedSet[f] then
            meta.indexed[#meta.indexed + 1] = f
            indexedSet[f] = true
        end
    end
end

--- Rebuild the indexes to prevent staleness.
--- Indexes map: meta.index[field][value] = rowPosition
---@param rows table
---@param meta table
---@return nil
local function rebuildIndexes(rows, meta)
    meta.index = {}
    for _, field in ipairs(meta.indexed or {}) do meta.index[field] = {} end

    for pos = 1, #rows do
        local r = rows[pos]
        for _, field in ipairs(meta.indexed or {}) do
            local v = r[field]
            if v ~= nil then meta.index[field][v] = pos end
        end
    end
end

---@alias WhereClause table|nil|fun(row: table): boolean

--- Load a table into memory
---@param tableName string
---@return table rows
---@return number lastId
---@return table|nil meta
local function loadTable(tableName)
    ensureRoot()
    local p = pathFor(tableName)
    ---@diagnostic disable-next-line: undefined-field
    if not fs.exists(p) then return {}, 0, nil end

    local h = assert(io.open(p, 'r'))
    local headerLine = h:read('*l')
    local header = headerLine and serialization.unserialize(headerLine) or {}
    local rows, lastId, meta = {}, header.lastId or 0, header.meta

    for line in h:lines() do
        local row = serialization.unserialize(line)
        if type(row) == 'table' then rows[#rows + 1] = row end
    end

    h:close()

    if meta then
        normalizeMeta(meta)
        meta.index = meta.index or {}
    end

    return rows, lastId, meta
end

--- Write a table to a database file
---@param tableName string
---@param rows table
---@param lastId number
---@param meta table|nil
---@return nil
local function saveTable(tableName, rows, lastId, meta)
    ensureRoot()
    local path = pathFor(tableName)

    local tmp = path .. '.tmp'
    local bak = path .. '.bak'

    local header = {lastId = lastId, meta = meta}

    local h = assert(io.open(tmp, 'w'))
    h:write(serialization.serialize(header), '\n')

    for i = 1, #rows do h:write(serialization.serialize(rows[i]), '\n') end

    h:flush()
    h:close()

    ---@diagnostic disable-next-line: undefined-field
    if fs.exists(path) then
        pcall(function()
            ---@diagnostic disable-next-line: undefined-field
            if fs.exists(bak) then fs.remove(bak) end
            ---@diagnostic disable-next-line: undefined-field
            fs.rename(path, bak)
        end)
    end

    ---@diagnostic disable-next-line: undefined-field
    if fs.exists(path) then fs.remove(path) end
    ---@diagnostic disable-next-line: undefined-field
    fs.rename(tmp, path)
end

--- Returns whether a row matches a WhereClause.
---@param row table
---@param where WhereClause
---@return boolean
local function matches(row, where)
    if where == nil then return true end
    if type(where) == 'function' then return where(row) end
    if type(where) == 'table' then
        for k, v in pairs(where) do if row[k] ~= v then return false end end
        return true
    end
    error('where must be nil, table, or function')
end

---@param rows table
---@param field string
---@param tableName string
---@return nil
local function assertUnique(rows, field, tableName)
    local seen = {}
    for i = 1, #rows do
        local v = rows[i][field]
        if v ~= nil then
            if seen[v] then
                error(("Duplicate %s %s in table %s"):format(field, tostring(v),
                                                             tableName))
            end
            seen[v] = true
        end
    end
end

---@param rows table
---@param lastId number
---@param meta table|nil
---@param tableName string
---@param row table
---@return number newLastId
---@return number id
local function insertIntoLoaded(rows, lastId, meta, tableName, row)
    -- enforce your DB model
    if meta then
        normalizeMeta(meta)
        if meta.primaryKey ~= "id" then
            error(
                ("Only primaryKey='id' is supported (got %s) for table %s"):format(
                    tostring(meta.primaryKey), tableName))
        end

        meta.index = meta.index or {}
        for _, f in ipairs(meta.indexed or {}) do
            meta.index[f] = meta.index[f] or {}
        end
    end

    -- assign id
    if row.id == nil then
        lastId = (lastId or 0) + 1
        row.id = lastId
    end

    -- duplicate id check
    for i = 1, #rows do
        if rows[i].id == row.id then
            error(("Duplicate id %s in table %s"):format(tostring(row.id),
                                                         tableName))
        end
    end

    -- unique checks
    if meta and meta.unique then
        for field, _ in pairs(meta.unique) do
            local v = row[field]
            if v ~= nil then
                local idx = meta.index and meta.index[field]
                if idx and idx[v] ~= nil then
                    error(("Duplicate %s %s in table %s"):format(field,
                                                                 tostring(v),
                                                                 tableName))
                end
            end
        end
    end

    -- append
    local pos = #rows + 1
    rows[pos] = row

    -- update indexes
    if meta then
        meta.index = meta.index or {}
        for _, f in ipairs(meta.indexed or {}) do
            meta.index[f] = meta.index[f] or {}
        end
        for _, f in ipairs(meta.indexed or {}) do
            local v = row[f]
            if v ~= nil then meta.index[f][v] = pos end
        end
    end

    return lastId, row.id
end

DB._stats = {indexHits = 0, indexMisses = 0}

--- Create a new table
---@param tableName string
---@param meta table|nil
---@return boolean success
---@return string|nil err
function DB.createTable(tableName, meta)
    ensureRoot()
    meta = meta or {}
    local p = pathFor(tableName)

    ---@diagnostic disable-next-line: undefined-field
    if fs.exists(p) then return false, 'table already exists' end

    normalizeMeta(meta)
    rebuildIndexes({}, meta)

    saveTable(tableName, {}, 0, meta)
    return true, nil
end

--- Perform a lookup on a table using an indexed field.
---@param tableName string The name of the database being searched
---@param field string The indexed field
---@param value any The value being searched
---@return table|nil row The matching row, or nil if not found/index is missing
function DB.getByIndexedField(tableName, field, value)
    local rows, _, meta = loadTable(tableName)
    local idx = meta and meta.index and meta.index[field]
    local pos = idx and idx[value]
    return pos and rows[pos] or nil
end

---@param tableName string
---@param row table
---@return number id
function DB.insert(tableName, row)
    local rows, lastId, meta = loadTable(tableName)
    lastId = lastId or 0

    local id
    lastId, id = insertIntoLoaded(rows, lastId, meta, tableName, row)

    saveTable(tableName, rows, lastId, meta)
    return id
end

---@param tableName string
---@param newRows table[] Array of rows to insert
---@return number inserted
function DB.insertMany(tableName, newRows)
    local rows, lastId, meta = loadTable(tableName)
    lastId = lastId or 0

    local id
    for i = 1, #newRows do
        lastId, id = insertIntoLoaded(rows, lastId, meta, tableName, newRows[i])
    end

    -- Optional but safe: guarantee position indexes match rows after batch
    if meta then rebuildIndexes(rows, meta) end

    saveTable(tableName, rows, lastId, meta)
    return #newRows
end

--- Insert or update a row based on a lookup clause.
--- If a matching row exists, updates it using `patch` and returns its `id`.
--- If none exists, inserts `createRow` and returns the new `id`.
---@param tableName string
---@param where WhereClause
---@param createRow table
---@param patch table
---@return number id The existing or newly-created row id
function DB.upsert(tableName, where, createRow, patch)
    local existing = DB.select(tableName):where(where):first()
    if existing then
        DB.update(tableName, where, patch)
        return existing.id
    end
    return DB.insert(tableName, createRow)
end

--- Update rows in a table that match a WhereClause, applying the given patch.
--- Ensures unique constraints remain valid and keeps meta indexes consistent.
---@param tableName string
---@param where WhereClause
---@param patch table
---@param opts DbUpdateOptions|nil
---@return number changed Number of rows modified
function DB.update(tableName, where, patch, opts)
    opts = opts or {}
    if opts.rebuildIndex == nil then opts.rebuildIndex = true end

    local rows, lastId, meta = loadTable(tableName)
    local changed = 0

    if meta then normalizeMeta(meta) end

    -- Apply patch
    for i = 1, #rows do
        local r = rows[i]
        if matches(r, where) then
            for k, v in pairs(patch) do r[k] = v end
            changed = changed + 1
        end
    end

    if changed > 0 then
        if meta and meta.unique then
            for field, _ in pairs(meta.unique) do
                assertUnique(rows, field, tableName)
            end
        end

        if meta and opts.rebuildIndex then rebuildIndexes(rows, meta) end
        saveTable(tableName, rows, lastId, meta)
    end

    return changed
end

function DB.truncate(tableName)
    local _, _, meta = loadTable(tableName)
    if meta then
        normalizeMeta(meta)
        rebuildIndexes({}, meta)
    end
    saveTable(tableName, {}, 0, meta)
end

function DB.count(tableName, where)
    local rows = (select(1, loadTable(tableName)))
    local c = 0
    for i = 1, #rows do if matches(rows[i], where) then c = c + 1 end end
    return c
end

---@param tableName string
---@param where WhereClause
---@return number deleted
function DB.delete(tableName, where)
    local rows, lastId, meta = loadTable(tableName)
    local out = {}
    local deleted = 0

    if meta then normalizeMeta(meta) end

    for i = 1, #rows do
        if matches(rows[i], where) then
            deleted = deleted + 1
        else
            out[#out + 1] = rows[i]
        end
    end

    if deleted > 0 then
        if meta then rebuildIndexes(out, meta) end
        saveTable(tableName, out, lastId, meta)
    end

    return deleted
end

function DB.replaceTable(tableName, rows, lastId)
    local _, _, meta = loadTable(tableName)
    if meta then normalizeMeta(meta) end

    local maxId = lastId or 0
    for i = 1, #rows do
        local id = rows[i].id
        if type(id) == "number" and id > maxId then maxId = id end
    end

    if meta then rebuildIndexes(rows, meta) end
    saveTable(tableName, rows, maxId, meta)
end

-- Query builder

---@param w WhereClause|nil
---@return string|nil field
---@return any value
local function tryGetSingleEqualityWhere(w)
    if type(w) ~= 'table' then return nil end

    local k, v
    for key, value in pairs(w) do
        if k ~= nil then return nil end
        k, v = key, value
    end

    if k == nil then return nil end
    return k, v
end

---@class Query
---@field tableName string
---@field _where WhereClause|nil
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
    local rows, _, meta = loadTable(self.tableName)

    -- Fast path (single equality WHERE on an indexed field, no offset)
    local field, value = tryGetSingleEqualityWhere(self._where)

    if field ~= nil and self._offset == 0 and
        (self._limit == nil or self._limit >= 1) then
        local idx = meta and meta.index and meta.index[field]
        local pos = idx and idx[value]

        if idx then
            if pos then
                DB._stats.indexHits = DB._stats.indexHits + 1
            else
                DB._stats.indexMisses = DB._stats.indexMisses + 1
            end
        end

        if pos then
            local r = rows[pos]
            if r and matches(r, self._where) then return {r} end
        end
    end

    -- Full scan
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
    local rows, _, meta = loadTable(self.tableName)

    -- index fast path
    local field, value = tryGetSingleEqualityWhere(self._where)
    local idx = meta and meta.index and meta.index[field]
    local pos = idx and idx[value]
    if pos then
        local r = rows[pos]
        if r and matches(r, self._where) then return r end
    end

    -- streaming scan
    for i = 1, #rows do
        local r = rows[i]
        if matches(r, self._where) then return r end
    end

    return nil
end

return DB
