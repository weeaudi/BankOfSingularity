---@diagnostic disable: undefined-field  -- OC API extensions (component.*, computer.uptime, dataComp.*)
-- Bank of Singularity — network integration test suite
-- Run on the POS client PC while the server is running.
-- Usage:  lua /bank/test/nettest.lua
--
-- Tests exercise every RPC endpoint through the full
-- encrypt-decrypt handshake stack, exactly as the POS does.
-- Two test accounts (NetTest_A, NetTest_B) and one test card
-- are created automatically and reused across runs.

local ROOT = '/bank'
package.path = ROOT .. '/clients/pos/?.lua;' ..
               ROOT .. '/clients/pos/?/init.lua;' ..
               ROOT .. '/shared/?.lua;' ..
               ROOT .. '/shared/?/init.lua;' ..
               package.path

local component  = require('component')
local event      = require('event')
local computer   = require('computer')
local Protocol   = require('src.net.protocol')
local RM         = require('src.net.requestManager')
local Handshake  = require('src.net.handshake')
local DeviceKeys = require('src.net.deviceKeys')

local modem    = component.modem
local dataComp = component.data

local PORT           = 100
local DISCOVERY_PORT = 999

-- Dedicated test device with its own persistent key file.
-- Trust it once via the server admin menu; subsequent runs reuse the same key.
local DEVICE_ID   = 'BANK-TEST'
local DEVICE_TYPE = 'admin'
local KEY_PATH    = '/bank/keys/test.key'

-- ─── Test fixtures ────────────────────────────────────────────────────────────
-- Fixed values so tests are deterministic and re-entrant.

local TEST_ACCT_A = 'NetTest_A'
local TEST_ACCT_B = 'NetTest_B'
local TEST_UID    = 'NETTEST-CARD-1'
local TEST_SALT   = 'NetTestSalt_v1'
local TEST_PIN    = '9999'
local TEST_PIN_BAD = '0000'

-- ─── Logger ──────────────────────────────────────────────────────────────────

local LOG_PATH = ROOT .. '/test/nettest.log'
local logFile  = io.open(LOG_PATH, 'w')  -- truncate on each run

local function log(line)
    print(line)
    if logFile then
        logFile:write(line .. '\n')
        logFile:flush()
    end
end

-- ─── Results ─────────────────────────────────────────────────────────────────

local passed = 0
local failed = 0
local server, aesKey

local function pass(name)
    passed = passed + 1
    log(('  [PASS] %s'):format(name))
end

local function fail(name, reason)
    failed = failed + 1
    log(('  [FAIL] %s  (%s)'):format(name, tostring(reason)))
end

local function errMsg(r)
    if not r then return 'no response' end
    if r.err then return (r.err.code or '?') .. ': ' .. (r.err.message or '?') end
    return 'unexpected success'
end

-- ─── Networking ──────────────────────────────────────────────────────────────

local function ensureOpen(port)
    if not modem.isOpen(port) then modem.open(port) end
end

local function onModemMessage(_, _, _, port, _, payload)
    if port ~= PORT then return end
    if not aesKey then return end
    local plain = Handshake.decrypt(dataComp, aesKey, payload)
    if plain then RM.onPacket(plain) end
end

--- Synchronous RPC call — blocks until response or timeout.
local function call(op, data, timeout)
    timeout = timeout or 5.0
    local req       = Protocol.makeRequest(op, modem.address, server, data, nil)
    ensureOpen(PORT)
    local encoded   = assert(Protocol.encode(req))
    local encrypted = Handshake.encrypt(dataComp, aesKey, encoded)
    modem.send(server, PORT, encrypted)

    local result, errOut
    RM.register(req.id, timeout, function(res, err)
        result = res
        errOut = err
    end)

    local deadline = computer.uptime() + timeout + 0.5
    while result == nil and errOut == nil and computer.uptime() < deadline do
        event.pull(0.05)
        RM.tick()
    end

    if errOut then return nil, errOut end
    return result, nil
end

-- ─── Bootstrap ───────────────────────────────────────────────────────────────

local function bootstrap()
    log('Discovering server...')
    modem.open(DISCOVERY_PORT)
    modem.broadcast(DISCOVERY_PORT, 'DISCOVER_BANK')
    local _, _, addr, _, _, msg = event.pull(5, 'modem_message')
    modem.close(DISCOVERY_PORT)
    if not addr or msg ~= 'BANK_HERE' then
        error('Server not found — is the bank server running?')
    end
    server = addr
    log('Server: ' .. server)

    -- Load (or generate-and-save) the persistent test identity.
    -- Trust this device once via the server admin menu; subsequent runs reuse the same key.
    local keys = DeviceKeys.load(dataComp, KEY_PATH)

    log('Announcing as ' .. DEVICE_ID .. ' (' .. DEVICE_TYPE .. ')...')
    local status, err = Handshake.announce(dataComp, modem, server,
                                           DEVICE_ID, DEVICE_TYPE, keys)
    if status ~= 'active' then
        error('Device not active: ' .. tostring(status) ..
              (err and (' — ' .. err) or ''))
    end

    log('Key exchange...')
    local key, herr = Handshake.doHandshake(dataComp, modem, server, DEVICE_ID, keys)
    if not key then
        error('Handshake failed: ' .. tostring(herr))
    end
    aesKey = key

    event.listen('modem_message', onModemMessage)
    log('Secure session established.\n')
end

-- ─── Test helpers ────────────────────────────────────────────────────────────

--- Get account ID, creating the account if it doesn't exist yet.
local function resolveAccount(name)
    local r = call('Accounts.GetByName', {accountName = name})
    if r and r.ok then return r.data.id end
    local r2 = call('Accounts.CreateAccount', {accountName = name})
    if r2 and r2.ok then return r2.data end
    return nil
end

--- Authenticate the test card and return a token, or nil.
local function authTestCard()
    local pinHash = dataComp.encode64(dataComp.sha256(TEST_PIN .. TEST_SALT))
    local r = call('Card.Authenticate', {cardUid = TEST_UID, pinHash = pinHash})
    if r and r.ok then return r.data.token end
    return nil
end

-- ─── Test suites ─────────────────────────────────────────────────────────────

local function suiteAccounts(idA, idB)
    log('── Accounts ─────────────────────────────────────────')

    -- GetByName
    local r = call('Accounts.GetByName', {accountName = TEST_ACCT_A})
    if r and r.ok and r.data.id == idA then
        pass('GetByName')
    else
        fail('GetByName', errMsg(r))
    end

    -- GetById
    r = call('Accounts.GetById', {accountId = idA})
    if r and r.ok and r.data.id == idA then
        pass('GetById')
    else
        fail('GetById', errMsg(r))
    end

    -- GetByName unknown
    r = call('Accounts.GetByName', {accountName = 'DOES_NOT_EXIST_XYZ'})
    if r and not r.ok and r.err.code == 'ACC_NOT_FOUND' then
        pass('GetByName unknown → ACC_NOT_FOUND')
    else
        fail('GetByName unknown → ACC_NOT_FOUND', errMsg(r))
    end

    -- CreateAccount duplicate → should fail
    r = call('Accounts.CreateAccount', {accountName = TEST_ACCT_A})
    if r and not r.ok and r.err.code == 'ACC_EXSIST' then
        pass('CreateAccount duplicate → ACC_EXSIST')
    else
        fail('CreateAccount duplicate → ACC_EXSIST', errMsg(r))
    end
end

local function suiteMintBurn(idA)
    log('\n── Mint / Burn ──────────────────────────────────────')

    -- Mint
    local r = call('Ledger.Mint', {accountId = idA, amount = 1000})
    if r and r.ok then
        pass('Mint 1000 cents')
    else
        fail('Mint 1000 cents', errMsg(r))
    end

    -- Burn
    r = call('Ledger.Burn', {accountId = idA, amount = 200})
    if r and r.ok then
        pass('Burn 200 cents')
    else
        fail('Burn 200 cents', errMsg(r))
    end

    -- Burn overdraft
    r = call('Ledger.Burn', {accountId = idA, amount = 9999999})
    if r and not r.ok and r.err.code == 'INSUFFICIENT_FUNDS' then
        pass('Burn overdraft → INSUFFICIENT_FUNDS')
    else
        fail('Burn overdraft → INSUFFICIENT_FUNDS', errMsg(r))
    end

    -- Mint bad amount
    r = call('Ledger.Mint', {accountId = idA, amount = -50})
    if r and not r.ok and r.err.code == 'BAD_AMOUNT' then
        pass('Mint negative → BAD_AMOUNT')
    else
        fail('Mint negative → BAD_AMOUNT', errMsg(r))
    end
end

local function suiteCards(idA)
    log('\n── Cards ────────────────────────────────────────────')

    local pinHash = dataComp.encode64(dataComp.sha256(TEST_PIN .. TEST_SALT))

    -- IssueCard
    local r = call('Card.IssueCard', {accountId = idA, uid = TEST_UID, pinHash = pinHash})
    if r and r.ok then
        pass('IssueCard')
    elseif r and r.err and r.err.code == 'CARD_EXISTS' then
        pass('IssueCard (already exists — OK)')
    else
        fail('IssueCard', errMsg(r))
    end

    -- IssueCard duplicate
    r = call('Card.IssueCard', {accountId = idA, uid = TEST_UID, pinHash = pinHash})
    if r and not r.ok and r.err.code == 'CARD_EXISTS' then
        pass('IssueCard duplicate → CARD_EXISTS')
    else
        fail('IssueCard duplicate → CARD_EXISTS', errMsg(r))
    end

    -- GetByAccountId
    r = call('Card.GetByAccountId', {accountId = idA})
    if r and r.ok and type(r.data) == 'table' and #r.data >= 1 then
        pass(('GetByAccountId (%d card(s))'):format(#r.data))
    else
        fail('GetByAccountId', errMsg(r))
    end

    -- GetByAccountId unknown account
    r = call('Card.GetByAccountId', {accountId = 999999})
    if r and not r.ok and r.err.code == 'CARD_NOT_FOUND' then
        pass('GetByAccountId unknown account → CARD_NOT_FOUND')
    else
        fail('GetByAccountId unknown account → CARD_NOT_FOUND', errMsg(r))
    end
end

local function suiteAuth()
    log('\n── Authentication ───────────────────────────────────')

    local pinHash    = dataComp.encode64(dataComp.sha256(TEST_PIN .. TEST_SALT))
    local badPinHash = dataComp.encode64(dataComp.sha256(TEST_PIN_BAD .. TEST_SALT))

    -- Wrong PIN
    local r = call('Card.Authenticate', {cardUid = TEST_UID, pinHash = badPinHash})
    if r and not r.ok and r.err.code == 'AUTH_FAILED' then
        pass('Authenticate wrong PIN → AUTH_FAILED')
    else
        fail('Authenticate wrong PIN → AUTH_FAILED', errMsg(r))
    end

    -- Unknown UID
    r = call('Card.Authenticate', {cardUid = 'FAKE-UID-XYZ', pinHash = pinHash})
    if r and not r.ok and r.err.code == 'CARD_NOT_FOUND' then
        pass('Authenticate unknown UID → CARD_NOT_FOUND')
    else
        fail('Authenticate unknown UID → CARD_NOT_FOUND', errMsg(r))
    end

    -- Correct
    r = call('Card.Authenticate', {cardUid = TEST_UID, pinHash = pinHash})
    if r and r.ok and r.data.token then
        pass('Authenticate correct PIN → token issued')
        return r.data.token
    else
        fail('Authenticate correct PIN → token issued', errMsg(r))
        return nil
    end
end

local function suiteLedger(token, idA, idB)
    log('\n── Ledger ───────────────────────────────────────────')
    if not token then
        log('  [SKIP] No token available — skipping ledger tests')
        return
    end

    -- GetBalance
    local r = call('Ledger.GetBalance', {token = token})
    if r and r.ok and type(r.data.balance) == 'number' then
        pass(('GetBalance (balance = %d cents)'):format(r.data.balance))
    else
        fail('GetBalance', errMsg(r))
    end

    -- GetBalance bad token
    r = call('Ledger.GetBalance', {token = 'fake-token-xyz'})
    if r and not r.ok and r.err.code == 'UNAUTHORIZED' then
        pass('GetBalance bad token → UNAUTHORIZED')
    else
        fail('GetBalance bad token → UNAUTHORIZED', errMsg(r))
    end

    -- Deposit
    r = call('Ledger.Deposit', {token = token, amount = 500})
    if r and r.ok then
        pass('Deposit 500 cents')
    else
        fail('Deposit 500 cents', errMsg(r))
    end

    -- Deposit bad amount
    r = call('Ledger.Deposit', {token = token, amount = 0})
    if r and not r.ok and r.err.code == 'BAD_AMOUNT' then
        pass('Deposit zero → BAD_AMOUNT')
    else
        fail('Deposit zero → BAD_AMOUNT', errMsg(r))
    end

    -- Withdraw
    r = call('Ledger.Withdraw', {token = token, amount = 200})
    if r and r.ok then
        pass('Withdraw 200 cents')
    else
        fail('Withdraw 200 cents', errMsg(r))
    end

    -- Withdraw overdraft
    r = call('Ledger.Withdraw', {token = token, amount = 9999999})
    if r and not r.ok and r.err.code == 'INSUFFICIENT_FUNDS' then
        pass('Withdraw overdraft → INSUFFICIENT_FUNDS')
    else
        fail('Withdraw overdraft → INSUFFICIENT_FUNDS', errMsg(r))
    end

    -- Transfer to NetTest_B
    r = call('Ledger.Transfer', {token = token, toAccountId = idB, amount = 100})
    if r and r.ok then
        pass('Transfer 100 → NetTest_B')
    else
        fail('Transfer 100 → NetTest_B', errMsg(r))
    end

    -- Transfer to self
    r = call('Ledger.Transfer', {token = token, toAccountId = idA, amount = 50})
    if r and not r.ok and r.err.code == 'SAME_ACCOUNT' then
        pass('Transfer to self → SAME_ACCOUNT')
    else
        fail('Transfer to self → SAME_ACCOUNT', errMsg(r))
    end

    -- Deauthenticate
    r = call('Card.Deauthenticate', {token = token})
    if r and r.ok then
        pass('Deauthenticate')
    else
        fail('Deauthenticate', errMsg(r))
    end

    -- Token no longer valid
    r = call('Ledger.GetBalance', {token = token})
    if r and not r.ok and r.err.code == 'UNAUTHORIZED' then
        pass('Deauthenticated token → UNAUTHORIZED')
    else
        fail('Deauthenticated token → UNAUTHORIZED', errMsg(r))
    end
end

local function suiteHolds(idA, idB)
    log('\n── Holds ────────────────────────────────────────────')

    -- Re-authenticate for this suite
    local token = authTestCard()
    if not token then
        log('  [SKIP] Could not authenticate for hold tests')
        return
    end

    -- Ensure enough balance
    call('Ledger.Mint', {accountId = idA, amount = 1000})

    -- Place hold
    local r = call('Ledger.Hold', {token = token, amount = 300, toAccountId = idB})
    if r and r.ok and r.data.holdId then
        local holdId = r.data.holdId
        pass(('Hold 300 cents (holdId=%d, captureIn=%s days)'):format(
            holdId, tostring(r.data.captureIn)))

        -- Adjust hold down (partial release)
        local adj = call('Ledger.Adjust', {token = token, holdId = holdId, actualAmount = 150})
        if adj and adj.ok then
            pass('Adjust hold 300 → 150 (releases 150 back)')
        else
            fail('Adjust hold 300 → 150', errMsg(adj))
        end

        -- Adjust above original → bad amount
        adj = call('Ledger.Adjust', {token = token, holdId = holdId, actualAmount = 9999})
        if adj and not adj.ok and adj.err.code == 'BAD_AMOUNT' then
            pass('Adjust hold above original → BAD_AMOUNT')
        else
            fail('Adjust hold above original → BAD_AMOUNT', errMsg(adj))
        end

        -- Release remaining hold
        local rel = call('Ledger.Release', {token = token, holdId = holdId})
        if rel and rel.ok then
            pass('Release adjusted hold')
        else
            fail('Release adjusted hold', errMsg(rel))
        end

        -- Release again → already gone
        rel = call('Ledger.Release', {token = token, holdId = holdId})
        if rel and not rel.ok and rel.err.code == 'HOLD_NOT_FOUND' then
            pass('Release settled hold → HOLD_NOT_FOUND')
        else
            fail('Release settled hold → HOLD_NOT_FOUND', errMsg(rel))
        end
    else
        fail('Hold 300 cents', errMsg(r))
    end

    -- Hold then release immediately
    r = call('Ledger.Hold', {token = token, amount = 100, toAccountId = idB})
    if r and r.ok then
        pass('Hold 100 cents')
        local rel = call('Ledger.Release', {token = token, holdId = r.data.holdId})
        if rel and rel.ok then
            pass('Immediate release')
        else
            fail('Immediate release', errMsg(rel))
        end
    else
        fail('Hold 100 cents', errMsg(r))
    end

    -- Hold overdraft
    r = call('Ledger.Hold', {token = token, amount = 9999999, toAccountId = idB})
    if r and not r.ok and r.err.code == 'INSUFFICIENT_FUNDS' then
        pass('Hold overdraft → INSUFFICIENT_FUNDS')
    else
        fail('Hold overdraft → INSUFFICIENT_FUNDS', errMsg(r))
    end

    call('Card.Deauthenticate', {token = token})
end

local function suiteFreezeUnfreeze(idB)
    log('\n── Freeze / Unfreeze ────────────────────────────────')

    -- Freeze
    local r = call('Ledger.Freeze', {accountId = idB})
    if r and r.ok then
        pass('Freeze NetTest_B')
    else
        fail('Freeze NetTest_B', errMsg(r))
    end

    -- Freeze already-frozen
    r = call('Ledger.Freeze', {accountId = idB})
    if r and not r.ok and r.err.code == 'ACC_ALREADY_FROZEN' then
        pass('Freeze already-frozen → ACC_ALREADY_FROZEN')
    else
        fail('Freeze already-frozen → ACC_ALREADY_FROZEN', errMsg(r))
    end

    -- Mint to frozen account
    r = call('Ledger.Mint', {accountId = idB, amount = 100})
    if r and not r.ok and r.err.code == 'ACC_NOT_ACTIVE' then
        pass('Mint to frozen account → ACC_NOT_ACTIVE')
    else
        fail('Mint to frozen account → ACC_NOT_ACTIVE', errMsg(r))
    end

    -- Unfreeze
    r = call('Ledger.Unfreeze', {accountId = idB})
    if r and r.ok then
        pass('Unfreeze NetTest_B')
    else
        fail('Unfreeze NetTest_B', errMsg(r))
    end

    -- Unfreeze already-active
    r = call('Ledger.Unfreeze', {accountId = idB})
    if r and not r.ok and r.err.code == 'ACC_NOT_FROZEN' then
        pass('Unfreeze active account → ACC_NOT_FROZEN')
    else
        fail('Unfreeze active account → ACC_NOT_FROZEN', errMsg(r))
    end

    -- Mint after unfreeze
    r = call('Ledger.Mint', {accountId = idB, amount = 50})
    if r and r.ok then
        pass('Mint after unfreeze → OK')
    else
        fail('Mint after unfreeze → OK', errMsg(r))
    end
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local ok, err = pcall(bootstrap)
if not ok then
    log('\nFATAL during bootstrap: ' .. tostring(err))
    if logFile then logFile:close() end
    return
end

log('Resolving test accounts...')
local idA = resolveAccount(TEST_ACCT_A)
local idB = resolveAccount(TEST_ACCT_B)
if not idA or not idB then
    log('FATAL: Could not resolve test accounts')
    event.ignore('modem_message', onModemMessage)
    if logFile then logFile:close() end
    return
end
log(('  %s = #%d,  %s = #%d\n'):format(TEST_ACCT_A, idA, TEST_ACCT_B, idB))

suiteAccounts(idA, idB)
suiteMintBurn(idA)
suiteCards(idA)
local token = suiteAuth()
suiteLedger(token, idA, idB)
suiteHolds(idA, idB)
suiteFreezeUnfreeze(idB)

log('\n══════════════════════════════════════════════════════')
local total = passed + failed
log(('Passed: %d / %d'):format(passed, total))
if failed == 0 then
    log('All tests passed.')
else
    log(('%d FAILED.'):format(failed))
end
log('')

event.ignore('modem_message', onModemMessage)
if logFile then logFile:close() end
