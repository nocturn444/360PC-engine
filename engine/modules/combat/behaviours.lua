-- combat.behaviours: states for combat.fsm that most enemies share: patrol between points,
-- chase a target, attack with windup / active / recovery. See engine/modules/combat/README.md.
--
--   local def = { initial = "patrol", states = {
--     patrol = behaviours.patrol({ speed = 30, pause = { 0.2, 0.6 } }),
--     chase = behaviours.chase({ speed = 55, stop = 14 }),
--     attack = behaviours.attack({ hitbox = "bite", windup = 0.2, active = 0.1, recovery = 0.3, next = "chase" }),
--   } }
--   def.states.patrol.transitions = { { to = "chase", when = behaviours.target_within(80) } }
--
-- Each call returns a new state table (add `transitions` to it). The states are data shared by
-- every machine of the definition; what one enemy needs is read from its agent, the owner
-- given to fsm.new:
--   agent.body            x, y, w, h, facing (default: the agent itself)
--   agent.target          a body-like table, or nil
--   agent.patrol_points   { { x =, y = }, ... } (patrol)
--   agent.hitboxes        { name = hitbox } (attack, charge)
--   agent.attacks         { name = combat.attacks Attack } (shoot)
--   agent.jump            true for one step to press jump (hop)
--   agent.jump_velocity   optional per-agent jump strength (hop and leap write it)
--   agent.jump_hold       true while a leap rises: jump stays held (no jump cut)
--   agent.move_accel      optional acceleration wish, px/s^2 (leap: hold the arc's speed)
--   agent.anchor          { x =, y = } home point for flyers (default: the body centre on enter)
--   agent.charge_dir      x direction of a dash (charge); agent.charge_dir_y for axis "xy"
--   agent.volley, agent.next_volley   shots fired and when the next one is due (shoot)
--   agent.hop_wait        seconds until the next hop (hop)
--   agent.rng             an engine.rng stream: the only source of randomness
-- A state moves nothing. It writes what the agent wants to do, and the game (or M.move, or a
-- controller through M.input) does it:
--   agent.move_x, agent.move_y   direction, each -1..1
--   agent.move_speed             px/s
local sqrt, huge = math.sqrt, math.huge
local floor, sin, cos, atan2, pi = math.floor, math.sin, math.cos, math.atan2, math.pi
local type = type

local M = {}

local EPS = 1e-9

local function body_of(agent) return agent.body or agent end
local function cx(b) return b.x + (b.w or 0) * 0.5 end
local function cy(b) return b.y + (b.h or 0) * 0.5 end

local function halt(agent)
  agent.move_x, agent.move_y = 0, 0
end

-- Heads for a point dx, dy away. both: also along y (a straight line), else along x only.
local function head(agent, b, dx, dy, speed, both)
  local mx, my = 0, 0
  if both then
    local len = sqrt(dx * dx + dy * dy)
    if len > 0 then mx, my = dx / len, dy / len end
  elseif dx > 0 then mx = 1
  elseif dx < 0 then mx = -1 end
  agent.move_x, agent.move_y, agent.move_speed = mx, my, speed
  if mx > 0 then b.facing = 1 elseif mx < 0 then b.facing = -1 end
end

-- Distance between the centres of the agent and its target: along x, or the straight line
-- with axis "xy". math.huge without a target.
function M.distance(agent, axis)
  local t = agent.target
  if not t then return huge end
  local b = body_of(agent)
  local dx = cx(t) - cx(b)
  if axis == "xy" then
    local dy = cy(t) - cy(b)
    return sqrt(dx * dx + dy * dy)
  end
  return dx < 0 and -dx or dx
end

-- Conditions for transitions: the target is at most / more than `range` pixels away (no
-- target counts as beyond).
function M.target_within(range, axis)
  return function(_, agent) return M.distance(agent, axis) <= range end
end
function M.target_beyond(range, axis)
  return function(_, agent) return M.distance(agent, axis) > range end
end

-- The target is within range (straight line) and no "solid" tile of grid stands between their
-- centres. grid: { tile_size =, kind(tx, ty) } (a platformer.grid and anything alike). The
-- line is walked in steps of half a tile, so no table is needed.
function M.target_in_sight(grid, range)
  return function(_, agent)
    local t = agent.target
    if not t then return false end
    local b = body_of(agent)
    local x1, y1 = cx(b), cy(b)
    local dx, dy = cx(t) - x1, cy(t) - y1
    local dist = sqrt(dx * dx + dy * dy)
    if dist > range then return false end
    if grid then
      local size = grid.tile_size
      local n = floor(dist / (size * 0.5)) + 1
      for i = 1, n - 1 do
        local f = i / n
        local tx = floor((x1 + dx * f) / size) + 1
        local ty = floor((y1 + dy * f) / size) + 1
        if grid:kind(tx, ty) == "solid" then return false end
      end
    end
    return true
  end
end

-- The target's centre is more than px pixels above / below the agent's.
function M.target_above(px)
  px = px or 0
  return function(_, agent)
    local t = agent.target
    if not t then return false end
    return cy(t) < cy(body_of(agent)) - px
  end
end
function M.target_below(px)
  px = px or 0
  return function(_, agent)
    local t = agent.target
    if not t then return false end
    return cy(t) > cy(body_of(agent)) + px
  end
end

-- The agent's body is on the ground (the platformer controller's on_ground field).
function M.grounded()
  return function(_, agent) return body_of(agent).on_ground == true end
end

-- The agent's fighter is below fraction of its max health (read from its stats, as world.lua).
function M.health_below(fraction)
  return function(_, agent)
    local f = agent.fighter
    if not f or f.dead then return false end
    local max = f.stats and f.stats:get("max_health") or 0
    return max > 0 and f.health / max < fraction
  end
end

-- Combine conditions at build time: every one, any one, or the opposite.
function M.all(...)
  local list, n = { ... }, select("#", ...)
  return function(m, agent)
    for i = 1, n do
      if not list[i](m, agent) then return false end
    end
    return true
  end
end
function M.any(...)
  local list, n = { ... }, select("#", ...)
  return function(m, agent)
    for i = 1, n do
      if list[i](m, agent) then return true end
    end
    return false
  end
end
function M.negate(condition)
  return function(m, agent) return not condition(m, agent) end
end

-- Walks from point to point, back and forth. opts:
--   points    { { x =, y = }, ... } for every agent; default: agent.patrol_points
--   speed     px/s (default 30)
--   axis      "x" (default: only x matters, a platformer) or "xy"
--   reach     pixels from a point at which it counts as reached (default 1)
--   loop      true: after the last point comes the first, instead of turning back
--   pause     seconds to wait at each point: a number, or { min, max } drawn from agent.rng
--             (or opts.rng); default 0
--   blocked   function(agent) -> true when it cannot go on (a wall, a ledge ahead): it goes
--             for the next point as if this one were reached
-- It keeps agent.patrol_i (the point it is going to), patrol_dir and patrol_wait.
function M.patrol(opts)
  opts = opts or {}
  local speed, reach, both = opts.speed or 30, opts.reach or 1, opts.axis == "xy"
  local pause, blocked = opts.pause or 0, opts.blocked
  local state = {}
  function state.enter(_, agent)
    agent.patrol_i = agent.patrol_i or 1
    agent.patrol_dir = agent.patrol_dir or 1
    agent.patrol_wait = 0
    agent.patrol_held = false
    halt(agent)
  end
  function state.update(_, agent, dt)
    if agent.patrol_wait > 0 then
      local w = agent.patrol_wait - dt
      agent.patrol_wait = w > EPS and w or 0
      halt(agent)
      return
    end
    local points = opts.points or agent.patrol_points
    local count = #points
    local b = body_of(agent)
    local p = points[agent.patrol_i]
    local dx, dy = p.x - cx(b), both and p.y - cy(b) or 0
    local near = speed * dt
    if near < reach then near = reach end
    local arrived = dx <= near and dx >= -near and dy <= near and dy >= -near
    -- a block turns it once: not again until the way has been clear
    local stuck = false
    if blocked then
      stuck = blocked(agent)
      if stuck and agent.patrol_held then stuck = false
      elseif not stuck then agent.patrol_held = false end
    end
    if arrived or stuck then
      if stuck then agent.patrol_held = true end
      local i = agent.patrol_i + agent.patrol_dir
      if opts.loop then
        if i > count then i = 1 end
      elseif i > count or i < 1 then
        agent.patrol_dir = -agent.patrol_dir
        i = agent.patrol_i + agent.patrol_dir
        if i > count or i < 1 then i = agent.patrol_i end       -- a single point
      end
      agent.patrol_i = i
      local wait = pause
      if type(pause) == "table" then
        local rng = agent.rng or opts.rng
        wait = pause[1]
        if rng then wait = wait + (pause[2] - pause[1]) * rng:float() end
      end
      agent.patrol_wait = wait
      halt(agent)
      return
    end
    head(agent, b, dx, dy, speed, both)
  end
  function state.exit(_, agent) halt(agent) end
  return state
end

-- Goes for agent.target. opts:
--   speed   px/s (default 60)
--   axis    "x" (default) or "xy"
--   stop    distance between centres at which it stands still, facing the target (default 0)
-- Without a target it stands still.
function M.chase(opts)
  opts = opts or {}
  local speed, both, stop = opts.speed or 60, opts.axis == "xy", opts.stop or 0
  local state = {}
  function state.enter(_, agent) halt(agent) end
  function state.update(_, agent)
    local t = agent.target
    if not t then halt(agent); return end
    local b = body_of(agent)
    local dx, dy = cx(t) - cx(b), both and cy(t) - cy(b) or 0
    local dist = both and sqrt(dx * dx + dy * dy) or (dx < 0 and -dx or dx)
    if dist <= stop then
      halt(agent)
      if dx > 0 then b.facing = 1 elseif dx < 0 then b.facing = -1 end
    else
      head(agent, b, dx, dy, speed, both)
    end
  end
  function state.exit(_, agent) halt(agent) end
  return state
end

-- An attack in three phases, standing still: windup (m.phase == "windup"), active (the
-- hitbox is on), recovery; then the state `next`. opts:
--   hitbox     the name of the hitbox in agent.hitboxes
--   windup, active, recovery   seconds (defaults 0.2, 0.1, 0.3)
--   next       the state to go to when it is over
--   face       false: do not turn to the target when the attack starts
-- Leaving the state early (a stagger) turns the hitbox off.
function M.attack(opts)
  local windup, active, recovery = opts.windup or 0.2, opts.active or 0.1, opts.recovery or 0.3
  local name, next_state = opts.hitbox, opts.next
  local state = {}
  function state.enter(m, agent)
    halt(agent)
    m.phase = "windup"
    local t = agent.target
    if t and opts.face ~= false then
      local b = body_of(agent)
      local dx = cx(t) - cx(b)
      if dx > 0 then b.facing = 1 elseif dx < 0 then b.facing = -1 end
    end
    if windup <= EPS then
      m.phase = "active"
      agent.hitboxes[name]:activate()
    end
  end
  function state.update(m, agent)
    local time, phase = m.time, m.phase
    if phase == "windup" then
      if time >= windup - EPS then
        m.phase = "active"
        agent.hitboxes[name]:activate()
      end
    elseif phase == "active" then
      if time >= windup + active - EPS then
        m.phase = "recovery"
        agent.hitboxes[name]:deactivate()
      end
    elseif time >= windup + active + recovery - EPS then
      return next_state
    end
  end
  function state.exit(_, agent)
    agent.hitboxes[name]:deactivate()
    halt(agent)
  end
  return state
end

-- Stands still and fires volleys of agent.attacks[opts.attack], then goes to `next`. opts:
--   attack     name in agent.attacks (required)
--   aim        "facing" (default: the config's own angle), "target" (at the target's centre
--              now) or "angle" (opts.angle degrees above the facing)
--   angle      degrees above the facing for aim "angle" (default 0)
--   volleys    triggers (default 1), interval seconds between them (default 0.2)
--   rotate     degrees added to the aim after each volley (default 0)
--   windup     seconds before the first volley (default 0.3)
--   recovery   seconds after the last one (default 0.4)
--   face       false: do not turn to the target on enter
-- On exit the shots already flying are left alone. m.phase: "windup", "firing", "recovery".
function M.shoot(opts)
  opts = opts or {}
  local attack_name = opts.attack
  local aim, angle = opts.aim or "facing", opts.angle or 0
  local volleys, interval = opts.volleys or 1, opts.interval or 0.2
  local rotate = opts.rotate or 0
  local windup, recovery = opts.windup or 0.3, opts.recovery or 0.4
  local next_state = opts.next
  local RAD = pi / 180
  local state = {}

  -- One trigger: the direction depends on the aim and on how many volleys were already fired.
  local function fire(m, agent)
    local attack = agent.attacks[attack_name]
    local b = body_of(agent)
    local t = agent.target
    local rot = rotate * agent.volley
    if aim == "target" and t then
      local dx, dy = cx(t) - cx(b), cy(t) - cy(b)
      if dx ~= 0 or dy ~= 0 then
        local a = atan2(-dy, dx) + rot * RAD
        attack:trigger(cos(a), -sin(a))
        return
      end
    end
    if aim == "facing" and rot == 0 then attack:trigger(); return end
    local base = aim == "angle" and angle or 0
    if aim == "facing" then base = attack.config and attack.config.angle or 0 end
    local a = (base + rot) * RAD
    local facing = (b.facing or 1) < 0 and -1 or 1
    attack:trigger(facing * cos(a), -sin(a))
  end

  function state.enter(m, agent)
    halt(agent)
    m.phase = "windup"
    local attack = agent.attacks and agent.attacks[attack_name]
    if not attack then
      error("combat.behaviours.shoot: agent.attacks has no " .. tostring(attack_name), 3)
    end
    if volleys > 1 and attack.config and (attack.config.cooldown or 0) > interval + EPS then
      error("combat.behaviours.shoot: " .. tostring(attack_name) .. " cooldown is longer than interval", 3)
    end
    agent.volley, agent.next_volley = 0, windup
    local t = agent.target
    if t and opts.face ~= false then
      local b = body_of(agent)
      local dx = cx(t) - cx(b)
      if dx > 0 then b.facing = 1 elseif dx < 0 then b.facing = -1 end
    end
    if windup <= EPS then m.phase = "firing" end
  end

  function state.update(m, agent, dt)
    local time = m.time
    if m.phase == "windup" then
      if time >= windup - EPS then m.phase = "firing" end
    end
    if m.phase == "firing" then
      local guard = 0
      while agent.volley < volleys and time >= agent.next_volley - EPS and guard < volleys do
        fire(m, agent)
        agent.volley = agent.volley + 1
        agent.next_volley = windup + agent.volley * interval
        guard = guard + 1
      end
      if agent.volley >= volleys then m.phase = "recovery" end
    end
    if m.phase == "recovery" then
      if time >= windup + (volleys - 1) * interval + recovery - EPS then return next_state end
    end
  end

  function state.exit(_, agent) halt(agent) end
  return state
end

-- Winds up, dashes at the target and recovers. opts:
--   speed      px/s (default 140)
--   time       max dash seconds (default 0.6)
--   distance   max dash pixels (optional)
--   windup     seconds (default 0.4), recovery seconds (default 0.3)
--   stun       recovery used instead when blocked(agent) stopped the dash (default 0.8)
--   blocked    function(agent) -> true at a wall or a ledge ahead
--   hitbox     name in agent.hitboxes, on during the dash (optional)
--   axis       "x" (default) or "xy"
--   next       the state to go to when it is over
-- m.phase: "windup", "dash", "recovery".
function M.charge(opts)
  opts = opts or {}
  local speed = opts.speed or 140
  local max_time = opts.time or 0.6
  local max_dist = opts.distance
  local windup, recovery, stun = opts.windup or 0.4, opts.recovery or 0.3, opts.stun or 0.8
  local blocked = opts.blocked
  local hitbox_name = opts.hitbox
  local both = opts.axis == "xy"
  local next_state = opts.next
  local state = {}

  local function hitbox_of(agent)
    if not hitbox_name then return nil end
    local hb = agent.hitboxes and agent.hitboxes[hitbox_name]
    if not hb then
      error("combat.behaviours.charge: agent.hitboxes has no " .. tostring(hitbox_name), 3)
    end
    return hb
  end

  local function start_dash(m, agent)
    local b = body_of(agent)
    local t = agent.target
    local ax, ay = 1, 0
    if t then
      local dx, dy = cx(t) - cx(b), cy(t) - cy(b)
      if both then
        local len = sqrt(dx * dx + dy * dy)
        if len > EPS then ax, ay = dx / len, dy / len else ax, ay = 0, 0 end
      elseif dx > 0 then ax = 1
      elseif dx < 0 then ax = -1
      else ax = (b.facing or 1) < 0 and -1 or 1 end
    else
      ax = (b.facing or 1) < 0 and -1 or 1
    end
    if ax == 0 and ay == 0 then ax = (b.facing or 1) < 0 and -1 or 1 end
    agent.charge_dir, agent.charge_dir_y = ax, ay
    if ax > 0 then b.facing = 1 elseif ax < 0 then b.facing = -1 end
    m.phase, m.t_dash, m.dash_dist = "dash", m.time, 0
    local hb = hitbox_of(agent)
    if hb then hb:activate() end
  end

  local function stop_dash(m, agent, duration)
    m.phase, m.t_rec, m.stun_time = "recovery", m.time, duration
    local hb = hitbox_of(agent)
    if hb then hb:deactivate() end
    halt(agent)
  end

  function state.enter(m, agent)
    halt(agent)
    m.phase = "windup"
    local t = agent.target
    if t then
      local b = body_of(agent)
      local dx = cx(t) - cx(b)
      if dx > 0 then b.facing = 1 elseif dx < 0 then b.facing = -1 end
    end
    if windup <= EPS then start_dash(m, agent) end
  end

  function state.update(m, agent, dt)
    if m.phase == "windup" then
      if m.time >= windup - EPS then start_dash(m, agent) end
    end
    if m.phase == "dash" then
      if blocked and blocked(agent) then
        stop_dash(m, agent, stun)
      elseif m.time - m.t_dash >= max_time - EPS
        or (max_dist and m.dash_dist >= max_dist - EPS) then
        stop_dash(m, agent, recovery)
      else
        agent.move_x, agent.move_y = agent.charge_dir, agent.charge_dir_y
        agent.move_speed = speed
        m.dash_dist = m.dash_dist + speed * dt
      end
    end
    if m.phase == "recovery" then
      halt(agent)
      if m.time - m.t_rec >= m.stun_time - EPS then return next_state end
    end
  end

  function state.exit(m, agent)
    local hb = hitbox_of(agent)
    if hb and m.phase == "dash" then hb:deactivate() end
    halt(agent)
  end
  return state
end

-- A jumping enemy: waits on the ground, then presses jump for one step and keeps moving that
-- way in the air. opts:
--   wait            seconds before each hop: a number, or { min, max } from agent.rng (default 0)
--   speed           px/s horizontally in the air (default 60)
--   toward          "target" (default) or "facing"
--   grounded        function(agent) -> true on the ground (default: body.on_ground)
--   jump_velocity   written to agent.jump_velocity on enter (optional)
-- Endless: leave it with transitions.
function M.hop(opts)
  opts = opts or {}
  local wait, speed = opts.wait or 0, opts.speed or 60
  local toward = opts.toward or "target"
  local grounded = opts.grounded or function(agent) return body_of(agent).on_ground == true end
  local jump_velocity = opts.jump_velocity
  local state = {}

  local function draw_wait(agent)
    if type(wait) ~= "table" then return wait end
    local rng = agent.rng
    if not rng then return wait[1] end
    return wait[1] + (wait[2] - wait[1]) * rng:float()
  end

  function state.enter(_, agent)
    if jump_velocity then agent.jump_velocity = jump_velocity end
    agent.jump = false
    agent.hop_wait = draw_wait(agent)
    halt(agent)
  end

  function state.update(_, agent, dt)
    local b = body_of(agent)
    if grounded(agent) then
      if agent.hop_wait > 0 then
        local w = agent.hop_wait - dt
        agent.hop_wait = w > EPS and w or 0
        halt(agent)
        agent.jump = false
        if agent.hop_wait > 0 then return end
      end
      local mx = 0
      if toward == "facing" then
        mx = (b.facing or 1) < 0 and -1 or 1
      else
        local t = agent.target
        if t then
          local dx = cx(t) - cx(b)
          mx = dx > 0 and 1 or (dx < 0 and -1 or 0)
        else
          mx = (b.facing or 1) < 0 and -1 or 1
        end
      end
      if mx ~= 0 then b.facing = mx end
      agent.move_x, agent.move_y, agent.move_speed = mx, 0, speed
      agent.jump = true
      agent.hop_wait = draw_wait(agent)
    else
      agent.jump = false
    end
  end

  function state.exit(_, agent)
    agent.jump = false
    halt(agent)
  end
  return state
end

-- A long, aimed jump with a tell: crouches on the ground for `windup` seconds (m.phase
-- "windup", the game can draw the charge), then jumps in one arc that lands on the target or on
-- another platform, then recovers. opts:
--   windup          seconds on the ground before the jump (default 1.2)
--   recovery        seconds after landing (default 0.4)
--   aim             "target" (default: where the target stands at take-off) or "platform"
--                   (a standable tile of ctx/opts.grid in reach, drawn with agent.rng; with no
--                   grid or no platform in reach it aims at the target)
--   gravity         px/s^2 of the body (default 900, the platformer default)
--   arc             extra pixels above the higher of the two ends (default 24); a far
--                   landing jumps higher so the capped horizontal speed still reaches it
--   max_jump        cap of the take-off speed upwards, px/s (default 420)
--   speed           cap of the horizontal speed, px/s (default 180)
--   reach           { min, max } horizontal pixels for "platform" (default { 32, 160 })
--   rise, drop      max pixels up / down for "platform" (default 72 / 96)
--   time            max seconds in the air before giving up (default 2.5)
--   grounded        function(agent) -> true on the ground (default: body.on_ground)
--   next            the state to go to when it is over
-- Writes agent.jump (one step), agent.jump_hold (true while rising: no jump cut),
-- agent.jump_velocity, agent.move_x / move_speed, and agent.move_accel (a very high
-- acceleration while airborne so the controller holds the arc's speed; nil otherwise).
-- m.phase: "windup", "air", "recovery". Allocates nothing (the platform draw is a reservoir
-- sample over the grid, once per jump).
function M.leap(opts)
  opts = opts or {}
  local windup, recovery = opts.windup or 1.2, opts.recovery or 0.4
  local aim = opts.aim or "target"
  if aim ~= "target" and aim ~= "platform" then
    error("behaviours.leap: aim is \"target\" or \"platform\"", 2)
  end
  local g = opts.gravity or 900
  local arc = opts.arc or 24
  local max_jump, max_speed = opts.max_jump or 420, opts.speed or 180
  local reach = opts.reach or { 32, 160 }
  local reach_min, reach_max = reach[1] or 32, reach[2] or 160
  local max_rise, max_drop = opts.rise or 72, opts.drop or 96
  local max_air = opts.time or 2.5
  local grid = opts.grid
  local grounded = opts.grounded or function(agent) return body_of(agent).on_ground == true end
  local next_state = opts.next
  local ACCEL = 1e6
  local state = {}

  local function standable(tx, ty, rows)
    local k = grid:kind(tx, ty)
    if k ~= "solid" and k ~= "one_way" then return false end
    for r = 1, rows do
      if grid:kind(tx, ty - r) == "solid" then return false end
      if ty - r < 1 then return false end
    end
    return true
  end

  -- A landing point (bottom centre, room pixels) on another platform, or nil.
  local function pick_platform(agent, b)
    if not grid then return nil end
    local rng = agent.rng
    if not rng then return nil end
    local size = grid.tile_size
    local rows = floor(((b.h or size) - 1) / size) + 1
    local x0, foot = cx(b), b.y + (b.h or 0)
    local home_ty = floor((foot + 1) / size) + 1
    local tx_lo = floor((x0 - reach_max) / size) + 1
    local tx_hi = floor((x0 + reach_max) / size) + 1
    if tx_lo < 1 then tx_lo = 1 end
    if tx_hi > grid.width then tx_hi = grid.width end
    local ty_lo = floor((foot - max_rise) / size) + 1
    local ty_hi = floor((foot + max_drop) / size) + 1
    if ty_lo < 2 then ty_lo = 2 end
    if ty_hi > grid.height then ty_hi = grid.height end
    local seen, px, py = 0, nil, nil
    for tx = tx_lo, tx_hi do
      local lx = (tx - 0.5) * size
      local dx = lx - x0
      if dx < 0 then dx = -dx end
      if dx >= reach_min then
        for ty = ty_lo, ty_hi do
          -- another platform: a different height, or the same row across a gap
          if ty ~= home_ty or grid:kind(tx - (lx > x0 and 1 or -1), ty) == nil then
            if standable(tx, ty, rows) then
              seen = seen + 1
              if rng:float() * seen < 1 then px, py = lx, (ty - 1) * size end
            end
          end
        end
      end
    end
    return px, py
  end

  local function launch(m, agent)
    local b = body_of(agent)
    local x0, foot = cx(b), b.y + (b.h or 0)
    local lx, ly
    if aim == "platform" then lx, ly = pick_platform(agent, b) end
    if not lx then
      local t = agent.target
      if t then
        lx, ly = cx(t), t.y + (t.h or 0)
      else
        lx, ly = x0 + ((b.facing or 1) < 0 and -reach_min or reach_min), foot
      end
    end
    local dx, rise = lx - x0, foot - ly
    local apex = (rise > 0 and rise or 0) + arc
    local vy = sqrt(2 * g * apex)
    if vy > max_jump then vy = max_jump; apex = vy * vy / (2 * g) end
    local fall = apex - rise
    if fall < 0 then fall = 0 end
    local t_air = vy / g + sqrt(2 * fall / g)
    local adx = dx < 0 and -dx or dx
    if adx > max_speed * t_air and vy < max_jump then
      -- too far for this arc at the capped speed: jump higher, to stay in the air longer
      local need = adx / max_speed
      local vy2 = (rise + 0.5 * g * need * need) / need
      if vy2 > max_jump then vy2 = max_jump end
      if vy2 > vy then
        vy = vy2
        fall = vy * vy / (2 * g) - rise
        if fall < 0 then fall = 0 end
        t_air = vy / g + sqrt(2 * fall / g)
      end
    end
    local vx = t_air > EPS and dx / t_air or 0
    local mx = vx > 0 and 1 or (vx < 0 and -1 or 0)
    if vx < 0 then vx = -vx end
    if vx > max_speed then vx = max_speed end
    if mx ~= 0 then b.facing = mx end
    agent.jump_velocity = vy
    agent.jump, agent.jump_hold = true, true
    agent.move_x, agent.move_y, agent.move_speed = mx, 0, vx
    agent.move_accel = ACCEL
    m.phase, m.t_air, m.airborne = "air", m.time, false
    m.land_x, m.land_y = lx, ly
  end

  local function land(m, agent)
    agent.jump, agent.jump_hold, agent.move_accel = false, false, nil
    halt(agent)
    m.phase, m.t_rec = "recovery", m.time
  end

  function state.enter(m, agent)
    halt(agent)
    agent.jump, agent.jump_hold, agent.move_accel = false, false, nil
    m.phase, m.airborne = "windup", false
    local t = agent.target
    if t then
      local b = body_of(agent)
      local dx = cx(t) - cx(b)
      if dx > 0 then b.facing = 1 elseif dx < 0 then b.facing = -1 end
    end
  end

  function state.update(m, agent)
    if m.phase == "windup" then
      halt(agent)
      -- the charge only counts on the ground (a fall restarts nothing, it just waits)
      if m.time >= windup - EPS and grounded(agent) then launch(m, agent) end
      return
    end
    if m.phase == "air" then
      agent.jump = false
      local on = grounded(agent)
      if not on then m.airborne = true end
      -- jump stays held while rising (no jump cut), let go once the body falls
      local vy = body_of(agent).vy
      if m.airborne and (vy == nil or vy >= 0) then agent.jump_hold = false end
      if (m.airborne and on) or m.time - m.t_air >= max_air - EPS
          or (not m.airborne and m.time - m.t_air >= 0.25) then
        land(m, agent)
      end
      return
    end
    halt(agent)
    if m.time - m.t_rec >= recovery - EPS then return next_state end
  end

  function state.exit(_, agent)
    agent.jump, agent.jump_hold, agent.move_accel = false, false, nil
    halt(agent)
  end
  return state
end

-- Movement for bodies without gravity (always along "xy"). opts:
--   mode    "hover" (default), "follow" or "swoop"
--   speed   px/s (default 40)
--   keep    follow distance between centres (default 60), band (default 12)
--   radius  hover figure radius (default 8), period seconds (default 2)
--   bob     vertical amplitude while following at distance (default 4)
--   time    max swoop seconds (default 1)
--   next    swoop only: the state to go to when it is over
-- m.phase is the mode. Only sin/cos of numbers: deterministic.
function M.fly(opts)
  opts = opts or {}
  local mode = opts.mode or "hover"
  local speed = opts.speed or 40
  local keep, band = opts.keep or 60, opts.band or 12
  local radius, period = opts.radius or 8, opts.period or 2
  local bob, max_time = opts.bob or 4, opts.time or 1
  local next_state = opts.next
  local TAU = 2 * pi
  local state = {}

  local function anchor(m, agent)
    local a = agent.anchor
    if a then return a.x, a.y end
    return m.anchor_x, m.anchor_y
  end

  local function aim(agent, tx, ty)
    local b = body_of(agent)
    local dx, dy = tx - cx(b), ty - cy(b)
    local len = sqrt(dx * dx + dy * dy)
    if len > EPS then
      agent.move_x, agent.move_y = dx / len, dy / len
    else
      agent.move_x, agent.move_y = 0, 0
    end
    agent.move_speed = speed
  end

  function state.enter(m, agent)
    halt(agent)
    m.phase = mode
    local b = body_of(agent)
    if not agent.anchor then m.anchor_x, m.anchor_y = cx(b), cy(b) end
    if mode == "swoop" then
      local t = agent.target
      local dx, dy
      if t then
        dx, dy = cx(t) - cx(b), cy(t) - cy(b)
      else
        dx = (b.facing or 1) < 0 and -1 or 1
        dy = 0
      end
      local len = sqrt(dx * dx + dy * dy)
      if len > EPS then
        m.swoop_x, m.swoop_y = dx / len, dy / len
      else
        m.swoop_x, m.swoop_y = (b.facing or 1) < 0 and -1 or 1, 0
      end
    end
  end

  function state.update(m, agent, dt)
    local time = m.time
    if mode == "hover" then
      local ax, ay = anchor(m, agent)
      local a = TAU * time / period
      aim(agent, ax + cos(a) * radius, ay + sin(a) * radius)
    elseif mode == "follow" then
      local t = agent.target
      local b = body_of(agent)
      if not t then
        local ax, ay = anchor(m, agent)
        local a = TAU * time / period
        aim(agent, ax + cos(a) * radius, ay + sin(a) * radius)
        return
      end
      local dx, dy = cx(t) - cx(b), cy(t) - cy(b)
      local dist = sqrt(dx * dx + dy * dy)
      if dx > 0 then b.facing = 1 elseif dx < 0 then b.facing = -1 end
      if dist > keep then
        if dist > EPS then agent.move_x, agent.move_y = dx / dist, dy / dist else halt(agent) end
        agent.move_speed = speed
      elseif dist < keep - band then
        if dist > EPS then
          agent.move_x, agent.move_y = -dx / dist, -dy / dist
        else
          agent.move_x = (b.facing or 1) < 0 and 1 or -1
          agent.move_y = 0
        end
        agent.move_speed = speed
      else
        agent.move_x = 0
        local vy = cy(t) + sin(TAU * time / period) * bob - cy(b)
        agent.move_y = vy > EPS and 1 or (vy < -EPS and -1 or 0)
        agent.move_speed = speed
      end
    else
      agent.move_x, agent.move_y = m.swoop_x, m.swoop_y
      agent.move_speed = speed
      if m.swoop_x > 0 then
        body_of(agent).facing = 1
      elseif m.swoop_x < 0 then
        body_of(agent).facing = -1
      end
      if time >= max_time - EPS then return next_state end
    end
  end

  function state.exit(_, agent) halt(agent) end
  return state
end

-- Picks the next attack: stands still facing the target for `pause` seconds, then goes to one
-- of `options` ({ { to = "spray", weight = 2 }, { to = "charge" } }, weight default 1).
-- opts:
--   options    array of { to = state name, weight = number } (required, at least one)
--   order      "random" (default: weighted draw with agent.rng) or "cycle" (in list order)
--   no_repeat  true: never the same option twice in a row (when there are two or more)
--   pause      seconds to wait first: a number, or { min, max } drawn from agent.rng (default 0.6)
-- Each attack state usually ends with next = this state, so a boss phase loops: pick, tell,
-- attack, recover, pick. Per agent: agent.rotate_last (index of the last option taken).
-- Allocates nothing per step (the weight function is built here, once).
function M.rotate(opts)
  opts = opts or {}
  local options = opts.options
  if type(options) ~= "table" or #options == 0 then
    error("behaviours.rotate: options is a non-empty array of { to = state }", 2)
  end
  for i = 1, #options do
    local o = options[i]
    if type(o) ~= "table" or type(o.to) ~= "string" then
      error("behaviours.rotate: options[" .. i .. "].to is a state name", 2)
    end
    if o.weight ~= nil and (type(o.weight) ~= "number" or o.weight < 0) then
      error("behaviours.rotate: options[" .. i .. "].weight is a number >= 0", 2)
    end
  end
  local order = opts.order or "random"
  if order ~= "random" and order ~= "cycle" then
    error("behaviours.rotate: order is \"random\" or \"cycle\"", 2)
  end
  local n, no_repeat = #options, opts.no_repeat == true and #options > 1
  local pause = opts.pause or 0.6
  local skip = 0                                   -- the option index the draw leaves out
  local function weight(o, i)
    if i == skip then return 0 end
    return o.weight or 1
  end
  local function choose(agent)
    local last = agent.rotate_last
    local i
    if order == "cycle" then
      i = ((last or 0) % n) + 1
    else
      skip = (no_repeat and last) or 0
      local rng = agent.rng
      if rng == nil then error("behaviours.rotate: agent.rng is needed for order \"random\"", 3) end
      local total = 0
      for k = 1, n do total = total + weight(options[k], k) end
      if total > 0 then
        local _, k = rng:weighted(options, weight)
        i = k
      else
        i = (last or 0) % n + 1                    -- every other weight is 0: take the next one
      end
      skip = 0
    end
    agent.rotate_last = i
    return options[i].to
  end
  local state = {}
  function state.enter(m, agent)
    halt(agent)
    m.phase = "pause"
    local p = pause
    if type(p) == "table" then
      local rng = agent.rng
      p = rng and (p[1] + (p[2] - p[1]) * rng:float()) or p[1]
    end
    m.wait = p
  end
  function state.update(m, agent)
    halt(agent)
    local t, b = agent.target, body_of(agent)
    if t then
      local dx = cx(t) - cx(b)
      if dx > 0 then b.facing = 1 elseif dx < 0 then b.facing = -1 end
    end
    if m.time >= (m.wait or 0) - EPS then return choose(agent) end
  end
  return state
end

-- Kites the target: walks away when closer than `min`, towards it when farther than `max`,
-- stands still (facing it) in between. opts: min (48), max (96), speed (40), axis ("x" or "xy").
function M.keep_away(opts)
  opts = opts or {}
  local min, max = opts.min or 48, opts.max or 96
  local speed = opts.speed or 40
  local both = opts.axis == "xy"
  local state = {}

  function state.enter(_, agent) halt(agent) end
  function state.update(_, agent)
    local t = agent.target
    if not t then halt(agent); return end
    local b = body_of(agent)
    local dx, dy = cx(t) - cx(b), cy(t) - cy(b)
    local dist = both and sqrt(dx * dx + dy * dy) or (dx < 0 and -dx or dx)
    if dx > 0 then b.facing = 1 elseif dx < 0 then b.facing = -1 end
    local away = dist < min
    local toward = dist > max
    if not away and not toward then halt(agent); return end
    local mx, my = 0, 0
    if both and dist > EPS then
      local s = away and -1 or 1
      mx, my = s * dx / dist, s * dy / dist
    elseif dx > 0 then
      mx = away and -1 or 1
    elseif dx < 0 then
      mx = away and 1 or -1
    end
    agent.move_x, agent.move_y, agent.move_speed = mx, my, speed
  end
  function state.exit(_, agent) halt(agent) end
  return state
end

-- For a game without physics: moves the agent's body by its wish for one step.
function M.move(agent, dt)
  local b = body_of(agent)
  local d = (agent.move_speed or 0) * dt
  b.x = b.x + (agent.move_x or 0) * d
  b.y = b.y + (agent.move_y or 0) * d
end

-- For a flying body in a bump.lua world: moves agent.body by its wish, sets body.px, body.py
-- (to interpolate), body.wall (-1, 0 or 1) and body.ceiling / body.floor from the collisions.
-- The world is passed in (duck typing: it needs :move(item, x, y, filter)); nothing is
-- required from bump or the platformer module.
function M.fly_move(agent, world, filter, dt)
  local b = body_of(agent)
  local d = (agent.move_speed or 0) * dt
  local x, y = b.x + (agent.move_x or 0) * d, b.y + (agent.move_y or 0) * d
  b.px, b.py = b.x, b.y
  local nx, ny, cols, len = world:move(b, x, y, filter)
  b.x, b.y = nx, ny
  local wall, ceiling, floor = 0, false, false
  for i = 1, len do
    local c = cols[i]
    if c.type ~= "cross" then
      local normal = c.normal
      if normal.y < 0 then
        floor = true
      elseif normal.y > 0 then
        ceiling = true
      end
      if normal.x ~= 0 then wall = -normal.x end
    end
  end
  b.wall, b.ceiling, b.floor = wall, ceiling, floor
end

-- For a platformer controller: an input that holds what the agent wants, to give to
-- body:step(input, dt) of a controller made with actions = { move_x = "move_x" } (its speed is
-- then the controller's max_speed, not move_speed). agent.jump = true presses jump that step;
-- agent.jump_hold = true keeps it held (a leap's full arc).
local Input = {}
Input.__index = Input
function Input:axis() return self.agent.move_x or 0 end
function Input:down(name)
  return name == "jump" and (self.agent.jump == true or self.agent.jump_hold == true)
end
function Input:pressed(name) return name == "jump" and self.agent.jump == true end
function M.input(agent) return setmetatable({ agent = agent }, Input) end

return M
