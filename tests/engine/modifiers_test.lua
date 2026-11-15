local T = ...
local Modifiers = require("engine.modifiers")
local mods = Modifiers.new()
mods:stat("speed", { base = 100, min = 0, max = 1000 })
mods:defineAll({
  { id = "boots", stats = { { "speed", "add", 20 } }, stacking = "stack", max_stacks = 3 },
  { id = "wind", stats = { { "speed", "mul_base", 0.5 } } },
  { id = "gale", stats = { { "speed", "mul_base", 0.25 } } },
  { id = "rage", stats = { { "speed", "mul", 2 } }, stacking = "stack" },
  { id = "mud", tags = { "curse" }, stats = { { "speed", "max", 150 } } },
  { id = "stone", tags = { "curse" }, stats = { { "speed", "set", 10 }, { "armor", "add", 5 } } },
  { id = "statue", priority = 5, stats = { { "speed", "set", 3 } } },
  { id = "floor", stats = { { "speed", "min", 40 } } },
  { id = "haste", stats = { { "speed", "add", 50 } }, stacking = "refresh", duration = 0.5 },
  { id = "poison", stacking = "stack", duration = 1 },
})
T.check(not pcall(mods.define, mods, { id = "boots" }), "an id is defined once")
T.check(not pcall(mods.define, mods, { id = "bad", stats = { { "speed", "divide", 2 } } }), "unknown operations are refused")

-- the evaluation order, whatever the order of acquisition
local owner = { name = "hero" }
local set = mods:attach(owner)
T.check(set:get("speed") == 100 and set:get("armor") == 0, "the declared base, or 0")
set:add("rage"); set:add("gale"); set:add("boots"); set:add("wind")
T.near(set:get("speed"), (100 + 20) * (1 + 0.25 + 0.5) * 2, "base, add, mul_base (summed), mul")
local other = mods:attach({})
other:add("wind"); other:add("boots"); other:add("rage"); other:add("gale")
T.check(other:get("speed") == set:get("speed"), "the order of acquisition does not matter")
set:setBase("speed", 80)
T.near(set:get("speed"), (80 + 20) * 1.75 * 2, "a new base")
set:add("mud")
T.check(set:get("speed") == 150, "max clamps the result")
set:add("stone")
T.check(set:get("speed") == 10 and set:get("armor") == 5, "set replaces what came before")
set:add("floor")
T.check(set:get("speed") == 40, "min applies after set")
set:add("statue")
T.check(set:get("speed") == 40 and set:removeTagged("curse") == 2 and not set:hasTag("curse"), "removeTagged")
set:remove("floor")
T.check(set:get("speed") == 3, "the set with the highest priority wins")
set:remove("statue")
T.near(set:get("speed"), 350, "and back")
set:add("rage", 3)
T.check(set:get("speed") == 1000, "the stat's own limit comes last (2800 without)")
set:remove("rage")

-- caching
local evals = set.evals
local version = set.version
for _ = 1, 10 do set:get("speed") end
T.check(set.evals == evals + 1, "a stat is computed once")
set:get("armor")
T.check(set.evals == evals + 2 and set.version == version, "each stat on its own")
set:add("wind")
set:get("speed")
T.check(set.evals == evals + 2 and set.version == version, "a unique modifier added again changes nothing")
set:add("boots"); set:get("speed"); set:get("speed")
T.check(set.evals == evals + 3 and set.version == version + 1, "a change empties the cache")

-- stacking
T.check(set:stacks("boots") == 2 and set:add("boots", 5) and set:stacks("boots") == 3, "stack, up to max_stacks")
T.near(set:get("speed"), (80 + 60) * 1.75, "stacks multiply add")
T.check(set:add("wind") == false and set:stacks("wind") == 1, "unique")
T.check(set:remove("boots", 2) and set:stacks("boots") == 1 and set:remove("boots") and not set:has("boots")
  and set:remove("boots") == false and set:stacks("boots") == 0, "remove stacks, then all")
T.check(not pcall(set.add, set, "nope"), "an unknown id is an error")

-- durations, on fixed steps
local dt = 1 / 60
set:add("haste")
for _ = 1, 20 do set:update(dt) end
T.near(set:timeLeft("haste"), 0.5 - 20 / 60, "the timer runs")
set:add("haste")
T.check(set:stacks("haste") == 1 and set:timeLeft("haste") == 0.5, "refresh: one stack, the timer starts again")
for _ = 1, 29 do set:update(dt) end
T.check(set:has("haste") and set:get("speed") == (80 + 50) * 1.75, "still there one step before the end")
set:update(dt)
T.check(not set:has("haste") and set:get("speed") == 80 * 1.75, "gone after exactly 30 steps of 1/60, and the stat follows")
set:add("poison", 2); set:update(dt); set:add("poison")
T.check(set:stacks("poison") == 3 and set:timeLeft("poison") == 1, "stack: more stacks, one timer, started again")
set:add("poison", 1, 0.1)
for _ = 1, 6 do set:update(dt) end
T.check(not set:has("poison") and set:timeLeft("poison") == nil, "a duration given to add; every stack goes together")

-- events: order, combination, isolation
local ev = Modifiers.new()
ev:event("on_score", { combine = "sum" })
ev:event("can_fly", { combine = "any" })
ev:event("may_act", { combine = "all" })
local log = {}
local captured
local function says(text) return function(entity, ctx, m) log[#log + 1] = text .. (ctx and ctx.tag or "") end end
ev:defineAll({
  { id = "a", events = { on_jump = says("a"), on_score = function() return 2 end, may_act = function() return true end } },
  { id = "b", priority = 10, events = { on_jump = says("b"), on_score = function() return 3 end,
    can_fly = function() return true end, may_act = function() return false end } },
  { id = "c", events = { on_jump = says("c"), on_dance = says("dance"), can_fly = function() return false end } },
  { id = "d", priority = 10, events = { on_jump = says("d") } },
  { id = "armor", priority = 1, events = { on_damaged = function(_, ctx) return ctx.amount - 3 end } },
  { id = "frail", priority = 2, events = { on_damaged = function(_, ctx) return ctx.amount * 2 end } },
  { id = "watcher", events = { on_damaged = function(_, ctx, m) m.state.seen = (m.state.seen or 0) + ctx.amount end } },
  { id = "shield", priority = -1, events = { on_damaged = function() return -50 end } },
  { id = "counter", stacking = "stack", events = {
    on_add = function(entity, ctx, m) log[#log + 1] = "add " .. ctx.reason .. " " .. m.stacks end,
    on_remove = function(entity, ctx) log[#log + 1] = "remove " .. ctx.reason end,
    on_update = function(entity, ctx, m)
      m.state.steps = (m.state.steps or 0) + 1
      m.state.dt = ctx.dt
      captured = m
    end,
    on_jump = function(entity, ctx, m)
      entity.mods:add("a")            -- from a handler: waits for the end of the event
      entity.mods:remove("c")
      log[#log + 1] = "counter" .. (entity.mods:has("a") and "!" or "")
    end } },
  { id = "timed", duration = 0.05, events = { on_remove = function(e, ctx) log[#log + 1] = "timed " .. ctx.reason end } },
})
local hero = {}
hero.mods = ev:attach(hero)
local s = hero.mods
s:add("c"); s:add("b"); s:add("d")
s:emit("on_jump", { tag = "!" })
T.check(table.concat(log, ",") == "b!,d!,c!", "priority first, then the order of acquisition: " .. table.concat(log, ","))
T.check(table.concat(s:ids(), ",") == "b,d,c" and s:count() == 3, "ids")
log = {}
s:add("counter"); s:add("counter", 2)
s:emit("on_jump")
T.check(table.concat(log, ",") == "add new 1,add stack 3,b,d,c,counter", "on_add; a handler's changes wait: " .. table.concat(log, ","))
T.check(s:has("a") and not s:has("c"), "and are made when the event is over")
log = {}
s:emit("on_jump"); s:emit("on_dance"); s:emit("on_nothing")
T.check(table.concat(log, ",") == "b,d,counter!,a", "the same order every time; events nobody hears")
T.check(s:emit("on_score") == 5 and s:emit("can_fly") == true and s:emit("may_act") == false and s:emit("on_jump") == nil,
  "sum, any, all, none")
s:remove("b")
T.check(s:emit("can_fly") == false and s:emit("may_act") == true, "any and all without the one that decided")

-- the damage chain
s:add("watcher"); s:add("armor"); s:add("frail")
local hit = { amount = 10 }
T.check(s:emit("on_damaged", hit) == 17 and hit.amount == 17, "damage goes through the chain by priority: 10 * 2 - 3")
s:add("shield")
T.check(s:emit("on_damaged", { amount = 10 }) == 0, "a chain event keeps its minimum")

-- isolation: a handler's own state, a read-only view, and nobody else's
s:update(dt); s:update(dt)
T.check(captured.id == "counter" and captured.stacks == 3 and captured.state.steps == 2 and captured.state.dt == dt,
  "on_update each step; the view shows the modifier's own data")
T.check(not pcall(function() captured.stacks = 99 end) and not pcall(function() captured.other = 1 end)
  and s:stacks("counter") == 3, "the view is read-only")
T.check(getmetatable(captured) == "read-only" and captured.c == nil and captured.def == nil and captured.view == nil,
  "and leads to nothing else")
log = {}
s:add("timed")
s:update(dt); s:update(dt); s:update(dt)
T.check(table.concat(log, ",") == "timed expire" and not s:has("timed"), "on_remove when the time is up")
log = {}
s:remove("counter")
T.check(table.concat(log, ",") == "remove remove", "on_remove when removed")

-- serialise and restore
local save = mods:attach({}, { speed = 90, jump = 7 })
save:add("boots", 2); save:add("wind"); save:add("haste"); save:add("statue")
for _ = 1, 12 do save:update(dt) end
local data = save:serialize()
local function plain(v)
  local t = type(v)
  if t == "table" then
    if getmetatable(v) then return false end
    for k, x in pairs(v) do if not plain(k) or not plain(x) then return false end end
    return true
  end
  return t == "number" or t == "string" or t == "boolean"
end
T.check(plain(data), "the saved state is plain data")
local back = mods:attach({})
T.check(back:restore(data) == nil, "restore")
T.check(table.concat(back:ids(), ",") == table.concat(save:ids(), ",") and back:stacks("boots") == 2
  and back:timeLeft("haste") == save:timeLeft("haste") and back:getBase("jump") == 7, "ids, stacks, timers and bases come back")
save:remove("statue"); back:remove("statue")
T.check(back:get("speed") == save:get("speed") and back:get("speed") == (90 + 40 + 50) * 1.5, "and the stats with them")
for _ = 1, 17 do save:update(dt); back:update(dt) end
T.check(back:has("haste") and save:has("haste"), "the timers go on from where they were")
save:update(dt); back:update(dt)
T.check(not back:has("haste") and not save:has("haste"), "and end on the same step")
back:add("gale")
T.check(back:ids()[#back:ids()] == "gale", "new ones come after the restored ones")
hero.mods:add("counter"); hero.mods:update(dt)
local d2 = hero.mods:serialize()
local hero2 = {}
hero2.mods = ev:attach(hero2)
hero2.mods:restore(d2)
hero2.mods:update(dt)
T.check(captured.state.steps == 2 and plain(d2), "a modifier's state is saved too")
local missing = mods:attach({}):restore(d2)
T.check(type(missing) == "table" and #missing == #d2.mods, "ids that are not defined any more are reported")

-- with engine.entity
local world = require("engine.entity").new()
world:addSystem(Modifiers.system())
local e = world:add({ mods = mods:attach(nil, { speed = 10 }) })
e.mods:add("haste")
for _ = 1, 30 do world:update(dt) end
T.check(not e.mods:has("haste") and e.mods:get("speed") == 10, "the modifiers system runs the timers")

-- stats and events allocate nothing
local quiet = Modifiers.new()
quiet:defineAll({ { id = "x", stats = { { "speed", "add", 1 } }, events = { on_damaged = function(_, ctx) return ctx.amount - 1 end,
  on_update = function() end } }, { id = "y", stats = { { "speed", "mul", 2 } } } })
local qs = quiet:attach({}, { speed = 5 })
qs:add("x"); qs:add("y")
local ctx = { amount = 0 }
qs:update(dt); qs:get("speed"); qs:emit("on_damaged", ctx)
collectgarbage(); collectgarbage("stop")
local before = collectgarbage("count")
for _ = 1, 200 do
  ctx.amount = 9
  qs:update(dt); qs:emit("on_damaged", ctx); qs:get("speed")
end
local grown = collectgarbage("count") - before
collectgarbage("restart")
T.check(grown == 0 and ctx.amount == 8 and qs:get("speed") == 12, "update, emit and get allocate nothing (" .. grown .. " KB)")
