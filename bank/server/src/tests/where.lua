-- test_where.lua
local W = require("src.util.whereClause") -- whatever file you returned { compileWhere = ... }

local compileWhere = W.compileWhere

local rows = {
    {id = 1, account_status = "ACTIVE", balance = 50},
    {id = 2, account_status = "FROZEN", balance = 10},
    {id = 3, account_status = "ACTIVE", balance = 0},
    {id = 4, account_status = "CLOSED", balance = -5}
}

local function filterRows(where)
    local pred = compileWhere(where)
    local out = {}
    for _, r in ipairs(rows) do if pred(r) then out[#out + 1] = r end end
    return out
end

local function ids(t)
    local out = {}
    for _, r in ipairs(t) do out[#out + 1] = r.id end
    table.sort(out)
    return table.concat(out, ",")
end

local function assertEq(label, got, want)
    if got ~= want then
        error(("[FAIL] %s: got=%s want=%s"):format(label, tostring(got),
                                                   tostring(want)))
    end
    print("[OK] " .. label .. " -> " .. got)
end

-- 1) nil (match all)
assertEq("nil", ids(filterRows(nil)), "1,2,3,4")

-- 2) equality map
assertEq("map status=ACTIVE", ids(filterRows({account_status = "ACTIVE"})),
         "1,3")

-- 3) single atom
assertEq("atom balance gt 0",
         ids(filterRows({field = "balance", op = "gt", value = 0})), "1,2")

-- 4) atom list (AND)
assertEq("AND status=ACTIVE & balance>0", ids(filterRows({
    {field = "account_status", op = "eq", value = "ACTIVE"},
    {field = "balance", op = "gt", value = 0}
})), "1")

-- 6) in operator
assertEq("in status ACTIVE/FROZEN", ids(filterRows({
    field = "account_status",
    op = "in",
    value = {"ACTIVE", "FROZEN"}
})), "1,2,3")

print("All tests passed.")
