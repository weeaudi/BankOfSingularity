package.loaded["src.db.database"] = nil
local db = require("src.db.database")
local computer = require("computer")

local TABLE = "tiny_users"
local TOTAL = 50000
local CHUNK = 25 -- keep this small on 16MB

---@diagnostic disable-next-line undefined-field
math.randomseed((os.time() % 2147483647) + math.floor(computer.uptime() * 1000))
math.random()

local function timer(name, fn)
    ---@diagnostic disable-next-line undefined-field
    local t1 = computer.uptime()
    fn()
    ---@diagnostic disable-next-line undefined-field
    local t2 = computer.uptime()
    print(("%s: %.3fs"):format(name, t2 - t1))
end

local function timerN(name, n, fn)
    ---@diagnostic disable-next-line undefined-field
    local t1 = computer.uptime()
    for i = 1, n do fn() end
    ---@diagnostic disable-next-line undefined-field
    local t2 = computer.uptime()
    local dt = t2 - t1
    print(("%s x%d: %.3fs (avg %.6fs)"):format(name, n, dt, dt / n))
end

local function try(fn)
    local ok, err = pcall(fn)
    if not ok then print("ERROR: " .. tostring(err)) end
    return ok
end

-- Create/Reset table (same name everywhere)
do
    db.createTable(TABLE, {indexed = {"id"}})
    db.truncate(TABLE)
end

-- Insert MANY tiny rows in chunks WITHOUT building big batches
timer(("InsertMany TOTAL=%d CHUNK=%d"):format(TOTAL, CHUNK), function()
    local inserted = 0

    while inserted < TOTAL do
        local batch = {}
        local n = math.min(CHUNK, TOTAL - inserted)

        for i = 1, n do
            -- smallest useful row; avoid strings (they cost memory)
            batch[i] = {} -- id auto-assigned
        end

        if not try(function() db.insertMany(TABLE, batch) end) then
            print("Stopped at inserted=" .. inserted)
            break
        end

        inserted = inserted + n
        if inserted % 1000 == 0 then print("Inserted: " .. inserted) end
    end
end)

local MISSING = "__NOPE__"

timerN("Unindexed miss (forces scan)", 10,
       function() db.select(TABLE):where({nope = MISSING}):first() end)

timerN("Indexed hit (id at end)", 50,
       function() db.select(TABLE):where({id = TOTAL}):first() end)

timerN("Indexed miss (id not present)", 50,
       function() db.select(TABLE):where({id = TOTAL + 1}):first() end)

if db._stats then
    print(("Index hits: %d, misses: %d"):format(db._stats.indexHits or 0,
                                                db._stats.indexMisses or 0))
end
