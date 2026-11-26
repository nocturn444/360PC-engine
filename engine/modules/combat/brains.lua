-- combat.brains: builds a combat.fsm definition from plain data, looking behaviours and
-- conditions up by name in a registry a game can extend. See engine/modules/combat/README.md
-- ("Brains as data").
--
--   local brains = combat.brains
--   local def = brains.build({
--     initial = "patrol",
--     states = {
--       patrol = { "patrol", speed = 22, pause = { 0.3, 0.9 } },
--       chase  = { "chase", speed = 45, stop = 8 },
--       shoot  = { "shoot", attack = "spit", aim = "target", volleys = 3, interval = 0.25,
--                  next = "chase" },
--     },
--     transitions = {
--       patrol = { { to = "chase", when = { "target_within", 80, "xy" } } },
--       chase  = { { to = "shoot", when = { "target_in_sight", 140 }, after = 1.0 },
--                  { to = "patrol", when = { "target_beyond", 160, "xy" } } },
--     },
--   }, { grid = grid, blocked = blocked })       -- context shared by every state
--   local m = combat.fsm.new(def, enemy)
--
-- A state entry is { behaviour_name, opts... }; the opts are copied (without [1]) and passed to
-- the registered behaviour constructor. The build context fills the opts a behaviour may need
-- when the spec leaves them out: opts given in the spec win over ctx. The name "idle" is a
-- state that halts.
--
-- A transition's `when` is a condition: { name, args... }, { "all", c1, c2, ... },
-- { "any", ... }, { "not", c }, or a plain function(m, agent). Registered condition constructors
-- receive (args, ctx), where args is the condition spec ([1] is the name), and return a
-- function(m, agent). The built-in target_in_sight takes its range as the argument and its grid
-- from ctx.grid (or a third spec element).
--
-- A game extends the registry with brains.behaviour(name, ctor) and brains.condition(name,
-- ctor). build is called once per enemy type (never per frame); the definition it returns can be
-- shared by every machine of that type. Nothing here is random or reads a clock.
local type, pairs, unpack, error, tostring = type, pairs, unpack, error, tostring

local behaviours = require((...):gsub("brains$", "behaviours"))

local M = {}

local state_ctors = {}
local condition_ctors = {}

-- Registers a state constructor: ctor(opts) -> a state table (enter / update / exit / ...).
function M.behaviour(name, ctor)
  if type(name) ~= "string" then error("combat.brains.behaviour: the name must be a string", 2) end
  if type(ctor) ~= "function" then error("combat.brains.behaviour: " .. name .. " needs a function", 2) end
  state_ctors[name] = ctor
end

-- Registers a condition constructor: ctor(args, ctx) -> function(m, agent).
function M.condition(name, ctor)
  if type(name) ~= "string" then error("combat.brains.condition: the name must be a string", 2) end
  if type(ctor) ~= "function" then error("combat.brains.condition: " .. name .. " needs a function", 2) end
  condition_ctors[name] = ctor
end

-- A constructible condition from a plain behaviours function with positional arguments.
local function builtin(fn)
  return function(args) return fn(unpack(args, 2, #args)) end
end

-- A state that only stops the agent: enter and update halt, nothing else.
local function idle()
  local state = {}
  function state.enter(_, agent) agent.move_x, agent.move_y = 0, 0 end
  function state.update(_, agent) agent.move_x, agent.move_y = 0, 0 end
  return state
end

local function unknown_condition(state, name)
  error("combat.brains: state " .. tostring(state) .. ": unknown condition " .. tostring(name), 4)
end

-- Turns a condition spec into function(m, agent). state names the brain state for the errors.
local function condition(spec, ctx, state)
  if type(spec) == "function" then return spec end
  if type(spec) ~= "table" then
    error("combat.brains: state " .. tostring(state) .. ": a condition must be a table or a function", 4)
  end
  local name = spec[1]
  if type(name) ~= "string" then
    error("combat.brains: state " .. tostring(state) .. ": the first condition element must be its name", 4)
  end
  if name == "all" or name == "any" then
    local list, n = {}, #spec - 1
    for i = 2, #spec do list[i - 1] = condition(spec[i], ctx, state) end
    if name == "all" then return behaviours.all(unpack(list, 1, n)) end
    return behaviours.any(unpack(list, 1, n))
  elseif name == "not" then
    if #spec ~= 2 then
      error("combat.brains: state " .. tostring(state) .. ": \"not\" takes one condition", 4)
    end
    return behaviours.negate(condition(spec[2], ctx, state))
  end
  local ctor = condition_ctors[name]
  if not ctor then unknown_condition(state, name) end
  local fn = ctor(spec, ctx)
  if type(fn) ~= "function" then
    error("combat.brains: state " .. tostring(state) .. ": the condition " .. name
      .. " did not return a function", 4)
  end
  return fn
end

-- Copies the opts of a state entry (everything but [1]) over a copy of ctx: spec opts win.
local function options(entry, ctx)
  local opts = {}
  for k, v in pairs(ctx) do opts[k] = v end
  for k, v in pairs(entry) do
    if k ~= 1 then opts[k] = v end
  end
  return opts
end

local function make_state(state_name, entry, ctx)
  if type(entry) ~= "table" then
    error("combat.brains: state " .. tostring(state_name)
      .. ": the entry must be a table { behaviour_name, opts... }", 4)
  end
  local behaviour = entry[1]
  if type(behaviour) ~= "string" then
    error("combat.brains: state " .. tostring(state_name)
      .. ": the first element must be the behaviour name", 4)
  end
  local ctor = state_ctors[behaviour]
  if not ctor then
    error("combat.brains: state " .. tostring(state_name) .. ": unknown behaviour " .. behaviour, 4)
  end
  return ctor(options(entry, ctx))
end

local function make_transitions(state_name, list, ctx)
  if type(list) ~= "table" then
    error("combat.brains: state " .. tostring(state_name)
      .. ": field transitions must be a list", 4)
  end
  local out = {}
  for i = 1, #list do
    local t = list[i]
    local where = "combat.brains: state " .. tostring(state_name) .. ": transition " .. i
    if type(t) ~= "table" then error(where .. " must be a table", 4) end
    if type(t.to) ~= "string" then
      error(where .. ": field to must be a state name", 4)
    end
    if t.when == nil and t.after == nil then
      error(where .. " needs when or after", 4)
    end
    if t.after ~= nil and type(t.after) ~= "number" then
      error(where .. ": field after must be a number", 4)
    end
    local nt = { to = t.to }
    if t.after ~= nil then nt.after = t.after end
    if t.when ~= nil then nt.when = condition(t.when, ctx, state_name) end
    out[i] = nt
  end
  return out
end

-- Turns a data spec into a fsm definition. ctx is an optional table of values a behaviour or
-- condition may need (grid, blocked, grounded, points, ...); spec values win over it.
function M.build(spec, ctx)
  if type(spec) ~= "table" then error("combat.brains.build: the spec must be a table", 2) end
  if ctx ~= nil and type(ctx) ~= "table" then
    error("combat.brains.build: ctx must be a table", 2)
  end
  ctx = ctx or {}
  local initial = spec.initial
  if type(initial) ~= "string" then
    error("combat.brains.build: the spec needs an initial state name", 2)
  end
  local states = spec.states
  if type(states) ~= "table" then error("combat.brains.build: the spec needs states", 2) end
  if states[initial] == nil then
    error("combat.brains: initial state " .. initial .. " is not in states", 2)
  end
  local transitions = spec.transitions
  if transitions ~= nil and type(transitions) ~= "table" then
    error("combat.brains.build: field transitions must be a table", 2)
  end
  local def = { initial = initial, states = {} }
  for name, entry in pairs(states) do
    if type(name) ~= "string" then
      error("combat.brains: a state name must be a string", 2)
    end
    if type(entry) == "table" and entry.next ~= nil and states[entry.next] == nil then
      error("combat.brains: state " .. name .. ": next goes to the unknown state "
        .. tostring(entry.next), 2)
    end
    if type(entry) == "table" and entry[1] == "rotate" and type(entry.options) == "table" then
      for i = 1, #entry.options do
        local o = entry.options[i]
        if type(o) == "table" and states[o.to] == nil then
          error("combat.brains: state " .. name .. ": options[" .. i .. "] goes to the unknown state "
            .. tostring(o.to), 2)
        end
      end
    end
    local state = make_state(name, entry, ctx)
    local list = transitions and transitions[name]
    if list ~= nil then state.transitions = make_transitions(name, list, ctx) end
    def.states[name] = state
  end
  return def
end

M.behaviour("patrol", behaviours.patrol)
M.behaviour("chase", behaviours.chase)
M.behaviour("attack", behaviours.attack)
M.behaviour("shoot", behaviours.shoot)
M.behaviour("charge", behaviours.charge)
M.behaviour("hop", behaviours.hop)
M.behaviour("leap", behaviours.leap)
M.behaviour("fly", behaviours.fly)
M.behaviour("keep_away", behaviours.keep_away)
M.behaviour("rotate", behaviours.rotate)
M.behaviour("idle", idle)

M.condition("target_within", builtin(behaviours.target_within))
M.condition("target_beyond", builtin(behaviours.target_beyond))
M.condition("target_above", builtin(behaviours.target_above))
M.condition("target_below", builtin(behaviours.target_below))
M.condition("grounded", function() return behaviours.grounded() end)
M.condition("health_below", builtin(behaviours.health_below))
M.condition("target_in_sight", function(args, ctx)
  local grid = args[3]
  if grid == nil then grid = ctx and ctx.grid end
  return behaviours.target_in_sight(grid, args[2])
end)

return M
