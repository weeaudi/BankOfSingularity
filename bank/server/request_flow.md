# Request Flow

The server receives a request with the following format:

```lua
---@class Request
---@field v number Protocol version
---@field kind "req"
---@field op string Requested operation
---@field id string Request ID
---@field from string Sender
---@field to string Recipient
---@field ts number Timestamp (os.time)
---@field data table Payload
---@class Error
---@field code string
---@field message string Error message
```

Request is first routed to the dispatch (src/protocol/dispatch.lua) which, upon resolving the req.kind as req, routes the request to the appropriate handler (src/handler/req.lua).

The handler then makes a request to the service layer, which returns data that the handler uses to construct a response.

```pgsql
network → decode → validate → handler → service
                                 ↓
                          domain result
                                 ↓
                         handler wraps it
                                 ↓
                              response
```

Service layer should not directly access the database; instead it should call the functions that are currenly located in the models layer.

Responses are shaped like:

```lua
---@class Response
---@field v number Protocol version
---@field kind "res"
---@field op string Requested operation
---@field id string request ID
---@field from string Sender
---@field to string Recipient
---@field ok boolean
---@field data table|nil Payload
---@field err Error|nil

---
---@class Event
---@field v number
---@field kind "evt"
---@field op string
---@field from string
---@field to string|nil
---@field ts number
---@field data table
```

Errors should follow the shape:

```lua
---@class Error
---@field code string 
---@field message string Error message
```
