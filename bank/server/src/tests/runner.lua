local ROOT = '/bank'
local original_package_path = package.path
package.path = ROOT .. '/server/?.lua;' .. ROOT .. '/server/?/init.lua;' ..
    package.path

local testUtils = require('src.tests.utils')


local tests = {}

local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

local function run()
  local passed, failed = 0, 0

  for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)

    if ok then
      print('PASS: ' .. t.name)
      passed = passed + 1
    else
      print('FAIL: ' .. t.name)
      print('     ' .. err)
      failed = failed + 1
    end
  end

  print(('\n%d passed, %d failed'):format(passed, failed))

  if failed > 0 then
    error('Test suite failed', 0)
  end
end

local function add(a, b)
  return a + b
end

local function subtract(a, b)
  return a - b
end

test('adds numbers', function()
  testUtils.assertEq(add(2, 3), 5)
end)

test('subract numbers', function()
  testUtils.assertEq(subtract(5, 2), 3)
end)

run()

package.path = original_package_path
