local fs = require('filesystem')
local serialization = require('serialization')

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
  Denied = 16,
  LoginFail = 17,
  LoginOk = 18,
}

---@class LedgerTransaction
---@field id integer|nil
---@field accountId string
---@field playerName string
---@field amount number
---@field data table|nil
---@field transactionType TransactionType
---@field createdAt number|nil

---@class Ledger
---@field db table
---@field root string
---@field logPath string
---@field metaPath string
local Ledger = {}
Ledger.__index = Ledger

---@param db table
---@param root string|nil
---@return Ledger
function Ledger:new(db, root)
  local r = root or "/bank/db"
  local obj = {
    db = db,
    root = r,
    logPath = r .. "/ledger.log",
    metaPath = r .. "/ledger.meta",
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

---@return integer
function Ledger:_nextId()
  ensureDir(self.root)

  ---@diagnostic disable-next-line: undefined-field
  if not fs.exists(self.metaPath) then
    local h0 = assert(io.open(self.metaPath, "w"))
    h0:write("0")
    h0:close()
  end

  local h = assert(io.open(self.metaPath, "r"))
  local n = tonumber(h:read("*a")) or 0
  h:close()

  n = n + 1
  h = assert(io.open(self.metaPath, "w"))
  h:write(tostring(n))
  h:close()

  return n
end

function Ledger:_applyMaterialized(tx)
  self.db.insert('tx_by_id', {
    id = tx.id,
    accountId = tx.accountId,
    playerName = tx.playerName,
    data = tx.data,
    amount = tx.amount,
    transactionType = tx.transactionType,
    createdAt = tx.createdAt,
  })

  local acct = self.db.select('accounts'):where({ id = tx.accountId }):first()
  local oldBal = (acct and acct.balance) or 0
  local newBal = oldBal + (tx.amount or 0)

  if acct then
    self.db.update('accounts', { id = tx.accountId }, { balance = newBal })
  else
    self.db.insert('accounts', { id = tx.accountId, balance = newBal })
  end

  local idx = self.db.select('account_tx_index'):where({ accountId = tx.accountId }):first()
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
    self.db.update('account_tx_index', { accountId = tx.accountId }, { txIds = txIds })
  else
    self.db.insert('account_tx_index', { accountId = tx.accountId, txIds = txIds })
  end
end

function Ledger:rebuildMaterialized()
  self.db.truncate('tx_by_id')
  self.db.truncate('account_tx_index')

  self:scan(nil, function(tx)
    self:_applyMaterialized(tx)
  end)
end

--- Append a transaction to the ledger
---@param tx LedgerTransaction
---@return integer id
function Ledger:append(tx)
  ensureDir(self.root)

  tx.id = tx.id or self:_nextId()
  tx.createdAt = tx.createdAt or os.time()

  local h = assert(io.open(self.logPath, "a"))
  h:write(serialization.serialize(tx), "\n")
  h:close()

  self:_applyMaterialized(tx)
  return tx.id
end

--- Stream transactions; avoids loading whole ledger
---@param where table|fun(tx: LedgerTransaction): boolean|nil
---@param onRow fun(tx: LedgerTransaction): nil
---@return nil
function Ledger:scan(where, onRow)
  ---@diagnostic disable-next-line: undefined-field
  if not fs.exists(self.logPath) then return end
  local h = assert(io.open(self.logPath, "r"))

  local function matches(tx)
    if where == nil then return true end
    if type(where) == "function" then return where(tx) end
    for k, v in pairs(where) do
      if tx[k] ~= v then return false end
    end
    return true
  end

  for line in h:lines() do
    local tx = serialization.unserialize(line)
    if type(tx) == "table" and matches(tx) then
      onRow(tx)
    end
  end

  h:close()
end

return {
  Ledger = Ledger,
  TransactionType = TransactionType,
}
