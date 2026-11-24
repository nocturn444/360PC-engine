# engine/modules/combat

Genre module (objective 13): hitboxes and hurtboxes, a damage pipeline that reads stats and
emits modifier events, invulnerability frames, knockback, hitstop, and a small state machine
with enemy behaviours. It works for a platformer, a top-down game or anything with rectangles.
Nothing in `engine/` requires it; it requires no other module (no bump, no platformer, not even
`engine.modifiers` or `engine.rng`: it uses the objects the game hands over) and it knows
nothing about a game.

A game needs `engine/modules/combat/` in its folder. Tests: `tests/engine/combat_test.lua`.

```lua
local engine = require("engine")
local combat = require("engine.modules.combat")

local world = combat.world.new()
local set = mods:attach(player, combat.stats.new({ max_health = 5, attack_damage = 2 }))
local hero = world:fighter({ body = body, team = "player", mods = set })     -- body: x, y, w, h, facing, vx, vy
hero:hurtbox({ w = 10, h = 14 })
local slash = hero:hitbox({ ox = 10, oy = 2, w = 12, h = 8, knockback = 150, hitstop = 3 / 60 })

function play:update(dt)                                    -- the fixed step
  if not hero:frozen() then
    body:step(engine.controls, dt)                          -- move (a platformer body, or anything)
    if engine.controls:pressed("attack") then slash:activate(6 / 60) end
  end
  world:step(dt)                                            -- always, after the bodies moved
end
```

| File | What it is |
|---|---|
| `init.lua` | `require("engine.modules.combat")`: `{ stats, world, fsm, behaviours, attacks }`. |
| `stats.lua` | The combat stats and their defaults. |
| `world.lua` | Fighters, hitboxes, hurtboxes, the overlap search, the damage pipeline, i-frames, knockback, hitstop. |
| `fsm.lua` | A state machine: states with enter / update / exit, transitions, time in the state. |
| `behaviours.lua` | States for enemies: patrol, chase, attack, shoot, charge, hop, fly, keep_away, and their conditions. |
| `brains.lua` | Brains as data: builds a `combat.fsm` definition from plain tables, with an extendable registry of behaviours and conditions. |
| `attacks.lua` | Attacks as data: melee sweeps, ranged shots, explosive bombs, on top of a world. |

Units: pixels and seconds. `y` grows downwards; a body's `x, y` is its top left corner. Every
time is counted in fixed steps of the `dt` given: `n / 60` is `n` steps at 60 Hz (a timer
within 1e-9 of zero has run out, so `0.5` is exactly 30 steps).

## Fighters and boxes

`combat.world.new(opts)`; `opts`: `can_hit(attacker_team, target_team)` (default: the teams are
different), `default_hitstop` (seconds, default 0), `on_hit(hit)`.

`world:fighter(opts)` adds a fighter: whatever can hit or be hit. `opts`:

| | |
|---|---|
| `body` | Where it is: a table with `x`, `y` and optionally `w`, `h`, `facing` (1 / -1), `vx`, `vy`. A platformer body is one; so is any table of the game's. The module only reads it, except for knockback. |
| `team` | Any value. A fighter never hits itself, whatever `can_hit` says. |
| `mods` | An `engine.modifiers` set: the stats are read from it and the events are sent through it. |
| `stats` | Instead: anything with `:get(name)` that answers every stat name. |
| `params` | Instead: a table from `combat.stats.new` (default: the defaults). |
| `health` | Default: the `max_health` stat. |
| `on_hurt(fighter, hit)`, `on_death(fighter, hit)` | Callbacks. |
| `owner` | Anything of the game's (the entity); kept in `fighter.owner`. |

Fields to read: `health`, `dead`, `invuln` and `hitstop` (seconds left), `team`, `body`,
`hitboxes`, `hurtboxes`. Methods: `fighter:hurtbox(opts)`, `fighter:hitbox(opts)`,
`fighter:frozen()`, `fighter:invulnerable()`, `fighter:stop(seconds)`, `fighter:heal(amount)`
(up to `max_health`; returns the health), `fighter:revive(health)`, and `world:remove(fighter)`.

A box is a rectangle attached to its fighter's body: `ox`, `oy` (offset from the body's top
left corner when it faces right), `w`, `h`, and `tag` (anything). When the body faces left
(`facing < 0`) the box is mirrored inside the body's width: `x = body.x + body.w - ox - w`.
`box:rect()` gives `x, y, w, h` now (to draw it), `box:set(ox, oy, w, h)` changes it,
`box:remove()` takes it out; every box has an `id`, the order it was created in.

- A **hurtbox** can be hit while `box.enabled` (true at first).
- A **hitbox** hits while it is active. `hitbox:activate(duration)` turns it on with an empty
  hit list; `duration` is in seconds (it is active for `duration / dt` world steps) or nil
  (until `hitbox:deactivate()`). Its other options:

| | |
|---|---|
| `power` | Multiplies the fighter's `attack_damage` (default 1). |
| `damage` | A fixed amount instead of `attack_damage * power`. |
| `knockback` | px/s given to the target (default 0). |
| `kx`, `ky` | The knockback's direction when facing right (default 1, 0), multiplied as given: use a unit vector. `kx` is mirrored when the fighter faces left. |
| `away` | true: `kx` points away from the fighter's centre instead of along its facing (an explosion, a body that hurts on contact). |
| `hitstop` | Seconds both fighters freeze (default: the world's `default_hitstop`). |
| `global_hitstop` | Seconds the whole world freezes (default 0). |

### Once per activation

A hitbox hits a fighter at most once per activation, whatever the number of steps they overlap
and of hurtboxes the fighter has (the first one by id is the one in `hit.hurtbox`).
`hitbox:activate` empties the list; `hitbox:hasHit(fighter)` reads it. A hit that the target's
i-frames ignored is not in the list, so a hitbox that stays active (spikes) hits again when
they end; a hit that a modifier cancelled is.

### `world:step(dt)`

Once per fixed step, after the bodies moved and the state machines ran. It returns how many
hits landed (also `world.hit_count`):

1. Finds the overlaps (touching edges do not overlap) between active hitboxes and enabled
   hurtboxes of living fighters that `can_hit` allows.
2. Resolves them: hitbox by hitbox, and for each its hurtboxes, both in creation order.
3. Runs the timers: hitbox active time, i-frames, hitstop.

The search does not use bump: the hurtboxes are kept sorted by their left edge (an insertion
sort, cheap because they barely move between steps) and each hitbox looks only at the ones its
x range can reach. The order of the hits never depends on positions, on activation order or on
a hash table, so PC and console resolve the same hits in the same order. When two hitboxes
reach one target in the same step, the one created first lands and the target's i-frames stop
the other; a fighter killed earlier in the step no longer hits.

## Damage

One hit, in this order (`world:strike(attacker, target, spec)` runs the same for a hit without
boxes, such as a hazard or a poison tick: `spec` has the fields of a hitbox, `attacker` may be
nil, and there is no overlap, team or hit list check):

1. Nothing happens if the target is dead or has i-frames.
2. `hit.amount = hitbox.damage`, or the attacker's `attack_damage * hitbox.power`.
3. The attacker's modifiers hear `on_hit`.
4. The target's `defense` is subtracted (not below 0); the target's modifiers hear
   `on_damaged`. A handler that sets `hit.cancel = true` stops the hit here.
5. Health goes down by `hit.amount` (not below 0).
6. Knockback: `hit.knockback * (1 - knockback_resist)` along the direction. The result is in
   `hit.knock_x`, `hit.knock_y`; if the target's body has a `vx` it is set to `knock_x` (and
   `vy` to `knock_y` when `ky` is not 0), which is all a platformer body needs.
7. I-frames: `target.invuln = invuln_time`. Hitstop (below).
8. `target.on_hurt`. If the health is 0: `target.dead`, its hitboxes go off, its modifiers
   hear `on_death`, `target.on_death`, and the attacker's modifiers hear `on_kill`.
9. `world.on_hit(hit)`.

The `hit` record: `attacker`, `target`, `hitbox`, `hurtbox`, `base` (the amount of step 2),
`amount`, `knockback`, `knock_x`, `knock_y`, `cancel`, `killed`. It is reused by the next hit:
copy what you keep.

### Stats

`combat.stats.defaults`; `combat.stats.new(overrides)` returns a copy with the given values
(unknown names are an error); `combat.stats.resolve(source)` reads them all into a plain table.

| Name | Default | |
|---|---|---|
| `max_health` | 10 | Starting health; `heal` stops there. |
| `attack_damage` | 1 | The damage of a hit with `power` 1. |
| `defense` | 0 | Subtracted from every hit received. |
| `knockback_resist` | 0 | 0..1: the part of a knockback that is ignored. |
| `invuln_time` | 0.5 | Seconds of i-frames after being hurt. 0: none. |

### Modifiers

Stats are read through `fighter.stats:get(name)` on every hit, and a `combat.stats.new` table
is the `base` that `attach` takes, exactly as in the platformer module. Events use the names
`engine.modifiers` already declares; the context is the `hit` record:

| Event | Heard by | |
|---|---|---|
| `on_hit` | the attacker | Before the target's defense. A `chain` event on `amount`: the number a handler returns replaces `hit.amount`. |
| `on_damaged` | the target | After its defense; `chain` on `amount` too. `hit.cancel = true` cancels the hit. |
| `on_death` | the target | Not declared by the registry (returns are ignored). |
| `on_kill` | the attacker | |

Handlers may also change `hit.knockback`, and may call `world:strike` (thorns): the pipeline is
re-entrant.

```lua
mods:defineAll({
  { id = "sharp", stats = { { "attack_damage", "add", 2 } } },
  { id = "crit", events = { on_hit = function(owner, hit, m)
      m.state.n = (m.state.n or 0) + 1
      if m.state.n % 3 == 0 then return hit.amount * 2 end
    end } },
  { id = "shield", events = { on_damaged = function(owner, hit) hit.cancel = true end }, duration = 3 },
})
```

## I-frames, knockback, hitstop

**I-frames.** `fighter.invuln` seconds, set to the `invuln_time` stat by every hit that lands.
With 0.5 the next hit can land exactly 30 steps after the first.

**Knockback.** See step 6. With a body that has no velocity (a top-down game that moves by
hand) read `hit.knock_x`, `hit.knock_y` in `on_hurt`.

**Hitstop.** The module never freezes anything by itself: it keeps two counters and the game
asks. A hit raises `fighter.hitstop` of both fighters to the hitbox's `hitstop`, and
`world.hitstop` to its `global_hitstop`; `fighter:stop(t)` and `world:stop(t)` do it by hand
(they never shorten a freeze). `fighter:frozen()` is true while its own counter or the world's
runs; `world:frozen()` is the world's only. Skip the update of what is frozen (its controller,
its state machine, its animation) and keep calling `world:step(dt)`, which is what counts
them down: a hitstop of `n / 60` skips exactly `n` updates. While the world is frozen no
overlap is searched. A frozen fighter's i-frames and its hitboxes' active time do not run, so
a freeze does not eat them.

## State machines

`combat.fsm.new(def, owner)` returns a machine. `def` is data, shared by every machine made
from it:

```lua
local def = {
  initial = "idle",
  states = {
    idle = { transitions = { { to = "walk", after = 0.5 } } },
    walk = {
      enter = function(m, owner, previous) end,
      update = function(m, owner, dt) end,          -- may return a state name to go there
      exit = function(m, owner, next) end,
      transitions = { { to = "idle", when = function(m, owner) return owner.tired end } },
    },
  },
}
```

`m:update(dt)` once per fixed step: the state's `update`, then its `transitions` in order; the
first whose `after` (seconds in the state) has passed and whose `when` holds is taken (either
may be left out, not both). At most one change per step; it returns the new state's name.
`m:set(name)` changes now; `m:is(name)`. Fields: `m.state`, `m.previous`, `m.time` (seconds in
the state), `m.phase` (free for the state, cleared on every change), `m.changes`, `m.owner`.
Unknown states are an error when the machine is made.

## Behaviours

`combat.behaviours` has states to put in a definition. Each call returns a new state table;
add `transitions` to it. What one enemy needs is read from its agent (the machine's owner):

| | |
|---|---|
| `agent.body` | `x`, `y`, `w`, `h`, `facing`. Default: the agent itself. |
| `agent.target` | A body-like table, or nil. |
| `agent.patrol_points` | `{ { x =, y = }, ... }` for patrol. |
| `agent.hitboxes` | `{ name = hitbox }` for attack and charge. |
| `agent.attacks` | `{ name = combat.attacks Attack }` for shoot. |
| `agent.jump` | `true` for one step to press jump (hop). |
| `agent.jump_velocity` | Optional per-agent jump strength (hop writes it on enter). |
| `agent.anchor` | `{ x =, y = }` home point for a flyer (default: the body centre on enter). |
| `agent.rng` | An `engine.rng` stream: the only source of randomness. |

A state moves nothing. It writes what the agent wants: `agent.move_x`, `agent.move_y` (a
direction, each -1..1) and `agent.move_speed` (px/s), and turns `body.facing`. The game
applies it: `behaviours.move(agent, dt)` moves the body directly (no physics),
`behaviours.fly_move(agent, world, filter, dt)` moves it in a bump world, and
`behaviours.input(agent)` is an input to give to a platformer controller made with
`actions = { move_x = "move_x" }` (`agent.jump = true` presses jump; `pressed("jump")` is true
only on that step).

| | |
|---|---|
| `behaviours.patrol(opts)` | Walks from point to point and back. `points` (for every agent; default `agent.patrol_points`), `speed` (30), `axis` (`"x"`: only x matters; or `"xy"`), `reach` (1 px), `loop`, `pause` (seconds at each point: a number, or `{ min, max }` drawn from `agent.rng`), `blocked(agent)` (true at a wall or a ledge: it goes for the next point; one turn per block). |
| `behaviours.chase(opts)` | Goes for `agent.target`. `speed` (60), `axis`, `stop` (distance between centres at which it stands still, facing the target). |
| `behaviours.attack(opts)` | Stands still through `windup`, `active`, `recovery` (seconds; `m.phase` has the name), with `agent.hitboxes[opts.hitbox]` on during `active`, then goes to `next`. `face = false`: do not turn to the target first. Leaving the state early turns the hitbox off. |
| `behaviours.shoot(opts)` | Stands still and fires `volleys` (1) volleys of `agent.attacks[opts.attack]` `interval` (0.2) seconds apart, then goes to `next`. `aim`: `"facing"` (default: the config's own angle), `"target"` (at the target's centre each volley) or `"angle"` (`opts.angle` degrees above the facing); `rotate` (0) degrees more after each volley (a spiral). `windup` (0.3) and `recovery` (0.4) are the tell and the pause; `m.phase` is `"windup"`, `"firing"` or `"recovery"`. `face = false`: do not turn to the target first. A ranged config with `count = 8, spread = 315` is a ring; with `volleys = 6, rotate = 15` a spiral. The attack's own `cooldown` must not be longer than `interval` when there is more than one volley (an error at enter says so). |
| `behaviours.charge(opts)` | Winds up (`windup`, 0.4 s), dashes at the direction fixed at the end of the windup for at most `time` (0.6 s) or `distance` px at `speed` (140 px/s), then recovers (`recovery`, 0.3 s; `stun`, 0.8 s, if `blocked(agent)` stopped it), then goes to `next`. `hitbox` (optional): a name in `agent.hitboxes`, on only during the dash. `axis`: `"x"` (default) or `"xy"`. `m.phase`: `"windup"`, `"dash"`, `"recovery"`. |
| `behaviours.hop(opts)` | On the ground waits `wait` s (a number, or `{ min, max }` from `agent.rng`; default 0), sets `agent.jump = true` for one step, and moves `speed` (60) px/s towards the target (`toward = "target"`, default) or forwards (`"facing"`) until it lands. `grounded(agent)` (default `body.on_ground`) says where the ground is; `jump_velocity` is written to `agent.jump_velocity` on enter. Endless: leave it with transitions. |
| `behaviours.fly(opts)` | Moves a body without gravity (always `"xy"`). `mode = "hover"`: bobs around `agent.anchor` on a circle of `radius` (8) with `period` (2). `"follow"`: goes for the target, keeps `keep` (60) px away, backs off closer than `keep - band` (12) and bobs vertically by `bob` (4) px while holding. `"swoop"`: flies at the target's position taken on enter for at most `time` (1 s), then goes to `next`. `speed` (40); only `sin`/`cos` of numbers, so it is deterministic. |
| `behaviours.keep_away(opts)` | Kites the target: walks away closer than `min` (48), towards it farther than `max` (96), stands still (facing it) in between. `speed` (40), `axis` (`"x"` default, or `"xy"`). |
| `behaviours.target_within(range, axis)`, `target_beyond(range, axis)` | Conditions for `when`. No target counts as beyond. |
| `behaviours.target_in_sight(grid, range)` | The target is within `range` (straight line) and no `"solid"` tile of `grid` (`grid:kind(tx, ty)`, `grid.tile_size`) stands between their centres. |
| `behaviours.target_above(px)`, `target_below(px)` | The target's centre is more than `px` higher / lower. |
| `behaviours.grounded()` | `body.on_ground` is true. |
| `behaviours.health_below(fraction)` | `agent.fighter` is below `fraction` of the `max_health` stat. |
| `behaviours.all(...)`, `any(...)`, `negate(c)` | Combine conditions when the definition is built. |
| `behaviours.distance(agent, axis)` | Between the centres of the agent and its target; `math.huge` without one. |
| `behaviours.fly_move(agent, world, filter, dt)` | Moves `agent.body` by its wish with `world:move` (a bump world; passed in, nothing is required), keeps `body.px`, `body.py` to interpolate, and sets `body.wall` (-1, 0, 1), `body.ceiling` and `body.floor` from the collisions. |

```lua
local B = combat.behaviours
local brain = { initial = "patrol", states = {
  patrol = B.patrol({ speed = 30, pause = { 0.2, 0.6 }, blocked = function(a) return a.body.wall ~= 0 end }),
  chase = B.chase({ speed = 55, stop = 14 }),
  attack = B.attack({ hitbox = "bite", windup = 0.2, active = 0.1, recovery = 0.3, next = "chase" }),
} }
brain.states.patrol.transitions = { { to = "chase", when = B.target_within(80) } }
brain.states.chase.transitions = {
  { to = "attack", when = B.target_within(14) },
  { to = "patrol", when = B.target_beyond(120) },
}

local enemy = { body = body, target = player_body, patrol_points = { { x = 40 }, { x = 120 } },
  rng = streams:get("enemies") }
enemy.fighter = world:fighter({ body = body, team = "enemy" })
enemy.fighter:hurtbox({ w = 12, h = 12 })
enemy.hitboxes = { bite = enemy.fighter:hitbox({ ox = 12, w = 8, h = 12, knockback = 90 }) }
enemy.machine = combat.fsm.new(brain, enemy)

-- per fixed step
if not enemy.fighter:frozen() and not enemy.fighter.dead then
  enemy.machine:update(dt)
  B.move(enemy, dt)
end
world:step(dt)
```

## Brains as data

`combat.brains.build(spec, ctx)` turns a plain table into a `combat.fsm` definition. The
`spec` is pure data, so an enemy type can keep its brain in a table and a game can build the
same definition for every enemy of that type:

```lua
local brains = combat.brains
local def = brains.build({
  initial = "patrol",
  states = {
    patrol = { "patrol", speed = 22, pause = { 0.3, 0.9 } },
    chase  = { "chase", speed = 45, stop = 8 },
    shoot  = { "shoot", attack = "spit", aim = "target", volleys = 3, interval = 0.25,
               next = "chase" },
  },
  transitions = {
    patrol = { { to = "chase", when = { "target_within", 80, "xy" } } },
    chase  = { { to = "shoot", when = { "target_in_sight", 140 }, after = 1.0 },
               { to = "patrol", when = { "target_beyond", 160, "xy" } } },
  },
}, { grid = grid, blocked = function(agent) return agent.body.wall ~= 0 end })
local machine = combat.fsm.new(def, enemy)
```

A state entry is `{ behaviour_name, opts... }`: the rest of the table is copied (without `[1]`)
and given to the constructor of that behaviour, exactly like calling `behaviours.patrol(opts)`.
The name `"idle"` is a state that halts the agent.

A transition is `{ to = name, when = condition, after = seconds }` (`when` or `after`, at least
one). A condition is one of:

- `{ "name", args... }`, calling the registered condition with those positional arguments
- `{ "all", c1, c2, ... }`, `{ "any", ... }` or `{ "not", c }`
- a plain function `function(m, agent) -> boolean` (the escape hatch)

The built-in conditions are the ones in `behaviours`: `target_within`, `target_beyond`,
`target_in_sight` (range as its argument; the grid comes from `ctx.grid` or a third element),
`target_above`, `target_below`, `grounded` and `health_below`.

`ctx` is an optional table of values a behaviour or condition may need (`grid`, `blocked`,
`grounded`, `points`, ...). For a state, the fields of `ctx` are copied under the spec opts and
**the spec wins**; so `{ "patrol", speed = 22 }` with `ctx.blocked` gets the `blocked` function
while keeping its own speed. Conditions get `(args, ctx)`, with `args` being the condition spec
(`args[1]` is its name). `build` never changes `spec` or `ctx`.

A game extends the registry with its own behaviours and conditions:

```lua
brains.behaviour("spin", function(opts)
  local state = {}
  function state.update(_, agent) agent.spin_time = (agent.spin_time or 0) + opts.speed end
  return state
end)
brains.condition("health_under", function(args)
  local fraction = args[2]
  return function(_, agent)
    return agent.fighter.health / agent.fighter.stats:get("max_health") < fraction
  end
end)
```

`brains.behaviour(name, ctor)` takes `ctor(opts) -> state`; `brains.condition(name, ctor)` takes
`ctor(args, ctx) -> function(m, agent)`. They can replace a built-in name, and the registry is
global to the module (register a game's names once, before building).

`build` is called once per enemy type (never per enemy and never per frame), and the definition
it returns is shared by every machine of that type. It allocates only while building; the
compiled conditions and states allocate nothing per step. Unknown behaviours, unknown
conditions, an unknown initial state and a wrong field type are errors that name the brain state
and the field. An unknown target state is named by `combat.fsm` when the machine is made.

## Bosses

A boss uses the same behaviours as any enemy; `combat.boss` adds only what bosses have.

```lua
local def = combat.boss.build({
  name = "Big One",
  phases = {
    { at = 1.0, brain = { initial = "pick", states = {
        pick  = { "rotate", options = { { to = "spray", weight = 2 }, { to = "dash" } },
                  no_repeat = true, pause = 0.6 },
        spray = { "shoot", attack = "ring", volleys = 3, interval = 0.3, windup = 0.5, next = "pick" },
        dash  = { "charge", speed = 160, windup = 0.6, next = "pick" },
    } } },
    { at = 0.5, brain = { ... }, transition = { time = 1.2, invulnerable = true } },
  },
}, { grid = grid })                            -- ctx for combat.brains.build
local b = combat.boss.new(def, agent, { on_phase = function(b, index) end })
b:update(dt)                                   -- once per fixed step, instead of a fsm update
```

| Field / call | Meaning |
|---|---|
| `phases[i].at` | Health fraction where the phase starts: 1 for the first, then strictly lower. |
| `phases[i].brain` | A `combat.brains` spec, built once by `build`. |
| `phases[i].transition` | `{ time, invulnerable }`: the boss halts `time` seconds before the phase's brain starts; `invulnerable` sets `fighter.invuln` for that time. |
| `spec.bar` | `{ down = 1.5, up = 0.5 }`: how fast `b.bar` follows the health (units per second). |
| `b.phase` | Current phase. One hit past several thresholds goes straight to the lowest one (one `on_phase` call). |
| `b.bar` | Displayed health fraction 0..1, eased towards the real one. The game draws the bar. |
| `b.telegraph`, `b.telegraph_t` | The state being wound up (`m.phase == "windup"` of `attack`, `shoot` or `charge`) and its progress 0..1 (from the state's `windup`, or the behaviour's default), else `nil` and 0. |
| `b.transitioning` | True during a phase change. |
| `b:state()` | The current brain state's name (`nil` during a transition). |
| `b:enter_phase(i)` | Go to a phase now (scripted phases). |
| `opts.on_phase(b, i)` | Called when a later phase begins (start of its transition). |

The behaviour `rotate` (in `combat.behaviours`, registered in `combat.brains`, usable by any
enemy) picks the next attack: it stands still facing the target for `pause` seconds (a number or
`{ min, max }` from `agent.rng`), then goes to one of `options` (`{ to, weight }`), `order =
"random"` (weighted draw with `agent.rng`, default) or `"cycle"`; `no_repeat = true` never takes
the same option twice in a row. `agent.rotate_last` keeps the last index. An option naming an
unknown state is an error when the brain is built. Each attack state ends with `next = "<the
rotate state>"`, so a phase loops: pick, tell, attack, recover, pick.

The director allocates nothing per step; the machine of a later phase is made once, when that
phase first starts. It draws nothing and reads the health from `agent.fighter` (its stats'
`max_health`).

## Attacks as data

`combat.attacks` turns a plain config table into an attack a fighter can trigger, on top of a
combat world. The three kinds share one config shape, so a game keeps its attacks as data
(a Lua table per weapon, an item that swaps a config, a modifier that edits a field) and the
module knows nothing about what they are for.

```lua
local arsenal = combat.attacks.new(world, { grid = grid })   -- walls for shots and bombs
local slash = arsenal:equip(hero, {
  kind = "melee", cooldown = 0.35, windup = 2 / 60, active = 0.15, damage = 1, knockback = 150,
  boxes = { { ox = 2, oy = -16, w = 12, h = 10 }, { ox = 7, oy = -7, w = 14, h = 14 } },
})
local gun = arsenal:equip(hero, { kind = "ranged", speed = 220, life = 0.9, damage = 1 })
local bomb = arsenal:equip(hero, { kind = "explosive", radius = 28, fuse = 0.8, damage = 2,
  knockback = 220, throw = { speed = 160, angle = 20, contact = true } })

function play:update(dt)                       -- the fixed step
  body:step(engine.controls, dt)               -- move first
  if engine.controls:pressed("attack") then gun:trigger() end
  arsenal:step(dt)                             -- then the attacks
  world:step(dt)                               -- then the hits
end
```

`combat.attacks.new(world, opts)`: `grid` (anything with `width`, `height`, `tile_size` and
`kind(tx, ty)`, such as a `platformer.grid`; only `"solid"` tiles stop shots and bombs) or
`solid(x, y)` (a function instead), `max_projectiles` (default 64), `max_blasts` (default 16),
`on_blast(blast)`. Then:

| | |
|---|---|
| `arsenal:equip(fighter, config)` | Returns an attack. The config is checked and copied (`attacks.define`). |
| `attack:trigger(ax, ay)` | Starts it if `attack:ready()` (idle, cooldown over, fighter alive). `ax, ay`: a direction for shots and thrown bombs instead of the facing one. Returns true if it started. |
| `attack:cancel()` | Puts it away; the cooldown keeps running. |
| `attack.phase`, `attack.cool`, `attack.uses`, `attack.burst_left`, `attack.name` | `"idle"`, `"windup"` or `"active"`; seconds of cooldown left; triggers that fired; volleys still to fire of a burst; the config's `name` (default: its kind). |
| `arsenal:step(dt)` | Once per fixed step, after the bodies moved and before `world:step`. Nothing of a frozen fighter (hitstop) runs. |
| `arsenal.projectiles`, `arsenal.blasts` | Pools to draw from: read `p.alive`, `p.kind` (`"shot"` or `"bomb"`), `p.w`, `p.h`, `p.life`; `b.alive`, `b.x`, `b.y`, `b.radius`, `b.t`, `b.time`, `b.hits`. |
| `attacks.position(p, alpha)` | A projectile's top left corner between the last two steps, rounded to the pixel grid. |
| `arsenal:clear()`, `arsenal:count()`, `arsenal:unequip(attack)` | Everything put away; shots and bombs in flight; one attack taken away. |
| `attacks.define(config)` | The checked copy with every default; an unknown kind or field, or a wrong type, is an error that names it. |

Every config has `kind` (`"melee"`, `"ranged"` or `"explosive"`), `name`, `cooldown` (s from a
trigger to the next, default 0.3), `windup` (s from the trigger to the hit, the shot or the
throw, default 0), and the fields of a hit: `damage` or `power`, `knockback`, `kx`, `ky`,
`away`, `hitstop`, `global_hitstop` (see the hitbox options above). Offsets are from the body's
centre when it faces right (+x in front, y down) and are mirrored when it faces left, so they
hold when a soft body changes size.

| Kind | Fields (default) |
|---|---|
| `melee` | `boxes` (`{ { ox, oy, w, h }, ... }`, at least one; `ox, oy` is the box's top left corner) and `active` (0.1 s). One hitbox walks through the boxes in equal slices of `active`: one box is a stab, three around the front are an arc, one big box around the body is an area. It hits each fighter once per trigger. |
| `ranged` | `count` (1) shots per volley in a fan `spread` degrees wide (0), `gap` px apart across the aim line (0; with `count > 1`, `gap > 0` and `spread == 0` the shots fly parallel, centred on the aim; `gap` and `spread` combine), at `angle` degrees above the facing (0), `speed` (200 px/s), `gravity` (0 px/s²), `life` (1 s), `w`, `h` (4), from `ox, oy` (their centre), `pierce` (1 fighter), `walls` (`"stop"` or `"pass"`), `burst` (1: volleys per trigger), `burst_interval` (0.06 s between two volleys). A shot is a fighter of its own with the owner's team, stats and modifiers, so `power`, `on_hit` events and team rules read as the owner's. |
| `explosive` | A bomb (`w`, `h`, 4; from `ox, oy`) that blows `fuse` s (0.5) after it is placed or thrown: every fighter whose hurtbox is within `radius` (24 px) is struck once, the damage and the knockback lessened by `falloff` (0.5: half at the edge; damage is rounded, at least 1), pushed away from the centre with `lift` (0) added upwards. `self` (false): it may hurt its owner. `blast_time` (0.2 s): how long the blast stays in `arsenal.blasts`. `throw` (none: it stays where it was placed): `speed` (150), `angle` (30), `gravity` (500), `bounce` (0.4, speed kept off a wall, floor or ceiling), `friction` (0.8, horizontal speed kept on a floor bounce), `contact` (false: true blows it on touching a fighter it may hit). |

A burst fires `burst` volleys of `count` shots, `burst_interval` seconds apart. Every volley
keeps the aim the trigger had (`aim_x, aim_y`, or the facing at the trigger) and reads the
fighter's position again, so it follows a moving fighter. The cooldown starts at the trigger as
usual (a burst longer than the cooldown is allowed); the next trigger or `attack:cancel()` stops
the remaining volleys. `max_projectiles` still caps everything, as for single shots.

Times run in fixed steps like the rest of the module: a windup of `n / 60` fires `n` steps
after the trigger's step, `active = n / 60` is `n` world steps, and a fuse or a shot's life
starts on the step after the one it was born in (a fuse of 0 blows at once). A blast uses
`world:strike`, so i-frames still protect, `can_hit` decides who is a target (the owner only
with `self`), and walls do not shield (a game that wants that filters in its `can_hit` or adds
its own check). Example configs: `examples/rooms/rooms_attacks.lua`. Tests:
`tests/engine/attacks_test.lua`.

## On the console

Plain Lua 5.1: no FFI, no `goto`, nothing from `love`, no `math.random`, no clock.
`world:step`, `activate`, the machine, the behaviours and `arsenal:step` / `attack:trigger` create
no tables once the world's lists and the arsenal's pools have grown to the size the fight needs (they grow when more boxes overlap at once than
ever before). The search is near linear in the number of hurtboxes plus the overlaps found.
