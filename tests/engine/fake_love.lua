-- A tiny fake `love` for the engine tests: keyboard, mouse and gamepads whose state the test
-- sets, and a love.graphics that records the calls and tracks the transform (translate and
-- scale only) so tests can ask where something was drawn on the screen.
local F = {}

function F.install(opts)
  opts = opts or {}
  local love = {}
  local keys, buttons, pads = {}, {}, {}
  F.keys, F.mouse_buttons, F.pads = keys, buttons, pads
  F.mouse_x, F.mouse_y = 0, 0
  F.calls = {}
  F.screen_w, F.screen_h = opts.width or 1280, opts.height or 720
  F.os = opts.os or "Linux"

  love.keyboard = { isDown = function(k) return keys[k] == true end }
  love.mouse = {
    isDown = function(b) return buttons[b] == true end,
    getPosition = function() return F.mouse_x, F.mouse_y end,
  }
  love.joystick = { getJoysticks = function()
    local out = {}
    for i, p in ipairs(pads) do out[i] = p end
    return out
  end }
  love.system = { getOS = function() return F.os end }
  love.timer = { getTime = function() return 0 end, getDelta = function() return 1 / 60 end,
    getFPS = function() return 60 end }
  love.event = { quit = function() F.quit = true end }
  love.filesystem = { read = function() return nil end, write = function() return true end }

  -- graphics
  local g = {}
  local tx, ty, sx, sy = 0, 0, 1, 1
  local stack = {}
  local color = { 1, 1, 1, 1 }
  local canvas
  local function rec(name, ...)
    -- with the canvas, transform (where 0,0 lands, and the scale) and colour in force
    local c = { name, ... }
    c.canvas, c.tx, c.ty, c.sx, c.sy = canvas, tx, ty, sx, sy
    c.color = { color[1], color[2], color[3], color[4] }
    F.calls[#F.calls + 1] = c
  end
  function g.push(...) stack[#stack + 1] = { tx, ty, sx, sy }; rec("push", ...) end
  function g.pop()
    local t = assert(table.remove(stack), "pop without push")
    tx, ty, sx, sy = t[1], t[2], t[3], t[4]
    rec("pop")
  end
  function g.origin() tx, ty, sx, sy = 0, 0, 1, 1 end
  function g.translate(x, y) tx, ty = tx + x * sx, ty + y * sy end
  function g.scale(x, y) sx, sy = sx * x, sy * (y or x) end
  function g.setColor(r, gg, b, a) color[1], color[2], color[3], color[4] = r, gg, b, a or 1 end
  function g.getColor() return color[1], color[2], color[3], color[4] end
  function g.getDimensions() return F.screen_w, F.screen_h end
  function g.getWidth() return F.screen_w end
  function g.getHeight() return F.screen_h end
  function g.setDefaultFilter(...) rec("setDefaultFilter", ...) end
  function g.setBlendMode(...) rec("setBlendMode", ...) end
  function g.setCanvas(c) canvas = c; rec("setCanvas", c) end
  function g.clear(...) rec("clear", ...) end
  function g.rectangle(...) rec("rectangle", ...) end
  function g.print(...) rec("print", ...) end
  function g.draw(...) rec("draw", ...) end
  local function object(kind, w, h)
    return { kind = kind, w = w, h = h,
      getWidth = function(self) return self.w end, getHeight = function(self) return self.h end,
      getDimensions = function(self) return self.w, self.h end,
      setFilter = function(self, a, b) self.filter = a end }
  end
  function g.newCanvas(w, h) rec("newCanvas", w, h); return object("canvas", w or F.screen_w, h or F.screen_h) end
  function g.newImage(path) return object("image", opts.image_w or 32, opts.image_h or 16) end
  function g.newQuad(x, y, w, h, iw, ih)
    return { kind = "quad", x = x, y = y, w = w, h = h,
      getViewport = function(self) return self.x, self.y, self.w, self.h end }
  end
  love.graphics = g
  F.stack_depth = function() return #stack end
  F.reset_calls = function() F.calls = {} end
  -- the calls with that name, in order
  F.find = function(name)
    local out = {}
    for _, c in ipairs(F.calls) do if c[1] == name then out[#out + 1] = c end end
    return out
  end

  _G.love = love
  return love
end

-- A gamepad the test drives: pad.buttons[name] = true, pad.axes[name] = value
function F.add_pad()
  local pad = { buttons = {}, axes = {} }
  function pad:isGamepad() return true end
  function pad:isGamepadDown(b) return self.buttons[b] == true end
  function pad:getGamepadAxis(a) return self.axes[a] or 0 end
  F.pads[#F.pads + 1] = pad
  return pad
end

return F
