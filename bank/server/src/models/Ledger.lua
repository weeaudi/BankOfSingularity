---@diagnostic disable: undefined-field, undefined-doc-name  -- OC API extensions; AccountBalance defined in Account.lua
--- bank/server/src/models/Ledger.lua
--- Append-only transaction log and materialized-view manager.
---
--- Storage layout (`/bank/db/`):
---   ledger.log   — newline-delimited serialized LedgerTransaction records
---   ledger.meta  — plain-text next-TX-ID counter (healed from log on missing/corrupt)
---
--- Materialized views (kept in-memory DB, rebuilt on boot via rebuildMaterialized):
---   account_balance   — {accountId, balance}  (sum of all `amount` fields)
---   account_tx_index  — {accountId, txIds[]}  (last 200 TX IDs per account)
---
--- Key methods:
---   Ledger:new(db, root)         — constructor; `root` defaults to "/bank/db"
---   Ledger:append(tx)            — write a TX, update materialized views, return id
---   Ledger:scan(where, onRow)    — stream TX rows; `where` = nil|table|function
---   Ledger:rebuildMaterialized() — full replay from log (called on server boot)

---@class LedgerTransaction
---@field id              integer|nil      Assigned by append(); nil before write
---@field accountId       integer          Account this TX applies to
---@field transactionType TransactionType  Kind of transaction (see TransactionType enum)
---@field amount          number           Signed cents delta (negative = debit)
---@field meta            table|nil        Arbitrary extra data (holdId, toAccountId, …)
---@field createdAt       integer|nil      os.time() stamp; set by append()

---@diagnostic disable-next-line: duplicate-doc-alias
---@alias WhereClause nil | table | fun(tx: LedgerTransaction): boolean

local Config        = require('config')
local fs            = require('filesystem')
local serialization = require('serialization')
local computer      = require('computer')
local Log           = require('src.util.log')

---@enum TransactionType
local TransactionType = {
    Deposit = 0,
    Withdraw = 1,
    Transfer = 2,
    Mint = 3,
    Burn = 4,
    Adjust = 5,
    Refund = 6,
    Chargeback = 7,
    Hold = 8,
    Release = 9,
    Commit = 10,
    Freeze = 11,
    Unfreeze = 12,
    PinChange = 13,
    CardIssue = 14,
    CardRevoke = 15,
    LoginFail = 16,
    LoginOk = 17
}

---@class Ledger
---@field db       table   In-memory database handle
---@field root     string  Path to DB directory (default "/bank/db")
---@field logPath  string  Path to ledger.log
---@field metaPath string  Path to ledger.meta (TX ID counter)
---@field nextId   integer In-memory TX ID counter (0 = not yet loaded)
local Ledger = {}
Ledger.__index = Ledger

---@param db table
---@param root string|nil
---@return Ledger
function Ledger:new(db, root)
    local r = root or Config.DB_ROOT
    local obj = {
        db = db,
        root = r,
        logPath = r .. "/ledger.log",
        metaPath = r .. "/ledger.meta",
        nextId = 0
    }
    return setmetatable(obj, Ledger)
end

local function ensureDir(path)
    -- create parents if needed for /bank/db
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then
        ---@diagnostic disable-next-line: undefined-field
        if not fs.exists(parent) then fs.makeDirectory(parent) end
    end
    ---@diagnostic disable-next-line: undefined-field
    if not fs.exists(path) then fs.makeDirectory(path) end
end

--- Scan the ledger log for the highest id present.
function Ledger:_maxIdInLog()
    local max = 0
    ---@diagnostic disable-next-line: param-type-mismatch
    self:scan(function() return true end, function(tx)
        local id = tx['id']
        if type(id) == "number" and id > max then max = id end
    end)
    return max
end

--- Persist the id counter to disk.
function Ledger:_saveMeta(n)
    ensureDir(self.root)
    local h = assert(io.open(self.metaPath, "w"))
    h:write(tostring(n))
    h:close()
end

---@return integer
function Ledger:_nextId()
    ensureDir(self.root)

    -- Fast path: counter already loaded into memory this session.
    if self.nextId > 0 then
        self.nextId = self.nextId + 1
        self:_saveMeta(self.nextId)
        return self.nextId
    end

    -- Read persisted counter (may be absent or stale after a crash).
    local persisted = 0
    ---@diagnostic disable-next-line: undefined-field
    if fs.exists(self.metaPath) then
        local h = assert(io.open(self.metaPath, "r"))
        persisted = tonumber(h:read("*a")) or 0
        h:close()
    end

    -- If meta is missing or looks lower than what the log already contains,
    -- scan the log and heal the counter so IDs are never reused.
    if persisted == 0 then
        Log.info('ledger.meta missing or zero — scanning log for max id')
        persisted = self:_maxIdInLog()
        Log.info('max id in log: ' .. tostring(persisted))
    end

    local n = persisted + 1
    self:_saveMeta(n)
    self.nextId = n
    return n
end

function Ledger:_applyMaterialized(tx)
    -- Check if it's already applied
    -- local existing = self.db.select('tx_by_id'):where({id = tx.id}):first()
    -- if existing then return end

    -- 1) update balance
    ---@type AccountBalance|nil
    local balRow = self.db.select('account_balance'):where({
        accountId = tx.accountId
    }):first()
    local oldBal = (balRow and balRow.balance) or 0
    local newBal = oldBal + (tx.amount or 0)

    if balRow then
        self.db.update('account_balance', {accountId = tx.accountId},
                       {balance = newBal})
    else
        self.db.insert('account_balance', {
            id = tx.accountId,
            accountId = tx.accountId,
            balance = newBal
        })
    end

    -- 2) update account tx index
    local idx = self.db.select('account_tx_index'):where({
        accountId = tx.accountId
    }):first()
    local txIds = (idx and idx.txIds) or {}
    txIds[#txIds + 1] = tx.id

    local MAX = 200
    if #txIds > MAX then
        local trimmed = {}
        for i = #txIds - MAX + 1, #txIds do
            trimmed[#trimmed + 1] = txIds[i]
        end
        txIds = trimmed
    end

    if idx then
        self.db.update('account_tx_index', {accountId = tx.accountId},
                       {txIds = txIds})
    else
        self.db.insert('account_tx_index', {
            id = tx.accountId,
            accountId = tx.accountId,
            txIds = txIds
        })
    end

end

function Ledger:rebuildMaterializedFast()
    local balances = {} -- [accountId] = number
    local idx = {} -- [accountId] = { txIds... }

    local MAX = 200

    Log.info('Performing scan')
    self:scan(nil, function(tx)
        -- balance
        local a = tx.accountId
        balances[a] = (balances[a] or 0) + (tx.amount or 0)

        -- index (cap)
        local list = idx[a]
        if not list then
            list = {}
            idx[a] = list
        end
        list[#list + 1] = tx.id
        if #list > MAX then table.remove(list, 1) end
    end)

    Log.info('scan complete, writing materialized data')

    local balRows = {}
    for accountId, bal in pairs(balances) do
        balRows[#balRows + 1] = {
            id = accountId,
            accountId = accountId,
            balance = bal
        }
    end

    local idxRows = {}
    for accountId, txIds in pairs(idx) do
        idxRows[#idxRows + 1] = {
            id = accountId,
            accountId = accountId,
            txIds = txIds
        }
    end

    -- self.db.replaceTable("tx_by_id", txByIdRows)
    self.db.replaceTable("account_balance", balRows)
    self.db.replaceTable("account_tx_index", idxRows)
end

function Ledger:rebuildMaterialized() return self:rebuildMaterializedFast() end

--- Append a transaction to the ledger
---@param tx LedgerTransaction
---@return integer id
function Ledger:append(tx)
    ensureDir(self.root)

    tx.id = --[[tx.id or]] self:_nextId()
    tx.createdAt = --[[tx.createdAt or]] os.time()

    local h = assert(io.open(self.logPath, "a"))
    h:write(serialization.serialize(tx), "\n")
    h:close()

    self:_applyMaterialized(tx)
    return tx.id
end

--- Stream transactions; avoids loading whole ledger
---@param where WhereClause
---@param onRow fun(tx: LedgerTransaction): nil
---@return nil
function Ledger:scan(where, onRow, opts)
    ---@diagnostic disable-next-line: undefined-field
    if not fs.exists(self.logPath) then return end
    local h = assert(io.open(self.logPath, "r"))

    local chunkSize = (opts and opts.chunkSize) or 8192 -- 8kb

    local stats = {readCalls = 0, bytesRead = 0, linesSeen = 0, rowsMatched = 0}

    local buf = ""

    local function matches(tx)
        if where == nil then return true end
        if type(where) == "function" then return where(tx) end
        for k, v in pairs(where) do if tx[k] ~= v then return false end end
        return true
    end

    local function handleLine(line)
        if line == "" then return end
        stats.linesSeen = stats.linesSeen + 1

        ---@diagnostic disable-next-line: undefined-field
        local t0 = computer.uptime()
        local tx = serialization.unserialize(line)
        ---@diagnostic disable-next-line: undefined-field
        local t1 = computer.uptime()

        if type(tx) == "table" and matches(tx) then
            stats.rowsMatched = stats.rowsMatched + 1
            onRow(tx)
        end
        ---@diagnostic disable-next-line: undefined-field
        local t2 = computer.uptime()

        stats.parseTime = (stats.parseTime or 0) + (t1 - t0)
        stats.onRowTime = (stats.onRowTime or 0) + (t2 - t1)
    end

    while true do
        local chunk = h:read(chunkSize)
        if not chunk then break end

        stats.readCalls = stats.readCalls + 1
        stats.bytesRead = stats.bytesRead + #chunk

        buf = buf .. chunk

        while true do
            local nl = buf:find("\n", 1, true)
            if not nl then break end
            local line = buf:sub(1, nl - 1)
            buf = buf:sub(nl + 1)
            handleLine(line)
        end
    end

    -- last line (if no trailing newline)
    if #buf > 0 then handleLine(buf) end

    h:close()
end

-- Shared singleton — all services must use this instance so the in-memory
-- nextId counter stays consistent. Creating multiple Ledger instances causes
-- each one to cache its own counter after first read, leading to ID collisions.
local _sharedInstance = Ledger:new(require('src.db').database)

return {Ledger = Ledger, TransactionType = TransactionType, instance = _sharedInstance}
