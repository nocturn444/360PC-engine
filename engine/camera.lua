-- engine.camera: a 2D camera. x, y is the world point at the centre of the view; width, height
-- is the view in screen (game) pixels. See docs/ENGINE.md.
local floor, exp = math.floor, math.exp

local M = {}
local Camera = {}
Camera.__index = Camera

-- opts: width, height (required), x, y, zoom (1), lerp (0 = follow at once; otherwise the speed,
-- per second, at which the distance to the target shrinks), deadzone_w, deadzone_h (the target
-- moves freely inside this box at the centre), bounds = { x, y, w, h }, snap (whole pixels), seed
function M.new(opts)
  assert(opts and opts.width and opts.height, "camera needs width and height")
  local self = setmetatable({}, Camera)
  self.width, self.height = opts.width, opts.height
  self.x, self.y = opts.x or opts.width / 2, opts.y or opts.height / 2
  self.px, self.py = self.x, self.y            -- position at the previous step (for interpolation)
  self.tx, self.ty = self.x, self.y            -- target
  self.zoom = opts.zoom or 1
  self.lerp = opts.lerp or 0
  self.deadzone_w, self.deadzone_h = opts.deadzone_w or 0, opts.deadzone_h or 0
  self.snap = opts.snap and true or false
  self.bounded = false
  self.bx, self.by, self.bw, self.bh = 0, 0, 0, 0
  self.fade = 0                                -- 0..1 during a "fade" transition: draw it with drawFade
  self.mode = nil                              -- "slide" or "fade" while a transition runs
  self.t, self.duration = 0, 0
  self.fx, self.fy = 0, 0                      -- slide: where it started
  self.nx, self.ny, self.nw, self.nh = 0, 0, 0, 0   -- fade: the bounds to switch to
  self.cut = false
  self.on_done = nil
  self.shake_x, self.shake_y = 0, 0
  self.shake_amp, self.shake_t, self.shake_dur = 0, 0, 0
  self.seed = opts.seed or 12345
  if opts.bounds then
    local b = opts.bounds
    self:setBounds(b.x or b[1], b.y or b[2], b.w or b[3], b.h or b[4])
  end
  return self
end

-- The position nearest to x, y that keeps the view inside the bounds (centred on an axis where
-- the bounds are smaller than the view).
function Camera:clamp(x, y)
  if not self.bounded then return x, y end
  local hw, hh = self.width / (2 * self.zoom), self.height / (2 * self.zoom)
  if self.bw <= hw * 2 then x = self.bx + self.bw / 2
  elseif x < self.bx + hw then x = self.bx + hw
  elseif x > self.bx + self.bw - hw then x = self.bx + self.bw - hw end
  if self.bh <= hh * 2 then y = self.by + self.bh / 2
  elseif y < self.by + hh then y = self.by + hh
  elseif y > self.by + self.bh - hh then y = self.by + self.bh - hh end
  return x, y
end

function Camera:setBounds(x, y, w, h)
  self.bounded = true
  self.bx, self.by, self.bw, self.bh = x, y, w, h
  if not self.mode then self.x, self.y = self:clamp(self.x, self.y) end
end

function Camera:clearBounds() self.bounded = false end

-- The point to follow. Call it every step with the target's position.
function Camera:follow(x, y) self.tx, self.ty = x, y end

-- Jumps there (clamped), with no smoothing and no interpolation from the old position.
function Camera:setPosition(x, y)
  self.x, self.y = self:clamp(x, y)
  self.px, self.py = self.x, self.y
  self.tx, self.ty = x, y
end

-- Changes room: new bounds, reached with mode "instant", "slide" (the view travels to its place
-- in the new room) or "fade" (camera.fade goes 0 -> 1, the view jumps, 1 -> 0).
-- opts: mode ("slide"), duration (0.4 s), on_done (function(camera)).
function Camera:transition(x, y, w, h, opts)
  opts = opts or {}
  local mode = opts.mode or "slide"
  local duration = opts.duration or 0.4
  self.on_done = opts.on_done
  if mode == "instant" or duration <= 0 then
    self.mode = nil
    self.fade = 0
    self:setBounds(x, y, w, h)
    self:setPosition(self.tx, self.ty)
    local done = self.on_done
    self.on_done = nil
    if done then done(self) end
    return
  end
  assert(mode == "slide" or mode == "fade", "camera transition mode must be instant, slide or fade")
  self.mode, self.t, self.duration = mode, 0, duration
  if mode == "slide" then
    self.fx, self.fy = self.x, self.y
    self.bounded = true
    self.bx, self.by, self.bw, self.bh = x, y, w, h
  else
    self.nx, self.ny, self.nw, self.nh = x, y, w, h
    self.cut = false
  end
end

function Camera:isTransitioning() return self.mode ~= nil end

-- Shakes the view by up to `amplitude` pixels, fading out over `duration` seconds.
function Camera:shake(amplitude, duration)
  self.shake_amp, self.shake_dur, self.shake_t = amplitude, duration or 0.3, duration or 0.3
end

local function rand(self)   -- -1..1, the camera's own generator (the same shake on PC and console)
  self.seed = (self.seed * 16807) % 2147483647
  return self.seed / 1073741823.5 - 1
end

-- One fixed step.
function Camera:update(dt)
  self.px, self.py = self.x, self.y
  local mode = self.mode
  if mode then
    self.t = self.t + dt
    local p = self.t / self.duration
    if p > 1 then p = 1 end
    if mode == "slide" then
      local ex, ey = self:clamp(self.tx, self.ty)
      local e = p * p * (3 - 2 * p)
      self.x, self.y = self.fx + (ex - self.fx) * e, self.fy + (ey - self.fy) * e
    else
      if self.cut then
        self.x, self.y = self:clamp(self.tx, self.ty)
      elseif p >= 0.5 then
        -- the cut: until here the view stays in the old room
        self.cut = true
        self.bounded = true
        self.bx, self.by, self.bw, self.bh = self.nx, self.ny, self.nw, self.nh
        self.x, self.y = self:clamp(self.tx, self.ty)
        self.px, self.py = self.x, self.y
      end
      self.fade = p < 0.5 and p * 2 or (1 - p) * 2
    end
    if p >= 1 then
      self.mode, self.fade = nil, 0
      local done = self.on_done
      self.on_done = nil
      if done then done(self) end
    end
  else
    local x, y = self.x, self.y
    local gx, gy = x, y
    local hw, hh = self.deadzone_w / 2, self.deadzone_h / 2
    if self.tx - x > hw then gx = self.tx - hw elseif self.tx - x < -hw then gx = self.tx + hw end
    if self.ty - y > hh then gy = self.ty - hh elseif self.ty - y < -hh then gy = self.ty + hh end
    local k = self.lerp > 0 and (1 - exp(-self.lerp * dt)) or 1
    self.x, self.y = self:clamp(x + (gx - x) * k, y + (gy - y) * k)
  end

  if self.shake_t > 0 then
    self.shake_t = self.shake_t - dt
    if self.shake_t <= 0 then
      self.shake_t, self.shake_x, self.shake_y = 0, 0, 0
    else
      local m = self.shake_amp * self.shake_t / self.shake_dur
      self.shake_x, self.shake_y = rand(self) * m, rand(self) * m
    end
  end
end

-- The world position drawn at the centre for an interpolation alpha (nil = 1), without shake.
function Camera:getDrawPosition(alpha)
  if not alpha then return self.x, self.y end
  return self.px + (self.x - self.px) * alpha, self.py + (self.y - self.py) * alpha
end

-- The translation attach() applies, in screen pixels.
function Camera:getOffset(alpha)
  local x, y = self:getDrawPosition(alpha)
  local ox = self.width / 2 - x * self.zoom + self.shake_x
  local oy = self.height / 2 - y * self.zoom + self.shake_y
  if self.snap then ox, oy = floor(ox + 0.5), floor(oy + 0.5) end
  return ox, oy
end

-- Between attach and detach, drawing is in world coordinates.
function Camera:attach(alpha)
  local g = love.graphics
  local ox, oy = self:getOffset(alpha)
  g.push()
  g.translate(ox, oy)
  if self.zoom ~= 1 then g.scale(self.zoom, self.zoom) end
end

function Camera:detach() love.graphics.pop() end

function Camera:toWorld(sx, sy)
  return (sx - self.width / 2) / self.zoom + self.x, (sy - self.height / 2) / self.zoom + self.y
end

function Camera:toScreen(wx, wy)
  return (wx - self.x) * self.zoom + self.width / 2, (wy - self.y) * self.zoom + self.height / 2
end

-- The world rectangle in view: x, y, w, h (to skip what is off screen).
function Camera:getViewport(alpha)
  local x, y = self:getDrawPosition(alpha)
  local w, h = self.width / self.zoom, self.height / self.zoom
  return x - w / 2, y - h / 2, w, h
end

-- Covers the view with a colour at camera.fade's opacity (call it after detach). Nothing at 0.
function Camera:drawFade(r, g, b)
  if self.fade <= 0 then return end
  local gfx = love.graphics
  local cr, cg, cb, ca = gfx.getColor()
  gfx.setColor(r or 0, g or 0, b or 0, self.fade)
  gfx.rectangle("fill", 0, 0, self.width, self.height)
  gfx.setColor(cr, cg, cb, ca)
end

return M
