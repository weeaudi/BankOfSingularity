## Installation

Run these commands on each computer (requires an internet card).

### Bank Server
```
mkdir /install
wget -f https://raw.githubusercontent.com/weeaudi/BankOfSingularity/refs/heads/main/install/server.lua /install/server.lua
lua /install/server.lua
```

### Shop (POS)
```
mkdir /install
wget -f https://raw.githubusercontent.com/weeaudi/BankOfSingularity/refs/heads/main/install/shop.lua /install/shop.lua
lua /install/pos.lua
```

### Casino
```
mkdir /install
wget -f https://raw.githubusercontent.com/weeaudi/BankOfSingularity/refs/heads/main/install/casino.lua /install/casino.lua
lua /install/casino.lua
```

After each installer finishes, create the config.lua for that system before starting.
All 3 have examples in repo.

Bank:
```
/bank/server/config.lua
```

Shop
```
/shop/config.lua
```

Casino
```
/casino/config.lua
```
