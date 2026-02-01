local ROOT = "/bank"
package.path =
    ROOT .. "/server/?.lua;" .. ROOT .. "/server/?/init.lua;" .. ROOT ..
        "/shared/?.lua;" .. ROOT .. "/shared/?/init.lua;" .. package.path

local Protocol = require("src.net.protocol")
local ReqHandler = require("src.handlers.req")

local serial = require("serialization")

package.loaded["src.tests.utils"] = nil
local TestUtils = require("src.tests.utils")

---@class HandlerExpect
---@field ok boolean
---@field hasErr boolean
---@field dataPredicate (fun(data: any): boolean)|nil

---@class HandlerTestCase
---@field name string
---@field req Request
---@field expect HandlerExpect

---@type ExecutionContext
local ctx = {
    resOk = Protocol.resOk,
    resErr = Protocol.resErr,
    makeError = Protocol.makeError,
    fromAddr = "client:atm-01",
    localAddr = "server:bank-01",
    port = 100,
    receivedAt = 1000
}

---@param res any
local function assertResponseShape(res)
    TestUtils.assertTrue(type(res) == "table")
    TestUtils.assertTrue(type(res.ok) == "boolean")

    if res.err ~= nil then
        TestUtils.assertTrue(type(res.err) == "table")
        TestUtils.assertTrue(type(res.err.code) == "string")
        TestUtils.assertTrue(type(res.err.message) == "string")
    end
end

---@type HandlerTestCase[]
local CASES = {
    {
        name = "ok: get cards",
        req = {
            v = 1,
            kind = "req",
            op = "Card.GetByAccountId",
            id = "t_ok_1",
            from = "client",
            to = "server",
            ts = 1000,
            data = {accountId = 42}
        },
        expect = {
            ok = true,
            hasErr = false,
            dataPredicate = function(data)
                return type(data) == "table"
            end
        }
    }, {
        name = "err: missing account",
        req = {
            v = 1,
            kind = "req",
            op = "Card.GetByAccountId",
            id = "t_missing",
            from = "client",
            to = "server",
            ts = 1000,
            data = {accountId = 999999}
        },
        expect = {ok = false, hasErr = true}
    }, {
        name = "err: missing accountId",
        req = {
            v = 1,
            kind = "req",
            op = "Card.GetByAccountId",
            id = "t_missing_accountId",
            from = "client",
            to = "server",
            ts = 1000,
            data = {}
        },
        expect = {ok = false, hasErr = true}
    }
}

local function addCase(tc)
    TestUtils.test("ReqHandler: " .. tc.name, function()
        local res = ReqHandler.handle(tc.req, ctx)

        assertResponseShape(res)

        TestUtils.assertEq(res.ok, tc.expect.ok)

        local hasErr = res.err ~= nil
        TestUtils.assertEq(hasErr, tc.expect.hasErr)

        if tc.expect.dataPredicate then
            TestUtils.assertTrue(tc.expect.dataPredicate(res.data))
        end
    end)
end

for _, tc in ipairs(CASES) do addCase(tc) end

TestUtils.run()
