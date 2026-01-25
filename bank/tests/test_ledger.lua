-- bank/tests/test_ledger.lua

package.path =
  "/bank/?.lua;" ..
  "/bank/?/init.lua;" ..
  "/bank/src/?.lua;" ..
  "/bank/src/?/init.lua;" ..
  "/bank/tests/?.lua;" ..
  "/bank/tests/?/init.lua;" ..
  package.path

local tester = require("tests.tester")

local function getBalance(db, accountId)
  local row = db.select("account_balance"):where({ accountId = accountId }):first()
  return row and row.balance or 0
end

local function getIndex(db, accountId)
  local row = db.select("account_tx_index"):where({ accountId = accountId }):first()
  return row and row.txIds or {}
end

local function run()
  tester.withDbRoot("/tmp/bank_test_ledger", function(db)
    tester.resetBankTables(db)

    local LedgerMod = tester.reload("src.models.Ledger")
    local ledger = LedgerMod.Ledger:new(db, db.root)
    local TT = LedgerMod.TransactionType

    local txId = ledger:append({
      accountId = 1,
      playerName = "Steven",
      amount = 400,
      data = { note = "initial deposit" },
      transactionType = TT.Deposit,
    })

    tester.assertEq(txId, 1, "append returns first id as 1")
    tester.assertEq(getBalance(db, 1), 400, "balance increments after deposit")
    tester.assertDeepEq(getIndex(db, 1), { 1 }, "account tx index contains tx id")

    tester.ok("Ledger tests passed")
  end)
end

run()
