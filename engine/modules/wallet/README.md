# engine/modules/wallet

Genre module: a bag of named integer currencies for a run.

- The game names its currencies when it makes the wallet; any other name is an error.
- Amounts are whole numbers >= 0. Spending is all or nothing, so a balance never goes negative.
- It is plain data: `state()` is ready for the run's save in `engine.save`, and `set_state`
  puts it back. Unknown currencies in an old save are ignored.
- It needs no other module, does nothing per frame, and knows nothing about a game.

Tests: `tests/engine/wallet_test.lua`.

```lua
local wallet = require("engine.modules.wallet")

local w = wallet.new({ virus = 0 })
w:add("virus", 12)
w:get("virus")          -- 12
w:can("virus", 10)      -- true
w:spend("virus", 10)    -- true; now 2
w:spend("virus", 99)    -- false; still 2
```

## Saving a run

```lua
-- when the run is saved
local run = { wallet = w:state() }     -- { virus = 2 }
save:save_run(run)

-- when it is loaded
local w = wallet.new({ virus = 0 })
local data = save:load_run()
if data then w:set_state(data.wallet or {}) end
```

## API

| Call | Meaning |
|---|---|
| `wallet.new(initial)` | A wallet. `initial` maps currency names to starting whole amounts (`{ virus = 0 }`). A bad name or amount raises. |
| `w:add(name, n)` | Adds a whole amount >= 0 and returns the new total. |
| `w:get(name)` | The amount. |
| `w:can(name, n)` | Whether there are at least `n`. |
| `w:spend(name, n)` | Takes `n` and returns `true`, or returns `false` and changes nothing. |
| `w:state()` | A plain `{ [name] = amount }` table. |
| `w:set_state(state)` | Restores saved amounts; names the wallet does not know are ignored. |

Any call with an unknown currency raises, so a typo is noticed instead of spending nothing.
