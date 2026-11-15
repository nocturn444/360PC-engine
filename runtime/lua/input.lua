-- Renderer-independent input adapter. Lua 5.1 / LuaJIT without JIT.
-- One snapshot per frame; getters never query USB. Port 0 only.
local M = {}
local buttons = {
  {'a','a'}, {'b','b'}, {'x','x'}, {'y','y'}, {'back','back'}, {'start','start'},
  {'leftshoulder','lb'}, {'rightshoulder','rb'}, {'leftstick','s1_z'},
  {'rightstick','s2_z'}, {'dpup','up'}, {'dpdown','down'},
  {'dpleft','left'}, {'dpright','right'},
}
local axes = {'leftx','lefty','rightx','righty','triggerleft','triggerright'}
local guid = '030000005e0400008e02000000000000'
local function clamp(n, lo, hi) return math.max(lo, math.min(hi, n)) end
local function down(n) return n == true or (type(n) == 'number' and n ~= 0) end
local function stick(n)
  n = clamp(tonumber(n) or 0, -32768, 32767)
  return n / (n < 0 and 32768 or 32767)
end
-- Radial cutoff without rescaling: the game applies its own thresholds.
local function pair(x, y, dz)
  x, y = stick(x), -stick(y) -- XInput: up is positive; LOVE: down is positive.
  if x*x + y*y <= dz*dz then return 0, 0 end
  return x, y
end
function M.new(love, native, cfg)
  cfg = cfg or {}
  local dz = cfg.deadzone or 0.2
  assert(type(dz) == 'number' and dz >= 0 and dz < 1, 'deadzone out of range')
  assert(type(native.pad) == 'function', 'missing l360.pad')
  local joy = {connected=false, buttons={}, axes={}}
  local blocked, blocked_axes, previous = {}, {}, {}
  local rumble_until, vibration_left, vibration_right = nil, 0, 0
  local api = {}
  local function emit(name, ...)
    local f = rawget(love, name) -- do not call love's __index stub
    if type(f) == 'function' then f(joy, ...) end
  end
  function joy:isGamepad() return true end
  function joy:getName() return 'Xbox 360 Controller' end
  function joy:getGUID() return guid end
  function joy:getID() return 1, 0 end
  function joy:isConnected() return self.connected end
  function joy:getGamepadMappingString()
    return guid .. ',Xbox 360 Controller,a:b0,b:b1,x:b2,y:b3,back:b4,start:b5,leftstick:b6,rightstick:b7,leftshoulder:b8,rightshoulder:b9,dpup:b10,dpdown:b11,dpleft:b12,dpright:b13,leftx:a0,lefty:a1,rightx:a2,righty:a3,triggerleft:a4,triggerright:a5,'
  end
  function joy:getGamepadAxis(name) return self.axes[name] or 0 end
  function joy:isGamepadDown(...)
    for i=1,select('#',...) do if self.buttons[select(i,...)] then return true end end
    return false
  end
  function joy:isVibrationSupported() return type(native.rumble) == 'function' end
  function joy:getVibration() return vibration_left, vibration_right end
  function joy:setVibration(left, right, duration)
    left = clamp(tonumber(left) or 0, 0, 1)
    right = clamp(tonumber(right) or left, 0, 1)
    if not self.connected or not self:isVibrationSupported() then return false end
    local ok = native.rumble(0, math.floor(left*255+0.5), math.floor(right*255+0.5))
    if ok == false then return false end
    vibration_left, vibration_right = left, right
    rumble_until = duration and (native.time() + math.max(0, duration)) or nil
    return true
  end
  function joy:type() return 'Joystick' end
  function joy:typeOf(name) return name == 'Joystick' or name == 'Object' end
  love.joystick = {
    getJoysticks=function() return joy.connected and {joy} or {} end,
    getJoystickCount=function() return joy.connected and 1 or 0 end,
    loadGamepadMappings=function() return 0 end, -- fixed mapping, no SDL in libXenon
  }
  function api:update()
    local pad = native.pad(0)
    if not pad then
      if joy.connected then
        joy:setVibration()
        joy.connected = false
        local oldbuttons, oldaxes = joy.buttons, joy.axes
        joy.buttons, joy.axes = {}, {}
        for _, b in ipairs(buttons) do
          if oldbuttons[b[1]] then emit('gamepadreleased', b[1]) end
        end
        for i, name in ipairs(axes) do
          if (oldaxes[name] or 0) ~= 0 then
            emit('joystickaxis', i, 0); emit('gamepadaxis', name, 0)
          end
        end
        emit('joystickremoved')
        blocked, blocked_axes, previous = {}, {}, {}
        rumble_until, vibration_left, vibration_right = nil, 0, 0
      end
      return
    end
    local values = {}
    values.leftx, values.lefty = pair(pad.s1_x, pad.s1_y, dz)
    values.rightx, values.righty = pair(pad.s2_x, pad.s2_y, dz)
    values.triggerleft = clamp(tonumber(pad.lt) or 0, 0, 255) / 255
    values.triggerright = clamp(tonumber(pad.rt) or 0, 0, 255) / 255
    if not joy.connected then
      joy.connected = true
      -- Connecting with A/Start/axes held must not confirm or move anything.
      for _, b in ipairs(buttons) do blocked[b[1]] = down(pad[b[2]]) end
      for _, name in ipairs(axes) do blocked_axes[name] = values[name] ~= 0 end
      emit('joystickadded')
    end
    local current = {}
    for _, b in ipairs(buttons) do
      local held = down(pad[b[2]])
      if not held then blocked[b[1]] = nil end
      current[b[1]] = held and not blocked[b[1]] or false
    end
    local oldbuttons, oldaxes = joy.buttons, joy.axes
    joy.buttons, joy.axes = {}, {}
    for _, name in ipairs(axes) do
      if values[name] == 0 then blocked_axes[name] = nil end
      joy.axes[name] = not blocked_axes[name] and values[name] or 0
    end
    joy.buttons = current
    -- Full snapshot visible to all callbacks; releases before presses.
    for _, b in ipairs(buttons) do
      if oldbuttons[b[1]] and not joy.buttons[b[1]] then emit('gamepadreleased', b[1]) end
    end
    for i, name in ipairs(axes) do
      if joy.axes[name] ~= (oldaxes[name] or 0) then
        emit('joystickaxis', i, joy.axes[name]); emit('gamepadaxis', name, joy.axes[name])
      end
    end
    for _, b in ipairs(buttons) do
      if joy.buttons[b[1]] and not oldbuttons[b[1]] then emit('gamepadpressed', b[1]) end
    end
    previous = current
    if rumble_until and native.time() >= rumble_until then joy:setVibration() end
  end
  return api
end
return M
