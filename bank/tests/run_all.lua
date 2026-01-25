-- bank/tests/run_all.lua
-- Runs all tests in /bank/tests that start with "test_"
-- Continues after failures, prints summary, and writes summary to /bank/tests/output.txt

package.path =
  "/bank/?.lua;" ..
  "/bank/?/init.lua;" ..
  "/bank/src/?.lua;" ..
  "/bank/src/?/init.lua;" ..
  "/bank/tests/?.lua;" ..
  "/bank/tests/?/init.lua;" ..
  package.path

local fs = require("filesystem")

local TEST_DIR = "/bank/tests"
local OUTPUT_PATH = TEST_DIR .. "/output.txt"

local function isTestFile(name)
  return type(name) == "string" and name:match("^test_.*%.lua$")
end

local function now()
  return os.date("%Y-%m-%d %H:%M:%S")
end

local function runFile(path)
  print(("\n=== Running %s ==="):format(path))

  local chunk, loadErr = loadfile(path)
  if not chunk then
    return false, ("Could not load: %s"):format(tostring(loadErr))
  end

  local ok, err = pcall(chunk)
  if not ok then
    return false, tostring(err)
  end

  print(("[OK] %s"):format(path))
  return true, nil
end

---@diagnostic disable-next-line: undefined-field
if not fs.exists(TEST_DIR) then
  error("Test folder not found: " .. TEST_DIR, 0)
end

local files = {}
---@diagnostic disable-next-line: undefined-field
for name in fs.list(TEST_DIR) do
  if isTestFile(name) then
    files[#files + 1] = name
  end
end
table.sort(files)

if #files == 0 then
  local msg = "[INFO] No test_*.lua files found in " .. TEST_DIR
  print(msg)
  local h = assert(io.open(OUTPUT_PATH, "w"))
  h:write(msg .. "\n")
  h:close()
  return
end

local results = {
  startedAt = now(),
  total = #files,
  passed = 0,
  failed = 0,
  failures = {}, -- { {file=..., err=...}, ... }
}

for i = 1, #files do
  local file = files[i]
  local path = TEST_DIR .. "/" .. file

  local ok, err = runFile(path)
  if ok then
    results.passed = results.passed + 1
  else
    results.failed = results.failed + 1
    results.failures[#results.failures + 1] = { file = file, err = err }
    print(("[FAIL] %s -> %s"):format(file, err))
  end
end

local summaryLines = {}
summaryLines[#summaryLines + 1] = ("Test run @ %s"):format(results.startedAt)
summaryLines[#summaryLines + 1] = ("Total: %d  Passed: %d  Failed: %d"):format(results.total, results.passed, results.failed)

if results.failed > 0 then
  summaryLines[#summaryLines + 1] = ""
  summaryLines[#summaryLines + 1] = "Failures:"
  for i = 1, #results.failures do
    local f = results.failures[i]
    summaryLines[#summaryLines + 1] = ("- %s: %s"):format(f.file, f.err)
  end
end

local summary = table.concat(summaryLines, "\n") .. "\n"

print("\n=== Summary ===")
print(summary)

local out = assert(io.open(OUTPUT_PATH, "w"))
out:write(summary)
out:close()
