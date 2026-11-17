-- rooms.transition: a short screen transition in two halves. The first half covers the screen
-- (fade to a colour, or slide the old room out); in the middle a callback swaps the room; the
-- second half uncovers it. Only numbers: the game draws with them.
--
--   local fade = rooms.transition.new({ kind = "fade", time = 0.3 })
--   fade:start(function() swap_room() end)          -- runs once, at the middle
--   fade:update(dt)                                  -- in the fixed step
--   -- draw: the room, then a rectangle over the screen with alpha fade:cover(alpha)
--   -- slide: draw the room shifted by fade:offset(alpha, w, h) (dir from start)
local min, floor, abs = math.min, math.floor, math.abs

local M = {}
local T = {}
T.__index = T

local DX = { left = -1, right = 1, up = 0, down = 0 }
local DY = { left = 0, right = 0, up = -1, down = 1 }
M.dx, M.dy = DX, DY

-- transition.new(opts): opts.kind "fade" (default) or "slide", opts.time (whole transition,
-- seconds, default 0.3)
function M.new(opts)
  opts = opts or {}
  local kind = opts.kind or "fade"
  assert(kind == "fade" or kind == "slide", "rooms.transition: kind is fade or slide")
  local time = opts.time or 0.3
  assert(type(time) == "number" and time > 0, "rooms.transition: time > 0")
  return setmetatable({ kind = kind, time = time, t = 0, prev_t = 0, active = false, swapped = true,
    dir = "right", on_swap = nil }, T)
end

-- Starts a transition; dir ("left", "right", "up", "down": where the player goes) is what a
-- slide follows. on_swap runs once, when the screen is covered. Ignored while one is running.
function T:start(on_swap, dir)
  if self.active then return false end
  self.active, self.swapped, self.t, self.prev_t = true, false, 0, 0
  self.on_swap, self.dir = on_swap, dir or "right"
  return true
end

function T:busy() return self.active end

function T:update(dt)
  self.prev_t = self.t
  if not self.active then return end
  self.t = min(self.time, self.t + dt)
  if not self.swapped and self.t >= self.time / 2 - 1e-9 then
    self.swapped = true
    local f = self.on_swap
    self.on_swap = nil
    if f then f() end
  end
  if self.t >= self.time - 1e-9 then self.active = false end
end

-- Progress 0..1 between the last two steps
function T:progress(alpha)
  if not self.active and self.t == self.prev_t then return 0 end
  local t = self.prev_t + (self.t - self.prev_t) * (alpha or 1)
  return t / self.time
end

-- How covered the screen is, 0..1: up to 1 at the middle, back to 0 at the end
function T:cover(alpha)
  local p = self:progress(alpha)
  if p <= 0 or p >= 1 then return 0 end
  return 1 - abs(2 * p - 1)
end

-- The room's draw offset for a slide, in whole pixels: the old room leaves towards -dir in the
-- first half, the new one comes in from dir in the second.
function T:offset(alpha, w, h)
  local p = self:progress(alpha)
  if p <= 0 or p >= 1 then return 0, 0 end
  local dx, dy = DX[self.dir] or 0, DY[self.dir] or 0
  local s
  if p < 0.5 then s = -2 * p else s = 2 - 2 * p end      -- old room: 0 .. -1; new room: 1 .. 0
  return floor(dx * s * w + 0.5), floor(dy * s * h + 0.5)
end

return M
