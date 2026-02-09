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

# Card

## account_id


```lua
integer
```

## card_data


```lua
string
```

## meta


```lua
CardMetadata|nil
```

## status


```lua
CardStatus
```

## uid


```lua
string
```


---

# CardMetadata

## last_used_at


```lua
number
```

## revoked_reason


```lua
string
```


---

# CardStatus


---

# DB

## root


```lua
string
```


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

# Error

 Error shape

## code


```lua
string
```

## message


```lua
string
```

Error message


---

# Event

 Event shape

## data


```lua
table
```

## from


```lua
string
```

## kind


```lua
"evt"
```

## op


```lua
string
```

## to


```lua
string|nil
```

## ts


```lua
number
```

## v


```lua
number
```


---

# ExecutionContext

## fromAddr


```lua
string
```

## localAddr


```lua
string
```

## makeError


```lua
function
```

## port


```lua
integer
```

## receivedAt


```lua
number
```

## resErr


```lua
function
```

## resOk


```lua
function
```


---

# HandlerExpect

## dataPredicate


```lua
fun(data: any):boolean|nil
```

## hasErr


```lua
boolean
```

## ok


```lua
boolean
```


---

# HandlerTestCase

## expect


```lua
HandlerExpect
```

## name


```lua
string
```

## req


```lua
Request
```

 Request shape


---

# Ledger

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

## nextId


```lua
integer
```

## root


```lua
string
```


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

# MakeRequestOps

## ts


```lua
number
```

timestamp


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

# PendingRequest

## callback


```lua
fun(res: Response|nil, err: Error|nil)
```

## deadline


```lua
number
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

# QueryAndCleanBuffer


```lua
function QueryAndCleanBuffer()
```


---

# Request

 Request shape

## data


```lua
table
```

Payload

## from


```lua
string
```

Sender

## id


```lua
string
```

Request ID

## kind


```lua
"req"
```

## op


```lua
string
```

Requested operation

## to


```lua
string
```

Recipient

## ts


```lua
number
```

Timestamp (os.time)

## v


```lua
number
```

Protocol version


---

# RequestHandler


---

# RequestType


---

# Response

 Response shape

## data


```lua
table|nil
```

Payload

## err


```lua
Error|nil
```

 Error shape

## from


```lua
string
```

Sender

## id


```lua
string
```

request ID

## kind


```lua
"res"
```

## ok


```lua
boolean
```

## op


```lua
string
```

Requested operation

## to


```lua
string
```

Recipient

## v


```lua
number
```

Protocol version


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

# package.loaded.src.tests.utils


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


```lua
string
```


```lua
string
```


```lua
string
```