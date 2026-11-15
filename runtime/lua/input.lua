-- The controller as official LOVE 11 shows an Xbox controller on PC (SDL's XInput layout), so the
-- same game code runs on both. Lua 5.1 / LuaJIT without JIT. No keyboard emulation.
-- One snapshot per frame (l360.poll_input, then api:update); the getters never query the hardware.
-- No deadzone is applied: like LOVE, that is left to the game.
local M = {}
local PORTS = 4
local GUID = '030000005e0400008e02000000007200' -- what SDL gives an XInput controller on Windows
local MAPPING = GUID .. ',Xbox 360 Controller,a:b0,b:b1,back:b6,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,'
  .. 'dpup:h0.1,guide:b10,leftshoulder:b4,leftstick:b8,lefttrigger:a4,leftx:a0,lefty:a1,'
  .. 'rightshoulder:b5,rightstick:b9,righttrigger:a5,rightx:a2,righty:a3,start:b7,x:b2,y:b3,'
-- Gamepad button -> l360.pad field. The first 11 are also SDL's raw buttons, in this order (1-based
-- in LOVE); the d-pad is raw hat 1, not buttons.
local BUTTONS = {
  {'a','a'}, {'b','b'}, {'x','x'}, {'y','y'}, {'leftshoulder','lb'}, {'rightshoulder','rb'},
  {'back','back'}, {'start','start'}, {'leftstick','s1_z'}, {'rightstick','s2_z'}, {'guide','logo'},
  {'dpup','up'}, {'dpdown','down'}, {'dpleft','left'}, {'dpright','right'},
}
local RAW_BUTTONS = 11
-- Gamepad axes, which are also SDL's raw axes 1 to 6 (raw triggers go from -1 to 1, gamepad 0 to 1).
local AXES = {'leftx','lefty','rightx','righty','triggerleft','triggerright'}
local HAT_INPUT = {dpup='u', dpdown='d', dpleft='l', dpright='r'}
local function clamp(n, lo, hi) return math.max(lo, math.min(hi, n)) end
local function down(n) return n == true or (type(n) == 'number' and n ~= 0) end
local function stick(n) return clamp((tonumber(n) or 0) / 32767, -1, 1) end
local function trigger(n) return clamp(tonumber(n) or 0, 0, 255) / 255 end
local function hat_of(b)
  local v = (b.dpleft and 'l' or b.dpright and 'r' or '') .. (b.dpup and 'u' or b.dpdown and 'd' or '')
  return v == '' and 'c' or v
end

function M.new(love, native)
  assert(type(native.pad) == 'function', 'missing l360.pad')
  local connected = {}          -- joysticks in connection order, as getJoysticks returns them
  local next_id, next_instance = 1, 1
  local Joystick = {}
  Joystick.__index = Joystick
  local function emit(name, ...)
    local f = rawget(love, name) -- do not call love's __index stub
    if type(f) == 'function' then f(...) end
  end

  function Joystick:type() return 'Joystick' end
  function Joystick:typeOf(name) return name == 'Joystick' or name == 'Object' end
  function Joystick:release() return false end
  function Joystick:isConnected() return self.connected end
  function Joystick:getID() return self.id, self.connected and self.instance or nil end
  function Joystick:getName() return 'Xbox 360 Controller' end
  function Joystick:getGUID() return GUID end
  function Joystick:getDeviceInfo() return 0x045e, 0x028e, 0 end
  function Joystick:isGamepad() return true end
  function Joystick:getGamepadMappingString() return MAPPING end
  function Joystick:getGamepadMapping(name)
    if HAT_INPUT[name] then return 'hat', 1, HAT_INPUT[name] end
    for i = 1, RAW_BUTTONS do if BUTTONS[i][1] == name then return 'button', i end end
    for i, a in ipairs(AXES) do if a == name then return 'axis', i end end
    return nil
  end
  function Joystick:getGamepadAxis(name)
    local v = self.axes[name]
    if v == nil then error('Invalid gamepad axis: ' .. tostring(name), 2) end
    return v
  end
  function Joystick:isGamepadDown(...)
    local list = ...
    if type(list) ~= 'table' then list = {...} end
    for _, name in ipairs(list) do
      local v = self.buttons[name]
      if v == nil then error('Invalid gamepad button: ' .. tostring(name), 2) end
      if v then return true end
    end
    return false
  end
  function Joystick:getAxisCount() return self.connected and #AXES or 0 end
  function Joystick:getButtonCount() return self.connected and RAW_BUTTONS or 0 end
  function Joystick:getHatCount() return self.connected and 1 or 0 end
  function Joystick:getAxis(i) return self.connected and self.raw[i] or 0 end
  function Joystick:getAxes() if self.connected then return unpack(self.raw, 1, #AXES) end end
  function Joystick:getHat(i) return i == 1 and hat_of(self.buttons) or 'c' end
  function Joystick:isDown(...)
    local list = ...
    if type(list) ~= 'table' then list = {...} end
    for _, i in ipairs(list) do
      local b = BUTTONS[i]
      if b and i <= RAW_BUTTONS and self.buttons[b[1]] then return true end
    end
    return false
  end
  function Joystick:isVibrationSupported() return type(native.rumble) == 'function' end
  function Joystick:getVibration() return self.vib_left, self.vib_right end
  -- setVibration() stops; setVibration(left, right, duration): 0..1, duration in seconds (none or
  -- negative = until changed).
  function Joystick:setVibration(left, right, duration)
    left = clamp(tonumber(left) or 0, 0, 1)
    right = clamp(tonumber(right) or left, 0, 1)
    if not self.connected or not self:isVibrationSupported() then return false end
    if not native.rumble(self.port, math.floor(left * 255 + 0.5), math.floor(right * 255 + 0.5)) then
      return false
    end
    self.vib_left, self.vib_right = left, right
    self.vib_until = (left > 0 or right > 0) and duration and duration >= 0
      and (native.time() + duration) or nil
    return true
  end

  local function clear(joy)
    joy.buttons, joy.axes, joy.raw = {}, {}, {0, 0, 0, 0, -1, -1}
    for _, b in ipairs(BUTTONS) do joy.buttons[b[1]] = false end
    for _, a in ipairs(AXES) do joy.axes[a] = 0 end
    joy.vib_left, joy.vib_right, joy.vib_until = 0, 0, nil
  end
  local ports = {}
  for port = 0, PORTS - 1 do
    local joy = setmetatable({port = port, connected = false}, Joystick)
    clear(joy)
    ports[port] = joy
  end

  love.joystick = {
    getJoysticks = function()
      local out = {}
      for i, joy in ipairs(connected) do out[i] = joy end
      return out
    end,
    getJoystickCount = function() return #connected end,
    -- The mapping is fixed (there is no SDL here)
    loadGamepadMappings = function() end,
    setGamepadMapping = function() return false end,
    saveGamepadMappings = function() return MAPPING end,
    getGamepadMappingString = function(guid) return guid == GUID and MAPPING or nil end,
  }

  local function update(joy)
    local pad = native.pad(joy.port)
    if not pad then
      if joy.connected then -- like LOVE: no release events, just joystickremoved
        joy.connected = false
        clear(joy)
        for i, j in ipairs(connected) do if j == joy then table.remove(connected, i); break end end
        emit('joystickremoved', joy)
      end
      return
    end
    if not joy.connected then
      joy.connected = true
      joy.id = joy.id or next_id
      if joy.id == next_id then next_id = next_id + 1 end
      joy.instance, next_instance = next_instance, next_instance + 1
      connected[#connected + 1] = joy
      emit('joystickadded', joy)
    end
    local old_buttons, old_axes, old_raw, old_hat = joy.buttons, joy.axes, joy.raw, hat_of(joy.buttons)
    local buttons, axes = {}, {}
    for _, b in ipairs(BUTTONS) do buttons[b[1]] = down(pad[b[2]]) end
    axes.leftx, axes.lefty = stick(pad.s1_x), 0 - stick(pad.s1_y) -- XAM: up is positive; SDL: down (0 - x: no -0)
    axes.rightx, axes.righty = stick(pad.s2_x), 0 - stick(pad.s2_y)
    axes.triggerleft, axes.triggerright = trigger(pad.lt), trigger(pad.rt)
    local raw = {axes.leftx, axes.lefty, axes.rightx, axes.righty,
      axes.triggerleft * 2 - 1, axes.triggerright * 2 - 1}
    -- The whole snapshot is visible from every callback
    joy.buttons, joy.axes, joy.raw = buttons, axes, raw
    for i, name in ipairs(AXES) do
      if raw[i] ~= old_raw[i] then emit('joystickaxis', joy, i, raw[i]) end
      if axes[name] ~= old_axes[name] then emit('gamepadaxis', joy, name, axes[name]) end
    end
    local hat = hat_of(buttons)
    if hat ~= old_hat then emit('joystickhat', joy, 1, hat) end
    for i, b in ipairs(BUTTONS) do
      local now = buttons[b[1]]
      if now ~= old_buttons[b[1]] then
        if i <= RAW_BUTTONS then emit(now and 'joystickpressed' or 'joystickreleased', joy, i) end
        emit(now and 'gamepadpressed' or 'gamepadreleased', joy, b[1])
      end
    end
    if joy.vib_until and native.time() >= joy.vib_until then joy:setVibration() end
  end

  local api = {}
  function api:update()
    for port = 0, PORTS - 1 do update(ports[port]) end
  end
  return api
end
return M
