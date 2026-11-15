-- engine.state: a stack of game states (menu, play, pause...). See docs/ENGINE.md.
-- A state is any table; every hook is optional:
--   enter(self, previous, ...)   pushed or switched to       exit(self, next)      removed
--   pause(self, next)            another state pushed on top resume(self, from, ...) top again after a pop
--   input(self, input)           once per fixed step, before update
--   update(self, dt)             once per fixed step (top state only)
--   draw(self, alpha)            every frame; states under a state with `transparent = true` are drawn first
-- Other events reach the top state with machine:emit(name, ...).
local M = {}
local Machine = {}
Machine.__index = Machine

function M.new()
  return setmetatable({ stack = {}, n = 0, named = {} }, Machine)
end

-- Registers a state under a name, so push/switch can take the name.
function Machine:add(name, state)
  assert(type(state) == "table", "a state must be a table")
  self.named[name] = state
  return state
end

function Machine:get(name) return self.named[name] end

local function resolve(self, state)
  if type(state) ~= "table" then
    local s = self.named[state]
    if not s then error("unknown state: " .. tostring(state), 3) end
    return s
  end
  return state
end

function Machine:top() return self.stack[self.n] end
function Machine:depth() return self.n end

function Machine:push(state, ...)
  state = resolve(self, state)
  local prev = self.stack[self.n]
  if prev and prev.pause then prev:pause(state) end
  self.n = self.n + 1
  self.stack[self.n] = state
  if state.enter then state:enter(prev, ...) end
  return state
end

-- Removes the top state; the extra arguments go to the resume hook of the one under it.
function Machine:pop(...)
  local n = self.n
  if n == 0 then return nil end
  local old = self.stack[n]
  local below = self.stack[n - 1]
  self.stack[n] = nil
  self.n = n - 1
  if old.exit then old:exit(below) end
  if below and below.resume then below:resume(old, ...) end
  return old
end

-- Replaces the top state (or pushes, on an empty stack).
function Machine:switch(state, ...)
  state = resolve(self, state)
  local n = self.n
  local old = self.stack[n]
  if old then
    self.stack[n] = nil
    self.n = n - 1
    if old.exit then old:exit(state) end
  end
  self.n = self.n + 1
  self.stack[self.n] = state
  if state.enter then state:enter(old, ...) end
  return state
end

-- Empties the stack (exit hooks run top to bottom) and, if given, enters a state.
function Machine:reset(state, ...)
  while self.n > 0 do
    local old = self.stack[self.n]
    self.stack[self.n] = nil
    self.n = self.n - 1
    if old.exit then old:exit(nil) end
  end
  if state ~= nil then return self:push(state, ...) end
end

function Machine:input(input)
  local s = self.stack[self.n]
  if s and s.input then s:input(input) end
end

function Machine:update(dt)
  local s = self.stack[self.n]
  if s and s.update then s:update(dt) end
end

-- Draws from the highest state that is not transparent up to the top. `hook` defaults to "draw".
function Machine:draw(alpha, hook)
  hook = hook or "draw"
  local stack, n = self.stack, self.n
  local first = n
  while first > 1 and stack[first].transparent do first = first - 1 end
  for i = first, n do
    local s = stack[i]
    -- a hook may pop: the state can be gone by now
    if s and s[hook] then s[hook](s, alpha) end
  end
end

-- Calls the hook `name` of the top state, if it has it.
function Machine:emit(name, ...)
  local s = self.stack[self.n]
  local f = s and s[name]
  if f then return f(s, ...) end
end

return M
