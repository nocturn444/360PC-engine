# Final boss and unlocks (plan)

Status: steps 1, 2 and 3 done; step 4 in progress.

The owner asked for two things:

1. A **final boss** (placeholder) whose choice depends on the run or on earlier progress.
2. **Unlockable content**: any content (a mutation, a biome, a final boss, later items) can be
   locked behind a trigger: win a challenge, earn an achievement, kill N enemies (of a type),
   get a build (a combination of items), or abstain from something during a run (no hearts
   picked, no damage taken...).

Both are rules over the same data (what the profile has, what the run did), so they share one
generic condition evaluator. Everything game specific is data in `examples/rooms`; the engine
part knows nothing about Blob.

What already exists and is reused: `items.pool` and `procgen.biomes` already hide entries whose
`unlock = "<tag>"` is not in their `unlocked` set. So the unlock system only has to **produce
tags** and persist them; locked content is declared with the existing `unlock` field.

Four steps, each a commit on this branch:

1. **Engine:** `engine/modules/progress/` (conditions, run counters, rules, pick), tests, docs.
2. **Game, unlocks and achievements:** `rooms_progress.lua` (achievements, unlock rules, run
   counters hooked into play), profile fields, Progress pages, unlock notices. Needs the
   profile of PR #88.
3. **Engine, boss director:** `engine/modules/combat/boss.lua`: phases by health, attack
   rotation with telegraphs, health bar values. Reuses the behaviours and brains of PR #87
   (merged into this branch first); no behaviour code is duplicated.
4. **Game, final boss:** `rooms_final_bosses.lua`, chosen on the last floor and driven by the
   boss director, hooked into the victory of PR #88 and the ending pick of PR #89.

## 1. Engine: `engine/modules/progress/`

A genre module (`require("engine.modules.progress")`), plain Lua 5.1, console LOVE subset only
(it uses no LOVE at all), no `math.random`. It needs no other module. Allocation: building
rules may allocate; `counters:add`, `counters:set`, `counters:has` and `conditions.test` must not
allocate (they run on kills and pickups). `rules:check` may allocate only the array it returns,
and only when something new was earned (return a shared empty table otherwise).

### `progress.counters`: what a run (or a floor) did

```lua
local run = progress.counters.new()
run:add("kills", 1)              -- numbers (missing = 0)
run:add("kills:shooter", 1)      -- any string key; the game picks the names
run:set("floor", 3)
run:mark("items", "spring_heel") -- named sets: items held, rooms visited, ...
run:has("items", "spring_heel")  -- -> boolean
run:count("items")               -- size of a set
run:get("kills")                 -- -> number
run:reset()                      -- new run (keeps the tables, clears them)
run:state() / run:set_state(t)   -- plain tables, for a run save
```

`mark` on a set that does not exist yet creates it (allocation is fine the first time). A run
usually keeps two: `run` (whole run) and `floor` (reset by the game when a floor starts).

### `progress.conditions`: rules as data

A condition is a plain table whose first array item is its kind. Validated by
`conditions.compile(c)` (raises an error naming the path, e.g. `when[2].at_least: a number`).

| Kind | Fields | True when |
|---|---|---|
| `all` | array of conditions | every one is true |
| `any` | array of conditions | at least one is true |
| `none` | array of conditions | none is true |
| `count` | `key`, `scope` (`"run"`, `"floor"`, `"profile"`; default `"run"`), `at_least`, `at_most` (one or both) | the counter is in range. Abstaining is `at_most = 0` |
| `has` | `set`, `id`, `scope` (default `"profile"`) | the set has the id (achievements, challenges won, endings seen, unlocks) |
| `build` | `all` (ids), `any` (ids), `at_least` (how many of `any`, default 1), `set` (default `"items"`), `scope` (default `"run"`) | the run's set holds that combination |
| `size` | `set`, `scope`, `at_least`, `at_most` | the set's size is in range (e.g. 5 mutations) |
| `result` | `value` (`"win"`, `"loss"`) | `ctx.result` equals it |
| `test` | `name` | the game's predicate `opts.tests[name](ctx)` returns true (escape hatch; registered by name so the data stays plain) |

`ctx` passed to `test` / `check`: `{ run = counters, floor = counters, profile = <table>,
result = "win" | "loss" | nil }`. `scope = "profile"` reads `ctx.profile.counters[key]` for
`count` and `ctx.profile[set][id]` for `has` / `size`. Missing values count as 0 / absent, never
an error at run time.

### `progress.rules`: achievements and unlocks

```lua
local rules = progress.rules.new(list, { tests = { ... } })
local earned = rules:check(moment, ctx, profile_set)   -- array of newly earned rules
rules:is_earned(id, profile_set)
```

A rule:

| Field | Meaning |
|---|---|
| `id` | unique string; for an unlock it is the **tag** that content declares with `unlock = id` |
| `when` | a condition (above) |
| `at` | when it is checked: `"event"` (after any tracked event: kill, pickup, item taken), `"floor_end"`, `"run_end"` (default). Abstain rules use `"floor_end"` or `"run_end"`, never `"event"`, so "no damage" is only true once the floor or run is over |
| `requires` | optional array of rule ids that must already be earned (chains) |
| `hidden` | the Progress page shows "???" until earned |
| anything else | the game's (name, description, what it unlocks for the UI, icon) |

`check(moment, ctx, set)` tests every rule with that `at` (and every `"event"` rule at
`"floor_end"` / `"run_end"` too) that is not in `set`, writes `set[id] = true` for the ones that
pass and returns them in list order. The game passes `profile.achievements` for one rule list
and `profile.unlocks` for another. Deterministic: list order, no randomness.

### `progress.pick`: choose one entry by conditions

```lua
local e = progress.pick(list, ctx, rng, opts)   -- rng: an engine.rng stream
```

Each entry may have `when` (condition), `priority` (number, default 0) and `weight` (default 1).
Entries whose `when` fails are skipped; among the rest only the highest `priority` counts; a
weighted draw with `rng` breaks ties. Returns nil if nothing matches. Same rng state and ctx give
the same pick on PC and console. Used for the final boss and reusable for anything else
(special rooms, endings).

### Docs and tests

- `engine/modules/progress/README.md`, a row in `engine/modules/README.md`, a section in
  `docs/ENGINE.md`, `CHANGELOG.md` under `[Unreleased]` / Added.
- `tests/engine/progress_test.lua`, registered in `tests/engine/run.lua`: every condition kind
  true and false; scopes; missing values; compile errors name the path; `requires` chains;
  `at` moments (an abstain rule is not earned at `"event"`); `check` returns only new rules and
  writes the set; `pick` priority, weights, determinism with a fixed seed, nil when nothing
  matches; counters state roundtrip; no allocation in `add` / `set` / `mark` (existing set) /
  `has` / `conditions.test` over many calls (`collectgarbage("count")` check like other tests).

## 2. Game: achievements and unlocks (`examples/rooms`)

Depends on the profile of PR #88 (`rooms_profile.lua`).

### `rooms_progress.lua`

- `M.achievements`: rule list (placeholders, English names, owner to replace):
  - `first_win` "First Victory": `{ "result", value = "win" }`.
  - `exterminator` "Exterminator": `{ "count", key = "kills", scope = "profile", at_least = 200 }`, `at = "event"`.
  - `untouchable` "Untouchable": a floor with no damage, `{ "count", key = "damage", scope = "floor", at_most = 0 }`, `at = "floor_end"`.
  - `heartless` "Heartless": win without picking up a heart, `{ "all", { "result", value = "win" }, { "count", key = "hearts", at_most = 0 } }`.
  - `spring_build` "Bouncy Build": hold both example mutations, `{ "build", all = { "example_spring_heel", "<second example id>" } }`, `at = "event"`.
- `M.unlocks`: rule list; each names what it opens for the UI (`gives = { kind = "mutation" | "biome" | "final_boss", id = ... }`):
  - a new placeholder mutation in `rooms_mutations.lua` with `unlock = "unlock_heartless"`, unlocked by `{ "has", set = "achievements", id = "heartless" }`;
  - a placeholder alternative biome (see below) unlocked by killing 50 enemies of one type: `{ "count", key = "kills:<some mob id>", scope = "profile", at_least = 50 }`;
  - a challenge trigger example, `{ "has", set = "challenges", id = "<id>" }`, kept in the data but unreachable until challenges exist (the title's Challenges page is empty).
- Run counters (`progress.counters`), owned by `rooms_play`: `kills`, `kills:<enemy id>`,
  `hearts` (hearts picked up), `damage` (hits taken), `virus_spent`, set `items` (mutation ids
  taken), set `rooms` (room types entered), `floor`. A `floor` counters object reset at each
  floor start. Profile lifetime totals: `profile.counters` (same keys, added at run end; kills
  also on each kill so `"event"` rules see them).
- Check moments: `"event"` after a kill, a pickup or a mutation taken; `"floor_end"` when the
  stairs are taken (and on victory); `"run_end"` when the run ends (win or loss; quitting from
  pause does not count). Earned achievements and unlocks are saved at once (`profile:save()`).
- Content: `rooms_content` pools get `unlocked = profile.unlocks` (items already filters by
  `unlock`); `rooms_biomes.new` passes `unlocked = profile.unlocks` to `procgen.biomes`.
  Something unlocked mid-run applies from the next run (pools are built at run start).
- Notices: a short HUD message "UNLOCKED: <name>" / "ACHIEVEMENT: <name>" (the existing
  `play.message`), and an "Earned this run" list on the end-of-run Stats page.
- Progress pages: Achievements lists every achievement (hidden ones "???" until earned, earned
  ones with their name); "Unlocked items" becomes **Unlocks**: every unlock rule, locked ones
  show a hint (the rule's `hint` text, or "???" if hidden); completion % counts achievements
  and unlocks from these lists.
- Debug builds (`debug = true`): an "Unlock all" button on the Progress page for testing on the
  console (sets every unlock in the profile; not saved unless the owner confirms).

### Alternative biome (placeholder)

Blob's path is fixed per floor, so an unlockable biome needs a slot that can vary. Placeholder:
floors 6-7 become a variable slot (`min_floor = 6, max_floor = 6`, span 2) holding
`fungal_cave` (always available) and a new `crystal_cave` (`unlock = "unlock_crystal_cave"`,
weight 1 each once unlocked). Every other floor keeps its fixed biome. (Owner to confirm.)

### Tests

In `tests/pc/rooms_progress_test.lua` (new) and `rooms_example_test.lua`: each placeholder
achievement is earned by simulating its run (counters + ctx) and not earned otherwise; abstain
rules are not earned before the floor/run ends; earned ids are saved and survive a reload;
a locked mutation is never drawn until its tag is unlocked, then can be; the locked biome never
appears before unlock and can appear after; notices and Stats list; Progress pages fit 320x180
with no printf/setFont.

## 3. Engine: the boss director (`engine/modules/combat/boss.lua`)

The owner asked whether bosses need their own AI. Answer (approved 2026-11-24): bosses reuse the
modular enemy behaviours and `combat.brains` from PR #87, plus a thin generic **director** on top
for what only bosses have: phases, an attack rotation with clear tells, and a health bar.
Before this step, merge `claude/project-thread-2yza81` (PR #87, steps 1-2: `combat.behaviours`,
`combat.brains`) into this branch with a merge commit.

### API (exported as `combat.boss`)

```lua
local def = combat.boss.build(spec, ctx)   -- once per boss type (ctx: the brains build context)
local b = combat.boss.new(def, agent, opts) -- once per fight; opts.on_phase(b, index)
b:update(dt)        -- once per fixed step, instead of the agent's fsm update
b.phase             -- current phase index (1..n)
b.bar               -- displayed health fraction 0..1, eased towards the real one (no allocation)
b.telegraph         -- nil, or the current state's name while it is in its "windup" phase
b.telegraph_t       -- 0..1 progress of that windup (for a flashing tell or a charge-up bar)
b.transitioning     -- true during a phase change
```

A spec:

```lua
{
  name = "The Mutant",
  phases = {
    { at = 1.0, brain = { ... } },                         -- a combat.brains spec
    { at = 0.5, brain = { ... }, transition = { time = 1.2, invulnerable = true, shake = 4 } },
  },
}
```

- `phases[i].at`: health fraction at which the phase starts (first is 1.0, strictly
  decreasing). Each phase has its own brain (built once by `build` through `combat.brains`, so
  every behaviour and condition from PR #87 is available by name).
- Phase change: when health drops to `at` or below, the current state exits, the boss halts for
  `transition.time` seconds (invulnerable if asked: the director sets `agent.invulnerable`, the
  game's damage hook respects it), `opts.on_phase` is called (the game plays a sound, a shake,
  spawns adds), then the new phase's fsm starts at its `initial`. Skipping several thresholds
  with one hit goes straight to the lowest one reached.
- **Attack rotation**: a new behaviour `"rotate"` registered in `combat.brains` (generic, also
  usable by normal enemies): `{ "rotate", options = { { to = "spray", weight = 2 }, { to =
  "charge" } }, order = "random" | "cycle", no_repeat = true, pause = 0.6 }`. It waits `pause`
  seconds (facing the target), then goes to the next state picked from `options` with
  `agent.rng` (an `engine.rng` stream; `"cycle"` takes them in order). Each attack state ends
  with `next = "<the rotate state>"`, so a phase is a loop: pick, tell, attack, recover, pick.
- **Telegraphs**: the attack behaviours already expose `m.phase == "windup"`; the director only
  reads it into `b.telegraph` / `b.telegraph_t` so the game can draw one standard tell (flash,
  exclamation mark, charge-up) for every boss attack. A `windup` value in the spec controls its
  length per attack.
- **Health bar**: `b.bar` eases towards `health / max` (fast down, so damage reads at once). The
  game draws it; the engine draws nothing.

Plain Lua 5.1, no allocation in `update` (phases and machines are built in `build` / `new`),
randomness only through `agent.rng`.

### Docs and tests

`engine/modules/combat/README.md` (Bosses section), `docs/ENGINE.md`, `CHANGELOG.md`.
`tests/engine/boss_test.lua` (registered in `run.lua`): phase thresholds (including skipping
two with one hit), transition time and invulnerability, `on_phase` once per phase, `rotate`
cycle and random with `no_repeat` (deterministic per seed), telegraph values during a shoot and
a charge windup, `bar` easing, no allocation over 600 steps.

## 4. Game: the final boss (`examples/rooms`)

### `rooms_final_bosses.lua`

A list of final bosses as data, chosen with `progress.pick` when the run **enters the last
floor** (`FLOORS`), from the stream `"final_boss"`, so it can depend on the run so far and on the
profile. Each entry: `id`, `name`, `health`, `damage`, `color`, `size` (scale of the boss body),
`when`, `priority`, `weight`, and optionally `unlock` (only once unlocked). All placeholders:

| id | Name | When (placeholder) |
|---|---|---|
| `final_mutant` | "The Mutant" | always (priority 0): the current catastrophe boss |
| `final_ai` | "The Caretaker AI" | priority 1: the profile has at least one win and the run holds 3+ mutations |
| `final_scientist` | "The Last Scientist" | priority 2: the run never picked up a heart (`hearts` at_most 0) |

The chosen boss replaces the biome boss in the boss room of the last floor (stats, colour,
size) and is driven by `combat.boss` with the entry's `phases` (each a brain spec). It is
shown on the boss room's name banner and discovered in the profile's bestiary like other
bosses. HUD: while a director-driven boss is alive, its name and health bar (`b.bar`) are drawn
at the top of the screen with the built-in pixel font; during a windup the boss flashes
(`b.telegraph_t`). The attacks it uses are entries of `rooms_attacks.lua` (placeholders).

Placeholder patterns, two phases each (the second at 50% health, faster and with one more
attack):

| Boss | Phase 1 | Phase 2 |
|---|---|---|
| `final_mutant` | walks at the player, charge, ring of 8 shots | adds hop slams and a spiral (`rotate`) |
| `final_ai` | flies (`fly` follow), aimed 3-shot volleys, swoop | spray patterns, faster swoops |
| `final_scientist` | keeps away, throws bombs (explosive), aimed shots | adds a charge and a bomb volley |

### Hooks

- `play.final_boss` (the picked entry) is set when floor `FLOORS` starts and kept in the run
  state.
- Victory (PR #88) is unchanged: clearing that boss room wins.
- Endings (PR #89): `rooms_endings.pick(play)` gets one rule: an ending entry may name
  `final_boss = "<id>"`; the first ending whose `final_boss` matches the boss that was killed
  is played, otherwise the current default (`plush`). Placeholder mapping: `final_ai` ->
  `helpful_ai`, `final_scientist` -> `cryo_scientist`.

### Tests

The pick is deterministic per seed; each placeholder condition selects its boss (simulated
run state) and the default otherwise; the last floor's boss room spawns the picked boss with
its stats; every boss spec builds; each boss reaches phase 2 at half health; the HUD bar fits
320x180 with no printf/setFont; killing it wins and plays the mapped ending; the boss appears
in the bestiary.
