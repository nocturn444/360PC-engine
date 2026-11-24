# Ability mutations plan: movement abilities, shot modifiers, bombs as consumables, Isaac-style HUD

Status: plan. Step 1 (engine) ready to build; step 2 (game) has the owner's answers (end of file). Branch `claude/project-thread-j7uxll`, stacked on PR #87
(`claude/project-thread-2yza81`, modular enemy AI), because both change `rooms_enemies.lua`.

Requested by the owner on 2026-11-24: mutations that give special abilities instead of only stats
(double jump, wall jump, grappling hook, dash, free aim shot, double shot, burst). By default the
Blob only has the shot and the melee attack. Bombs become consumables. The screen shows the stats
and the consumable counts, like The Binding of Isaac.

Read `AGENTS.md` first. Hard rules that matter most here: engine/module code knows nothing about
the game; plain Lua 5.1; **no per-frame allocation** in update and draw paths; randomness only
through `engine.rng` streams; only the console's LOVE subset (no mouse on the console: the
`love.mouse` stub returns the screen centre); 30 FPS on the console.

## Today

- `examples/rooms/rooms_mutations.lua`: three example mutations, each changes one stat
  (`rooms_stats.lua`, `engine.modifiers`) and the look (`rooms_look.lua`).
- `examples/rooms/rooms_attacks.lua`: three slime attacks (melee, ranged, explosive). The Y button
  (`switch`) cycles them, X (`attack`) fires the current one (`Fight:attack`, `Fight:switch` in
  `rooms_enemies.lua`). Bombs are unlimited.
- `engine/modules/combat/attacks.lua`: ranged configs already have `count`, `spread` (a fan) and
  `Attack:trigger(ax, ay)` aims a shot at any direction. No parallel shots, no burst.
- `engine/modules/softbody`: `Body:on_ground()`, `Body:on_wall()` (no side), `impulse`, `push`,
  `set_velocity`, `velocity`, `center`, `bounds`.
- `examples/rooms/rooms_vines.lua`: a pendulum the slime grabs (a good reference for the hook's
  swing feel).
- Movement lives in `control()` in `rooms_play.lua`: ground jump, charged jump (hold down), push.
- HUD: four text lines top-left (`HP`, `VIRUS`, `SH ... LUCK`, `FLOOR`), minimap top-right, FPS and
  version bottom-left.
- `engine/modules/wallet`: named integer currencies (`virus`, `bonus_key`).
- `rooms_shop.lua`: sells mutations and consumables, prices by `kind`.

## Design

Three layers, each usable without the next:

1. **Engine, generic** (`engine/modules/abilities`, small additions to `softbody` and
   `combat.attacks`): movement abilities that act on any body through a small adapter, as data,
   with a registry of kinds a game can extend.
2. **Game data** (`examples/rooms/`): mutations that carry an `ability` (movement) or a `shot`
   fragment (attack modifiers); bombs as a wallet currency; controls in `main.lua`.
3. **HUD** (`examples/rooms/rooms_hud.lua`): Isaac-style left column.

Adding a new ability later = one mutation entry with an `ability` table of an existing kind, or
one new kind registered with `abilities.kind(name, handlers)`.

## Step 1: engine (one opencode run)

### 1a. `softbody`: which side the wall is on

`Body:wall_side()` -> `-1` (a wall on the left touches the body), `1` (on the right), `0` (none).
Count left and right wall contacts separately in `collide`/`step` (`self.wall_left`,
`self.wall_right`, numbers, no tables). `on_wall()` keeps working (`wall_left + wall_right > 0`).
Contact "wall" from `side == "left"` of a tile means the tile is to the RIGHT of the point (the
point was pushed to `left - EPS`): get the sign right and test it.

### 1b. `combat.attacks`: parallel shots and bursts (ranged only)

New ranged fields, validated like the others, defaults keep today's behaviour:

| Field | Default | Meaning |
|---|---|---|
| `gap` | `0` | px between parallel shots, perpendicular to the aim. With `count > 1`, `gap > 0` and `spread == 0` the shots fly parallel, centred on the aim line. `gap` and `spread` can be combined. |
| `burst` | `1` | volleys per trigger. Each volley fires `count` shots. |
| `burst_interval` | `0.06` | s between two volleys of a burst. |

- A burst keeps the aim it was triggered with (`aim_x`, `aim_y`, or the facing if none) for all
  its volleys; the shooter's position is read again at each volley (it moves with the fighter).
- State per attack in plain number fields (`burst_left`, `burst_timer`), no tables per trigger.
  `Attack:cancel()` stops the remaining volleys. The cooldown starts at the trigger as today
  (a burst longer than the cooldown is allowed; the next trigger cancels the rest of the old
  burst).
- `max_projectiles` still caps everything (shots beyond it are dropped, as today).
- Tests in `tests/engine/` (existing combat attacks test file or a new one, registered in
  `tests/engine/run.lua`): parallel positions, burst timing and count, cancel, no allocation
  while a burst runs (same `collectgarbage("count")` style the other tests use).
- Document the fields in `engine/modules/combat/README.md` ("Attacks as data").

### 1c. New genre module `engine/modules/abilities`

Generic movement abilities for any body. It needs no other module and knows nothing about a game.

```lua
local abilities = require("engine.modules.abilities")

-- body: an adapter with these methods (softbody.Body fits directly once 1a is done;
-- a platformer controller can be wrapped):
--   on_ground() -> bool, wall_side() -> -1|0|1, center() -> x, y,
--   velocity() -> vx, vy, set_velocity(vx|nil, vy|nil), impulse(vx, vy)
-- opts.solid(x, y) -> true if that world pixel is solid (the hook needs it);
-- or opts.grid (tile_size + kind(tx, ty)) like combat.attacks.
local set = abilities.new(body, { solid = ..., grid = ... })

set:grant(def)        -- def is data (below); granting the same id again adds one stack
set:revoke(id)
set:has(id) -> bool ; set:get(id) -> the live ability (read-only for the game: state, timers)
set:stacks(id) -> n
set:step(dt, intent)  -- once per fixed step, BEFORE body:step
set:reset()           -- drop transient state (on room change): hook released, dash stopped
set:state() / set:set_state(t)   -- granted ids and stacks, plain data, for a run save

abilities.kind(name, handlers)   -- register a kind (built-ins below use the same call)
```

`intent` is ONE table the game owns and refills every step (never a new table):

```lua
intent = {
  move_x = 0, move_y = 0,        -- -1..1 (left stick / keys)
  jump = false,                  -- jump pressed this step
  jump_held = false,             -- jump button down
  dash = false, hook = false,    -- pressed this step
  jump_speed = 260,              -- the game's current jump impulse (stats applied)
  consumed_jump = false,         -- set by the set when an ability used the jump press
}
```

The game does its own ground jump first; `set:step` only looks at `intent.jump` when the body is
not on the ground (or is hooked). Kinds are tried in `priority` order (lower first); the first
that uses the jump sets `intent.consumed_jump = true` and the rest ignore it.

Definition fields common to every kind: `id` (string, unique), `kind` (registered name),
`priority` (number, default per kind). Unknown fields or wrong types are errors that name the
field (same style as `combat.attacks.define`).

Built-in kinds (tunable numbers are defaults; the game data can override each):

| Kind | Fields | Behaviour |
|---|---|---|
| `air_jump` | `count = 1` (per stack), `power = 1.0` | Jump pressed in the air: vertical velocity set to `-jump_speed * power` (not added). Uses refill on landing, on a wall jump and when the hook releases. priority 30 |
| `wall_jump` | `kick_x = 180`, `power = 1.0`, `slide_speed = 60`, `lock = 0.15` | In the air touching a wall (`wall_side() ~= 0`): jump sets velocity `(-side * kick_x, -jump_speed * power)`; for `lock` s after, `move_x` toward the wall is ignored (so the kick is not cancelled). While pushing into the wall and falling, vertical speed is capped at `slide_speed` (0 disables). priority 10 |
| `dash` | `speed = 330`, `time = 0.14`, `cooldown = 0.45`, `air_uses = 1` (per stack), `dirs = 8`, `trigger = "button"` or `"double_tap"`, `tap_window = 0.25`, `tap_threshold = 0.5` | With `trigger = "double_tap"` the set itself detects two taps of `move_x` in the same direction within `tap_window` s (a tap = `|move_x|` crossing `tap_threshold` from below; analog stick and keys alike; number fields only) and dashes horizontally that way; otherwise `intent.dash`: direction from `move_x, move_y` (snapped to 8 or 4 dirs; none held: facing, which the game passes as `intent.facing`). For `time` s the velocity is held at `dir * speed` every step (gravity cancelled). Ends early on hitting a wall in its direction. `air_uses` refills on landing. Exposes `active` (bool) and `dir_x`, `dir_y` so the game can draw a trail or give i-frames. priority n/a |
| `hook` | `range = 112`, `speed = 420` (hook flight px/s), `angle = 55` (degrees above horizontal, toward facing; `move_y < 0` held: straight up), `reel = 60` (px/s with up/down), `min_length = 16`, `pump = 260` (px/s^2 with left/right while swinging), `release_boost = 1.0` | `intent.hook` fires the hook: a point that flies until it hits `solid` (attach), or passes `range` (miss, comes back). While attached, a rope constraint each step: if the body centre is farther than `length` from the anchor, remove the outward part of the velocity and move it back onto the circle (through `set_velocity`/`impulse`, never by moving points directly); gravity makes the swing. `move_y` reels in/out, `move_x` pumps. Releases on `intent.hook` again, on jump (keeps the swing velocity, times `release_boost`, plus a small upward kick `-jump_speed * 0.5`, `consumed_jump`), or on `set:reset()`. Exposes `phase` (`"idle"`, `"flying"`, `"attached"`), `hx`, `hy` (hook point), `length`, for the game to draw the rope. priority 5 |

Raycasting for the hook: step along the segment in 2 px increments with `solid(x, y)`; no tables.
All live state is number/boolean fields on the ability object created at `grant`.

Tests `tests/engine/abilities_test.lua` (fake body table with the adapter methods, plus one test
with a real `softbody` on a `platformer.grid`): each kind's trigger and refill rules, priority
(wall jump before air jump; hook release uses the jump), stacks, validation errors, `reset`,
`state`/`set_state` round trip, and **no allocation** in `step` over a few hundred steps with all
kinds granted. Register in `tests/engine/run.lua`. README `engine/modules/abilities/README.md`,
row in `engine/modules/README.md`, section in `docs/ENGINE.md`, `CHANGELOG.md` under
`[Unreleased]`.

## Step 2: game (one opencode run, after the owner's answers)

### Controls (`examples/rooms/main.lua`), confirmed by the owner 2026-11-24

| Action | Pad | Keyboard / mouse (PC) |
|---|---|---|
| `jump` | A | space, up, w |
| `shoot` | RT (`triggerright+`) | x, j |
| `melee` | Y | c, k |
| `interact` | B | e, f |
| `bomb` | RB | v, l |
| `dash` | double tap left or right (stick or d-pad) | double tap left or right key |
| `hook` | LB | q |
| axes `aim_x`, `aim_y` | right stick (`rightx`, `righty`) | mouse position relative to the slime |
| `aim_fire` (PC) | n/a | mouse button 1 |
| `pause` | Start | escape, p |

`switch` and `attack` go away. `move_y` axis from the left stick (`lefty`) and up/down for the dash
and the hook.

### Attacks and bombs

- `rooms_attacks.lua`: `melee`, `ranged`, `bomb` (today's explosive config renamed). The slime
  equips all three; `Fight:attack`, `Fight:switch`, `Fight.mode` are replaced by
  `Fight:shoot(ax, ay)`, `Fight:melee()`, `Fight:bomb()` (the game checks and spends the bomb
  before calling it). Keep the statues working (`TURRET_ATTACKS` reads `ranged` and `bomb`).
- Bombs: a wallet currency `bomb`, the run starts with 1 (confirmed), max 99. `rooms_pickups.lua`
  gets `M.bomb(x, y, amount)`; `rooms_consumables.lua` a `bomb` entry (sources `mob`,
  `room_clear`, `obstacle`, weight like the heart's); `rooms_shop.lua` price `bomb = 5`; the
  room template pickups accept kind `bomb`. Breaking props with the attack keeps working with
  melee and shots.

### Ability mutations (`rooms_mutations.lua`)

Seven new entries, `unique = true`, `rarity = "rare"`, sources treasure/boss/shop, placeholder
names (the owner names them later), a look (limbs/colour) like the existing examples, and either:

- `ability = { kind = ..., ... }` (granted to the run's `abilities` set on acquire), or
- `shot = { count = +1, gap = 4 }` / `shot = { burst = +2 }` / `shot = { aim = "free" }`: the
  game keeps the slime's base ranged config, adds every acquired `shot` fragment in order
  (numbers add, `aim` overrides) and re-equips the ranged attack with
  `combat.attacks.define` only when a mutation is acquired (never per frame).

| id | Placeholder name | Data |
|---|---|---|
| `ability_double_jump` | TWIN HOP | `ability = { kind = "air_jump", id = "double_jump" }` |
| `ability_wall_jump` | STICKY SOLES | `ability = { kind = "wall_jump", id = "wall_jump" }` |
| `ability_hook` | TONGUE HOOK | `ability = { kind = "hook", id = "hook" }` |
| `ability_dash` | BURST SAC | `ability = { kind = "dash", id = "dash" }` |
| `shot_free_aim` | WANDERING EYE | `shot = { aim = "free" }` |
| `shot_double` | SPLIT GLAND | `shot = { count = 1, gap = 4 }` |
| `shot_burst` | RAPID SPORES | `shot = { burst = 2, burst_interval = 0.06 }` |

Tags: `mobility` for the four movement ones, `shot` for the three shot ones (for synergy rules).
They must work with the soft body: the abilities set is created with the slime as its body.
Room change: `set:reset()` in `load_room`. New run: a new set. The vines and the hook must not
fight: grabbing a vine releases the hook.

Free aim: with `aim = "free"`, RT fires toward the right stick when it is past the deadzone,
and toward the facing when it is centred. Holding RT keeps firing whenever the attack is ready. On PC with keyboard, the
mouse aims (screen to game with `engine.pixel`'s `toGame`, plus the camera offset) and mouse
button 1 fires. Without the mutation, the right stick does nothing.

### HUD (`examples/rooms/rooms_hud.lua`), Isaac-style, top-left column

```
[hearts]  HP as small heart icons (current/max), shield as small blue pips after them
[virus]   12
[bomb]    1
[key+]    0
--
[spd]  1.00     stats with an icon (8x8 placeholder, drawn with rectangles or the
[jmp]  1.20     placeholder art sheet if rooms_art has one), 2 decimals for multipliers,
[dmg]  1        integers for flat stats
[lck]  5
```

- Floor and biome: small, top centre (or under the minimap). `GOT <name>` and messages stay
  bottom-centre. FPS and version stay bottom-left. Minimap stays top-right.
- No per-frame string building: cache each value's text and rebuild it only when the number
  changes (like the FPS text today).
- Readable at 320x180 on a TV: use `engine.text` at scale 1, values aligned in a column.

### Tests and docs

`tests/pc/rooms_example_test.lua`: acquiring each ability mutation grants it; a bomb is spent per
throw and none is thrown at 0; double shot + burst give 2 x 3 shots; the HUD draws without errors.
Update `examples/rooms/README.md`, `examples/rooms/docs/CONTENT.md` (new mutation fields),
`CHANGELOG.md`, and bump `examples/rooms/rooms_version.lua` when it goes to `test-build`.

## Owner decisions (2026-11-24)

1. Pad mapping above: shoot on RT, bomb on RB. The dash has no button: it fires on a double tap
   of left or right (stick or d-pad on the pad, the direction keys on PC).
2. The dash makes the slime invulnerable while `active`, and has a cooldown: the game sets the
   player fighter's i-frames for the dash `time` (no blink) when it starts.
3. A run starts with 1 bomb.
4. Ability mutations are in the same pools as the stat ones (the unlock system of PR #90 can gate
   some later).
5. HUD layout above (no objection).
