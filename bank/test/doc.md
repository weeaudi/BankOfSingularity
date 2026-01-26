# Account

## account_name


```lua
string
```

## account_status


```lua
AccountStatus
```

## id


```lua
integer
```


---

# AccountBalance

## accountId


```lua
integer
```

## balance


```lua
number
```


---

# AccountStatus


---

# AccountWithBalance

## account_name


```lua
string
```

## account_status


```lua
AccountStatus
```

## balance


```lua
number
```

## id


```lua
integer
```


---

# Bank

## __index


```lua
Bank
```

## bankId


```lua
string
```

## connections


```lua
table<string, EncryptedConnection>
```

## handle


```lua
(method) Bank:handle(handle: string, sender: string, message: string)
  -> boolean
```

## handlers


```lua
table<string, fun(bank: Bank, sender: string, message: string):boolean>
```

\

## new


```lua
(method) Bank:new(secureNetwork: SecureNetwork, bankId: string)
  -> Bank
```

## registerHandler


```lua
(method) Bank:registerHandler(handle: string, handler: fun(bank: Bank, sender: string, message: string):boolean)
```

## secureNetwork


```lua
SecureNetwork
```


---

# DB

## createTable


```lua
function DB.createTable(tableName: string, meta: table|nil)
  -> success: boolean
  2. err: string|nil
```

 Create a new table

## delete


```lua
function DB.delete(tableName: string, where: table|fun(row: table):boolean|nil)
  -> deleted: number
```

## getByIndexedField


```lua
function DB.getByIndexedField(tableName: string, field: string, value: any)
  -> row: table|nil
```

 Perform a lookup on a table using an indexed field.

@*param* `tableName` — The name of the database being searched

@*param* `field` — The indexed field

@*param* `value` — The value being searched

@*return* `row` — The matching row, or nil if not found/index is missing

## insert


```lua
function DB.insert(tableName: string, row: table)
  -> id: number
```

## replaceTable


```lua
function DB.replaceTable(tableName: any, rows: any, lastId: any)
```

## root


```lua
string
```

## select


```lua
function DB.select(tableName: string)
  -> Query
```

## truncate


```lua
function DB.truncate(tableName: any)
```

## update


```lua
function DB.update(tableName: string, where: table|fun(row: table):boolean|nil, patch: table, opts: DbUpdateOptions|nil)
  -> changed: number
```

 Update rows in a table that match a WhereClause, applying the given patch.
 Ensures unique constraints remain valid and keeps meta indexes consistent.

@*return* `changed` — Number of rows modified

## upsert


```lua
function DB.upsert(tableName: string, where: table|fun(row: table):boolean|nil, createRow: table, patch: table)
  -> id: number
```

 Insert or update a row based on a lookup clause.
 If a matching row exists, updates it using `patch` and returns its `id`.
 If none exists, inserts `createRow` and returns the new `id`.

@*return* `id` — The existing or newly-created row id


---

# DbTable

## meta


```lua
table|nil
```

## rows


```lua
table
```


---

# DbUpdateOptions

## rebuildIndex


```lua
boolean|nil
```


---

# EncryptedConnection

## __index


```lua
EncryptedConnection
```

## address


```lua
string
```

## remotePublicKey


```lua
table
```

## secureNetwork


```lua
SecureNetwork
```

## sessionKey


```lua
EncryptionKeys
```

## sharedKey


```lua
string
```


---

# EncryptionKeys

## private


```lua
table
```

## public


```lua
table
```


---

# Ledger

## __index


```lua
Ledger
```

## _applyMaterialized


```lua
(method) Ledger:_applyMaterialized(tx: any)
```

## _nextId


```lua
(method) Ledger:_nextId()
  -> integer
```

## append


```lua
(method) Ledger:append(tx: LedgerTransaction)
  -> id: integer
```

 Append a transaction to the ledger

## db


```lua
table
```

## logPath


```lua
string
```

## metaPath


```lua
string
```

## new


```lua
(method) Ledger:new(db: table, root: string|nil)
  -> Ledger
```

## nextId


```lua
integer
```

## rebuildMaterialized


```lua
(method) Ledger:rebuildMaterialized()
```

## rebuildMaterializedFast


```lua
(method) Ledger:rebuildMaterializedFast()
```

## root


```lua
string
```

## scan


```lua
(method) Ledger:scan(where: table|fun(row: table):boolean|nil, onRow: fun(tx: LedgerTransaction):nil, opts: any)
  -> nil
```

 Stream transactions; avoids loading whole ledger


---

# LedgerTransaction

## accountId


```lua
integer
```

## amount


```lua
number
```

## createdAt


```lua
number|nil
```

## data


```lua
table|nil
```

## id


```lua
integer
```

## playerName


```lua
string
```

## transactionType


```lua
TransactionType
```


---

# LuaLS


---

# MessageHandler


---

# Network

 Module handling network communications using an OC modem component

## __index


```lua
Network
```

 Module handling network communications using an OC modem component

## broadcast


```lua
(method) Network:broadcast(message: string)
  -> nil
```

 Sends a broadcast message on the network's port

@*param* `message` — message to broadcast

## init


```lua
(method) Network:init(modem: table, port: number)
  -> network: Network
```

 initializes a network instance and opens the specified port

@*param* `modem` — OC modem component

@*param* `port` — port number to use

@*return* `network` — instance

## modem


```lua
table
```

OC modem component

## port


```lua
number
```

port number used for communications

## receive


```lua
(method) Network:receive(timeout: number)
  -> string|nil
  2. string
```

 Receives a message on the network's port

@*param* `timeout` — timeout in seconds; 0 for no timeout

## send


```lua
(method) Network:send(address: string, message: string)
  -> nil
```

 Sends a message to the specified address using the newtork's port

@*param* `address` — OC modem address to send to

@*param* `message` — message to send


---

# NonceTable


```lua
table
```


---

# Query

## __index


```lua
Query
```

## _limit


```lua
integer|nil
```

## _offset


```lua
integer
```

## _orderDir


```lua
"asc"|"desc"
```

## _orderKey


```lua
string|nil
```

## _where


```lua
table|fun(row: table):boolean|nil
```

## all


```lua
(method) Query:all()
  -> rows: table
```

## first


```lua
(method) Query:first()
  -> row: table|nil
```

## limit


```lua
(method) Query:limit(n: integer)
  -> self: Query
```

## offset


```lua
(method) Query:offset(n: integer)
  -> self: Query
```

## orderBy


```lua
(method) Query:orderBy(key: string, dir: "asc"|"desc"|nil)
  -> self: Query
```

```lua
dir:
    | "asc"
    | "desc"
```

## tableName


```lua
string
```

## where


```lua
(method) Query:where(w: table|fun(row: table):boolean|nil)
  -> self: Query
```


---

# SecureNetwork

## __index


```lua
SecureNetwork
```

## _clientId


```lua
string
```

## _encryptionKeys


```lua
EncryptionKeys
```

## _network


```lua
Network
```

 Module handling network communications using an OC modem component

## connect


```lua
(method) SecureNetwork:connect(address: string)
  -> EncryptedConnection
```

## dataCard


```lua
table
```

## generateSignature


```lua
(method) SecureNetwork:generateSignature(clientId: string, publicKey: string, publicId: string, address: string, nonce: integer, bankId: string)
  -> string
```

## handleIncoming


```lua
(method) SecureNetwork:handleIncoming(bank: Bank, senderAddress: string, message: string)
  -> EncryptedConnection|nil
```

## init


```lua
(method) SecureNetwork:init(encryptionKeyFile: string, network: Network, clientId: string, dataCard: table)
  -> SecureNetwork
```

## receive


```lua
(method) SecureNetwork:receive(timeout: integer)
  -> string|nil
  2. string
```

## send


```lua
(method) SecureNetwork:send(address: string, message: string)
  -> nil
```

## sign


```lua
(method) SecureNetwork:sign(data: string)
  -> string
```

## trustedKeys


```lua
table
```

## verifySignature


```lua
(method) SecureNetwork:verifySignature(clientId: string, publicKey: string, publicId: string, address: string, nonce: integer, bankId: string, signature: string)
  -> boolean
```


---

# TransactionById

## accountId


```lua
integer
```

## amount


```lua
number
```

## createdAt


```lua
number
```

## data


```lua
table|nil
```

## id


```lua
integer
```

## transactionType


```lua
TransactionType
```


---

# TransactionType


---

# WhereClause


---

# h


```lua
file*
```


---

# package.loaded.src.db.database


```lua
nil
```


```lua
nil
```


---

# package.loaded.src.models.Account


```lua
nil
```


---

# package.loaded.src.models.Ledger


```lua
nil
```


---

# package.loaded.src.models.database


```lua
nil
```


---

# package.path


```lua
string
```


```lua
string
```


```lua
string
```


```lua
string
```