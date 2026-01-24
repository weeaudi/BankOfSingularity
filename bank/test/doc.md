# Account

## accountStatus


```lua
AccountStatus
```

## accountname


```lua
string
```

## balance


```lua
number
```

## id


```lua
integer
```

## name


```lua
string
```


---

# AccountStatus


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

## rebuildMaterialized


```lua
(method) Ledger:rebuildMaterialized()
```

## root


```lua
string
```

## scan


```lua
(method) Ledger:scan(where: table|fun(tx: LedgerTransaction):boolean|nil, onRow: fun(tx: LedgerTransaction):nil)
  -> nil
```

 Stream transactions; avoids loading whole ledger


---

# LedgerTransaction

## accountId


```lua
string
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
integer|nil
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

## recive


```lua
(method) Network:recive(timeout: number)
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

# TransactionType


---

# WhereClause


---

# package.loaded.src.db.database


```lua
nil
```