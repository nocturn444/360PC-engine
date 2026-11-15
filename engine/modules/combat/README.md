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
| `init.lua` | `require("engine.modules.combat")`: `{ stats, world, fsm, behaviours }`. |
| `stats.lua` | The combat stats and their defaults. |
| `world.lua` | Fighters, hitboxes, hurtboxes, the overlap search, the damage pipeline, i-frames, knockback, hitstop. |
| `fsm.lua` | A state machine: states with enter / update / exit, transitions, time in the state. |
| `behaviours.lua` | States for enemies: patrol, chase, attack. |

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
| `agent.hitboxes` | `{ name = hitbox }` for attack. |
| `agent.rng` | An `engine.rng` stream: the only source of randomness. |

A state moves nothing. It writes what the agent wants: `agent.move_x`, `agent.move_y` (a
direction, each -1..1) and `agent.move_speed` (px/s), and turns `body.facing`. The game
applies it: `behaviours.move(agent, dt)` moves the body directly (no physics), and
`behaviours.input(agent)` is an input to give to a platformer controller made with
`actions = { move_x = "move_x" }` (`agent.jump = true` presses jump).

| | |
|---|---|
| `behaviours.patrol(opts)` | Walks from point to point and back. `points` (for every agent; default `agent.patrol_points`), `speed` (30), `axis` (`"x"`: only x matters; or `"xy"`), `reach` (1 px), `loop`, `pause` (seconds at each point: a number, or `{ min, max }` drawn from `agent.rng`), `blocked(agent)` (true at a wall or a ledge: it goes for the next point; one turn per block). |
| `behaviours.chase(opts)` | Goes for `agent.target`. `speed` (60), `axis`, `stop` (distance between centres at which it stands still, facing the target). |
| `behaviours.attack(opts)` | Stands still through `windup`, `active`, `recovery` (seconds; `m.phase` has the name), with `agent.hitboxes[opts.hitbox]` on during `active`, then goes to `next`. `face = false`: do not turn to the target first. Leaving the state early turns the hitbox off. |
| `behaviours.target_within(range, axis)`, `target_beyond(range, axis)` | Conditions for `when`. No target counts as beyond. |
| `behaviours.distance(agent, axis)` | Between the centres of the agent and its target; `math.huge` without one. |

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

## On the console

Plain Lua 5.1: no FFI, no `goto`, nothing from `love`, no `math.random`, no clock.
`world:step`, `activate`, the machine and the behaviours create no tables once the world's
lists have grown to the size the fight needs (they grow when more boxes overlap at once than
ever before). The search is near linear in the number of hurtboxes plus the overlaps found.
