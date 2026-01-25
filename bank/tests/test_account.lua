-- bank/tests/test_account.lua

package.path =
  "/bank/?.lua;" ..
  "/bank/?/init.lua;" ..
  "/bank/src/?.lua;" ..
  "/bank/src/?/init.lua;" ..
  "/bank/tests/?.lua;" ..
  "/bank/tests/?/init.lua;" ..
  package.path

local tester = require("tests.tester")

local function devRequire(name)
  package.loaded[name] = nil
  return require(name)
end

local function run()
  tester.withDbRoot("/tmp/bank_test_account", function(db)
    tester.resetBankTables(db)

    -- Reload Account AFTER db root is set by withDbRoot
    local Accounts = devRequire("src.models.Account")
    tester.assertNotNil(Accounts, "require('src.models.Account') returned nil")
    tester.assertNotNil(Accounts.getOrCreate, "Accounts.getOrCreate missing")

    local LedgerMod = tester.reload("src.models.Ledger")
    local ledger = LedgerMod.Ledger:new(db, db.root)
    local TT = LedgerMod.TransactionType

    local id1 = Accounts.getOrCreate("Steven")
    tester.assertEq(id1, 1, "first account id should be 1")

    local id1b = Accounts.getOrCreate("Steven")
    tester.assertEq(id1b, 1, "getOrCreate returns existing id for same name")
    tester.assertLen(db.select("accounts"):all(), 1, "accounts table should not duplicate")

    local acct = Accounts.getById(1)
    tester.assertNotNil(acct, "getById returns account")
    tester.assertEq(acct.account_name, "Steven", "account_name matches")
    tester.assertEq(acct.account_status, Accounts.Status.Active, "default status Active")
    tester.assertNil(Accounts.getById(999), "getById returns nil for missing")

    local awb0 = Accounts.getWithBalance(1)
    tester.assertNotNil(awb0, "getWithBalance returns account")
    tester.assertEq(awb0.balance, 0, "default balance is 0")

    ledger:append({
      accountId = 1,
      playerName = "Steven",
      amount = 400,
      data = { note = "deposit" },
      transactionType = TT.Deposit,
    })

    local awb1 = Accounts.getWithBalance(1)
    tester.assertNotNil(awb1, "getWithBalance after deposit returns account")
    tester.assertEq(awb1.balance, 400, "balance reflects deposit")

    tester.assertNil(Accounts.getWithBalance(999), "getWithBalance returns nil for missing account")

    tester.ok("Account tests passed")
  end)
end

run()
