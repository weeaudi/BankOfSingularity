---@diagnostic disable: lowercase-global  -- type-stub file; globals are annotation-only
---@enum RequestType
--- Request shape
---@class Request
---@field v number Protocol version
---@field kind "req"
---@field op string Requested operation
---@field id string Request ID
---@field from string Sender
---@field to string Recipient
---@field ts number Timestamp (os.time)
---@field data table Payload
req = {}

--- Error shape
---@class Error
---@field code string
---@field message string Error message
err = {}

--- Response shape
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
res = {}

--- Event shape
---@class Event
---@field v number
---@field kind "evt"
---@field op string
---@field from string
---@field to string|nil
---@field ts number
---@field data table
evnt = {}
