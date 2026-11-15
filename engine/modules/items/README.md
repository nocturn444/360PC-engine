# engine/modules/items

Genre module (objective 15): weighted item pools for a run.

- Entries are plain data.
- A pool draws with an `engine.rng` stream (the run's `"loot"` stream), so the same seed gives the
  same items on PC and console.
- It filters entries by room type or by any rule of the game's.
- It keeps what the run has taken, for unique items.
- It grows when the game unlocks content for good.

Nothing in `engine/` requires it, it needs no other module, and it knows nothing about a game.
The entries' effects are the game's to define, usually `engine.modifiers` modifier sets.

Tests: `tests/engine/items_test.lua`. To check on hardware: `tests/console/items_check.lua`.

```lua
local items = require("engine.modules.items")
local relics = items.pool.new({
  { id = "heart",  weight = 10 },
  { id = "sword",  weight = 5, max = 1 },                    -- unique in a run
  { id = "map",    weight = 5, rooms = { "shop" } },         -- only in shops
  { id = "wings",  weight = 3, unlock = "beat_boss" },       -- after a permanent unlock
  { id = "fins",   weight = 3, requires = { "swim" } },      -- only once the run has "swim"
}, { unlocked = profile.unlocks })                           -- from engine.save's permanent progress

local loot = run.streams:get("loot")
local drop = relics:draw(loot, { room = "treasure", have = run.abilities })   -- an entry, or nil
local offer = relics:draw_many(loot, 3, { room = "shop" })                     -- 3 distinct, for ui.pick
relics:take(offer[chosen])                                   -- the player got it: counts for max
```

## Entries

| Field | Meaning |
|---|---|
| `id` | A unique string. |
| `weight` | A number >= 0 (default 1). 0 never comes out. |
| `rooms` | nil (any room), or an array of room types it can appear in. With `rooms` set, an entry only comes out when `ctx.room` is one of them. |
| `unlock` | nil, or a tag. The entry is in the pool only once `pool:unlock(tag)` was called, or the tag was given in `opts.unlocked`. |
| `max` | nil (no limit), or how many times a run can take it. Use 1 for a unique item. |
| `requires` | nil, or tags the run must have (`ctx.have`), such as an ability. |

Anything else in an entry (name, sprite, price, the modifiers it gives) belongs to the game. Keep
the order of the entries stable: it is part of every draw's result.

## The context of a draw

All of its fields are optional:

| Field | Meaning |
|---|---|
| `room` | The type of the room the draw is for. |
| `have` | The run's tags, as an array or `{ tag = true }`. |
| `exclude` | `{ [id] = true }`: entries that never come out. |
| `filter` | `function(entry, ctx) -> boolean`: the game's own rule. |
| `weight` | `function(entry, weight, ctx) -> number`: changes a weight (luck, a modifier stat, a pity rule). |

- **`pool:draw(rng, ctx)`** costs one rng draw when something can come out, and none when nothing
  can (it then returns nil).
- **`pool:draw_many(rng, n, ctx)`** returns up to n distinct entries. It takes nothing, so call
  `pool:take` for the one the player gets.
- **`pool:available(entry, ctx)`** says whether one entry could come out now.

## Run state and unlocks

- **`pool:run_state()`** returns `{ [id] = times taken }`, ready for the run in progress in
  `engine.save`. **`pool:set_run_state(t)`** puts it back and ignores ids it does not know.
- **`pool:new_run()`** forgets the run.
- **`pool:unlock(tag)`** and **`pool:add(entry)`**:
  - unlocks are permanent progress, and the pool does not save them;
  - pass the saved tags in `opts.unlocked` when making the pool;
  - `add` appends content, for example entries that a permanent unlock brings.
