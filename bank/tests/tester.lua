-- bank/tests/tester.lua
-- Shared test helpers. Do not run tests here; only provide utilities.

package.path =
  "/bank/?.lua;" ..
  "/bank/?/init.lua;" ..
  "/bank/src/?.lua;" ..
  "/bank/src/?/init.lua;" ..
  "/bank/tests/?.lua;" ..
  "/bank/tests/?/init.lua;" ..
  package.path

local fs = require("filesystem")
local serialization = require("serialization")

local M = {}

local function fmt(v)
  if type(v) == "table" then
    return serialization.serialize(v)
  end
  return tostring(v)
end

local function fail(msg, level)
  error("[FAIL] " .. msg, (level or 1) + 1)
end

function M.ok(msg) print("[OK] " .. msg) end
function M.fail(msg) fail(msg, 2) end

function M.assertTrue(cond, msg) if not cond then fail(msg, 2) end end
function M.assertFalse(cond, msg) if cond then fail(msg, 2) end end

function M.assertEq(actual, expected, msg)
  if actual ~= expected then
    fail(("%s (expected=%s, got=%s)"):format(msg, fmt(expected), fmt(actual)), 2)
  end
end

function M.assertNe(actual, expected, msg)
  if actual == expected then
    fail(("%s (did not expect=%s)"):format(msg, fmt(expected)), 2)
  end
end

function M.assertNil(v, msg)
  if v ~= nil then
    fail(("%s (expected=nil, got=%s)"):format(msg, fmt(v)), 2)
  end
end

function M.assertNotNil(v, msg)
  if v == nil then fail(msg .. " (got nil)", 2) end
end

function M.assertEmpty(t, msg)
  M.assertTrue(type(t) == "table", msg .. " (not a table)")
  M.assertEq(#t, 0, msg)
end

function M.assertLen(t, n, msg)
  M.assertTrue(type(t) == "table", msg .. " (not a table)")
  M.assertEq(#t, n, msg)
end

function M.assertNoThrow(fn, msg)
  local ok, err = pcall(fn)
  if not ok then
    fail(("%s (threw=%s)"):format(msg, tostring(err)), 2)
  end
end

function M.assertThrows(fn, msg)
  local ok = pcall(fn)
  if ok then fail(msg .. " (expected error)", 2) end
end

local function deepEq(a, b, seen)
  if a == b then return true end
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return false end

  seen = seen or {}
  if seen[a] and seen[a] == b then return true end
  seen[a] = b

  for k, va in pairs(a) do
    if not deepEq(va, b[k], seen) then return false end
  end
  for k, _ in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

function M.assertDeepEq(actual, expected, msg)
  if not deepEq(actual, expected) then
    fail(("%s (expected=%s, got=%s)"):format(msg, fmt(expected), fmt(actual)), 2)
  end
end

function M.reload(name)
  package.loaded[name] = nil
  return require(name)
end

function M.truncateTables(db, tables)
  for i = 1, #tables do
    db.truncate(tables[i])
  end
end

function M.resetBankTables(db)
  M.truncateTables(db, { "accounts", "tx_by_id", "account_tx_index", "account_balance" })
end

function M.rmrf(path)
  ---@diagnostic disable-next-line: undefined-field
  if not fs.exists(path) then return end

  ---@diagnostic disable-next-line: undefined-field
  if fs.isDirectory(path) then
    ---@diagnostic disable-next-line: undefined-field
    for name in fs.list(path) do
      M.rmrf(path .. "/" .. name)
    end
    ---@diagnostic disable-next-line: undefined-field
    fs.remove(path)
  else
    ---@diagnostic disable-next-line: undefined-field
    fs.remove(path)
  end
end

function M.ensureDir(path)
  local parent = path:match("^(.*)/[^/]+$")
  if parent and parent ~= "" then
    ---@diagnostic disable-next-line: undefined-field
    if not fs.exists(parent) then fs.makeDirectory(parent) end
  end
  ---@diagnostic disable-next-line: undefined-field
  if not fs.exists(path) then fs.makeDirectory(path) end
end

-- Create isolated DB root for a test and restore afterward.
-- Uses the singleton src.db.database module (same instance production code uses).
function M.withDbRoot(root, fn)
  local db = M.reload("src.db.database")
  local oldRoot = db.root

  db.root = root
  M.rmrf(root)
  M.ensureDir(root)

  local okRun, err = pcall(fn, db)

  M.rmrf(root)
  db.root = oldRoot

  if not okRun then error(err, 0) end
end

return M
