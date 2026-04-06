--- bank/server/config.lua
--- Central configuration for the Bank of Singularity server.
--- Edit values here; all modules import this file instead of hardcoding paths.
local Config = {}

--- Root directory for all database files (accounts, cards, ledger, holds, …).
--- Must be an absolute path. The directory is created automatically on first boot.
Config.DB_ROOT = '/mnt/0fe'

return Config
