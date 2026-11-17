-- engine.modules.softbody: a soft body made of points on a ring, joined by springs and kept
-- inflated by a pressure term, that falls, rolls and squashes against a tile grid (Verlet
-- integration, a fixed number of relaxation passes per step). A genre module: nothing in
-- engine/ requires it, it needs no other module and it knows nothing about a game. Its outline
-- is a plain array of points, ready for engine.pixelgrid:polygon.
-- Reference: engine/modules/softbody/README.md.
--
--   local softbody = require("engine.modules.softbody")
--   local slime = softbody.new({ x = 80, y = 40, radius = 8, points = 16 })
--   function play:update(dt)
--     slime:push(input:axis("move_x") * 400, 0)          -- an acceleration for this step
--     if input:pressed("jump") and slime:on_ground() then slime:impulse(0, -220) end
--     slime:step(dt, grid)                               -- grid: platformer.grid or the same four fields
--   end
--   function play:draw(alpha)
--     slime:outline(points, ox, oy, 1, alpha)            -- grid coordinates for pixelgrid
--   end
--
-- Units are game pixels and seconds. Same inputs, same results on PC and on the console: plain
-- arithmetic, no randomness, no clock, nothing allocated per step.
local floor, sqrt, cos, sin, pi, huge = math.floor, math.sqrt, math.cos, math.sin, math.pi, math.huge

local M = {}
local Body = {}
Body.__index = Body

local EPS = 1e-4          -- how far outside a tile face a point is put back, so it reads as empty

local DEFAULTS = {
  radius = 8,             -- rest radius of the ring
  points = 16,            -- points on the ring (6 or more)
  stiffness = 0.9,        -- 0..1: how hard the springs between neighbours hold their length
  pressure = 0.8,         -- 0..1: how hard the body keeps its area
  inflate = 1,            -- target area, as a fraction of the rest area; the springs' length
                          -- follows (its square root), so the body shrinks or swells evenly
  damping = 0.998,        -- velocity kept per step
  gravity = 600,          -- pixels / s^2, down
  friction = 0.35,        -- 0..1: tangential velocity lost per step while touching a surface
  iterations = 6,         -- relaxation passes per step
  max_speed = 600,        -- pixels / s, per point (keeps a fast body from crossing a tile)
}
M.defaults = DEFAULTS

local function option(opts, k)
  local v = opts[k]
  if v == nil then return DEFAULTS[k] end
  assert(type(v) == "number", "softbody.new: " .. k .. " is a number")
  return v
end

-- softbody.new(opts): opts.x, opts.y (centre, default 0, 0) and any key of softbody.defaults
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Body)
  for k in next, DEFAULTS do self[k] = option(opts, k) end
  local n = self.points
  assert(n >= 6 and n == floor(n), "softbody.new: points is a whole number >= 6")
  assert(self.radius > 0, "softbody.new: radius > 0")
  self.n = n
  self.x, self.y, self.ox, self.oy, self.lx, self.ly = {}, {}, {}, {}, {}, {}
  self.mx, self.my = {}, {}        -- the springs' moves within a pass
  self.contact = {}        -- per point: false, "floor", "wall" or "ceiling" (last step)
  self.rest_length = 2 * self.radius * sin(pi / n)
  self.rest_area = 0.5 * n * self.radius * self.radius * sin(2 * pi / n)
  self.ax, self.ay, self.ivx, self.ivy = 0, 0, 0, 0
  self.floor_count, self.wall_count, self.ceiling_count = 0, 0, 0
  self.dt = 1 / 60
  local cx, cy = opts.x or 0, opts.y or 0
  for i = 1, n do
    local a = 2 * pi * (i - 1) / n          -- angle grows clockwise on screen (y down)
    local x, y = cx + self.radius * cos(a), cy + self.radius * sin(a)
    self.x[i], self.y[i], self.ox[i], self.oy[i], self.lx[i], self.ly[i] = x, y, x, y, x, y
    self.contact[i] = false
  end
  return self
end

-- The area inside the ring (positive while the ring is not turned inside out)
function Body:area()
  local x, y, n = self.x, self.y, self.n
  local a, px, py = 0, x[n], y[n]
  for i = 1, n do
    a = a + px * y[i] - x[i] * py
    px, py = x[i], y[i]
  end
  return 0.5 * a
end

-- The mean of the points
function Body:center()
  local x, y, n = self.x, self.y, self.n
  local sx, sy = 0, 0
  for i = 1, n do sx, sy = sx + x[i], sy + y[i] end
  return sx / n, sy / n
end

-- The mean velocity over the last step, pixels / s
function Body:velocity()
  local x, y, ox, oy, n = self.x, self.y, self.ox, self.oy, self.n
  local sx, sy = 0, 0
  for i = 1, n do sx, sy = sx + x[i] - ox[i], sy + y[i] - oy[i] end
  return sx / n / self.dt, sy / n / self.dt
end

-- The box around the points: x0, y0, x1, y1
function Body:bounds()
  local x, y = self.x, self.y
  local x0, y0, x1, y1 = x[1], y[1], x[1], y[1]
  for i = 2, self.n do
    if x[i] < x0 then x0 = x[i] elseif x[i] > x1 then x1 = x[i] end
    if y[i] < y0 then y0 = y[i] elseif y[i] > y1 then y1 = y[i] end
  end
  return x0, y0, x1, y1
end

function Body:on_ground() return self.floor_count > 0 end
function Body:on_wall() return self.wall_count > 0 end
function Body:on_ceiling() return self.ceiling_count > 0 end

-- An acceleration (pixels / s^2) added to gravity for the next step only
function Body:push(ax, ay)
  self.ax, self.ay = self.ax + ax, self.ay + (ay or 0)
end

-- A change of velocity (pixels / s) given to every point at the next step
function Body:impulse(vx, vy)
  self.ivx, self.ivy = self.ivx + vx, self.ivy + (vy or 0)
end

-- Moves the body without giving it any velocity
function Body:move_to(cx, cy)
  local mx, my = self:center()
  local dx, dy = cx - mx, cy - my
  for i = 1, self.n do
    self.x[i], self.y[i] = self.x[i] + dx, self.y[i] + dy
    self.ox[i], self.oy[i] = self.ox[i] + dx, self.oy[i] + dy
    self.lx[i], self.ly[i] = self.lx[i] + dx, self.ly[i] + dy
  end
end

-- Springs between neighbours, all from the same positions (a pass in a fixed order around
-- the ring would turn the body: a resting body would slowly roll)
local function springs(self)
  local x, y, n, k = self.x, self.y, self.n, self.stiffness * 0.5
  local rest = self.rest_length * sqrt(self.inflate)
  local mx, my = self.mx, self.my
  for i = 1, n do mx[i], my[i] = 0, 0 end
  for i = 1, n do
    local j = i == n and 1 or i + 1
    local dx, dy = x[j] - x[i], y[j] - y[i]
    local d = sqrt(dx * dx + dy * dy)
    if d > 1e-9 then
      local f = (d - rest) / d * k
      dx, dy = dx * f, dy * f
      mx[i], my[i] = mx[i] + dx, my[i] + dy
      mx[j], my[j] = mx[j] - dx, my[j] - dy
    end
  end
  for i = 1, n do x[i], y[i] = x[i] + mx[i], y[i] + my[i] end
end

-- Pressure: moves every point along the gradient of the area, by just enough to bring the
-- area `pressure` of the way to its target (the smallest move that does it)
local function inflate(self)
  local x, y, n = self.x, self.y, self.n
  local missing = (self.rest_area * self.inflate - self:area()) * self.pressure
  local sum = 0
  for i = 1, n do
    local p, q = i == 1 and n or i - 1, i == n and 1 or i + 1
    local gx, gy = y[q] - y[p], x[p] - x[q]
    sum = sum + gx * gx + gy * gy
  end
  if sum < 1e-12 then return end
  local s = 2 * missing / sum              -- d(area)/d(point) is half of (gx, gy)
  -- every gradient from the positions before this pass: the previous point's old position is
  -- kept in px, py, and the first point's in fx, fy for the last one
  local fx, fy = x[1], y[1]
  local px, py = x[n], y[n]
  for i = 1, n do
    local cx, cy = x[i], y[i]
    local qx, qy
    if i == n then qx, qy = fx, fy else qx, qy = x[i + 1], y[i + 1] end
    x[i], y[i] = cx + (qy - py) * s, cy + (px - qx) * s
    px, py = cx, cy
  end
end

-- A face is open when the tile past it is not solid and is inside the grid: the edge of the
-- grid counts as a wall, so nothing is pushed out of the level
local function open(grid, tx, ty)
  if tx < 1 or ty < 1 or tx > grid.width or ty > grid.height then return false end
  return grid:kind(tx, ty) ~= "solid"
end

-- Pushes point i out of the grid; records the side it touched
local function collide(self, i, grid, gx, gy)
  local ts = grid.tile_size
  local x, y = self.x[i], self.y[i]
  local tx, ty = floor((x - gx) / ts) + 1, floor((y - gy) / ts) + 1
  local kind = grid:kind(tx, ty)
  if kind == nil then return end
  local left, top = gx + (tx - 1) * ts, gy + (ty - 1) * ts
  if kind == "one_way" then
    -- only from above: the point was over the top face at the start of the step
    if self.ly[i] <= top + EPS and y > top then
      self.y[i] = top - EPS
      self.contact[i] = "floor"
    end
    return
  end
  if kind ~= "solid" then return end
  -- the face it came through, when the start of the step was outside that face; otherwise
  -- (it started inside, or that face is closed) the nearest open face
  local px, py, side = self.lx[i], self.ly[i], nil
  if py <= top and open(grid, tx, ty - 1) then side = "top"
  elseif py >= top + ts and open(grid, tx, ty + 1) then side = "bottom"
  elseif px <= left and open(grid, tx - 1, ty) then side = "left"
  elseif px >= left + ts and open(grid, tx + 1, ty) then side = "right"
  else
    local best = huge
    local d = y - top
    if d < best and open(grid, tx, ty - 1) then best, side = d, "top" end
    d = top + ts - y
    if d < best and open(grid, tx, ty + 1) then best, side = d, "bottom" end
    d = x - left
    if d < best and open(grid, tx - 1, ty) then best, side = d, "left" end
    d = left + ts - x
    if d < best and open(grid, tx + 1, ty) then side = "right" end
  end
  if side == "top" then self.y[i] = top - EPS; self.contact[i] = "floor"
  elseif side == "bottom" then self.y[i] = top + ts; self.contact[i] = "ceiling"
  elseif side == "left" then self.x[i] = left - EPS; self.contact[i] = "wall"
  elseif side == "right" then self.x[i] = left + ts; self.contact[i] = "wall"
  else                                    -- buried: back to where it started the step
    self.x[i], self.y[i] = self.lx[i], self.ly[i]
  end
end

-- One fixed step. grid (optional): an object with tile_size and kind(tx, ty) ("solid",
-- "one_way" or nil), such as platformer.grid; gx, gy: where its tile (1, 1) starts (default 0).
function Body:step(dt, grid, gx, gy)
  gx, gy = gx or 0, gy or 0
  self.dt = dt
  local x, y, ox, oy, lx, ly, contact = self.x, self.y, self.ox, self.oy, self.lx, self.ly, self.contact
  local n, keep = self.n, self.damping
  local ax, ay = self.ax * dt * dt, (self.ay + self.gravity) * dt * dt
  local ix, iy = self.ivx * dt, self.ivy * dt
  local limit = self.max_speed * dt
  self.ax, self.ay, self.ivx, self.ivy = 0, 0, 0, 0
  for i = 1, n do
    local vx, vy = (x[i] - ox[i]) * keep + ix, (y[i] - oy[i]) * keep + iy
    local v2 = vx * vx + vy * vy
    if v2 > limit * limit then
      local f = limit / sqrt(v2)
      vx, vy = vx * f, vy * f
    end
    lx[i], ly[i] = x[i], y[i]
    ox[i], oy[i] = x[i], y[i]
    x[i], y[i] = x[i] + vx + ax, y[i] + vy + ay
    contact[i] = false
  end
  for _ = 1, self.iterations do
    springs(self)
    inflate(self)
    if grid then for i = 1, n do collide(self, i, grid, gx, gy) end end
  end
  -- contacts: no velocity into the surface, and friction along it
  local f = 1 - self.friction
  local floors, walls, ceilings = 0, 0, 0
  for i = 1, n do
    local c = contact[i]
    if c == "floor" or c == "ceiling" then
      oy[i] = y[i]
      ox[i] = x[i] - (x[i] - ox[i]) * f
      if c == "floor" then floors = floors + 1 else ceilings = ceilings + 1 end
    elseif c == "wall" then
      ox[i] = x[i]
      oy[i] = y[i] - (y[i] - oy[i]) * f
      walls = walls + 1
    end
  end
  self.floor_count, self.wall_count, self.ceiling_count = floors, walls, ceilings
end

-- The outline as { x1, y1, x2, y2, ... }: ((point - (ox, oy)) / scale), between the last two
-- steps by alpha (default 1). Writes into `out` (made if nil) and returns it.
function Body:outline(out, ox, oy, scale, alpha)
  out = out or {}
  ox, oy, scale, alpha = ox or 0, oy or 0, scale or 1, alpha or 1
  local x, y, lx, ly = self.x, self.y, self.lx, self.ly
  for i = 1, self.n do
    out[2 * i - 1] = (lx[i] + (x[i] - lx[i]) * alpha - ox) / scale
    out[2 * i] = (ly[i] + (y[i] - ly[i]) * alpha - oy) / scale
  end
  for i = 2 * self.n + 1, #out do out[i] = nil end
  return out
end

return M
