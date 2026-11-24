-- engine/modules/progress: counters (numbers, sets, state), every condition kind true and false,
-- scopes and missing values, compile errors with the path, rules at each moment (and an abstain
-- rule not earned at "event"), requires chains, pick by priority and weight with a fixed seed,
-- allocation-free paths, and a static check of the module.
-- Usage: luajit -joff tests/engine/progress_test.lua  (ends with "OK:")
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;" .. package.path

local passed = ...
local T = passed
local checks = 0
if not T then
  T = { check = function(cond, what)
    checks = checks + 1
    if not cond then print("FAILED: " .. what); os.exit(1) end
  end }
end

local globals = {}
for k in pairs(_G) do globals[k] = true end
local Save = require("engine.save")
local Rng = require("engine.rng")
local progress = require("engine.modules.progress")

local function refuses(f, what, pattern)
  local ok, err = pcall(f)
  T.check(not ok and tostring(err):find(pattern, 1, true), what .. " (" .. tostring(err) .. ")")
end

-- Counters
local run = progress.counters.new()
T.check(run:get("kills") == 0, "a missing counter is 0")
T.check(run:add("kills", 2) == 2 and run:add("kills", 3) == 5, "add accumulates and returns the total")
T.check(run:set("floor", 4) == 4 and run:get("floor") == 4, "set")
T.check(run:has("items", "spring") == false and run:count("items") == 0, "a missing set is empty")
run:mark("items", "spring")
run:mark("items", "spring")
T.check(run:has("items", "spring") and run:count("items") == 1, "mark: a set, marked once")
run:mark("items", "boot")
run:mark("rooms", "shop")
T.check(run:count("items") == 2 and run:count("rooms") == 1, "mark adds ids, sets are separate")
refuses(function() run:add("", 1) end, "an empty counter key", "non-empty string")
refuses(function() run:add("kills", "one") end, "a non-number value", "a number")
refuses(function() run:mark("", "x") end, "an empty set name", "non-empty string")
refuses(function() run:set_state(3) end, "set_state with a non-table", "needs a table")

-- state / set_state through engine.save
local snapshot = run:state()
snapshot.numbers.kills = 999
snapshot.sets.items.spring = nil
T.check(run:get("kills") == 5 and run:has("items", "spring"), "state is a copy")
local ok, saved = Save.parse(Save.serialize(run:state()))
T.check(ok and saved.numbers.kills == 5 and saved.numbers.floor == 4
  and saved.sets.items.spring == true and saved.sets.rooms.shop == true, "state is plain data")
local copy = progress.counters.new()
copy:set_state(saved)
T.check(copy:get("kills") == 5 and copy:get("floor") == 4, "set_state restores numbers")
T.check(copy:has("items", "spring") and copy:has("items", "boot") and copy:count("items") == 2,
  "set_state restores sets")
copy:set_state({ numbers = { kills = "bad" }, sets = { items = { spring = false, boot = true } } })
T.check(copy:get("kills") == 0 and not copy:has("items", "spring") and copy:has("items", "boot"),
  "set_state ignores malformed entries")
copy:reset()
T.check(copy:get("kills") == 0 and copy:count("items") == 0, "reset clears everything")

-- The context of every condition test
local floor = progress.counters.new()
floor:add("damage", 0)
floor:set("number", 2)
floor:mark("rooms", "shop")
local profile = {
  counters = { kills = 200, runs = 5 },
  achievements = { first = true },
  unlocks = { crystal = true },
  items = { a = true, b = true, c = true },
}
local ctx = { run = run, floor = floor, profile = profile, result = "win" }
local function cond(c) return progress.conditions.test(c, ctx) end

-- all / any / none
T.check(cond({ "all", { "count", key = "kills", at_least = 5 }, { "result", value = "win" } }), "all true")
T.check(not cond({ "all", { "count", key = "kills", at_least = 5 }, { "result", value = "loss" } }), "all false")
T.check(cond({ "any", { "result", value = "loss" }, { "result", value = "win" } }), "any true")
T.check(not cond({ "any", { "result", value = "loss" }, { "count", key = "kills", at_least = 6 } }), "any false")
T.check(cond({ "none", { "result", value = "loss" }, { "count", key = "kills", at_least = 6 } }), "none true")
T.check(not cond({ "none", { "result", value = "win" } }), "none false")

-- count: bounds, scopes, missing values
T.check(cond({ "count", key = "kills", at_least = 5 }), "count at_least (run default)")
T.check(not cond({ "count", key = "kills", at_least = 6 }), "count at_least false")
T.check(cond({ "count", key = "kills", at_most = 5 }), "count at_most")
T.check(not cond({ "count", key = "kills", at_most = 4 }), "count at_most false")
T.check(cond({ "count", key = "kills", at_least = 5, at_most = 5 }), "count both bounds")
T.check(cond({ "count", key = "damage", scope = "floor", at_most = 0 }), "count scope floor")
T.check(not cond({ "count", key = "damage", scope = "floor", at_least = 1 }), "count scope floor false")
T.check(cond({ "count", key = "kills", scope = "profile", at_least = 200 }), "count scope profile")
T.check(cond({ "count", key = "never", at_most = 0 }), "a missing run counter is 0")
T.check(cond({ "count", key = "never", scope = "profile", at_most = 0 }), "a missing profile counter is 0")
T.check(progress.conditions.test({ "count", key = "never", at_most = 0 }, { profile = {} }), "no ctx.profile: 0")

-- has
T.check(cond({ "has", set = "items", id = "spring", scope = "run" }), "has run scope")
T.check(not cond({ "has", set = "items", id = "ghost", scope = "run" }), "has run scope false")
T.check(cond({ "has", set = "rooms", id = "shop", scope = "floor" }), "has floor scope")
T.check(cond({ "has", set = "achievements", id = "first" }), "has profile scope (default)")
T.check(cond({ "has", set = "unlocks", id = "crystal" }), "has profile first set")
T.check(not cond({ "has", set = "achievements", id = "ghost" }), "has profile false")
T.check(not progress.conditions.test({ "has", set = "achievements", id = "first" }, {}), "no ctx.profile: absent")

-- build
T.check(cond({ "build", all = { "spring", "boot" } }), "build all")
T.check(not cond({ "build", all = { "spring", "ghost" } }), "build all false")
T.check(cond({ "build", any = { "ghost", "spring" } }), "build any (default at_least 1)")
T.check(cond({ "build", any = { "spring", "boot" }, at_least = 2 }), "build any at_least 2")
T.check(not cond({ "build", any = { "ghost", "boot" }, at_least = 2 }), "build any at_least false")
T.check(not cond({ "build", all = { "spring" }, any = { "ghost" } }), "build all and any")
T.check(cond({ "build", all = { "a", "b" }, set = "items", scope = "profile" }), "build profile set")
T.check(not progress.conditions.test({ "build", all = { "a" } }, {}), "build with no ctx sets: false")

-- size
T.check(cond({ "size", set = "items", at_least = 2 }), "size run (default)")
T.check(not cond({ "size", set = "items", at_most = 1 }), "size run false")
T.check(cond({ "size", set = "rooms", scope = "floor", at_most = 1 }), "size floor")
T.check(cond({ "size", set = "items", scope = "profile", at_least = 3, at_most = 3 }), "size profile")
T.check(not progress.conditions.test({ "size", set = "items", at_least = 1 }, {}), "size with no ctx: 0")

-- result and test
T.check(cond({ "result", value = "win" }) and not cond({ "result", value = "loss" }), "result")
T.check(not progress.conditions.test({ "result", value = "win" }, { result = nil }), "result with nil")
local tests = { healthy = function(c) return c.run:get("health") == 10 end }
run:add("health", 10)
T.check(progress.conditions.test({ "test", name = "healthy" }, ctx, tests), "test predicate true")
run:set("health", 0)
T.check(not progress.conditions.test({ "test", name = "healthy" }, ctx, tests), "test predicate false")
refuses(function() progress.conditions.test({ "test", name = "ghost" }, ctx, tests) end,
  "a test name that is not registered", "no test named ghost")

-- compile: returns the data and names the path of a bad field
local good = { "all", { "count", key = "kills", at_least = 1 } }
T.check(progress.conditions.compile(good) == good, "compile returns the same table")
local function compile_refuses(c, pattern, path, reg)
  local ok, err = pcall(function() progress.conditions.compile(c, path, reg) end)
  T.check(not ok and tostring(err):find(pattern, 1, true),
    "compile refuses with " .. pattern .. " (" .. tostring(err) .. ")")
end
compile_refuses(3, "a condition is a table")
compile_refuses({ true }, "when[1]")
compile_refuses({ "bogus" }, "unknown condition kind")
compile_refuses({ "count", key = "kills" }, "count needs at_least or at_most")
compile_refuses({ "count", key = "kills", at_least = "many" }, "when.at_least: a number")
compile_refuses({ "count", key = "", at_least = 1 }, "when.key: a non-empty string")
compile_refuses({ "count", key = "kills", at_least = 1, scope = "world" }, "when.scope")
compile_refuses({ "all", { "count", key = "kills", at_least = "many" } }, "when[2].at_least: a number")
compile_refuses({ "has", set = "items" }, "when.id: a non-empty string")
compile_refuses({ "build" }, "build needs all or any")
compile_refuses({ "build", any = { 1 } }, "when.any")
compile_refuses({ "size", set = "items" }, "size needs at_least or at_most")
compile_refuses({ "result", value = "draw" }, "when.value")
compile_refuses({ "test" }, "when.name: a non-empty string")
compile_refuses({ "test", name = "ghost" }, "no test named ghost", nil, tests)
T.check(progress.conditions.compile({ "test", name = "healthy" }, "when", tests) ~= nil,
  "compile checks test names against the registry")

-- Rules: moments, the abstain rule, chains, only-new, the shared empty table
local function new_ctx()
  local r = progress.counters.new()
  r:add("kills", 5)
  r:add("health", 10)
  local f = progress.counters.new()
  f:add("damage", 0)
  local p = { counters = { kills = 0 }, achievements = {} }
  return { run = r, floor = f, profile = p, result = "win" }, p
end
local defs = {
  { id = "first_win", when = { "result", value = "win" } },
  { id = "kills_event", at = "event", when = { "count", key = "kills", at_least = 3 } },
  { id = "clean_floor", at = "floor_end", when = { "count", key = "damage", scope = "floor", at_most = 0 } },
  { id = "chain", requires = { "first_win" }, when = { "count", key = "kills", at_least = 1 } },
  { id = "healthy", at = "event", when = { "test", name = "healthy" } },
}
local rules = progress.rules.new(defs, { tests = tests })
local rctx, rprof = new_ctx()
local set = rprof.achievements

local e1 = rules:check("event", rctx, set)
T.check(#e1 == 2 and e1[1].id == "kills_event" and e1[2].id == "healthy", "event: only event rules, list order")
T.check(set.kills_event == true and set.healthy == true, "check writes the profile set")
T.check(set.first_win == nil and set.clean_floor == nil and set.chain == nil,
  "an abstain rule is not earned at event, nor are run_end rules")
local e2 = rules:check("event", rctx, set)
T.check(next(e2) == nil and e2 == rules:check("event", rctx, set), "nothing new: one shared empty table")
local e3 = rules:check("floor_end", rctx, set)
T.check(#e3 == 1 and e3[1].id == "clean_floor", "floor_end: floor_end rules plus earned events")
local e4 = rules:check("run_end", rctx, set)
T.check(#e4 == 2 and e4[1].id == "first_win" and e4[2].id == "chain",
  "run_end: run rules in list order, a chain after its prerequisite")
T.check(rules:is_earned("chain", set) and not rules:is_earned("chain", {}), "is_earned")
refuses(function() return rules:is_earned("ghost", set) end, "an unknown rule id", "no rule ghost")
refuses(function() return rules:check("every_frame", rctx, set) end, "an unknown moment", "the moment")
refuses(function() return rules:check("event", rctx, nil) end, "a nil set", "needs the profile set")

-- An "event" rule that was false at "event" is tested again at "floor_end" and "run_end"
local late = progress.rules.new({ { id = "late", at = "event",
  when = { "count", key = "kills", at_least = 10 } } })
local late_ctx = new_ctx()
T.check(next(late:check("event", late_ctx, {})) == nil, "an event rule is false while its condition is")
late_ctx.run:add("kills", 5)
T.check(late:check("floor_end", late_ctx, {})[1].id == "late", "event rules are tested at floor_end too")

-- A prerequisite that comes later in the list earns on the next check, not now
local later = progress.rules.new({
  { id = "a", requires = { "b" }, when = { "count", key = "kills", at_least = 1 } },
  { id = "b", when = { "count", key = "kills", at_least = 1 } },
})
local lctx, lprof = new_ctx()
local lset = lprof.achievements
local l1 = later:check("run_end", lctx, lset)
T.check(#l1 == 1 and l1[1].id == "b", "a rule that requires a later one waits")
local l2 = later:check("run_end", lctx, lset)
T.check(#l2 == 1 and l2[1].id == "a", "and earns on the next check")

-- has scope profile inside a rule
local hctx = { profile = { achievements = { first = true } } }
local hr = progress.rules.new({ { id = "seen", when = { "has", set = "achievements", id = "first" } } })
T.check(hr:check("run_end", hctx, {})[1].id == "seen", "has scope profile in a rule")

-- Rule validation
refuses(function() progress.rules.new(3) end, "a non-table list", "needs an array of rules")
refuses(function() progress.rules.new({ { when = { "result", value = "win" } } }) end,
  "a rule without id", "needs a non-empty string id")
refuses(function() progress.rules.new({ { id = "a", when = { "result", value = "win" } },
  { id = "a", when = { "result", value = "win" } } }) end, "a duplicate id", "two rules have the id a")
refuses(function() progress.rules.new({ { id = "a", when = 3 } }) end, "a rule without when", "when is a condition")
refuses(function() progress.rules.new({ { id = "a", when = { "result", value = "win" }, at = "later" } }) end,
  "a bad moment", "a.at")
refuses(function() progress.rules.new({ { id = "a", requires = { "ghost" }, when = { "result", value = "win" } } }) end,
  "a missing prerequisite", "no rule ghost")
refuses(function() progress.rules.new({ { id = "a", when = { "count", key = "kills", at_least = "many" } } }) end,
  "a bad condition in a rule", "rule a.when.at_least: a number")

-- Pick: conditions, priority, weight, determinism, nil
local picks = {
  { id = "low", priority = 0, weight = 1, when = { "result", value = "win" } },
  { id = "mid_a", priority = 2, weight = 1, when = { "result", value = "win" } },
  { id = "mid_b", priority = 2, weight = 3, when = { "result", value = "win" } },
  { id = "top_loss", priority = 9, when = { "result", value = "loss" } },
  { id = "never", when = { "count", key = "nothing", at_least = 1 } },
}
local pctx = { run = run, floor = floor, profile = profile, result = "win" }
local counts = {}
local prng = Rng.new(1234)
for _ = 1, 4000 do
  local e = progress.pick(picks, pctx, prng)
  counts[e.id] = (counts[e.id] or 0) + 1
end
T.check(counts.low == nil and counts.top_loss == nil and counts.never == nil,
  "pick: only the highest matching priority counts")
T.check(counts.mid_b > 2800 and counts.mid_b < 3200 and counts.mid_a > 800 and counts.mid_a < 1200,
  "pick: the weights break the tie, 1:3 (" .. tostring(counts.mid_a) .. ":" .. tostring(counts.mid_b) .. ")")
local loss_ctx = { run = run, floor = floor, profile = profile, result = "loss" }
local top = progress.pick(picks, loss_ctx, Rng.new(1))
T.check(top ~= nil and top.id == "top_loss", "pick: the matching highest priority wins")
T.check(progress.pick({ { id = "x", when = { "result", value = "win" } } }, loss_ctx, Rng.new(1)) == nil,
  "pick: nil when nothing matches")
T.check(progress.pick({}, pctx, Rng.new(1)) == nil, "pick: nil for an empty list")
T.check(progress.pick({ { id = "always" } }, { result = nil }, Rng.new(1)).id == "always",
  "pick: an entry without when always matches")
T.check(progress.pick({ { id = "zero", weight = 0 } }, pctx, Rng.new(1)) == nil,
  "pick: a single entry with weight 0 is never picked")
T.check(progress.pick({ { id = "zero", weight = 0 }, { id = "one", weight = 1 } }, pctx, Rng.new(1)).id == "one",
  "pick: weight 0 loses the tie")
local solo = Rng.new(5)
local before = solo:state()
progress.pick({ { id = "solo" } }, pctx, solo)
T.check(solo:state() == before, "pick: one candidate costs no draw")

local function sequence(seed)
  local rr = Rng.streams(seed):get("pick")
  local out = {}
  for i = 1, 30 do
    local c = { run = run, floor = floor, profile = profile, result = (i % 2 == 0) and "win" or "loss" }
    out[i] = progress.pick(picks, c, rr).id
  end
  return table.concat(out, ",")
end
T.check(sequence(7) == sequence(7) and sequence(7) ~= sequence(8), "pick: same seed, same picks")

-- Allocation: add / set / mark (existing set) / has / get and conditions.test
local condition = { "all",
  { "count", key = "kills", at_least = 1 },
  { "has", set = "items", id = "spring", scope = "run" },
  { "has", set = "achievements", id = "first" },
  { "build", all = { "spring" }, any = { "spring", "boot" }, at_least = 1 },
  { "size", set = "items", at_least = 2, at_most = 2 },
  { "size", set = "items", scope = "profile", at_least = 3 },
  { "result", value = "win" },
  { "test", name = "ok" },
}
progress.conditions.compile(condition)
run:set("floor", 0)
run:mark("items", "spring")
run:mark("items", "boot")
local actx = { run = run, floor = floor, profile = profile, result = "win" }
local atests = { ok = function() return true end }
T.check(progress.conditions.test(condition, actx, atests), "the allocation condition is true")
collectgarbage(); collectgarbage("stop")
local before_kb = collectgarbage("count")
for i = 1, 20000 do
  run:add("kills", 1)
  run:set("floor", i)
  run:mark("items", "spring")
  run:has("items", "spring")
  run:get("kills")
  progress.conditions.test(condition, actx, atests)
end
local grown = collectgarbage("count") - before_kb
collectgarbage("restart")
T.check(grown == 0, "add/set/mark(existing)/has/get/test allocate nothing (" .. grown .. " KB)")

-- Static checks: no LOVE, no randomness or clock of its own, no pairs, goto, FFI or jit
local files = { "init.lua", "counters.lua", "conditions.lua", "rules.lua", "pick.lua" }
for i = 1, #files do
  local f = assert(io.open("engine/modules/progress/" .. files[i], "rb"))
  local src = f:read("*a"):gsub("%-%-[^\n]*", ""); f:close()
  T.check(not src:find("%f[%w]goto%f[%W]") and not src:find("ffi") and not src:find("%f[%w_]jit%."),
    "progress/" .. files[i] .. ": no goto, FFI or jit")
  T.check(not src:find("%f[%w_]love%f[%W]") and not src:find("math%.random") and not src:find("os%.time"),
    "progress/" .. files[i] .. ": no love, nothing random of its own, no clock")
  T.check(not src:find("[^%w_]pairs%("), "progress/" .. files[i] .. ": no pairs()")
end
if T.no_new_globals then T.no_new_globals(globals) end

if not passed then print(string.format("OK: %d checks; progress", checks)) end
