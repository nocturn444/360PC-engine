-- engine/modules/combat/brains: building fsm definitions from data. The walker brain of
-- examples/rooms (copied here) rebuilt from data behaves step by step exactly like the
-- hand-written one; the registry can be extended; ctx fills opts but the spec wins; every error
-- names the state and the field; a built definition allocates nothing per step.
local T = ...
local C = require("engine.modules.combat")
local Brains = C.brains
local B = C.behaviours
local Rng = require("engine.rng")
local Grid = require("engine.modules.platformer.grid")

local dt = 1 / 60

local function body(x, y)
  return { x = x, y = y or 0, w = 12, h = 10, facing = 1, wall = 0, on_ground = true }
end

local function hitbox()
  local h = { active = false }
  function h:activate() self.active = true end
  function h:deactivate() self.active = false end
  return h
end

local function fails(pattern, fn, ...)
  local ok, err = pcall(fn, ...)
  T.check(not ok and tostring(err):find(pattern, 1, true) ~= nil,
    "expected an error with \"" .. pattern .. "\" (got " .. tostring(err) .. ")")
end

----------------------------------------------------------------------------
-- idle: a state that halts
----------------------------------------------------------------------------
do
  local agent = { body = body(0), move_x = 1, move_y = 1 }
  local def = Brains.build({ initial = "idle", states = { idle = { "idle" } } })
  local m = C.fsm.new(def, agent)
  T.check(agent.move_x == 0 and agent.move_y == 0, "idle halts on enter")
  agent.move_x, agent.move_y = 1, 1
  m:update(dt)
  T.check(agent.move_x == 0 and agent.move_y == 0, "idle halts on update")
end

----------------------------------------------------------------------------
-- The walker brain of examples/rooms, hand-written and rebuilt from data
----------------------------------------------------------------------------
do
  local function blocked(agent) return agent.body.wall ~= 0 end
  local HAND = { initial = "patrol", states = {
    patrol = B.patrol({ speed = 22, pause = { 0.3, 0.9 }, blocked = blocked }),
    chase = B.chase({ speed = 45, stop = 8 }),
    attack = B.attack({ hitbox = "bite", windup = 0.3, active = 0.12, recovery = 0.4, next = "chase" }),
  } }
  HAND.states.patrol.transitions = { { to = "chase", when = B.target_within(80, "xy") } }
  HAND.states.chase.transitions = {
    { to = "attack", when = B.target_within(16, "xy") },
    { to = "patrol", when = B.target_beyond(120, "xy") },
  }

  local SPEC = {
    initial = "patrol",
    states = {
      patrol = { "patrol", speed = 22, pause = { 0.3, 0.9 } },
      chase = { "chase", speed = 45, stop = 8 },
      attack = { "attack", hitbox = "bite", windup = 0.3, active = 0.12, recovery = 0.4, next = "chase" },
    },
    transitions = {
      patrol = { { to = "chase", when = { "target_within", 80, "xy" } } },
      chase = {
        { to = "attack", when = { "target_within", 16, "xy" } },
        { to = "patrol", when = { "target_beyond", 120, "xy" } },
      },
    },
  }
  local DATA = Brains.build(SPEC, { blocked = blocked })

  local target = body(60)
  local function make_agent(seed)
    return { body = body(0), target = target, rng = Rng.new(seed),
      patrol_points = { { x = -40 }, { x = 40 } }, hitboxes = { bite = hitbox() } }
  end
  local ah, ad = make_agent(123), make_agent(123)
  local mh, md = C.fsm.new(HAND, ah), C.fsm.new(DATA, ad)

  local function same()
    return mh.state == md.state and mh.previous == md.previous
      and mh.phase == md.phase and mh.time == md.time and mh.changes == md.changes
      and ah.move_x == ad.move_x and ah.move_y == ad.move_y
      and ah.move_speed == ad.move_speed and ah.jump == ad.jump
      and ah.body.x == ad.body.x and ah.body.y == ad.body.y
      and ah.body.facing == ad.body.facing
      and ah.patrol_i == ad.patrol_i and ah.patrol_dir == ad.patrol_dir
      and ah.patrol_wait == ad.patrol_wait and ah.patrol_held == ad.patrol_held
  end

  local seen = {}
  local steps = 1200
  for i = 1, steps do
    if i <= 150 then target.x = 60
    elseif i <= 350 then target.x = 500
    elseif i <= 450 then target.x = 20
    else target.x = 60 end
    local wall = (i % 97 == 0) and 1 or 0
    ah.body.wall, ad.body.wall = wall, wall
    mh:update(dt)
    md:update(dt)
    B.move(ah, dt)
    B.move(ad, dt)
    seen[mh.state] = true
    if not same() then
      T.check(false, "walker step " .. i .. ": the data brain differs from the hand-written one")
    end
  end
  T.check(md.state ~= nil, "the walker data brain ran " .. steps .. " steps")
  T.check(seen.patrol and seen.chase and seen.attack, "the walker test visited patrol, chase and attack")
  T.check(SPEC.states.patrol[1] == "patrol" and SPEC.states.patrol.speed == 22,
    "building did not mutate the state spec")
  T.check(SPEC.states.patrol.blocked == nil, "ctx is not written into the spec")
  T.check(SPEC.transitions.patrol[1].when[1] == "target_within",
    "building did not mutate the transition spec")
end

----------------------------------------------------------------------------
-- The registry can be extended; plain functions are conditions
----------------------------------------------------------------------------
do
  local captured
  Brains.behaviour("test_probe", function(opts)
    captured = opts
    local state = {}
    function state.enter(_, agent) agent.probe_entered = (agent.probe_entered or 0) + 1 end
    function state.update(_, agent) agent.probe_updated = (agent.probe_updated or 0) + 1 end
    return state
  end)
  Brains.condition("test_flag", function(args, ctx)
    local value = args[2]
    if value == nil then value = ctx and ctx.flag end
    return function() return value end
  end)

  local def = Brains.build({ initial = "probe", states = {
    probe = { "test_probe", next = "done" },
    done = { "idle" },
  }, transitions = {
    probe = { { to = "done", when = { "test_flag", true } } },
  } }, { flag = false })
  local agent = {}
  local m = C.fsm.new(def, agent)
  T.check(agent.probe_entered == 1, "a registered behaviour runs")
  m:update(dt)
  T.check(m.state == "done" and agent.probe_updated == 1, "a registered condition fires")
  T.check(captured and captured.next == "done", "a registered behaviour receives the spec opts")
end

----------------------------------------------------------------------------
-- ctx fills opts, the spec wins, and nothing of the caller is mutated
----------------------------------------------------------------------------
do
  Brains.behaviour("test_capture", function(opts)
    local state = {}
    function state.enter(_, agent) agent.captured = opts end
    return state
  end)
  local ctxfn = function() return false end
  local ctx = { a = 1, b = 2, blocked = ctxfn }
  local entry = { "test_capture", a = 10, c = 30 }
  local spec = { initial = "s", states = { s = entry } }
  local def = Brains.build(spec, ctx)
  local agent = {}
  C.fsm.new(def, agent)
  T.check(agent.captured.a == 10, "an opt in the spec wins over ctx")
  T.check(agent.captured.b == 2, "ctx fills an opt the spec leaves out")
  T.check(agent.captured.c == 30, "the spec's own opts are kept")
  T.check(agent.captured.blocked == ctxfn, "ctx can supply a function opt")
  T.check(entry[1] == "test_capture" and entry.a == 10, "the state spec is not mutated")
  T.check(ctx.a == 1 and ctx.b == 2 and not ctx.c, "the ctx table is not mutated")
end

----------------------------------------------------------------------------
-- all, any, not, a plain function and target_in_sight from ctx
----------------------------------------------------------------------------
do
  local function run(when, target, ctx, agent_extra)
    local agent = { body = body(0), target = target }
    for k, v in pairs(agent_extra or {}) do agent[k] = v end
    local def = Brains.build({ initial = "s", states = {
      s = { "idle" }, done = { "idle" },
    }, transitions = {
      s = { { to = "done", when = when } },
    } }, ctx)
    local m = C.fsm.new(def, agent)
    m:update(dt)
    return m.state == "done"
  end

  local near = body(50)
  T.check(run({ "all", { "target_within", 80, "xy" }, { "not", { "target_below", 10 } } }, near),
    "all with not: both hold")
  T.check(not run({ "all", { "target_within", 80, "xy" }, { "not", { "target_below", 10 } } },
    body(500)), "all: one fails, then all fails")
  T.check(run({ "any", { "target_within", 10, "xy" }, { "target_below", 10 } }, body(0, 100)),
    "any: one is enough")
  T.check(run(function(_, agent) return agent.go end, near, nil, { go = true }),
    "a plain function is a condition")
  T.check(not run(function() return false end, near), "a plain function that is false blocks")

  local grid = Grid.new({ "...", "#..", "..." }, { tile_size = 10 })
  local blocked_target = body(0, 20)                      -- centres (6,5) and (5,25)
  T.check(not run({ "target_in_sight", 40 }, blocked_target, { grid = grid }),
    "target_in_sight takes its grid from ctx")
  T.check(run({ "target_in_sight", 40 }, body(20, 20), { grid = grid }),
    "target_in_sight from ctx: a clear diagonal")
  T.check(run({ "target_in_sight", 40 }, blocked_target, nil),
    "target_in_sight without any grid is clear")
end

----------------------------------------------------------------------------
-- Errors name the state and the field
----------------------------------------------------------------------------
do
  fails("spec must be a table", Brains.build, nil)
  fails("needs an initial state name", Brains.build, { states = {} })
  fails("needs states", Brains.build, { initial = "x" })
  fails("initial state x is not in states", Brains.build, { initial = "x", states = { y = { "idle" } } })
  fails("ctx must be a table", Brains.build, { initial = "x", states = { x = { "idle" } } }, 5)

  fails("state x: the entry must be a table", Brains.build, { initial = "x", states = { x = 5 } })
  fails("state x: the first element must be the behaviour name", Brains.build,
    { initial = "x", states = { x = { 5 } } })
  fails("state x: unknown behaviour nope", Brains.build,
    { initial = "x", states = { x = { "nope" } } })
  fails("state x: next goes to the unknown state nowhere", Brains.build,
    { initial = "x", states = { x = { "shoot", attack = "a", next = "nowhere" } } })
  fails("a state name must be a string", Brains.build,
    { initial = "x", states = { x = { "idle" }, [1] = { "idle" } } })

  fails("field transitions must be a table", Brains.build,
    { initial = "x", states = { x = { "idle" } }, transitions = 5 })
  fails("state x: field transitions must be a list", Brains.build,
    { initial = "x", states = { x = { "idle" } }, transitions = { x = 5 } })
  fails("state x: transition 1 must be a table", Brains.build,
    { initial = "x", states = { x = { "idle" } }, transitions = { x = { 5 } } })
  fails("transition 1: field to must be a state name", Brains.build,
    { initial = "x", states = { x = { "idle" } }, transitions = { x = { { when = function() end } } } })
  fails("transition 1 needs when or after", Brains.build,
    { initial = "x", states = { x = { "idle" } }, transitions = { x = { { to = "x" } } } })
  fails("transition 1: field after must be a number", Brains.build,
    { initial = "x", states = { x = { "idle" } }, transitions = { x = { { to = "x", after = "1" } } } })
  fails("state x: unknown condition nope", Brains.build,
    { initial = "x", states = { x = { "idle" } }, transitions = { x = { { to = "x", when = { "nope" } } } } })
  fails("a condition must be a table or a function", Brains.build,
    { initial = "x", states = { x = { "idle" } }, transitions = { x = { { to = "x", when = 5 } } } })
  fails("the first condition element must be its name", Brains.build,
    { initial = "x", states = { x = { "idle" } }, transitions = { x = { { to = "x", when = { 5 } } } } })
  fails("\"not\" takes one condition", Brains.build,
    { initial = "x", states = { x = { "idle" } }, transitions = { x = { { to = "x", when = { "not" } } } } })

  fails("behaviour: the name must be a string", Brains.behaviour, 5, function() end)
  fails("behaviour: test_bad needs a function", Brains.behaviour, "test_bad", 5)
  fails("condition: the name must be a string", Brains.condition, 5, function() end)
  fails("condition: test_bad needs a function", Brains.condition, "test_bad", 5)

  Brains.condition("test_not_a_function", function() return 5 end)
  fails("the condition test_not_a_function did not return a function", Brains.build,
    { initial = "x", states = { x = { "idle" } },
      transitions = { x = { { to = "x", when = { "test_not_a_function" } } } } })

  -- an unknown target state is left to fsm, which names it
  local def = Brains.build({ initial = "x", states = { x = { "idle" } },
    transitions = { x = { { to = "missing", after = 1 } } } })
  fails("unknown state missing", C.fsm.new, def, {})
end

----------------------------------------------------------------------------
-- A built definition allocates nothing per step once warm
----------------------------------------------------------------------------
do
  local function blocked(agent) return agent.body.wall ~= 0 end
  local def = Brains.build({
    initial = "patrol",
    states = {
      patrol = { "patrol", speed = 22, pause = { 0.3, 0.9 } },
      chase = { "chase", speed = 45, stop = 8 },
      attack = { "attack", hitbox = "bite", windup = 0.3, active = 0.12, recovery = 0.4, next = "chase" },
    },
    transitions = {
      patrol = { { to = "chase", when = { "target_within", 80, "xy" } } },
      chase = {
        { to = "attack", when = { "target_within", 16, "xy" } },
        { to = "patrol", when = { "target_beyond", 120, "xy" } },
      },
    },
  }, { blocked = blocked })
  local agent = { body = body(0), target = body(60), rng = Rng.new(9),
    patrol_points = { { x = -40 }, { x = 40 } }, hitboxes = { bite = hitbox() } }
  local m = C.fsm.new(def, agent)
  local function step() m:update(dt) end
  for _ = 1, 200 do step() end
  collectgarbage(); collectgarbage("stop")
  local before = collectgarbage("count")
  for _ = 1, 600 do step() end
  local grown = collectgarbage("count") - before
  collectgarbage("restart")
  T.check(grown == 0, "a built brain allocates nothing per step once warm (" .. grown .. " KB)")
end
