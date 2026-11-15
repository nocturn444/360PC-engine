-- combat.fsm: a small state machine. See engine/modules/combat/README.md.
--
--   local def = {
--     initial = "idle",
--     states = {
--       idle = { transitions = { { to = "walk", after = 0.5 } } },
--       walk = {
--         enter = function(m, owner, previous) end,
--         update = function(m, owner, dt) end,       -- may return a state name to go there
--         exit = function(m, owner, next) end,
--         transitions = { { to = "idle", when = function(m, owner) return owner.tired end } },
--       },
--     },
--   }
--   local m = fsm.new(def, enemy)       -- the definition is data: many machines can share it
--   m:update(dt)                        -- once per fixed step
--
-- Nothing here is random or reads a clock: the time in a state is the sum of the dt given.
local pairs, tostring, type = pairs, tostring, type

local M = {}
local Machine = {}
Machine.__index = Machine

local EPS = 1e-9          -- a timer this close to its end has run out

local function check(def)
  if type(def.states) ~= "table" then error("fsm: the definition needs states", 3) end
  if not def.states[def.initial] then error("fsm: no initial state " .. tostring(def.initial), 3) end
  for name, state in pairs(def.states) do
    local list = state.transitions
    if list then
      for i = 1, #list do
        local t = list[i]
        if not def.states[t.to] then
          error("fsm: state " .. tostring(name) .. " goes to the unknown state " .. tostring(t.to), 3)
        end
        if not t.when and not t.after then
          error("fsm: a transition of " .. tostring(name) .. " needs when or after", 3)
        end
      end
    end
  end
end

-- def: { initial = name, states = { name = state, ... } }. A state (every field optional):
--   enter(m, owner, previous)   previous: the name of the state left (nil at the start)
--   update(m, owner, dt)        once per step; a state name returned is the next state
--   exit(m, owner, next)
--   transitions                 an array, tried in order after update:
--                                 { to = name, when = function(m, owner) -> true to go,
--                                   after = seconds in this state before it can go }
--                               with only `after` it goes when that time is up.
-- owner: anything; the callbacks get it.
function M.new(def, owner)
  check(def)
  local m = setmetatable({
    def = def, owner = owner,
    state = nil,           -- the current state's name
    previous = nil,        -- the name of the state before it
    time = 0,              -- seconds in the current state
    phase = nil,           -- free for the current state; cleared on every change
    changes = 0,           -- state changes so far
    _current = nil,
  }, Machine)
  m:set(def.initial)
  return m
end

-- Goes to that state now: exit of the current one, then enter of the new one.
function Machine:set(name)
  local nxt = self.def.states[name]
  if not nxt then error("fsm: no state " .. tostring(name), 2) end
  local cur = self._current
  if cur and cur.exit then cur.exit(self, self.owner, name) end
  self.previous, self.state, self._current = self.state, name, nxt
  self.time, self.phase = 0, nil
  self.changes = self.changes + 1
  if nxt.enter then nxt.enter(self, self.owner, self.previous) end
end

function Machine:is(name) return self.state == name end

-- One fixed step: the state's update, then its transitions in order. At most one change per
-- step. Returns the new state's name if it changed.
function Machine:update(dt)
  local cur = self._current
  local time = self.time + dt
  self.time = time
  if cur.update then
    local to = cur.update(self, self.owner, dt)
    if to then self:set(to); return to end
    if self._current ~= cur then return self.state end      -- update called set itself
  end
  local list = cur.transitions
  if list then
    for i = 1, #list do
      local t = list[i]
      if (not t.after or time >= t.after - EPS) and (not t.when or t.when(self, self.owner)) then
        self:set(t.to)
        return t.to
      end
    end
  end
end

return M
