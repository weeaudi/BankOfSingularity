-- test_db.lua
package.loaded['src.db.database'] = nil
local db = require('src.db.database')
local serialization = require('serialization')

local function fail(msg) error('[FAIL] ' .. msg, 2) end

local function ok(msg) print('[OK] ' .. msg) end

---@param cond boolean
---@param msg string
local function assertTrue(cond, msg) if not cond then fail(msg) end end

---@param actual any
---@param expected any
---@param msg string
local function assertEq(actual, expected, msg)
    if actual ~= expected then
        fail(('%s (expected=%s, got=%s)'):format(msg, tostring(expected),
                                                 tostring(actual)))
    end
end

---@param t table
---@param msg string
local function assertEmpty(t, msg)
    assertTrue(type(t) == 'table', msg .. ' (not a table)')
    assertEq(#t, 0, msg)
end

local function cleanup() db.delete('users', {isTest = true}) end

local function run()
    print('=== DB TESTS START ===')

    -- Always start clean
    cleanup()

    -- Insert
    local id1 = db.insert('users', {
        username = 'dos54',
        role = 'admin',
        bal = 300,
        isTest = true
    })
    assertTrue(type(id1) == 'number', 'insert should return numeric id')

    local id2 = db.insert('users', {
        username = 'Flurben',
        role = 'user',
        bal = 450,
        isTest = true
    })
    assertTrue(type(id2) == 'number', 'insert should return numeric id')
    assertTrue(id2 ~= id1, 'insert should return unique ids')
    ok('insert two users')

    -- Select admins
    local admins = db.select('users'):where({role = 'admin', isTest = true})
                       :orderBy('username', 'asc'):all()
    assertEq(#admins, 1, 'should have exactly 1 admin test user')
    assertEq(admins[1].username, 'dos54', 'admin username should be dos54')
    ok('select admins')

    -- Select all test users
    local testUsers = db.select('users'):where({isTest = true}):all()
    assertEq(#testUsers, 2, 'should have exactly 2 test users')
    ok('select all test users')

    -- Update (note: your rows use "bal", but you were updating "balance")
    local updated = db.update('users', {username = 'dos54', isTest = true},
                              {bal = 0})
    assertEq(updated, 1, 'update should modify exactly 1 row')
    local dos = db.select('users'):where({username = 'dos54', isTest = true})
                    :first()
    assertTrue(dos ~= nil, 'dos54 should exist after update')
    assertEq(dos.bal, 0, 'dos54 bal should be 0 after update')
    ok('update patch')

    -- Cleanup delete
    local deleted = db.delete('users', {isTest = true})
    assertEq(deleted, 2, 'delete should remove exactly 2 rows')
    local remaining = db.select('users'):where({isTest = true}):all()
    assertEmpty(remaining, 'test users should be empty after cleanup')
    ok('delete cleanup')

    print('=== DB TESTS PASS ===')
end

local okRun, err = pcall(run)
if not okRun then
    print(err)
    print('DEBUG: current test rows:')
    print(serialization.serialize(db.select('users'):where({isTest = true})
                                      :all(), true))
    -- Attempt cleanup even on failure
    pcall(cleanup)
    os.exit(1)
end
