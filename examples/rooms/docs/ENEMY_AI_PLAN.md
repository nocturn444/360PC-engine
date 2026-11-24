# Enemy AI plan: modular behaviours and enemy types

Status: plan, to be built in three steps on branch `claude/project-thread-2yza81` (stacked on
PR #85). Requested by the owner on 2026-11-24: straight-line shots, pattern shots, free (aimed)
shots, charge, jumping enemies, flying enemies, and an easy way to add new enemy types later.

Read `AGENTS.md` first. Hard rules that matter most here: engine/module code knows nothing about
the game; plain Lua 5.1; **no per-frame allocation** in update paths; randomness only through
`engine.rng` streams; only the console's LOVE subset; 30 FPS on the console.

## Today

- `engine/modules/combat/fsm.lua`: state machine (states with enter/update/exit, transitions
  with `when` / `after`).
- `engine/modules/combat/behaviours.lua`: `patrol`, `chase`, `attack` (melee hitbox with
  windup/active/recovery), conditions `target_within` / `target_beyond`, `move`, `input`.
- `engine/modules/combat/attacks.lua`: attacks as data. `Attack:trigger(ax, ay)` already aims a
  ranged shot or a thrown bomb at any direction.
- `examples/rooms/rooms_enemies.lua`: every enemy is the same walker (one `BRAIN`: patrol,
  chase, bite), a platformer controller body, drawn with `rooms_art.draw_enemy`.

## Design

Three layers, each usable without the next:

1. **Behaviours** (engine, generic): new fsm states and conditions in `combat.behaviours`.
2. **Brains as data** (engine, generic): `combat.brains.build(spec)` turns a plain table into an
   fsm definition, looking behaviours and conditions up by name in a registry that a game can
   extend (`brains.behaviour(name, ctor)`, `brains.condition(name, ctor)`).
3. **Enemy types** (game, `examples/rooms/`): a registry of enemy types as data (body, movement
   kind, stats, attacks, brain spec, look), and biome pools that pick types per spawn spot.

Adding a new enemy later = one entry in `rooms_enemy_types.lua` (and, only if it needs a new kind
of movement, one new behaviour registered by name).

## Step 1: engine behaviours (`engine/modules/combat/behaviours.lua`)

All states follow the existing conventions: they move nothing, they write
`agent.move_x`, `agent.move_y`, `agent.move_speed` (and `agent.jump`), read per-enemy data from
the agent, keep per-enemy state in agent fields or `m.phase`, use `m.time` as their clock, and
allocate nothing in `enter`/`update`/`exit`. Every new state supports `next` (state name when it
is over) where it has an end.

New agent fields (document them in the header):
- `agent.attacks` `{ name = combat.attacks Attack }` (shoot)
- `agent.jump` set to true for one step to press jump (hop); `agent.jump_velocity` optional
  per-agent jump strength the game's stats wrapper may read
- `agent.anchor` `{ x =, y = }` home point for flyers (default: the body centre on enter)
- `agent.charge_dir` (charge), `agent.volley`, `agent.next_volley` (shoot), `agent.hop_wait`
  (hop), `agent.fly_t` (fly)

### `M.shoot(opts)`: straight, pattern and aimed shots

Stands still and fires one or more volleys of a ranged (or explosive) attack from
`agent.attacks[opts.attack]`, then `next`.

opts:
- `attack` name in `agent.attacks` (required)
- `aim` `"facing"` (default; straight line ahead, uses the config's own `angle`), `"target"`
  (towards the target's centre at the moment of each volley: free/aimed shot), `"angle"` (a fixed
  angle in degrees above the facing direction, `opts.angle`)
- `volleys` number of triggers (default 1), `interval` seconds between volleys (default 0.2)
- `rotate` degrees added to the aim angle after each volley (default 0): spirals and sweeps.
  A ring = a ranged config with `count = 8, spread = 315`; a spiral = that ring with
  `volleys = 6, rotate = 15`.
- `windup` seconds before the first volley (default 0.3, `m.phase == "windup"`, so the game can
  draw a tell), `recovery` seconds after the last one (default 0.4, `m.phase == "recovery"`),
  `m.phase == "firing"` in between
- `face` false: do not turn to the target on enter

The state computes the direction (ax, ay) with numbers only and calls `attack:trigger(ax, ay)`
(or `trigger()` for `"facing"` with `rotate == 0`). `"target"` without a target falls back to
facing. The attack's own `cooldown` must be <= `interval` (otherwise later volleys are skipped);
assert it once in enter with a clear error. On exit it does not cancel shots already flying.

### `M.charge(opts)`: dash at the target

Phases: `windup` (stands still, faces the target, `m.phase == "windup"`), `dash` (moves at
`speed` in the direction fixed at the end of windup; along x by default, `axis = "xy"` for
flyers; an optional hitbox `agent.hitboxes[opts.hitbox]` is active during the dash), `recovery`
(stands still; longer when it hit a wall: `stun`). Then `next`.

opts: `speed` (default 140), `time` max dash seconds (default 0.6), `distance` max dash pixels
(optional), `windup` (0.4), `recovery` (0.3), `stun` (0.8, used instead of recovery when
`blocked(agent)` stopped it), `blocked` function(agent) -> true (wall/ledge ahead), `hitbox`
(optional), `axis`, `next`.

### `M.hop(opts)`: jumping enemy

On the ground it waits `wait` seconds (number or `{ min, max }` drawn from `agent.rng`), then
sets `agent.jump = true` for exactly one step and `move_x` towards the target (`toward =
"target"`, default) or forwards (`toward = "facing"`), keeping that `move_x` in the air and
halting on landing. It needs to know if the body is on the ground: `opts.grounded`
function(agent) -> boolean (default: `body.on_ground`, the platformer controller field).
`speed` px/s horizontal in the air (default 60), `jump_velocity` written to
`agent.jump_velocity` on enter (optional). Endless (no `next`); leave it with transitions.

### `M.fly(opts)`: flying movement

For bodies without gravity (axis "xy" always). Modes (`opts.mode`):
- `"hover"`: bobs around `agent.anchor` on a small figure (sin/cos of `m.time`, `radius`,
  `period`), no target needed
- `"follow"`: approaches the target until `keep` pixels, backs off when closer than `keep - band`,
  and bobs vertically while holding (`bob` px amplitude)
- `"swoop"`: flies straight at the target's position taken on enter, at `speed`, for at most
  `time` seconds, then `next` (combine with `charge` style tells through transitions)

opts: `mode`, `speed` (default 40), `keep` (60), `band` (12), `radius` (8), `period` (2), `bob`
(4), `time` (1), `next`. Only `sin`/`cos` of numbers: deterministic.

### `M.keep_away(opts)`: kite the target

Walks away from the target when closer than `min`, towards it when farther than `max`, stands
still (facing it) in between. opts: `min` (48), `max` (96), `speed` (40), `axis` ("x" default).

### Conditions (functions for `transitions.when`, built once, no allocation per call)

- `M.target_in_sight(grid, range)`: target within `range` (straight line) and no `"solid"` tile
  of `grid` (`grid:kind(tx, ty)`, `grid.tile_size`) between the two centres. Grid DDA or a fixed
  step walk of tile_size/2; no tables.
- `M.target_above(px)` / `M.target_below(px)`: the target's centre is more than px higher/lower.
- `M.grounded()`: `body.on_ground`.
- `M.health_below(fraction)`: `agent.fighter.health / max` below fraction (read max health
  through the fighter's stats as `world.lua` does).
- `M.all(a, b, ...)`, `M.any(a, b, ...)`, `M.negate(c)`: combine conditions at build time.

### Movers

- `M.input` already presses jump for `agent.jump`; it must report `pressed("jump")` only on the
  step `agent.jump` is true (the hop state clears it next step). Check and test.
- Add `M.fly_move(agent, world, filter, dt)`: moves `agent.body` by its wish in a bump world
  (`world:move(body, x, y, filter)`), keeps `body.px, body.py` for interpolation, sets
  `body.wall` (-1/0/1) and `body.ceiling`/`body.floor` from the collisions it reports. No
  require of bump or platformer: the world is passed in (duck typing).

### Tests (`tests/engine/combat_test.lua` or a new `behaviours_test.lua` added to `run.lua`)

For each state: phases and timings at 60 Hz (fake attack objects recording trigger calls and
their ax, ay), `rotate` producing the expected angles, aim at target, charge stops on blocked
and uses stun, hop presses jump exactly once per landing, fly modes stay within their radius /
keep band, keep_away directions, line of sight blocked by a solid tile, combinators. An
allocation check like the existing ones (collectgarbage count stable over 600 steps after warm
up) for shoot, charge, hop and fly.

Docs: `engine/modules/combat/README.md` (behaviour reference), `docs/ENGINE.md` if it lists
behaviours, `CHANGELOG.md` `[Unreleased]`.

## Step 2: brains as data (`engine/modules/combat/brains.lua`, exported in `combat/init.lua`)

```lua
local brains = combat.brains
local def = brains.build({
  initial = "patrol",
  states = {
    patrol = { "patrol", speed = 22, pause = { 0.3, 0.9 } },
    chase  = { "chase", speed = 45, stop = 8 },
    shoot  = { "shoot", attack = "spit", aim = "target", volleys = 3, interval = 0.25, next = "chase" },
  },
  transitions = {
    patrol = { { to = "chase", when = { "target_within", 80, "xy" } } },
    chase  = { { to = "shoot", when = { "target_in_sight", 140 }, after = 1.0 },
               { to = "patrol", when = { "target_beyond", 160, "xy" } } },
  },
}, { grid = grid, blocked = fn })   -- context: values a behaviour or condition may need
```

- A state entry is `{ behaviour_name, opts... }` (array part [1] is the name, the rest are opts
  passed as a copy to the constructor). Name `"idle"` = a state that halts.
- A condition is `{ name, args... }`, or `{ "all", c1, c2 }`, `{ "any", ... }`, `{ "not", c }`,
  or a function (escape hatch).
- `ctx` fills arguments a behaviour or condition declares it needs (e.g. `grid` for
  `target_in_sight`, `blocked`/`grounded` for patrol, charge, hop) so specs stay pure data.
  Rule: opts given in the spec win over ctx.
- `brains.behaviour(name, ctor)` and `brains.condition(name, ctor)` register new ones (a game's
  own behaviours). Built-ins registered from `combat.behaviours`.
- Errors name the brain state and field: unknown behaviour, unknown condition, unknown target
  state (fsm already checks), wrong arg types where cheap to check.
- `build` is called once per enemy type per room (not per enemy, not per frame); the result is
  shared by every machine of that type.

Tests: building the current walker brain from data gives the same behaviour as the hand-written
one over N steps (same positions/phases), registry extension, every error message, ctx merge.
Docs: combat README section "Brains as data", CHANGELOG.

## Step 3: enemy types in the game (`examples/rooms/`)

### `rooms_enemy_types.lua` (new): the registry, pure data

Each type:

```lua
shooter = {
  move = "walk",                    -- "walk": platformer controller; "fly": no gravity, fly_move
  w = 12, h = 10,
  health = 1.0, damage = 1.0,       -- multipliers over the biome's mob stats
  speed = 35,                       -- walk max speed / fly speed
  jump_velocity = nil,              -- hoppers
  contact = true,                   -- touching it hurts (a body hitbox always active)
  hitboxes = { bite = { ox = 10, oy = 2, w = 9, h = 7, knockback = 160, ky = -0.6 } },
  attacks = { spit = { kind = "ranged", cooldown = 0.2, speed = 120, life = 1.6, w = 3, h = 3,
                       power = 1, knockback = 60 } },
  brain = { ... brains.build spec ... },
  look = { shape = "shooter" },     -- placeholder drawing key (rooms_art), art comes later
},
```

Types to ship (numbers are first guesses for the owner to tune):
- `walker`: today's enemy (patrol, chase, bite). Must behave exactly as now.
- `hopper`: hops towards the target every 0.8-1.4 s (jump_velocity ~260), contact damage.
- `charger`: patrols; with the target in sight on its row (within 120 px, `target_above` false)
  it winds up 0.45 s (tell) and dashes 150 px/s, stunned 0.9 s if it hits a wall.
- `shooter`: keeps away (48-110 px), fires a straight shot ahead every ~1.5 s when in sight.
- `sniper`: keeps away, aims at the target (`aim = "target"`), 0.6 s windup, 1 shot.
- `sprayer`: slow walker; pattern: ring of 8 shots, 3 volleys rotating 22.5 degrees.
- `bat` (flyer): hovers, follows at a short distance, swoops at the target with a tell.
- `drone` (flyer + shooter): follows at 70 px and fires aimed shots.

### `rooms_enemies.lua` changes

- `M.new` takes per spot a type id (`spots[i].type`); missing = `"walker"`.
- Builds each type's brain once per room (`brains.build` with ctx `{ grid, blocked }`).
- Walk bodies: as today (controller + EnemyStats; EnemyStats also answers `jump_velocity` from
  `agent.jump_velocity`). Fly bodies: a plain body added to the same bump world, moved with
  `behaviours.fly_move` using `platformer.collision.filter`; they never fall through pits.
- One shared enemy arsenal (`combat.attacks.new(self.fight, { grid = grid, max_projectiles = 32 })`),
  each enemy equips its type's attacks into `agent.attacks`. `arsenal:step(dt)` every step.
- Contact damage: a hitbox the size of the body, always active, for types with `contact`.
- Drawing: windup phases (`m.phase == "windup"` in shoot/charge, swoop tell) flash light; enemy
  shots in a colour distinct from the slime's (e.g. 0.95, 0.35, 0.45); `rooms_art.draw_enemy`
  gets a `shape` argument and draws a simple distinct placeholder per shape (the owner will
  draw real sprites later; keep it to rectangles/existing atlas, no new assets required).
- Enemy projectiles stop at walls (the arsenal's grid) and are cleared when the room changes.

### Which types appear (`rooms_biomes.lua`)

Each biome's `mobs` gets `types = { walker = 3, hopper = 1, ... }` (weights). `rooms_play.lua`
picks a type per template spot with an rng stream seeded from the room seed and the spot index,
so a room always gets the same enemies when re-entered and the same seed gives the same run on
PC and console. Arrivals (enemies that fell from the room above) keep their type: store it in
`state.arrivals[k].type`. Flyers never fall. A template spot may force a type later
(`t.type` in the level), not required now.

Default introduction (gradual; pending the owner's confirmation):
- forest (1-2): walker, hopper
- deep jungle (3-4): + charger, bat
- grotto (5): + shooter
- fungal cave (6-7): + sniper
- catacombs (8): + sprayer
- labs (9), catastrophe (10): all, + drone
Bosses and minibosses stay as they are in this PR.

### Tests and checks

- `tests/pc/rooms_example_test.lua`: every type in the registry builds and runs 600 steps in a
  test room without errors; a shooter in sight fires; a hopper leaves the ground; a flyer stays
  off the ground and inside the room; type choice per spot is deterministic for a seed.
- Performance: a room with 8 mixed enemies (incl. 2 sprayers firing) for 600 steps under
  `-joff`; report the time per step. Enemy shots capped by `max_projectiles`.
- Console known answers (`tests/console/*_check.lua`) must stay 0 wrong; if the floor
  generation output changes because of the new rng use, explain it in the PR.
- Docs: `examples/rooms/README.md` (enemy types, how to add one), `examples/rooms/docs/` if an
  enemies doc exists, CHANGELOG.

## Order and ownership

1. Step 1 (engine behaviours): opencode, then Claude audits.
2. Step 2 (brains as data): opencode, then Claude audits.
3. Step 3 (game types): opencode, then Claude audits; then a console test build.
Each step is a commit on this branch (one PR), titles and messages in English.
