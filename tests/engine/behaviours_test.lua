-- engine/modules/combat/behaviours: the new enemy states (shoot, charge, hop, fly, keep_away),
-- the conditions, fly_move and the jump input, with timings at 60 Hz, aims and rotations,
-- determinism and no allocation once warm.
local T = ...
local C = require("engine.modules.combat")
local B = C.behaviours
local Rng = require("engine.rng")
local Grid = require("engine.modules.platformer.grid")
local Collision = require("engine.modules.platformer.collision")
local bump = require("lib.bump.bump")

local dt = 1 / 60
local function body(x, y, facing)
  return { x = x, y = y or 0, w = 10, h = 10, facing = facing or 1 }
end
local function centre(b) return b.x + (b.w or 0) * 0.5, b.y + (b.h or 0) * 0.5 end
local function dist(a, b)
  local ax, ay = centre(a)
  local bx, by = centre(b)
  local dx, dy = bx - ax, by - ay
  return math.sqrt(dx * dx + dy * dy)
end

-- A fake attack that records each trigger's direction (false when it was trigger()).
local function spy(cooldown, angle)
  local a = { config = { cooldown = cooldown or 0, angle = angle }, calls = 0, args = {} }
  function a:trigger(ax, ay)
    self.calls = self.calls + 1
    if ax ~= nil or ay ~= nil then
      self.args[self.calls] = { ax = ax or 0, ay = ay or 0 }
    else
      self.args[self.calls] = false
    end
    return true
  end
  return a
end

local function hitbox()
  local h = { active = false, activates = 0, deactivates = 0 }
  function h:activate()
    self.active, self.activates = true, self.activates + 1
  end
  function h:deactivate()
    self.active, self.deactivates = false, self.deactivates + 1
  end
  return h
end

----------------------------------------------------------------------------
-- shoot: phases and timings at 60 Hz
----------------------------------------------------------------------------
do
  local a = spy(0)
  local agent = { body = body(0, 0), attacks = { shot = a } }
  local def = { initial = "shoot", states = {
    shoot = B.shoot({ attack = "shot", aim = "facing", windup = 6 * dt, interval = 6 * dt,
      volleys = 2, recovery = 12 * dt, next = "done" }),
    done = {},
  } }
  local m = C.fsm.new(def, agent)
  T.check(m.phase == "windup" and a.calls == 0, "shoot starts in windup with nothing fired")
  for _ = 1, 5 do m:update(dt) end
  T.check(m.phase == "windup" and a.calls == 0, "windup: 5 steps, still no shot")
  m:update(dt)
  T.check(a.calls == 1 and m.phase == "firing", "step 6: the first volley, phase firing")
  for _ = 1, 5 do m:update(dt) end
  T.check(a.calls == 1, "between volleys only the interval runs")
  m:update(dt)
  T.check(a.calls == 2 and m.phase == "recovery", "step 12: the second volley, then recovery")
  for _ = 1, 11 do m:update(dt) end
  T.check(m.state == "shoot" and m.phase == "recovery", "recovery: 12 steps")
  m:update(dt)
  T.check(m.state == "done", "then it goes to next")
end

----------------------------------------------------------------------------
-- shoot: facing, aimed, fixed angle and rotation
----------------------------------------------------------------------------
local function one_shot(opts, agent)
  opts.attack, opts.windup, opts.recovery = "shot", opts.windup or 0, opts.recovery or 0
  local def = { initial = "shoot", states = { shoot = B.shoot(opts) } }
  local m = C.fsm.new(def, agent)
  local n = opts.steps or 1
  for _ = 1, n do m:update(dt) end
  return agent.attacks.shot, m
end

do
  local a = spy(0)
  local agent = { body = body(0, 0), attacks = { shot = a }, target = body(100, 0) }
  one_shot({ aim = "target" }, agent)
  local arg = a.args[1]
  T.near(arg.ax, 1, "aim target to the right (x)")
  T.near(arg.ay, 0, "aim target to the right (y)")

  a = spy(0)
  agent = { body = body(0, 0), attacks = { shot = a }, target = body(0, -100) }
  one_shot({ aim = "target" }, agent)
  arg = a.args[1]
  T.near(arg.ax, 0, "aim target above (x)")
  T.near(arg.ay, -1, "aim target above (y)")

  a = spy(0)
  agent = { body = body(0, 0), attacks = { shot = a } }
  one_shot({ aim = "angle", angle = 30 }, agent)
  arg = a.args[1]
  T.near(arg.ax, math.cos(math.pi / 6), "angle 30 above the facing (x)")
  T.near(arg.ay, -math.sin(math.pi / 6), "angle 30 above the facing (y)")

  a = spy(0)
  agent = { body = body(0, 0), attacks = { shot = a }, target = body(-100, 0) }
  one_shot({ aim = "target" }, agent)
  arg = a.args[1]
  T.near(arg.ax, -1, "aim target to the left (x)")
  T.near(arg.ay, 0, "aim target to the left (y)")

  -- rotate: 30 more degrees per volley, two volleys 6 steps apart
  a = spy(0)
  agent = { body = body(0, 0), attacks = { shot = a } }
  one_shot({ aim = "angle", angle = 30, rotate = 30, volleys = 2, interval = 6 * dt,
    steps = 6 }, agent)
  T.check(a.calls == 2, "two volleys")
  T.near(a.args[1].ax, math.cos(math.pi / 6), "first volley at 30")
  T.near(a.args[1].ay, -math.sin(math.pi / 6), "first volley at 30 (y)")
  T.near(a.args[2].ax, math.cos(math.pi / 3), "rotate: the second at 60")
  T.near(a.args[2].ay, -math.sin(math.pi / 3), "rotate: the second at 60 (y)")

  -- facing with no rotation calls trigger() and lets the config's own angle stand
  a = spy(0)
  agent = { body = body(0, 0), attacks = { shot = a } }
  one_shot({ aim = "facing" }, agent)
  T.check(a.args[1] == false, "facing without rotation: trigger() with no direction")

  -- facing with rotation: the first volley is the config's own angle, the next adds rotate
  a = spy(0, 10)
  agent = { body = body(0, 0), attacks = { shot = a } }
  one_shot({ aim = "facing", rotate = 20, volleys = 2, interval = 6 * dt, steps = 6 }, agent)
  T.check(a.args[1] == false, "facing rotate: the first volley leaves the config angle alone")
  T.near(a.args[2].ax, math.cos(30 * math.pi / 180), "facing rotate: config angle + rotate (x)")
  T.near(a.args[2].ay, -math.sin(30 * math.pi / 180), "facing rotate: config angle + rotate (y)")

  -- a cooldown longer than the interval is an error at enter
  a = spy(1)
  agent = { body = body(0, 0), attacks = { shot = a } }
  T.check(not pcall(C.fsm.new, { initial = "shoot", states = {
    shoot = B.shoot({ attack = "shot", volleys = 2, interval = 0.1 }) } }, agent),
    "shoot: cooldown longer than interval is an error")
  T.check(not pcall(C.fsm.new, { initial = "shoot", states = {
    shoot = B.shoot({ attack = "missing" }) } }, { body = body(0, 0), attacks = {} }),
    "shoot: an unknown attack is an error")
end

----------------------------------------------------------------------------
-- charge: windup, dash, recovery, a fixed direction, blocked -> stun
----------------------------------------------------------------------------
do
  local agent = { body = body(0, 0), target = body(200, 0), hitboxes = { dash = hitbox() } }
  local def = { initial = "charge", states = {
    charge = B.charge({ speed = 120, windup = 6 * dt, time = 12 * dt, recovery = 6 * dt,
      stun = 18 * dt, hitbox = "dash", next = "done" }),
    done = {},
  } }
  local m = C.fsm.new(def, agent)
  for _ = 1, 5 do m:update(dt) end
  T.check(m.phase == "windup" and agent.move_x == 0 and not agent.hitboxes.dash.active,
    "charge: windup stands still, hitbox off")
  m:update(dt)
  T.check(m.phase == "dash" and agent.move_x == 1 and agent.move_speed == 120
    and agent.hitboxes.dash.active, "charge: dash towards the target, hitbox on")
  agent.target.x = -1000
  m:update(dt)
  T.check(agent.move_x == 1, "the dash direction is fixed at the end of the windup")
  for _ = 1, 11 do m:update(dt) end                  -- step 18: dash is over
  T.check(m.phase == "recovery" and not agent.hitboxes.dash.active and agent.move_x == 0,
    "charge: after the dash time, recovery with the hitbox off")
  for _ = 1, 5 do m:update(dt) end
  T.check(m.state == "charge" and m.phase == "recovery", "recovery lasts its time")
  m:update(dt)
  T.check(m.state == "done", "charge: then next")

  -- blocked: recovery becomes stun, even if it was a short dash
  agent = { body = body(0, 0), target = body(200, 0), hitboxes = { dash = hitbox() } }
  m = C.fsm.new({ initial = "charge", states = {
    charge = B.charge({ speed = 120, windup = 6 * dt, time = 12 * dt, recovery = 6 * dt,
      stun = 18 * dt, hitbox = "dash", blocked = function(a) return a.blocked end,
      next = "done" }),
    done = {},
  } }, agent)
  for _ = 1, 6 do m:update(dt) end
  T.check(m.phase == "dash", "blocked test: dashing")
  agent.blocked = true
  m:update(dt)
  T.check(m.phase == "recovery" and m.stun_time == 18 * dt and not agent.hitboxes.dash.active,
    "blocked: the dash stops and uses stun")
  for _ = 1, 17 do m:update(dt) end
  T.check(m.state == "charge" and m.phase == "recovery", "stun is longer than recovery")
  m:update(dt)
  T.check(m.state == "done", "after the stun, next")

  -- distance: a short dash stops even before its time
  agent = { body = body(0, 0), target = body(1000, 0) }
  m = C.fsm.new({ initial = "charge", states = {
    charge = B.charge({ speed = 120, windup = 0, time = 100, distance = 10, next = "done" }),
    done = {},
  } }, agent)
  for _ = 1, 5 do m:update(dt) end
  T.check(m.phase == "dash", "distance: still dashing before the limit")
  m:update(dt)
  T.check(m.phase == "recovery", "distance: stops at the pixel limit")

  -- axis xy: a straight line
  agent = { body = body(0, 0), target = body(30, 40) }
  m = C.fsm.new({ initial = "charge", states = {
    charge = B.charge({ axis = "xy", windup = 0, time = 1 }) } }, agent)
  m:update(dt)
  T.near(agent.charge_dir, 0.6, "charge xy: x direction")
  T.near(agent.charge_dir_y, 0.8, "charge xy: y direction")
end

----------------------------------------------------------------------------
-- hop: jump once per landing, keep the direction in the air
----------------------------------------------------------------------------
do
  local agent = { body = body(0, 0), target = body(100, 0) }
  agent.body.on_ground = true
  local m = C.fsm.new({ initial = "hop", states = {
    hop = B.hop({ wait = 6 * dt, speed = 80, jump_velocity = 250 }) } }, agent)
  T.check(agent.jump_velocity == 250, "hop writes agent.jump_velocity on enter")
  for _ = 1, 5 do
    m:update(dt)
    T.check(not agent.jump, "hop waits on the ground")
  end
  m:update(dt)
  T.check(agent.jump == true and agent.move_x == 1 and agent.move_speed == 80,
    "hop: after the wait, jump once towards the target")
  agent.body.on_ground = false
  m:update(dt)
  T.check(not agent.jump and agent.move_x == 1, "in the air: jump is off, the direction stays")
  for _ = 1, 10 do m:update(dt) end
  T.check(agent.move_x == 1, "still moving forward in the air")
  agent.body.on_ground = true
  m:update(dt)
  T.check(agent.move_x == 0 and not agent.jump, "landing halts it")
  local second
  for _ = 1, 6 do
    m:update(dt)
    if agent.jump then second = true end
  end
  T.check(second, "after the wait on the ground it hops again")
end

----------------------------------------------------------------------------
-- fly: hover radius, follow keep band, swoop time
----------------------------------------------------------------------------
do
  local agent = { body = body(95, 95), anchor = { x = 100, y = 100 } }
  local m = C.fsm.new({ initial = "fly", states = {
    fly = B.fly({ mode = "hover", radius = 8, period = 2, speed = 40 }) } }, agent)
  local far = 0
  local ax, ay = agent.anchor.x, agent.anchor.y
  for _ = 1, 600 do
    m:update(dt)
    B.move(agent, dt)
    local x, y = centre(agent.body)
    local d = math.sqrt((x - ax) * (x - ax) + (y - ay) * (y - ay))
    if d > far then far = d end
  end
  T.check(far <= 9, "hover stays around its anchor within radius + a step (" .. far .. ")")

  local enemy = { body = body(0, 0), target = body(200, 0) }
  m = C.fsm.new({ initial = "fly", states = {
    fly = B.fly({ mode = "follow", keep = 60, band = 12, speed = 120, bob = 4 }) } }, enemy)
  local first = nil
  for i = 1, 600 do
    m:update(dt)
    if i == 1 then first = enemy.move_x end
    B.move(enemy, dt)
  end
  T.check(first == 1, "follow: from far away it heads for the target")
  local d = dist(enemy.body, enemy.target)
  T.check(d >= 46 and d <= 64, "follow holds the keep band (" .. d .. ")")

  -- too close: backs off
  enemy = { body = body(0, 0), target = body(20, 0) }
  m = C.fsm.new({ initial = "fly", states = { fly = B.fly({ mode = "follow", keep = 60, band = 12 }) } }, enemy)
  m:update(dt)
  T.check(enemy.move_x == -1, "follow: closer than keep - band, it backs off")

  -- swoop: a direction fixed on enter, then next after time
  local target = body(100, 0)
  enemy = { body = body(0, 0), target = target }
  m = C.fsm.new({ initial = "fly", states = {
    fly = B.fly({ mode = "swoop", speed = 100, time = 12 * dt, next = "done" }),
    done = {},
  } }, enemy)
  m:update(dt)
  T.check(enemy.move_x == 1 and enemy.move_y == 0, "swoop heads at the target on enter")
  target.x = -1000
  for _ = 1, 10 do m:update(dt); B.move(enemy, dt) end
  T.check(enemy.move_x == 1, "swoop keeps the direction it took on enter")
  m:update(dt)
  T.check(m.state == "done", "swoop: after time, next")
end

----------------------------------------------------------------------------
-- keep_away: away, towards, still
----------------------------------------------------------------------------
do
  local function kite(tx)
    local agent = { body = body(0, 0), target = body(tx, 0) }
    local m = C.fsm.new({ initial = "keep", states = {
      keep = B.keep_away({ min = 48, max = 96, speed = 40 }) } }, agent)
    m:update(dt)
    return agent
  end
  local a = kite(30)
  T.check(a.move_x == -1 and a.move_speed == 40 and a.body.facing == 1,
    "keep_away: too close, walks away facing the target")
  a = kite(300)
  T.check(a.move_x == 1 and a.move_speed == 40, "keep_away: too far, walks towards")
  a = kite(60)
  T.check(a.move_x == 0 and a.move_y == 0 and a.body.facing == 1,
    "keep_away: in between, stands still facing it")
  -- xy
  local agent = { body = body(0, 0), target = body(0, -200) }
  local m = C.fsm.new({ initial = "keep", states = {
    keep = B.keep_away({ min = 48, max = 96, axis = "xy" }) } }, agent)
  m:update(dt)
  T.check(agent.move_y == -1, "keep_away xy: away along y")
end

----------------------------------------------------------------------------
-- Conditions
----------------------------------------------------------------------------
do
  local grid = Grid.new({ "...", "#..", "..." }, { tile_size = 10 })
  local agent = { body = body(0, 0), target = body(0, 20) }        -- centres (5,5) and (5,25)
  local los = B.target_in_sight(grid, 40)
  T.check(not los(nil, agent), "target_in_sight: a solid tile between them blocks it")
  T.check(B.target_in_sight(nil, 40)(nil, agent), "target_in_sight: without a grid it is clear")
  agent.target = body(20, 20)                                      -- line clear of the solid
  T.check(los(nil, agent), "target_in_sight: a clear diagonal")
  T.check(not B.target_in_sight(grid, 5)(nil, agent), "target_in_sight: out of range")
  agent.target = nil
  T.check(not los(nil, agent), "target_in_sight: no target is not in sight")

  agent = { body = body(0, 0), target = body(0, -30) }              -- target above
  T.check(B.target_above(10)(nil, agent), "target_above")
  T.check(not B.target_above(40)(nil, agent), "target_above: not enough")
  T.check(B.target_below(10)(nil, { body = body(0, 0), target = body(0, 30) }), "target_below")

  agent = { body = { x = 0, y = 0, w = 10, h = 10, on_ground = true } }
  T.check(B.grounded()(nil, agent), "grounded: body.on_ground")

  local fighter = { health = 5, dead = false, stats = { get = function() return 10 end } }
  T.check(B.health_below(0.6)(nil, { fighter = fighter }), "health_below: 5 / 10 is below 0.6")
  T.check(not B.health_below(0.5)(nil, { fighter = fighter }), "health_below: not below exactly")
  T.check(not B.health_below(0.9)(nil, {}), "health_below: no fighter is false")

  local above = B.target_above(10)
  T.check(B.all(above, B.grounded())(nil, { body = agent.body, target = body(0, -30) }),
    "all: every condition")
  T.check(B.any(B.target_below(10), B.grounded())(nil, { body = agent.body, target = body(0, -30) }),
    "any: one is enough")
  T.check(not B.negate(B.grounded())(nil, agent), "negate")
end

----------------------------------------------------------------------------
-- input: jump is pressed only on the step agent.jump is true
----------------------------------------------------------------------------
do
  local agent = { body = body(0, 0) }
  local input = B.input(agent)
  T.check(not input:pressed("jump") and not input:down("jump"), "input: no jump by default")
  agent.jump = true
  T.check(input:pressed("jump") and input:down("jump"), "input: the jump step is pressed")
  agent.jump = false
  T.check(not input:pressed("jump"), "input: and only that step")
end

----------------------------------------------------------------------------
-- fly_move: moves the body, keeps px/py, reports wall, floor and ceiling
----------------------------------------------------------------------------
do
  local function world_with(rect)
    local w = bump.newWorld(16)
    local b = { x = 0, y = 0, w = 10, h = 10, px = 0, py = 0 }
    w:add(b, b.x, b.y, b.w, b.h)
    rect.kind = "solid"
    w:add(rect, rect.x, rect.y, rect.w, rect.h)
    return w, b
  end
  local w, b = world_with({ x = 30, y = 0, w = 10, h = 10 })
  local agent = { body = b, move_x = 1, move_y = 0, move_speed = 300 }
  B.fly_move(agent, w, Collision.filter, 0.1)
  T.check(b.x == 20 and b.px == 0 and b.py == 0, "fly_move: moved and kept the old position")
  T.check(b.wall == 1 and not b.floor and not b.ceiling, "fly_move: a wall on the right stops it")
  T.check(w:getRect(b) ~= nil, "fly_move: the bump world knows the new position")

  w, b = world_with({ x = 0, y = 30, w = 100, h = 10 })
  agent = { body = b, move_x = 0, move_y = 1, move_speed = 300 }
  B.fly_move(agent, w, Collision.filter, 0.1)
  T.check(b.y == 20 and b.floor and b.wall == 0, "fly_move: a floor below")

  w, b = world_with({ x = 0, y = -30, w = 100, h = 10 })
  b.y = 0
  w:update(b, 0, 0)
  agent = { body = b, move_x = 0, move_y = -1, move_speed = 300 }
  B.fly_move(agent, w, Collision.filter, 0.1)
  T.check(b.y == -20 and b.ceiling and not b.floor, "fly_move: a ceiling above")
end

----------------------------------------------------------------------------
-- Allocation: shoot, charge, hop and fly allocate nothing once warm
----------------------------------------------------------------------------
do
  local function measured(step)
    for _ = 1, 200 do step() end
    collectgarbage(); collectgarbage("stop")
    local before = collectgarbage("count")
    for _ = 1, 600 do step() end
    local grown = collectgarbage("count") - before
    collectgarbage("restart")
    return grown
  end

  -- shoot, cycling back into itself
  local shot = { config = { cooldown = 0 }, n = 0 }
  function shot:trigger() self.n = self.n + 1; return true end
  local agent = { body = body(0, 0), target = body(100, 0), attacks = { shot = shot } }
  local m = C.fsm.new({ initial = "shoot", states = {
    shoot = B.shoot({ attack = "shot", aim = "target", windup = 2 * dt, interval = 2 * dt,
      volleys = 2, recovery = 2 * dt, next = "shoot" }) } }, agent)
  local grown = measured(function() m:update(dt) end)
  T.check(grown == 0, "shoot: no allocation once warm (" .. grown .. " KB)")

  -- charge, cycling back into itself
  agent = { body = body(0, 0), target = body(100, 0), hitboxes = { dash = hitbox() } }
  m = C.fsm.new({ initial = "charge", states = {
    charge = B.charge({ speed = 100, windup = 2 * dt, time = 4 * dt, recovery = 2 * dt,
      hitbox = "dash", next = "charge" }) } }, agent)
  grown = measured(function() m:update(dt) end)
  T.check(grown == 0, "charge: no allocation once warm (" .. grown .. " KB)")

  -- hop, with an rng wait
  agent = { body = body(0, 0), target = body(100, 0), rng = Rng.new(7) }
  agent.body.on_ground = true
  m = C.fsm.new({ initial = "hop", states = {
    hop = B.hop({ wait = { 2 * dt, 4 * dt }, speed = 60 }) } }, agent)
  grown = measured(function() m:update(dt) end)
  T.check(grown == 0, "hop: no allocation once warm (" .. grown .. " KB)")

  -- fly, hover
  agent = { body = body(95, 95), anchor = { x = 100, y = 100 } }
  m = C.fsm.new({ initial = "fly", states = {
    fly = B.fly({ mode = "hover", speed = 200 }) } }, agent)
  grown = measured(function() m:update(dt); B.move(agent, dt) end)
  T.check(grown == 0, "fly: no allocation once warm (" .. grown .. " KB)")
end

----------------------------------------------------------------------------
-- leap: a 1.2 s crouch, then one arc onto the target or onto another platform
----------------------------------------------------------------------------
do
  local platformer = require("engine.modules.platformer")
  -- a floor, and a raised platform on the right
  local rows = {
    "####################",
    "#..................#",
    "#..................#",
    "#..................#",
    "#..................#",
    "#..................#",
    "#..................#",
    "#......####........#",
    "#..................#",
    "#..................#",
    "#..................#",
    "####################",
  }
  local params = platformer.params.new({})
  local function run(aim, target_x, target_y, seed)
    local grid = Grid.new(rows, { tile_size = 16 })
    local world = Collision.newWorld(grid)
    local agent = { rng = Rng.new(seed or 3) }
    local Stats = {}
    function Stats:get(name)
      if name == "max_speed" then return agent.move_speed or 0 end
      if name == "jump_velocity" then return agent.jump_velocity or params.jump_velocity end
      if (name == "air_accel" or name == "ground_accel") and agent.move_accel then return agent.move_accel end
      return params[name]
    end
    agent.body = platformer.controller.new(world, { x = 40, y = 176 - 10, w = 12, h = 10,
      stats = setmetatable({}, { __index = Stats }), actions = { move_x = "move_x" } })
    agent.target = { x = target_x, y = target_y, w = 10, h = 10 }
    local m = C.fsm.new({ initial = "leap", states = {
      leap = B.leap({ aim = aim, windup = 1.2, recovery = 0.4, grid = grid, next = "done" }),
      done = { update = function() end } } }, agent)
    local input = B.input(agent)
    local launched_at, landed_at, max_up
    local y0 = agent.body.y
    for i = 1, 60 * 5 do
      m:update(dt)
      agent.body:step(input, dt)
      if not launched_at and m.phase == "air" then launched_at = i end
      if launched_at and not landed_at and m.phase == "recovery" then landed_at = i end
      if not max_up or agent.body.y < max_up then max_up = agent.body.y end
      if m.state == "done" then break end
    end
    return agent, launched_at, landed_at, y0 - max_up
  end

  -- onto the target, on the floor 120 px away
  local agent, launched, landed = run("target", 160, 166)
  T.check(launched and launched >= 71 and launched <= 74, "leap: jumps after the 1.2 s crouch (" .. tostring(launched) .. ")")
  T.check(landed ~= nil, "leap: lands")
  local bx = agent.body.x + agent.body.w / 2
  T.check(math.abs(bx - 165) <= 10, "leap: lands on the target (" .. bx .. ")")
  T.check(agent.move_accel == nil and not agent.jump_hold, "leap: clears its wishes on landing")

  -- onto the raised platform (row 8, tiles 8..11): the only other platform in reach
  agent = run("platform", 0, 0, 5)
  local foot = agent.body.y + agent.body.h
  local cxp = agent.body.x + agent.body.w / 2
  T.check(math.abs(foot - 112) < 0.5 and cxp >= 7 * 16 and cxp <= 11 * 16,
    "leap: lands on another platform (" .. cxp .. ", " .. foot .. ")")

  -- deterministic: the same seed picks the same platform
  local a1 = run("platform", 0, 0, 9)
  local a2 = run("platform", 0, 0, 9)
  T.check(a1.body.x == a2.body.x and a1.body.y == a2.body.y, "leap: same seed, same landing")
end
