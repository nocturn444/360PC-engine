-- engine/modules/combat/boss: the boss director (phases by health, transition pause and
-- invulnerability, on_phase, telegraph values, the eased bar) and the "rotate" behaviour
-- (cycle, weighted random, no_repeat, deterministic per seed). No allocation per step.
local T = ...
local C = require("engine.modules.combat")
local Boss, Brains, B = C.boss, C.brains, C.behaviours
local Rng = require("engine.rng")

local dt = 1 / 60

local function body(x)
  return { x = x, y = 0, w = 12, h = 10, facing = 1, wall = 0, on_ground = true }
end

local function fighter(max)
  return { health = max, dead = false, invuln = 0,
    stats = { get = function(_, k) if k == "max_health" then return max end return 0 end } }
end

local function fake_attack()
  local a = { config = { cooldown = 0 }, fired = 0 }
  function a:trigger() self.fired = self.fired + 1 end
  return a
end

local function fails(pattern, fn, ...)
  local ok, err = pcall(fn, ...)
  T.check(not ok and tostring(err):find(pattern, 1, true) ~= nil,
    "expected an error with \"" .. pattern .. "\" (got " .. tostring(err) .. ")")
end

local function agent(seed)
  return { body = body(0), target = body(80), fighter = fighter(20), rng = Rng.new(seed or 1),
    attacks = { spit = fake_attack() }, hitboxes = {} }
end

-- A two-attack loop: pick, shoot or charge, back to pick.
local function loop_brain(order, no_repeat)
  return {
    initial = "pick",
    states = {
      pick = { "rotate", options = { { to = "spit" }, { to = "dash", weight = 2 } },
        order = order, no_repeat = no_repeat, pause = 0.1 },
      spit = { "shoot", attack = "spit", windup = 0.3, recovery = 0.2, next = "pick" },
      dash = { "charge", windup = 0.4, time = 0.2, recovery = 0.2, next = "pick" },
    },
  }
end

local SPEC = {
  name = "Test Boss",
  phases = {
    { at = 1, brain = loop_brain("cycle") },
    { at = 0.5, brain = loop_brain("random", true), transition = { time = 1, invulnerable = true } },
    { at = 0.25, brain = { initial = "rest", states = { rest = { "idle" } } } },
  },
}

----------------------------------------------------------------------------
-- build checks
----------------------------------------------------------------------------
fails("phases is a non-empty array", Boss.build, { phases = {} })
fails("the first phase starts at 1", Boss.build, { phases = { { at = 0.5, brain = loop_brain() } } })
fails("at must be lower", Boss.build, { phases = { { at = 1, brain = loop_brain() },
  { at = 1, brain = loop_brain() } } })
fails("brain is a combat.brains spec", Boss.build, { phases = { { at = 1 } } })
fails("goes to the unknown state", Brains.build, { initial = "p", states = {
  p = { "rotate", options = { { to = "nowhere" } } } } })
fails("options is a non-empty array", Brains.build, { initial = "p", states = { p = { "rotate" } } })

local def = Boss.build(SPEC)
T.check(def.phases[1].windups.spit == 0.3 and def.phases[1].windups.dash == 0.4,
  "the windups of each state are read from the spec")

----------------------------------------------------------------------------
-- rotate: cycle goes through the options in order
----------------------------------------------------------------------------
do
  local a = agent(3)
  local b = Boss.new(def, a)
  T.check(b.phase == 1 and b:state() == "pick", "the fight starts in phase 1 at its initial state")
  local seen = {}
  local last = b:state()
  for _ = 1, 60 * 6 do
    b:update(dt)
    local s = b:state()
    if s ~= last and s ~= "pick" then seen[#seen + 1] = s end
    last = s
  end
  T.check(#seen >= 4, "the cycle took several attacks (" .. #seen .. ")")
  T.check(seen[1] == "spit" and seen[2] == "dash" and seen[3] == "spit" and seen[4] == "dash",
    "cycle alternates the options in list order")
  T.check(a.attacks.spit.fired >= 2, "the shoot state fired")
end

----------------------------------------------------------------------------
-- telegraph values during a shoot windup and a charge windup
----------------------------------------------------------------------------
do
  local a = agent(4)
  local b = Boss.new(def, a)
  local spit_t, dash_t, saw_nil = 0, 0, false
  for _ = 1, 60 * 4 do
    b:update(dt)
    if b.telegraph == "spit" then
      if b.telegraph_t > spit_t then spit_t = b.telegraph_t end
    elseif b.telegraph == "dash" then
      if b.telegraph_t > dash_t then dash_t = b.telegraph_t end
    elseif b.telegraph == nil then
      saw_nil = true
      T.check(b.telegraph_t == 0, "no tell: telegraph_t is 0")
    end
  end
  T.check(spit_t > 0.9 and spit_t <= 1, "the shoot windup tell reaches about 1 (" .. spit_t .. ")")
  T.check(dash_t > 0.9 and dash_t <= 1, "the charge windup tell reaches about 1 (" .. dash_t .. ")")
  T.check(saw_nil, "between windups there is no tell")
end

----------------------------------------------------------------------------
-- phases: threshold, transition pause, invulnerability, on_phase once
----------------------------------------------------------------------------
do
  local a = agent(5)
  local calls = {}
  local b = Boss.new(def, a, { on_phase = function(_, i) calls[#calls + 1] = i end })
  for _ = 1, 30 do b:update(dt) end
  a.fighter.health = 11                               -- 55%: still phase 1
  b:update(dt)
  T.check(b.phase == 1 and #calls == 0, "above the threshold the phase stays")
  a.fighter.health = 10                               -- 50%
  b:update(dt)
  T.check(b.phase == 2 and b.transitioning, "at the threshold phase 2 starts with its transition")
  T.check(#calls == 1 and calls[1] == 2, "on_phase is called once with the phase")
  T.check(a.fighter.invuln >= 1 - 1e-9, "the transition makes the fighter invulnerable")
  T.check(a.move_x == 0 and a.move_y == 0 and b:state() == nil, "the boss halts during the transition")
  for _ = 1, 30 do b:update(dt) end
  T.check(b.transitioning, "still in the transition after 0.5 s")
  for _ = 1, 31 do b:update(dt) end
  T.check(not b.transitioning and b:state() == "pick", "after 1 s the phase's brain starts")
  T.check(#calls == 1, "on_phase was not called again")
end

----------------------------------------------------------------------------
-- one hit across two thresholds goes straight to the lowest
----------------------------------------------------------------------------
do
  local a = agent(6)
  local calls = 0
  local b = Boss.new(def, a, { on_phase = function() calls = calls + 1 end })
  b:update(dt)
  a.fighter.health = 4                                -- 20%: past 0.5 and 0.25
  b:update(dt)
  T.check(b.phase == 3 and calls == 1, "two thresholds at once: phase 3, one on_phase")
  T.check(not b.transitioning and b:state() == "rest", "phase 3 has no transition: it starts now")
end

----------------------------------------------------------------------------
-- rotate random with no_repeat: never twice in a row, deterministic per seed
----------------------------------------------------------------------------
local function random_run(seed)
  local spec = { phases = { { at = 1, brain = loop_brain("random", true) } } }
  local a = agent(seed)
  local b = Boss.new(Boss.build(spec), a)
  local seq, last = {}, b:state()
  for _ = 1, 60 * 20 do
    b:update(dt)
    local s = b:state()
    if s ~= last and s ~= "pick" then seq[#seq + 1] = s end
    last = s
  end
  return seq
end
do
  local s1, s2 = random_run(42), random_run(42)
  T.check(#s1 >= 8, "random rotation took several attacks (" .. #s1 .. ")")
  local same, repeats = #s1 == #s2, 0
  for i = 1, #s1 do
    if s1[i] ~= s2[i] then same = false end
    if i > 1 and s1[i] == s1[i - 1] then repeats = repeats + 1 end
  end
  T.check(same, "the same seed gives the same attack sequence")
  T.check(repeats == 0, "no_repeat never takes the same option twice in a row")
end
do
  -- without no_repeat and with a heavy weight, repeats do happen
  local a = { body = body(0), target = body(80), rng = Rng.new(7) }
  local st = B.rotate({ options = { { to = "x", weight = 9 }, { to = "y", weight = 1 } }, pause = 0 })
  local m = { time = 0 }
  st.enter(m, a)
  local xs = 0
  for _ = 1, 200 do
    if st.update(m, a) == "x" then xs = xs + 1 end
  end
  T.check(xs > 140 and xs < 200, "weights steer the random pick (" .. xs .. " of 200)")
end

----------------------------------------------------------------------------
-- the bar eases: fast down, slow up, never past the real value
----------------------------------------------------------------------------
do
  local a = agent(8)
  local b = Boss.new(Boss.build({ phases = { { at = 1, brain = { initial = "i",
    states = { i = { "idle" } } } } } }), a)
  T.check(b.bar == 1, "the bar starts full")
  a.fighter.health = 10
  b:update(dt)
  T.check(b.bar < 1 and b.bar > 0.5, "the bar moves down towards the health")
  for _ = 1, 30 do b:update(dt) end
  T.check(math.abs(b.bar - 0.5) < 1e-9, "the bar reaches the health and stops there")
  a.fighter.health = 20
  for _ = 1, 30 do b:update(dt) end
  T.check(b.bar > 0.5 and b.bar < 1, "the bar fills up more slowly")
  a.fighter.dead, a.fighter.health = true, 0
  for _ = 1, 120 do b:update(dt) end
  T.check(b.bar == 0 and b.telegraph == nil, "a dead boss: empty bar, no tell")
end

----------------------------------------------------------------------------
-- no allocation per step once warm (a full loop of both phases' brains)
----------------------------------------------------------------------------
do
  local a = agent(9)
  local b = Boss.new(def, a)
  for _ = 1, 600 do b:update(dt) end
  a.fighter.health = 10
  for _ = 1, 600 do b:update(dt) end                 -- phase 2 made its machine
  collectgarbage(); collectgarbage("stop")
  local before = collectgarbage("count")
  for _ = 1, 600 do b:update(dt) end
  local grown = collectgarbage("count") - before
  collectgarbage("restart")
  T.check(grown == 0, "the director allocates nothing per step (" .. grown .. " KB)")
end
