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
