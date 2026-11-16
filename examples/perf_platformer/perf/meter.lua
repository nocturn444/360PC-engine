-- Frame timings: what main.lua measures around the engine's update and draw, smoothed for the
-- overlay. Times come from love.timer.getTime; the draw calls from love.graphics.getStats,
-- read before and after the draw (on the console the counter is never reset, on LÖVE it is
-- reset at each present: the difference is right on both).
local meter = {
  fps = 0, frame_ms = 0, update_ms = 0, draw_ms = 0, draw_calls = 0,   -- smoothed
  worst_ms = 0,                 -- the longest frame since the overlay last asked
  frames = 0,
  last = { frame = 0, update = 0, draw = 0, calls = 0 },               -- the last frame, raw (seconds)
}

local SMOOTH = 0.1              -- weight of a new frame in the smoothed values
local last_start

local function blend(old, new, first)
  if first then return new end
  return old + (new - old) * SMOOTH
end

-- dt: what love.update was given; t0, t1: the clock before and after the update
function meter:updated(dt, t0, t1)
  local last = self.last
  -- The frame's length is the clock's, from one update to the next; dt (capped by the
  -- runtime, 0.1 s on the console) only when the clock did not move
  local frame = last_start and (t0 - last_start) or dt
  if frame <= 0 then frame = dt end
  last_start = t0
  last.frame, last.update = frame, t1 - t0
end

-- Returns the raw frame: seconds for the frame, the update and the draw, and the draw calls
function meter:drawn(t0, t1, calls)
  local last = self.last
  last.draw, last.calls = t1 - t0, calls
  local first = self.frames == 0
  self.frames = self.frames + 1
  self.frame_ms = blend(self.frame_ms, last.frame * 1000, first)
  self.update_ms = blend(self.update_ms, last.update * 1000, first)
  self.draw_ms = blend(self.draw_ms, last.draw * 1000, first)
  self.draw_calls = blend(self.draw_calls, calls, first)
  self.fps = self.frame_ms > 0 and 1000 / self.frame_ms or 0
  if last.frame * 1000 > self.worst_ms then self.worst_ms = last.frame * 1000 end
  return last.frame, last.update, last.draw, calls
end

-- The longest frame since the last call, in ms
function meter:take_worst()
  local w = self.worst_ms
  self.worst_ms = 0
  return w
end

return meter
