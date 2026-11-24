# engine/modules/progress

Genre module: a generic progress layer for achievements, unlocks and content chosen by what the
player did.

- **Conditions** are plain data (`all`, `any`, `none`, `count`, `has`, `build`, `size`, `result`,
  `test`) tested against a run and a profile.
- **Counters** hold what a run or a floor did: named numbers and named sets of ids.
- **Rules** turn conditions into achievements and unlocks, checked at an event, a floor end or a
  run end. An unlock's id is the tag content declares with `unlock = id` (`items`, `procgen.biomes`).
- **Pick** chooses one entry by conditions, priority and a weighted draw with an `engine.rng`
  stream (a final boss, a special room, an ending).

It needs no other module, uses no LOVE at all, does nothing per frame, and knows nothing about a
game: the game picks every counter key, set name and predicate name. Nothing in `engine/`
requires it.

Tests: `tests/engine/progress_test.lua`.

```lua
local progress = require("engine.modules.progress")

local run, floor = progress.counters.new(), progress.counters.new()
run:add("kills", 1)
run:mark("items", "spring_heel")

local profile = { counters = { kills = 0 }, achievements = {}, unlocks = {},
  items = { spring_heel = true } }
local ctx = { run = run, floor = floor, profile = profile, result = "win" }

local achievements = progress.rules.new({
  { id = "first_win", when = { "result", value = "win" } },                    -- at run_end
  { id = "untouchable", at = "floor_end",                                      -- never at "event"
    when = { "count", key = "damage", scope = "floor", at_most = 0 } },
  { id = "exterminator", at = "event",
    when = { "count", key = "kills", scope = "profile", at_least = 200 } },
})

local earned = achievements:check("event", ctx, profile.achievements)  -- only the new ones
local boss = progress.pick(bosses, ctx, run.streams:get("final_boss"))
```

## Counters

```lua
local run = progress.counters.new()
run:add("kills", 1)               -- numbers (missing = 0)
run:add("kills:shooter", 1)       -- any string key; the game picks the names
run:set("floor", 3)
run:mark("items", "spring_heel")  -- named sets: items held, rooms visited...
run:has("items", "spring_heel")   -- -> boolean
run:count("items")                -- size of the set
run:get("kills")                  -- -> number
run:reset()                       -- a new run (keeps the tables, clears them)
run:state()                       -- a plain table for a run save
run:set_state(saved)
```

`mark` creates a set the first time (allocation there is fine). `add`, `set`, `mark` on an
existing set, `has` and `get` allocate nothing, so they are safe on kills and pickups. A run
usually keeps two: `run` (the whole run) and `floor` (the game resets it when a floor starts).

## Conditions

A condition is a plain table whose first array item is its kind. `conditions.compile(c)` checks
it and raises an error naming the path, e.g. `when[2].at_least: a number`. Missing counters and
sets read as 0 / absent; they never raise at run time.

```lua
{ "all",  { "result", value = "win" }, { "count", key = "kills", at_least = 10 } }
{ "any",  { "has", set = "achievements", id = "first_win" }, { "result", value = "win" } }
{ "none", { "count", key = "damage", scope = "floor", at_least = 1 } }
{ "count", key = "kills", scope = "run", at_least = 10, at_most = 20 }
{ "has", set = "achievements", id = "first_win" }
{ "build", all = { "wings", "spring_heel" }, any = { "shield", "armor" }, at_least = 1 }
{ "size", set = "items", scope = "run", at_least = 5 }
{ "result", value = "win" }
{ "test", name = "no_misses" }
```

| Kind | Fields | True when |
|---|---|---|
| `all` | array of conditions | every one is true |
| `any` | array of conditions | at least one is true |
| `none` | array of conditions | none is true |
| `count` | `key`, `scope` (`"run"`, `"floor"`, `"profile"`; default `"run"`), `at_least`, `at_most` (one or both) | the counter is in range. Abstaining is `at_most = 0` |
| `has` | `set`, `id`, `scope` (default `"profile"`) | the set holds the id (achievements, challenges won, endings seen, unlocks) |
| `build` | `all` (ids), `any` (ids), `at_least` (how many of `any`, default 1), `set` (default `"items"`), `scope` (default `"run"`) | the run's set holds that combination |
| `size` | `set`, `scope` (default `"run"`), `at_least`, `at_most` | the set's size is in range (e.g. 5 mutations) |
| `result` | `value` (`"win"`, `"loss"`) | `ctx.result` equals it |
| `test` | `name` | the predicate `tests[name](ctx)` returns true (the game registers them by name, so the data stays plain) |

The `ctx` passed to `conditions.test` and `rules:check` is
`{ run = counters, floor = counters, profile = table, result = "win" | "loss" | nil }`.
`scope = "profile"` reads `ctx.profile.counters[key]` for `count` and `ctx.profile[set][id]` for
`has` / `size`.

## Rules: achievements and unlocks

```lua
local rules = progress.rules.new(list, { tests = { no_misses = function(ctx) ... end } })
local earned = rules:check(moment, ctx, profile.achievements)   -- only the newly earned rules
rules:is_earned(id, profile.achievements)
```

| Field | Meaning |
|---|---|
| `id` | Unique string; for an unlock it is the **tag** content declares with `unlock = id` |
| `when` | A condition |
| `at` | `"event"` (after any tracked event: kill, pickup, item taken), `"floor_end"`, `"run_end"` (default). Abstain rules use `"floor_end"` or `"run_end"`, never `"event"` |
| `requires` | Optional array of rule ids that must already be earned (chains) |
| `hidden` | The UI shows "???" until earned |
| anything else | The game's (name, description, what it unlocks, icon) |

`check` tests every rule with `at == moment`, plus every `"event"` rule at `"floor_end"` and
`"run_end"`. It skips ids already in the profile set, writes `set[id] = true` for the ones that
pass and returns them in list order. With nothing new it returns one shared empty table.
Deterministic: list order, no randomness. The game passes `profile.achievements` for one list and
`profile.unlocks` for another.

`requires` chains are resolved in list order: a rule whose prerequisite is earlier in the list
can earn in the same call; one whose prerequisite comes later earns on a later call. Every id
in `requires` must be a rule of the same list.

## Pick

```lua
local entry = progress.pick(list, ctx, rng, { tests = tests })   -- an entry, or nil
```

Each entry may have `when` (nil: always), `priority` (default 0) and `weight` (default 1). Entries
whose `when` fails are skipped, then only the highest `priority` counts, and a weighted draw with
`rng` breaks the tie. `weight = 0` is never picked; if every entry at the highest priority has
weight 0, the result is nil. One candidate costs no draw. The same rng state and `ctx` give the
same entry on PC and console (use a named stream such as `run.streams:get("final_boss")`).
