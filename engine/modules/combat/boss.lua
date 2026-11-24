-- combat.boss: a thin director on top of combat.brains for what only bosses have: phases by
-- health, a pause between phases, the tell of the attack being wound up, and the value of a
-- health bar. The behaviours are the same ones every enemy uses (combat.behaviours, by name
-- through combat.brains); a boss phase is just a brain spec. The director draws nothing.
-- See engine/modules/combat/README.md ("Bosses").
--
--   local def = combat.boss.build({
--     name = "Big One",
--     phases = {
--       { at = 1.0, brain = { initial = "pick", states = { ... } } },
--       { at = 0.5, brain = { ... }, transition = { time = 1.2, invulnerable = true } },
--     },
--   }, { grid = grid })                    -- ctx: the combat.brains build context
--   local b = combat.boss.new(def, agent, { on_phase = function(b, index) end })
--   b:update(dt)                           -- once per fixed step, instead of a fsm update
--   b.phase, b.bar, b.telegraph, b.telegraph_t, b.transitioning
--
-- agent is the same agent table a brain drives (body, target, fighter, rng, attacks...). The
-- phase is read from agent.fighter: health / max_health (its stats), as world.lua does.
local type, tostring, pairs = type, tostring, pairs

local brains = require((...):gsub("boss$", "brains"))
local fsm = require((...):gsub("boss$", "fsm"))

local M = {}
local Boss = {}
Boss.__index = Boss

local EPS = 1e-9
-- How long each behaviour winds up when the spec does not say (the behaviours' own defaults).
local DEFAULT_WINDUP = { attack = 0.2, shoot = 0.3, charge = 0.4 }

-- combat.boss.build(spec, ctx) -> a definition shared by every fight with this boss.
-- spec.name (optional), spec.phases: array of
--   at           health fraction where the phase starts: 1 for the first, then strictly lower
--   brain        a combat.brains spec
--   transition   optional { time = seconds halted before the phase starts (default 0),
--                invulnerable = true to ignore damage during that time }
-- spec.bar: optional { down = units per second (default 1.5), up = (default 0.5) } for b.bar.
function M.build(spec, ctx)
  if type(spec) ~= "table" then error("combat.boss.build: the spec must be a table", 2) end
  local phases = spec.phases
  if type(phases) ~= "table" or #phases == 0 then
    error("combat.boss.build: phases is a non-empty array", 2)
  end
  local def = { name = spec.name, phases = {}, bar_down = 1.5, bar_up = 0.5 }
  if spec.bar ~= nil then
    if type(spec.bar) ~= "table" then error("combat.boss.build: bar is a table", 2) end
    def.bar_down = spec.bar.down or def.bar_down
    def.bar_up = spec.bar.up or def.bar_up
  end
  local previous = nil
  for i = 1, #phases do
    local p = phases[i]
    local where = "combat.boss.build: phase " .. i
    if type(p) ~= "table" then error(where .. " must be a table", 2) end
    local at = p.at
    if type(at) ~= "number" or at <= 0 or at > 1 then error(where .. ": at is a number in (0, 1]", 2) end
    if i == 1 and at ~= 1 then error(where .. ": the first phase starts at 1", 2) end
    if previous ~= nil and at >= previous then error(where .. ": at must be lower than the phase before", 2) end
    previous = at
    if type(p.brain) ~= "table" then error(where .. ": brain is a combat.brains spec", 2) end
    local t = p.transition
    if t ~= nil and type(t) ~= "table" then error(where .. ": transition is a table", 2) end
    local time = t and t.time or 0
    if type(time) ~= "number" or time < 0 then error(where .. ": transition.time is a number >= 0", 2) end
    -- the windup of each state, for the telegraph progress
    local windups = {}
    for name, entry in pairs(p.brain.states or {}) do
      if type(entry) == "table" then
        local w = entry.windup
        if w == nil then w = DEFAULT_WINDUP[entry[1]] end
        if type(w) == "number" then windups[name] = w end
      end
    end
    def.phases[i] = {
      at = at,
      brain = brains.build(p.brain, ctx),
      windups = windups,
      time = time,
      invulnerable = t and t.invulnerable == true or false,
    }
  end
  return def
end

-- combat.boss.new(def, agent, opts) -> a director for one fight. opts.on_phase(b, index) is
-- called when a phase after the first begins (at the start of its transition).
function M.new(def, agent, opts)
  if type(def) ~= "table" or type(def.phases) ~= "table" then
    error("combat.boss.new: needs a definition from combat.boss.build", 2)
  end
  if type(agent) ~= "table" then error("combat.boss.new: needs the agent", 2) end
  local self = setmetatable({
    def = def, agent = agent, on_phase = opts and opts.on_phase,
    name = def.name,
    phase = 1,
    machines = {},          -- one machine per phase, made when the phase starts
    machine = nil,
    bar = 1,
    telegraph = nil,
    telegraph_t = 0,
    transitioning = false,
    transition_left = 0,
  }, Boss)
  self.bar = self:health_fraction()
  self.machine = fsm.new(def.phases[1].brain, agent)
  self.machines[1] = self.machine
  return self
end

-- The fighter's health over its max health (1 without a fighter or stats).
function Boss:health_fraction()
  local f = self.agent.fighter
  if not f then return 1 end
  if f.dead then return 0 end
  local max = f.stats and f.stats:get("max_health") or 0
  if max <= 0 then return 1 end
  local x = f.health / max
  if x < 0 then return 0 elseif x > 1 then return 1 end
  return x
end

local function halt(agent) agent.move_x, agent.move_y = 0, 0 end

-- Leaves the current machine's state (its exit runs) without entering another.
local function leave(m, agent)
  local cur = m and m._current
  if cur and cur.exit then cur.exit(m, agent, nil) end
end

function Boss:start_phase(index)
  local m = self.machines[index]
  if m == nil then
    m = fsm.new(self.def.phases[index].brain, self.agent)   -- once per phase per fight
    self.machines[index] = m
  else
    m:set(self.def.phases[index].brain.initial)
  end
  self.machine = m
end

-- Goes to phase `index` now (the game may also call it, e.g. for a scripted phase).
function Boss:enter_phase(index)
  local p = self.def.phases[index]
  if p == nil then error("combat.boss: no phase " .. tostring(index), 2) end
  if not self.transitioning then leave(self.machine, self.agent) end
  halt(self.agent)
  self.phase = index
  self.telegraph, self.telegraph_t = nil, 0
  if self.on_phase then self.on_phase(self, index) end
  if p.time > EPS then
    self.transitioning, self.transition_left = true, p.time
    local f = self.agent.fighter
    if p.invulnerable and f and f.invuln < p.time then f.invuln = p.time end
  else
    self.transitioning = false
    self:start_phase(index)
  end
end

-- One fixed step: eases the bar, changes phase when the health crossed a threshold (straight to
-- the lowest one reached), runs the transition pause or the phase's machine, and reads the tell.
function Boss:update(dt)
  local agent, def = self.agent, self.def
  local x = self:health_fraction()
  local bar = self.bar
  if bar > x then
    bar = bar - def.bar_down * dt
    if bar < x then bar = x end
  elseif bar < x then
    bar = bar + def.bar_up * dt
    if bar > x then bar = x end
  end
  self.bar = bar
  local f = agent.fighter
  if f and f.dead then
    halt(agent)
    self.telegraph, self.telegraph_t = nil, 0
    return
  end

  local phases, target = def.phases, nil
  for i = self.phase + 1, #phases do
    if x <= phases[i].at + EPS then target = i end
  end
  if target then
    self:enter_phase(target)
    return
  end

  if self.transitioning then
    halt(agent)
    self.transition_left = self.transition_left - dt
    if self.transition_left <= EPS then
      self.transitioning = false
      self:start_phase(self.phase)
    end
    return
  end

  local m = self.machine
  m:update(dt)
  if m.phase == "windup" then
    local w = phases[self.phase].windups[m.state]
    self.telegraph = m.state
    if w and w > EPS then
      local t = m.time / w
      if t > 1 then t = 1 end
      self.telegraph_t = t
    else
      self.telegraph_t = 1
    end
  else
    self.telegraph, self.telegraph_t = nil, 0
  end
end

-- The current state's name (for the game's animations and tests).
function Boss:state()
  if self.transitioning then return nil end
  return self.machine and self.machine.state
end

return M
