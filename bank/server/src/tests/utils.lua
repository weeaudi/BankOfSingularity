local M = {}

function M.assertEq(actual, expected)
  if actual ~= expected then
    error(('Expected %s, got %s'):format(expected, actual), 2)
  end
end

function M.assertTrue(val)
  local errmsg = ''
  if type(val) ~= "boolean" then error(('Expected type boolean, got type %s'):format(type(val)), 2) end
  if val ~= true then
    error(('Expected true, got %s'):format(val), 2)
  end
end

function M.assertNil(val)
  if type(val) ~= "nil" then error(('Expected type nil, got %s'):format(val), 2) end
end

return M
