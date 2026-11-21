# Virus, pickups and machines

Virus is the run's currency. It resets with a new run, survives floors, and is spent at machines
that have `accepts_money = true`. The wallet is the generic module
[`engine.modules.wallet`](../engine/modules/wallet/README.md); the game data is
`examples/rooms/rooms_pickups.lua`, `rooms_obstacles.lua` and `rooms_machines.lua`.

## Wallet

```lua
local wallet = require("engine.modules.wallet")
local w = wallet.new({ virus = 0 })
w:add("virus", 5)
w:can("virus", 3)            -- true
w:spend("virus", 3)          -- true, never below 0
w:get("virus")               -- 2
w:state()                    -- { virus = 2 }, plain data for a run save
```

Every currency name is declared at `new`; an unknown name is an error, so a typo cannot quietly
do nothing. Amounts are whole numbers >= 0, gold-style.

## Pickups

`rooms_pickups.lua` is data-only: `M.heart(x, y, amount)`, `M.virus(x, y, amount)`,
`M.overlaps(pickup, cx, cy)`, `M.color` and `M.label`. The room draws them as small squares and
collects them on touch.

- A heart heals its amount, capped at the current maximum health. At full health it becomes one
  virus instead of being wasted.
- A virus pickup adds its amount to the wallet.

Each room keeps its pickups in its persistent state, so drops left behind survive a re-entry. The
start room has one heart and one virus pickup for testing.

## Obstacles

`rooms_obstacles.lua` defines breakable props. A crate has a small persistent state
(`health`, `broken`), so a broken crate stays broken when the room is loaded again. It is a
non-solid prop for now: the slime breaks it with an attack in front or by falling onto it. Its
`virus = { chance, amount }` is rolled once with the room's obstacle stream and the run's luck; a
successful roll spawns a virus pickup.

The current templates put crates in some halls and steps rooms.

## Machines

A machine definition is data:

```lua
{ accepts_money = true, currency = "virus", price = 5, uses = 1,
  effect = "heal_full", color = { ... }, label = "HEAL" }
```

The instance lives in the room template (`machine = { tx, ty, kind = "healer" }`) and gets its own
state (`{ used = 0 }`) in the room's persistent table. It is not a global per-floor counter.

```lua
local allowed, reason = machines.can_buy(machine, wallet)
local effect, why = machines.buy(machine, wallet)
```

`buy` spends only on success and returns the effect string; the game applies it. The test healer
has `accepts_money = true`, costs 5 virus, has one use, and fills the health. The interaction is
the `interact` action (`E`/`F`, gamepad B); the HUD shows the prompt and the wallet.

A machine that is not `accepts_money` refuses with `"not accepts_money"`. The module also exposes
`available`, `uses_left` and a `draw` helper. Shop stock is deliberately not implemented yet; the
shop template has the test healer, and the virus source `machine` is ready for a future machine
that drops or pays virus.

## Persistence

The wallet is run-scoped: `play.new_run` creates `wallet.new({ virus = 0 })`; `new_floor` does not
reset it. Store `wallet:state()` in the run save when the run save is implemented. The machine's
state lives with the room, so a used healer stays used while that floor exists; a new run starts
fresh.
