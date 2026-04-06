--- casino/config.lua
--- Static configuration for the Bank of Singularity slot machine.
---
--- Edit this file to change gameplay tuning (costPerSpin, maxSpins) or
--- to point the machine at a different bank account name.
---
--- Casino card credentials (casinoCardUid / casinoCardSalt / casinoPin) are
--- populated automatically on first boot by the setup wizard in main.lua and
--- saved to `/casino/casino_card.dat` — you should not need to fill them here
--- manually.

---@class CasinoConfig
---@field deviceId        string   Unique identifier sent to the bank server during announce/handshake
---@field deviceType      string   Bank device role — "pos" allows holds, transfers, balance checks
---@field casinoAccountName string  Name of the casino's own bank account (must exist on the server)
---@field casinoCardUid   string   UID of the casino's physical card (auto-filled by setup wizard)
---@field casinoCardSalt  string   Salt stored with the casino card's PIN hash (auto-filled)
---@field casinoPin       string   Plain PIN digits for the casino card (auto-filled; never sent over wire)
---@field costPerSpin     integer  Amount in cents charged per spin (e.g. 10000 = $100.00)
---@field maxSpins        integer  Maximum number of spins a player can purchase in one session

return {
    deviceId = 'CASINO-1',
    deviceType = 'pos',

    -- The casino's own bank account. Spins are held to this account;
    -- winnings are transferred out of it.
    casinoAccountName = 'Casino',

    -- Casino card credentials — filled automatically by the first-boot setup
    -- wizard (main.lua). Delete /casino/casino_card.dat to re-run the wizard.
    casinoCardUid  = '', -- uid from cards.dat / card writer
    casinoCardSalt = '', -- salt printed by admin when card was issued
    casinoPin      = '', -- the PIN you set on the casino card (digits only)

    -- Gameplay config
    costPerSpin = 10000, -- currency units per spin (cents; 10000 = $100.00)
    maxSpins    = 10,    -- maximum spins a player can buy at once
}
