# Stats and shield

The rooms prototype has six run stats and a shield resource. The numeric engine is
[`engine.modifiers`](ENGINE.md#engine-modifiers); the game supplies the schema in
`examples/rooms/rooms_stats.lua`, so a new stat is data plus the code that reads it. Nothing here
is required by `engine/`, and the console uses the same plain Lua.

## The schema

| Stat | Base | Min | Max | Meaning |
|---|---:|---:|---:|---|
| `luck` | 5 | 0 | 10 | drop chance (see [CONTENT.md](CONTENT.md)); 5 is neutral |
| `jump` | 1.0 | 0.5 | 3.0 | multiplier on the slime's jump impulses |
| `speed` | 1.0 | 0.5 | 2.0 | multiplier on the slime's ground/air movement |
| `damage` | 1 | 0 | 20 | flat attack damage; the attacks multiply it with `power` |
| `shield` | 0 | 0 | 10 | shield capacity (the current shield is separate) |
| `health` | 5 | 1 | 20 | maximum health (the current health is the fighter's) |

`rooms_stats.lua` declares each one with `engine.modifiers` and attaches a set to the run:

```lua
local stats = require("rooms_stats")
local s = stats.new(mutation_defs)          -- definitions are plain data
s:get("jump")                               -- base + every acquired mutation
s:acquire("example_spring_heel")            -- one modifier stack, validated
s:stacks("example_spring_heel")
s:tags()                                    -- { jump = true, ... } for synergy
```

A mutation definition is an `engine.modifiers` definition: `id`, `stacking` (`unique` or `stack`),
`max_stacks`, `stats = { { "jump", "mul_base", 0.2 } }`, optional events, and `tags`. The content
catalogue lives in `rooms_mutations.lua`; see [CONTENT.md](CONTENT.md). All mutations are applied
in acquisition order, but `engine.modifiers` evaluates each stat in its fixed phase order, so the
result does not depend on that order.

## Mapping to the engine

The combat world reads stats through any object with `:get(name)`. `rooms_stats` provides one:

| Engine name | Source |
|---|---|
| `max_health` | `health` |
| `attack_damage` | `damage` |
| `defense` | 0 (the shield is a resource, not armour) |
| `knockback_resist` | 0 |
| `invuln_time` | 1.0 s |

The slime's attacks in `rooms_attacks.lua` use `power` instead of a fixed `damage` (melee and
ranged 1, explosive 2). At the base `damage = 1` the numbers are the same as before; a damage
mutation scales every attack. The stomp is a `power = 1` hitbox, so it scales too.

Movement reads the stats directly in `rooms_play.lua`:

```lua
local speed, jump = self.stats:get("speed"), self.stats:get("jump")
slime:push(move * (on_ground and MOVE or AIR_MOVE) * speed, 0)
slime:impulse(0, -JUMP * jump)
```

## Health

`health` is the maximum, never the current value. Acquiring a mutation that raises or lowers it
does not heal or hurt the slime; only hearts and the test healer change the current health. If a
mutation lowers the maximum below the current health, the current health is clamped to it.

## Shield

The stat is the capacity; the current shield is a run resource between 0 and that capacity.

- Damage is absorbed 1:1 before health; the overflow goes to health.
- Any hit that reaches the fighter restarts the recharge timer, even when the shield is empty.
- After `5 + 2.5 * capacity` seconds without a hit, the shield refills to its capacity. A capacity
  of 0 has no effect.
- A new run starts with 0 current shield (base capacity 0). Gaining capacity fills the current
  shield by the same delta; losing capacity clamps it.
- The HUD shows `SH current/capacity`.

The absorption is an internal `engine.modifiers` definition with an `on_damaged` chain handler, so
it uses the same damage pipeline as the rest of the combat module. `Stats:update(dt)` advances the
recharge and allocates nothing.

## Adding a stat

1. Add a row to `M.defs` with `base`, `min` and `max`.
2. Read it where it matters (a combat adapter, a movement formula, a pool context, the HUD).
3. If it needs a new effect, use an `engine.modifiers` event or a small game system; do not put
   the game's stat names into `engine/`.

`Stats:serialize()` / `set_state()` keep the acquisition counts, the current shield and its timer
as plain data, ready for an `engine.save` run slot.
