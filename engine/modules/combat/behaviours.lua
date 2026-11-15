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
--   agent.hitboxes        { name = hitbox } (attack)
--   agent.rng             an engine.rng stream: the only source of randomness
-- A state moves nothing. It writes what the agent wants to do, and the game (or M.move, or a
-- platformer controller through M.input) does it:
--   agent.move_x, agent.move_y   direction, each -1..1
--   agent.move_speed             px/s
local sqrt, huge = math.sqrt, math.huge

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

-- For a game without physics: moves the agent's body by its wish for one step.
function M.move(agent, dt)
  local b = body_of(agent)
  local d = (agent.move_speed or 0) * dt
  b.x = b.x + (agent.move_x or 0) * d
  b.y = b.y + (agent.move_y or 0) * d
end

-- For a platformer controller: an input that holds what the agent wants, to give to
-- body:step(input, dt) of a controller made with actions = { move_x = "move_x" } (its speed is
-- then the controller's max_speed, not move_speed). agent.jump = true presses jump that step.
local Input = {}
Input.__index = Input
function Input:axis() return self.agent.move_x or 0 end
function Input:down(name) return name == "jump" and self.agent.jump == true end
function Input:pressed(name) return name == "jump" and self.agent.jump == true end
function M.input(agent) return setmetatable({ agent = agent }, Input) end

return M
