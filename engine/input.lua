-- engine.input: actions instead of keys. The game declares, as data, which keyboard keys, mouse
-- buttons, gamepad buttons and gamepad axes trigger each action; the code only asks about
-- actions. See docs/ENGINE.md.
--
--   local input = Input.new({
--     deadzone = 0.25, threshold = 0.5,
--     actions = {
--       confirm = { keys = { "return", "z" }, mouse = { 1 }, buttons = { "a" } },
--       left    = { keys = { "left", "a" }, buttons = { "dpleft" } },
--       right   = { keys = { "right", "d" }, buttons = { "dpright" } },
--       fire    = { keys = { "x" }, axes = { "triggerright+" } },   -- or { axis = "triggerright", dir = 1, threshold = 0.3 }
--     },
--     axes = { move_x = { negative = "left", positive = "right", stick = "leftx" } },
--   })
--
-- input:poll() reads the devices (once per frame); input:step() advances the edges (once per
-- fixed step). pressed/released are true for exactly one step; a press shorter than a step is
-- not lost. Keyboard and mouse come from love.keyboard / love.mouse (PC), the controller from
-- love.joystick's gamepad API (PC and console). Nothing is turned into keys.
local abs = math.abs
local pairs, ipairs, type = pairs, ipairs, type

local M = {}
local Input = {}
Input.__index = Input

local KINDS = { "keys", "mouse", "buttons", "axes" }

-- "leftx+", "leftx-" or { axis = "leftx", dir = 1 | -1, threshold = n } -> { axis, dir, threshold }
local function compile_axis(spec)
  if type(spec) == "string" then
    local name, sign = spec:match("^(%a+)([+-])$")
    assert(name, "axis binding must look like \"leftx+\" or \"leftx-\": " .. spec)
    return { axis = name, dir = sign == "-" and -1 or 1 }
  end
  assert(type(spec) == "table" and type(spec.axis) == "string", "axis binding needs an axis name")
  return { axis = spec.axis, dir = (spec.dir or 1) < 0 and -1 or 1, threshold = spec.threshold }
end

local function export_axis(b)
  if b.threshold then return { axis = b.axis, dir = b.dir, threshold = b.threshold } end
  return b.axis .. (b.dir < 0 and "-" or "+")
end

local function same(kind, a, b)
  if kind ~= "axes" then return a == b end
  return a.axis == b.axis and a.dir == b.dir
end

function M.new(config)
  config = config or {}
  local self = setmetatable({}, Input)
  self.deadzone = config.deadzone or 0.25     -- sticks, for axis actions
  self.threshold = config.threshold or 0.5    -- an axis counts as a button past this
  self.pad_index = config.joystick            -- nil: every connected gamepad; n: only the nth
  self.actions, self.list = {}, {}
  self.axes, self.axis_list = {}, {}
  self.joysticks = {}
  self.device = config.device or "keyboard"   -- "keyboard" (keys and mouse) or "gamepad": last one used
  self.joystick = nil                         -- the gamepad last used
  self.listener = nil
  for name, b in pairs(config.actions or {}) do self:define(name, b) end
  for name, a in pairs(config.axes or {}) do self:defineAxis(name, a) end
  self:refreshJoysticks()
  return self
end

---------------------------------------------------------------------------
-- Bindings
---------------------------------------------------------------------------
local function action_of(self, name)
  local a = self.actions[name]
  if not a then error("unknown action: " .. tostring(name), 3) end
  return a
end

-- Creates an action or replaces all of its bindings. bindings: { keys, mouse, buttons, axes }.
function Input:define(name, bindings)
  local a = self.actions[name]
  if not a then
    a = { name = name, raw = false, latch = false, down = false, pressed = false, released = false,
      kb = false, pad = false }
    self.actions[name] = a
    self.list[#self.list + 1] = a
  end
  bindings = bindings or {}
  for _, kind in ipairs(KINDS) do
    local out = {}
    for i, v in ipairs(bindings[kind] or {}) do out[i] = kind == "axes" and compile_axis(v) or v end
    a[kind] = out
  end
  return a
end

-- An analog action, -1..1: `stick` is a gamepad axis; `negative` / `positive` are (digital) actions.
function Input:defineAxis(name, def)
  local x = self.axes[name]
  if not x then
    x = { name = name, analog = 0, value = 0 }
    self.axes[name] = x
    self.axis_list[#self.axis_list + 1] = x
  end
  x.stick, x.negative, x.positive = def.stick, def.negative, def.positive
  x.deadzone, x.invert = def.deadzone, def.invert and true or false
  if x.negative then action_of(self, x.negative) end
  if x.positive then action_of(self, x.positive) end
  return x
end

-- Adds one binding: input:bind("jump", "keys", "space"), input:bind("fire", "axes", "triggerright+").
function Input:bind(name, kind, value)
  local list = action_of(self, name)[kind]
  assert(list, "binding kind must be keys, mouse, buttons or axes")
  if kind == "axes" then value = compile_axis(value) end
  for i = 1, #list do if same(kind, list[i], value) then list[i] = value; return end end
  list[#list + 1] = value
end

-- Removes one binding, or every binding of that kind if value is nil.
function Input:unbind(name, kind, value)
  local list = action_of(self, name)[kind]
  assert(list, "binding kind must be keys, mouse, buttons or axes")
  if kind == "axes" and value ~= nil then value = compile_axis(value) end
  for i = #list, 1, -1 do
    if value == nil or same(kind, list[i], value) then table.remove(list, i) end
  end
end

-- A copy of an action's bindings, in the format define() takes.
function Input:getBindings(name)
  local a = action_of(self, name)
  local out = {}
  for _, kind in ipairs(KINDS) do
    local list = {}
    for i, v in ipairs(a[kind]) do list[i] = kind == "axes" and export_axis(v) or v end
    out[kind] = list
  end
  return out
end

-- Every action's bindings: { actions = { name = bindings } }, to store and pass back to load().
function Input:export()
  local out = { actions = {} }
  for name in pairs(self.actions) do out.actions[name] = self:getBindings(name) end
  return out
end

-- Applies bindings stored by export(); actions that no longer exist are skipped.
function Input:load(data)
  for name, b in pairs(data and data.actions or {}) do
    if self.actions[name] then self:define(name, b) end
  end
end

-- Rebinding: the next key, mouse button, gamepad button or axis seen by the event functions
-- below goes to fn(kind, value) instead of to the game. fn = nil cancels.
function Input:capture(fn) self.listener = fn end

---------------------------------------------------------------------------
-- Events (forwarded from the love callbacks by engine.run; only needed for capture)
---------------------------------------------------------------------------
local function deliver(self, kind, value)
  local fn = self.listener
  if not fn then return false end
  self.listener = nil
  fn(kind, value)
  return true
end

function Input:keypressed(key) self.device = "keyboard"; return deliver(self, "keys", key) end
function Input:mousepressed(button) self.device = "keyboard"; return deliver(self, "mouse", button) end
function Input:gamepadpressed(joystick, button)
  self.device, self.joystick = "gamepad", joystick
  return deliver(self, "buttons", button)
end
function Input:gamepadaxis(joystick, axis, value)
  if abs(value) < self.threshold then return false end
  self.device, self.joystick = "gamepad", joystick
  if not self.listener then return false end
  return deliver(self, "axes", axis .. (value < 0 and "-" or "+"))
end

-- Call when controllers come and go (love.joystickadded / love.joystickremoved).
function Input:refreshJoysticks()
  local list = self.joysticks
  for i = #list, 1, -1 do list[i] = nil end
  local js = love.joystick
  if not js then return end
  local n = 0
  for _, j in ipairs(js.getJoysticks()) do
    if j:isGamepad() then
      n = n + 1
      if not self.pad_index or self.pad_index == n then list[#list + 1] = j end
    end
  end
  if self.joystick then
    local found = false
    for i = 1, #list do if list[i] == self.joystick then found = true end end
    if not found then self.joystick = nil end
  end
end

---------------------------------------------------------------------------
-- Per frame and per step
---------------------------------------------------------------------------
-- Reads the devices. Once per frame, before the fixed steps.
function Input:poll()
  local kb, ms = love.keyboard, love.mouse
  local pads, npads = self.joysticks, #self.joysticks
  local threshold = self.threshold
  local list = self.list
  for i = 1, #list do
    local a = list[i]
    local on_kb, on_pad, pad = false, false, nil
    if kb then
      local keys = a.keys
      for k = 1, #keys do if kb.isDown(keys[k]) then on_kb = true; break end end
    end
    if ms and not on_kb then
      local buttons = a.mouse
      for k = 1, #buttons do if ms.isDown(buttons[k]) then on_kb = true; break end end
    end
    for p = 1, npads do
      local j = pads[p]
      local buttons = a.buttons
      for k = 1, #buttons do if j:isGamepadDown(buttons[k]) then on_pad = true; break end end
      if not on_pad then
        local axes = a.axes
        for k = 1, #axes do
          local b = axes[k]
          if j:getGamepadAxis(b.axis) * b.dir >= (b.threshold or threshold) then on_pad = true; break end
        end
      end
      if on_pad then pad = j; break end
    end
    -- the device is the one of the latest new press
    if on_kb and not a.kb then self.device = "keyboard" end
    if on_pad and not a.pad then self.device, self.joystick = "gamepad", pad end
    a.kb, a.pad = on_kb, on_pad
    local raw = on_kb or on_pad
    a.raw = raw
    if raw then a.latch = true end
  end

  local axes = self.axis_list
  for i = 1, #axes do
    local x = axes[i]
    local v = 0
    if x.stick then
      local dz = x.deadzone or self.deadzone
      for p = 1, npads do
        local s = pads[p]:getGamepadAxis(x.stick)
        local m = abs(s)
        if m > dz and m > abs(v) then
          -- rescaled so that the value starts at 0 at the edge of the deadzone
          m = (m - dz) / (1 - dz)
          if m > 1 then m = 1 end
          v = s < 0 and -m or m
          if x.analog == 0 then self.device, self.joystick = "gamepad", pads[p] end
        end
      end
    end
    x.analog = v
  end
end

-- Advances one fixed step: sets down / pressed / released for every action and the axis values.
function Input:step()
  local list = self.list
  for i = 1, #list do
    local a = list[i]
    local d = a.latch or a.raw
    a.pressed = d and not a.down
    a.released = a.down and not d
    a.down = d
    a.latch = false
  end
  local axes, actions = self.axis_list, self.actions
  for i = 1, #axes do
    local x = axes[i]
    local v = 0
    if x.positive and actions[x.positive].down then v = v + 1 end
    if x.negative and actions[x.negative].down then v = v - 1 end
    if v == 0 then v = x.analog end
    if x.invert then v = -v end
    x.value = v
  end
end

-- Forgets what is held (after a state change, so a held button does not fire in the new state):
-- everything held now has to be released and pressed again.
function Input:flush()
  local list = self.list
  for i = 1, #list do
    local a = list[i]
    a.latch, a.pressed, a.released = false, false, false
    a.down = a.raw
  end
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------
function Input:down(name) return action_of(self, name).down end
function Input:pressed(name) return action_of(self, name).pressed end
function Input:released(name) return action_of(self, name).released end

-- An axis action's value, -1..1. A plain action answers 1 or 0.
function Input:axis(name)
  local x = self.axes[name]
  if x then return x.value end
  return action_of(self, name).down and 1 or 0
end

function Input:getDevice() return self.device, self.joystick end

return M
