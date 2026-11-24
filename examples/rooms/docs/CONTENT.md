# Mutations, consumables and pools

> **Pending the owner's confirmation.** The design and the numbers here were chosen by an AI agent
> as examples. They are not decisions yet (see AGENTS.md, section 9).

The run's content is built on the generic weighted pool
[`engine.modules.items`](../../../engine/modules/items/README.md). The game side is
`examples/rooms/rooms_content.lua`; the data is `rooms_mutations.lua` and
`rooms_consumables.lua`.

## Entries

A mutation is plain data:

```lua
{
  id = "example_spring_heel", name = "SPRING HEEL (EXAMPLE)",
  weight = 4, rarity = "rare",
  sources = { "treasure", "boss", "shop" },
  floors = { min = 1, max = 10 }, mobs = nil, rooms = nil, biomes = nil,
  requires = nil,                 -- tags the run must have (items.requires)
  unique = true,                  -- max = 1; or max_stacks = N
  tags = { "jump" }, synergy = { "jump" }, anti = { "heavy" },
  stats = { { "jump", "mul_base", 0.2 } },
  look = { ... }, body = { ... }, -- cosmetics and physical rest shape
  color = { 0.40, 0.85, 0.95 },
}
```

Instead of (or besides) `stats`, a mutation can carry:

- `ability = { kind = "air_jump" | "wall_jump" | "dash" | "hook", id = "...", ...fields }`: an
  `engine.modules.abilities` definition granted to the run's set when it is acquired.
- `shot = { count = 1, gap = 4 }`, `shot = { burst = 2 }`, `shot = { aim = "free" }`: numbers add
  to the slime's ranged config (`burst_interval` and `walls` replace it), `aim = "free"` lets the
  right stick or the mouse aim. See [ABILITIES.md](ABILITIES.md).

A consumable is the same kind of entry plus `kind = "heart"` (`heal = 1`), `kind = "virus"`
(`amount = 1`) or `kind = "bomb"` (`amount = 1`). There is one normal heart for now; more types can be added without touching the
pool code.

The `items` module already filters `rooms`, `biomes`, `requires` and `max`; it also rejects an
entry whose unique id is at its run limit.

## Sources and restrictions

`rooms_content.M.filter` adds the game's rules for:

- `source`: `treasure`, `boss`, `shop` for mutations; `mob`, `room_clear`, `obstacle`, `machine`
  for consumables.
- `mobs`: the mob id of the room or the killed enemy (one id per biome today). An entry with
  `mobs` set only appears for those ids.
- `floors`: `{ min, max }` on the run's floor.
- `rooms`/`biomes`/`requires`: handled by `items`.

An entry with no restriction can appear anywhere that its source allows. `weight = 0` is never
drawn.

## Weights, the build and luck

`rooms_content.M.weigh` changes a base weight from the build:

- each `synergy` tag owned by the run multiplies by 1.5 (total at most 3×);
- each `anti` tag multiplies by 0.5 (total at least 0.1×).

`luck` is a stat from 0 to 10, neutral at 5. For now it only affects drop chances, not rarity
weights or generation:

```lua
M.luck_multiplier(5) == 1.0
M.luck_multiplier(10) == 1.5
M.luck_multiplier(0) == 0.5
M.chances = { mob = 0.10, obstacle = 0.35, machine = 0.35, room_clear = 0.20 }
```

`M.drop(pool, rng, ctx, chance)` rolls the source chance (scaled by luck), then draws a weighted
entry. It consumes RNG only for that decision. The hook leaves room for luck to reach other
systems later.

## Where content comes from

- **Treasure room**: one mutation, not a choice, drawn on the first visit and cached for the room.
- **Boss/miniboss**: one guaranteed mutation on the first clear (source `boss`).
- **Mobs**: hearts with a 10% base chance; virus does not drop from normal mobs.
- **Obstacles**: a broken crate can drop virus.
- **Clearing a room**: a 20% chance of virus.
- **Shop/machines**: the test healer spends virus; stock and more machine effects come later.

## Determinism

Every draw has its own named `engine.rng` stream and is cached:

- treasure: `reward:<floor>:<room>`
- boss reward: `boss:<floor>:<room>`
- room clear: `clear:<floor>:<room>`
- mob drop: `drop:<floor>:<room>:<enemy>:heart|virus`
- obstacle: `obstacle:<floor>:<room>:<index>`

The entry order in `rooms_mutations.lua` / `rooms_consumables.lua` is part of the result; keep it
stable. A draw is cached in the room state, so leaving and re-entering does not reroll it. The
console's known-answer tests must be updated only when the content order or the stream names change
on purpose.

## Adding content

1. Add an entry with a stable id, weight, sources and (when it matters) `floors`, `mobs`, tags,
   `synergy`.
2. If it changes the run, put the stat operations in `stats` and the appearance in `look`/`body`.
3. Add it to the tests in `tests/pc/rooms_content_test.lua` (schema, filters, uniqueness).
4. Run `luajit -joff tests/pc/rooms_content_test.lua` and `luajit -joff tests/pc/rooms_example_test.lua`.
