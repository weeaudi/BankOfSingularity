local M = {}

function M.assertEq(actual, expected)
    if actual ~= expected then
        error(('Expected %s, got %s'):format(expected, actual), 2)
    end
end

function M.assertTrue(val)
    local errmsg = ''
    if type(val) ~= "boolean" then
        error(('Expected type boolean, got type %s'):format(type(val)), 2)
    end
    if val ~= true then error(('Expected true, got %s'):format(val), 2) end
end

function M.assertNil(val)
    if type(val) ~= "nil" then
        error(('Expected type nil, got %s'):format(val), 2)
    end
end

local tests = {}

--- Add a function that you're trying to test into the testing queue
---@param name string
---@param fn function
function M.test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

function M.run()
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

    if failed > 0 then print('Test suite failed', 0) end
end

return M
