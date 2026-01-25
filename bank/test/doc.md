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

# DB

## delete


```lua
function DB.delete(tableName: string, where: table|fun(row: table):boolean|nil)
  -> deleted: number
```

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
function DB.update(tableName: string, where: table|fun(row: table):boolean|nil, patch: table)
  -> changed: number
```

## upsert


```lua
function DB.upsert(tableName: any, where: any, createRow: any, patch: any)
  -> number
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

# Network

## __index


```lua
Network
```

## broadcast


```lua
(method) Network:broadcast(message: string)
  -> nil
```

## init


```lua
(method) Network:init(modem: table, port: number)
  -> table
```

## modem


```lua
table
```

## port


```lua
number
```

## receive


```lua
(method) Network:receive(timeout: number)
  -> string|nil
  2. string
```

## send


```lua
(method) Network:send(address: string, message: string)
  -> nil
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

## _encryptionKeys


```lua
EncryptionKeys
```

## _network


```lua
Network
```

## connect


```lua
(method) SecureNetwork:connect(address: string)
  -> EncryptedConnection
```

## dataCard


```lua
table
```

## handleIncoming


```lua
(method) SecureNetwork:handleIncoming(senderAddress: string, message: string)
  -> EncryptedConnection|nil
```

## init


```lua
(method) SecureNetwork:init(encryptionKeyFile: string, network: Network, dataCard: table)
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