# Bank of Singularity — Full Documentation

> Distributed banking system built in Lua for OpenComputers (Minecraft mod).
> All monetary values are in **cents** (integers). $1.00 = 100.

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Directory Structure](#2-directory-structure)
3. [Architecture](#3-architecture)
4. [Network & Security](#4-network--security)
5. [Authentication Flow](#5-authentication-flow)
6. [Ledger & Transactions](#6-ledger--transactions)
7. [Holds (Deferred Settlement)](#7-holds-deferred-settlement)
8. [Data Schemas](#8-data-schemas)
9. [RPC API Reference](#9-rpc-api-reference)
10. [Device Permission Model](#10-device-permission-model)
11. [Admin Interface](#11-admin-interface)
12. [Running & Testing](#12-running--testing)

---

## 1. Project Overview

Bank of Singularity is a full-featured financial ledger running on virtual
computers inside Minecraft. It supports:

- Named bank **accounts** with status (Active / Frozen / Closed)
- Physical **cards** with PIN authentication (salted SHA-256 hashes)
- Encrypted **RPC** between clients (ATMs, POS terminals, casino) and server
- An **append-only ledger** with materialized balance/index views
- Deferred-settlement **holds** with auto-capture timers
- A **device registry** requiring admin approval before a client can connect
- An **admin interface** (touchscreen GUI or text CLI fallback)

---

## 2. Directory Structure

```
bank/
├── DOCS.md                         ← this file
├── server/
│   ├── main.lua                    ← boot entry point; opens ports, starts admin thread
│   ├── env.lua                     ← environment detection (OC vs plain Lua)
│   ├── admin.lua                   ← admin entry: delegates to adminUI or src/admin
│   └── src/
│       ├── admin.lua               ← text-CLI admin interface (21-item menu)
│       ├── adminUI.lua             ← touchscreen GUI admin (requires gpu+screen)
│       ├── dispatch.lua            ← op-level router + device permission gate
│       ├── db/
│       │   ├── database.lua        ← in-memory DB engine with file persistence
│       │   └── init.lua            ← DB module entry; creates standard tables
│       ├── handlers/
│       │   ├── init.lua            ← re-exports Req handler
│       │   └── req.lua             ← all RPC operation handlers (Card.*, Accounts.*, Ledger.*)
│       ├── models/
│       │   ├── Account.lua         ← account CRUD + status changes
│       │   ├── Account_types.lua   ← type annotations only (documentation)
│       │   ├── Card.lua            ← card CRUD + PIN update + status changes
│       │   ├── Card_types.lua      ← type annotations only
│       │   ├── Ledger.lua          ← append-only log + materialized view manager
│       │   └── Ledger_types.lua    ← type annotations only
│       ├── net/
│       │   └── handshakeServer.lua ← server-side ECDH handshake + session store
│       ├── services/
│       │   ├── accountService.lua  ← account business logic (create, get, list)
│       │   ├── authService.lua     ← card PIN auth, session tokens (TTL=300s)
│       │   ├── cardService.lua     ← card issue, revoke (with ledger audit)
│       │   ├── deviceService.lua   ← device registry (announce, trust, revoke)
│       │   └── ledgerService.lua   ← all financial operations + hold lifecycle
│       ├── tests/
│       │   ├── runner.lua          ← test runner
│       │   ├── test_card.lua       ← card model tests
│       │   ├── test_handlers.lua   ← handler integration tests
│       │   ├── utils.lua           ← test assertion helpers
│       │   └── where.lua           ← where-clause tests
│       └── util/
│           ├── log.lua             ← structured logger (info/warn/error)
│           └── whereClause.lua     ← filter compiler for DB queries
├── shared/                         ← code used by both server AND clients
│   ├── async.lua                   ← async/promise helpers
│   └── src/net/
│       ├── deviceKeys.lua          ← persistent EC-384 identity key pair
│       ├── handshake.lua           ← client-side ECDH handshake + AES encrypt/decrypt
│       ├── protocol.lua            ← wire format: encode/decode/validate packets
│       ├── protocol_types.lua      ← type annotations only
│       └── requestManager.lua      ← async RPC request tracker with timeout callbacks
├── clients/
│   └── atm/main.lua                ← ATM client (deposit/withdraw)
├── src/network/
│   ├── Network.lua                 ← low-level modem send/receive
│   └── SecureNetwork.lua           ← AES-encrypted network wrapper
└── tests/                          ← top-level integration tests
    ├── run_all.lua
    ├── test_account.lua
    ├── test_card.lua
    ├── test_ledger.lua
    └── tester.lua
```

---

## 3. Architecture

### Request Pipeline

```
Modem (port 100)
  └─ main.lua           onModemMessage()
       └─ handleRpc()   look up AES session key from HS.getSession()
            └─ AES-decrypt payload
                 └─ Protocol.decode()   deserialize + validate packet
                      └─ dispatch.lua   Dispatch.handle()
                           ├─ Device permission gate  (DEVICE_OPS table)
                           └─ handlers/req.lua         Req.handle()
                                └─ services/           business logic
                                     └─ models/        DB access
                                          └─ src/db/   in-memory engine
```

### Component Overview

| Component | Role |
|-----------|------|
| `main.lua` | Boot, port management, event loop |
| `dispatch.lua` | Permission gate + kind routing |
| `handlers/req.lua` | Op-name → handler function table |
| `services/*` | Business logic, validation, error building |
| `models/*` | Raw DB read/write |
| `src/db/database.lua` | In-memory DB with serialized file persistence |
| `shared/src/net/protocol.lua` | Wire-format encode/decode/validate |
| `src/net/handshakeServer.lua` | ECDH handshake server + session AES-key store |

---

## 4. Network & Security

### Ports

| Port | Purpose |
|------|---------|
| 100 | Encrypted RPC (all normal API calls) |
| 101 | ECDH handshake (establish per-device AES session key) |
| 102 | Device announce (register public key; admin must approve) |
| 999 | LAN discovery ping — server replies `"BANK_HERE"` |

### Encryption

All RPC traffic (port 100) uses **AES-128-CBC** with a fresh random IV per
message.  Wire format: `base64(iv) : base64(ciphertext)`.

The AES key is derived per-device via ECDH:
1. Device generates an ephemeral EC-384 key pair
2. Device signs `"hs1:<deviceId>:<ephPubKey>:<timestamp>"` with its persistent
   identity private key (ECDSA) to prevent replay attacks
3. Server verifies signature, performs ECDH, derives `sha256(sharedSecret)[1:16]`
4. Both sides now share the same 16-byte AES key for the session

Device sessions expire after **3600 s**. Card/user sessions expire after **300 s**.

### Key Storage

- **Server**: public keys stored in `devices` table after announce
- **Client**: persistent EC-384 identity key pair in `~/.keys/identity` (binary,
  re-used across reboots; key rotation resets device status to Pending)

---

## 5. Authentication Flow

### Device Registration (one-time per physical computer)

```
Client                                  Server
  │  device_announce → port 102           │
  │  { type, deviceId, deviceType,        │
  │    publicKey }                         │
  │ ─────────────────────────────────────►│ store in devices table (status=Pending)
  │◄───────────────────── announce_ack ───│ { status: "pending" }
  │                                        │
  │  (admin runs Trust Device on server)  │  status → Active
  │                                        │
  │  device_announce again → port 102      │
  │◄───────────────────── announce_ack ───│ { status: "active" }
```

### ECDH Handshake (each boot)

```
Client                                  Server
  │  handshake_init → port 101            │
  │  { deviceId, sessionPubKey,           │
  │    sig, ts }                           │
  │ ─────────────────────────────────────►│ verify ECDSA sig, ECDH → AES key
  │◄──────────────────── handshake_ok ───│ { sessionPubKey }
  │  derive same AES key                  │
```

### Card / User Authentication (per transaction session)

```
Client sends:  Card.Authenticate { cardUid, pinHash }
                 pinHash = base64(sha256(userPin .. cardSalt))

Server checks:
  1. Card exists and is Active
  2. pinHash matches stored pin_hash
  3. Logs LoginFail or LoginOk to ledger
  4. Returns { token, accountId }  (token expires in 300 s)

Logout:  Card.Deauthenticate { token }  — invalidates token immediately
```

---

## 6. Ledger & Transactions

### Storage

- **`/bank/db/ledger.log`** — newline-delimited serialized records (append-only)
- **`/bank/db/ledger.meta`** — plain-text next-TX-ID counter

### Materialized Views (in-memory, rebuilt on boot)

| Table | Key | Value |
|-------|-----|-------|
| `account_balance` | `accountId` | `balance` (sum of all `amount` deltas) |
| `account_tx_index` | `accountId` | last 200 TX IDs (array) |

### Transaction Types

| Name | Value | Meaning |
|------|-------|---------|
| Deposit | 0 | ATM cash deposit (positive amount) |
| Withdraw | 1 | ATM cash withdrawal (negative amount) |
| Transfer | 2 | Account-to-account move (two entries) |
| Mint | 3 | Admin creates money (positive, no source) |
| Burn | 4 | Admin destroys money (negative, no destination) |
| Adjust | 5 | Hold amount reduced; difference credited back |
| Refund | 6 | Store → customer credit (two entries) |
| Chargeback | 7 | Bank-initiated reversal (two entries) |
| Hold | 8 | POS pre-auth debit (balance debited immediately) |
| Release | 9 | Hold cancelled; amount returned to customer |
| Commit | 10 | Hold captured; store credited |
| Freeze | 11 | Account frozen (audit entry only, amount=0) |
| Unfreeze | 12 | Account unfrozen (audit entry only, amount=0) |
| PinChange | 13 | PIN updated (audit entry, amount=0) |
| CardIssue | 14 | New card registered (audit entry, amount=0) |
| CardRevoke | 15 | Card revoked (audit entry, amount=0) |
| LoginFail | 16 | Failed PIN attempt (audit entry, amount=0) |
| LoginOk | 17 | Successful login (audit entry, amount=0) |

### LedgerTransaction Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Auto-assigned sequential TX ID |
| `accountId` | integer | Account this TX applies to |
| `transactionType` | TransactionType | Kind of transaction |
| `amount` | number | Signed cents delta (negative = debit) |
| `meta` | table | Extra data (toAccountId, holdId, cardUid, …) |
| `createdAt` | integer | `os.time()` stamp at write time |

---

## 7. Holds (Deferred Settlement)

Used by POS terminals and the casino for card-present transactions where the
exact final amount may not be known immediately.

### Hold Lifecycle

```
hold(token, amount, toAccountId)
  → customer balance debited immediately
  → hold record saved to /bank/db/holds.dat
  → auto-capture timer set for 3 IRL days

adjustHold(token, holdId, actualAmount)
  → if actualAmount < original: difference credited back to customer
  → hold record updated with new amount

releaseHold(token, holdId)
  → timer cancelled
  → full amount credited back to customer
  → hold record deleted

AUTO-CAPTURE (timer fires after 3 IRL days)
  → store account credited with hold.amount
  → hold record deleted
  → audit Commit TX written for both accounts
```

### Hold Persistence

Holds survive server reboots.  On startup `ledgerService.lua` reads
`/bank/db/holds.dat`, re-registers timers for holds still within their window,
and immediately captures any that expired while the server was down.

### Time Conversion

Minecraft runs at 72× real time.  Capture window:

```
CAPTURE_DAYS     = 3
CAPTURE_REAL_SEC = 3 × 86400 = 259200 real seconds
CAPTURE_INGAME   = 259200 × 72 = 18,662,400 in-game seconds
```

`captureAt` is stored as an `os.time()` in-game value so it survives reboots.
The event timer is re-calculated in real seconds from the remaining in-game delta.

---

## 8. Data Schemas

### accounts table

| Column | Type | Notes |
|--------|------|-------|
| `id` | integer | Auto-assigned PK |
| `account_name` | string | Unique; human-readable |
| `account_status` | integer | 0=Active, 1=Frozen, 2=Closed |

### cards table

| Column | Type | Notes |
|--------|------|-------|
| `id` | integer | Auto-assigned PK |
| `account_id` | integer | FK → accounts.id |
| `uid` | string | OC card reader UID (unique) |
| `pin_hash` | string | base64(sha256(pin..salt)) |
| `status` | integer | 0=Active, 1=Inactive, 2=Revoked |
| `meta` | table | `{ last_used_at: timestamp }` |

### devices table

| Column | Type | Notes |
|--------|------|-------|
| `id` | integer | Auto-assigned PK |
| `device_id` | string | Unique device identifier |
| `device_type` | string | "pos", "atm", or nil (admin) |
| `public_key` | string | Serialized EC-384 public key |
| `status` | integer | 0=Pending, 1=Active, 2=Suspended, 3=Revoked |
| `registered_at` | integer | `os.time()` of first announce |

### account_balance table (materialized view)

| Column | Type | Notes |
|--------|------|-------|
| `id` | integer | Mirrors accountId |
| `accountId` | integer | FK → accounts.id |
| `balance` | number | Current balance in cents |

### account_tx_index table (materialized view)

| Column | Type | Notes |
|--------|------|-------|
| `id` | integer | Mirrors accountId |
| `accountId` | integer | FK → accounts.id |
| `txIds` | integer[] | Last 200 TX IDs for this account |

---

## 9. RPC API Reference

All requests/responses use the wire format defined in `shared/src/net/protocol.lua`.

### Wire Format

```lua
-- Request
{
  v    = 1,          -- protocol version
  kind = "req",
  op   = "Card.Authenticate",
  id   = "req-...", -- unique request ID
  from = clientAddr, -- sender modem address
  to   = serverAddr, -- recipient modem address
  ts   = os.time(),
  data = { ... }    -- operation-specific payload
}

-- Response
{
  v    = 1,
  kind = "res",
  op   = "Card.Authenticate",
  id   = "req-...", -- mirrors request ID
  from = serverAddr,
  to   = clientAddr,
  ok   = true,      -- false on error
  data = { ... },   -- present when ok=true
  err  = { code, message }  -- present when ok=false
}
```

### Card Operations

#### `Card.Authenticate`
Verify a card PIN and create a session token.
```
Request data:  { cardUid: string, pinHash: string }
Response data: { token: string, accountId: integer }
Error codes:   CARD_NOT_FOUND, CARD_NOT_ACTIVE, CARD_NO_PIN, AUTH_FAILED
```

#### `Card.Deauthenticate`
Invalidate a session token (logout).
```
Request data:  { token: string }
Response data: {}
```

#### `Card.IssueCard`
Register a new card for an account.
```
Request data:  { accountId: integer, uid: string, pinHash: string }
Response data: { cardId: integer }
Error codes:   ACC_NOT_FOUND, CARD_EXISTS
```

#### `Card.GetByAccountId`
List all cards linked to an account.
```
Request data:  { accountId: integer }
Response data: Card[]
Error codes:   CARD_NOT_FOUND
```

### Accounts Operations

#### `Accounts.CreateAccount`
Create a new named account.
```
Request data:  { accountName: string }
Response data: accountId (integer)
Error codes:   ACC_EXSIST, ACC_CREATE_FAILED
```

#### `Accounts.GetByName`
Look up an account by name.
```
Request data:  { accountName: string }
Response data: Account
Error codes:   ACC_NOT_FOUND
```

#### `Accounts.GetById`
Look up an account by ID.
```
Request data:  { accountId: integer }
Response data: Account
Error codes:   ACC_NOT_FOUND
```

### Ledger Operations

All token-gated operations require a valid session token from `Card.Authenticate`.

#### `Ledger.GetBalance`
Get the current balance for the authenticated account.
```
Request data:  { token: string }
Response data: { accountId: integer, balance: number }
Error codes:   UNAUTHORIZED
```

#### `Ledger.Deposit`
Add funds to the authenticated account (ATM cash deposit).
```
Request data:  { token: string, amount: number }
Response data: { balance: number }
Error codes:   UNAUTHORIZED, BAD_AMOUNT, ACC_NOT_ACTIVE
```

#### `Ledger.Withdraw`
Remove funds from the authenticated account (ATM withdrawal).
```
Request data:  { token: string, amount: number }
Response data: { balance: number }
Error codes:   UNAUTHORIZED, BAD_AMOUNT, ACC_NOT_ACTIVE, INSUFFICIENT_FUNDS
```

#### `Ledger.Transfer`
Move funds from the authenticated account to another.
```
Request data:  { token: string, toAccountId: integer, amount: number }
Response data: { fromBalance: number, toBalance: number }
Error codes:   UNAUTHORIZED, BAD_AMOUNT, SAME_ACCOUNT, ACC_NOT_ACTIVE, INSUFFICIENT_FUNDS
```

#### `Ledger.Hold`
Place a POS pre-authorization hold (debits balance immediately).
```
Request data:  { token: string, amount: number, toAccountId: integer }
Response data: { holdId: integer, balance: number, captureIn: integer }
               captureIn = days until auto-capture (for client display)
Error codes:   UNAUTHORIZED, BAD_AMOUNT, ACC_NOT_ACTIVE, INSUFFICIENT_FUNDS
```

#### `Ledger.Adjust`
Reduce a hold's amount after partial dispense; credits difference back.
```
Request data:  { token: string, holdId: integer, actualAmount: number }
Response data: { balance: number }
Error codes:   UNAUTHORIZED, HOLD_NOT_FOUND, FORBIDDEN, BAD_AMOUNT
```

#### `Ledger.Release`
Cancel a hold entirely; returns full held amount to customer.
```
Request data:  { token: string, holdId: integer }
Response data: { balance: number }
Error codes:   UNAUTHORIZED, HOLD_NOT_FOUND, FORBIDDEN
```

#### `Ledger.Mint` *(admin/unrestricted devices only)*
Create money in an account (no source account).
```
Request data:  { accountId: integer, amount: number }
Response data: { balance: number }
Error codes:   BAD_AMOUNT, ACC_NOT_ACTIVE
```

#### `Ledger.Burn` *(admin/unrestricted devices only)*
Destroy money from an account.
```
Request data:  { accountId: integer, amount: number }
Response data: { balance: number }
Error codes:   BAD_AMOUNT, ACC_NOT_ACTIVE
```

#### `Ledger.Freeze` *(admin/unrestricted devices only)*
Freeze an account (blocks all debits).
```
Request data:  { accountId: integer }
Response data: { balance: number }
Error codes:   ACC_NOT_FOUND, ACC_ALREADY_FROZEN
```

#### `Ledger.Unfreeze` *(admin/unrestricted devices only)*
Unfreeze a frozen account.
```
Request data:  { accountId: integer }
Response data: { balance: number }
Error codes:   ACC_NOT_FOUND, ACC_NOT_FROZEN
```

---

## 10. Device Permission Model

Defined in `dispatch.lua` as `DEVICE_OPS`.  `nil` device type = unrestricted.

| Operation | pos | atm | nil (admin) |
|-----------|-----|-----|-------------|
| Card.Authenticate | ✓ | ✓ | ✓ |
| Card.Deauthenticate | ✓ | ✓ | ✓ |
| Card.IssueCard | | | ✓ |
| Card.GetByAccountId | | | ✓ |
| Accounts.GetByName | ✓ | | ✓ |
| Accounts.CreateAccount | | | ✓ |
| Accounts.GetById | | | ✓ |
| Ledger.GetBalance | ✓ | ✓ | ✓ |
| Ledger.Deposit | | ✓ | ✓ |
| Ledger.Withdraw | | ✓ | ✓ |
| Ledger.Transfer | ✓ | | ✓ |
| Ledger.Hold | ✓ | | ✓ |
| Ledger.Adjust | ✓ | | ✓ |
| Ledger.Release | ✓ | | ✓ |
| Ledger.Mint/Burn/Freeze/Unfreeze | | | ✓ |

---

## 11. Admin Interface

Accessed by running `server/admin.lua` (or automatically at boot via `main.lua`).

- **With GPU + screen** → touchscreen GUI (`adminUI.lua`)
- **Without GPU** → numbered text menu (`src/admin.lua`)

### Text Menu Options

| # | Action | Description |
|---|--------|-------------|
| 1 | Create account | Create a new named account |
| 2 | Create card | Write a card (salt + display name) using os_cardwriter |
| 3 | Issue card | Link a swiped card to an account with a PIN |
| 4 | List accounts | Show all accounts with status |
| 5 | List cards | Show cards (optionally filtered by account) |
| 6 | Revoke card | Permanently block a card |
| 7 | Update PIN | Change the PIN on an existing card |
| 8 | Mint funds | Add money to an account (admin only) |
| 9 | Burn funds | Remove money from an account (admin only) |
| 10 | Transfer funds | Move money between accounts (admin, no token) |
| 11 | Refund funds | Credit customer from store account |
| 12 | Chargeback | Bank-initiated fraud reversal |
| 13 | Freeze account | Block all debits on an account |
| 14 | Unfreeze account | Re-enable a frozen account |
| 15 | Rebuild ledger | Full replay of ledger.log to fix materialized views |
| 16 | Pending devices | Show devices awaiting approval |
| 17 | Trust device | Approve a pending device (with optional type override) |
| 18 | List devices | Show all registered devices |
| 19 | Revoke device | Permanently block a device |
| 20 | List holds | Show all active holds with time-to-capture |
| 21 | Release hold | Admin-cancel a hold (returns funds to customer) |

---

## 12. Running & Testing

There is no build step.  Scripts run directly on OpenComputers virtual machines.

### Start the Server

```
/bank/server/main.lua
```

Blocks in an event loop.  Press Ctrl+C (or send `interrupted` event) to stop.

### Run Tests (outside Minecraft, standard Lua 5.2+)

```bash
# Full server test suite
lua bank/server/src/tests/runner.lua

# Individual test files
lua bank/server/src/tests/test_card.lua
lua bank/server/src/tests/test_handlers.lua

# Top-level integration tests
lua bank/tests/run_all.lua
```

### Test Helpers (`src/tests/utils.lua`)

```lua
testUtils.assertEq(actual, expected)   -- strict equality check
test("name", function() ... end)       -- register a test case
```

### First Boot Checklist

1. Start server — it waits for `modem` and `data` components.
2. Admin: run **Pending devices** to see the client's device ID.
3. Admin: run **Trust device**, select the device, set type (`pos`/`atm`).
4. Client will complete the handshake on its next announce cycle.
5. Admin: **Create account** for each player.
6. Admin: **Create card** (writes salt to physical card via os_cardwriter).
7. Admin: **Issue card** (swipe the card, enter account name + PIN).
8. Admin: **Mint funds** to seed initial balance.

### Rebuilding Materialized Views

If the server crashes mid-write, balances may be stale.  Run:

```
Admin menu → Rebuild ledger
```

This replays every record in `ledger.log` from scratch and rewrites
`account_balance` and `account_tx_index`.

---

*Bank of Singularity — Aidcraft*
