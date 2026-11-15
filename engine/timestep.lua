-- engine.timestep: fixed-rate logic steps driven by a variable frame time.
-- Each frame: steps, alpha = ts:advance(dt); run `steps` logic updates of ts.dt seconds each and
-- draw with `alpha` (0..1, how far the frame is between the last two steps). See docs/ENGINE.md.
local floor = math.floor

local M = {}
local Timestep = {}
Timestep.__index = Timestep

-- opts: rate (Hz, default 60), max_steps (per frame, default 5), max_frame (largest frame time
-- taken, seconds, default 0.25)
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Timestep)
  self.max_steps = opts.max_steps or 5
  self.max_frame = opts.max_frame or 0.25
  self.acc = 0          -- time not yet simulated
  self.alpha = 0        -- acc / dt after the last advance
  self.tick = 0         -- steps run since the start
  self.time = 0         -- simulated seconds (tick * dt)
  self.dropped = 0      -- seconds thrown away by the max_steps guard
  self:setRate(opts.rate or 60)
  return self
end

function Timestep:setRate(hz)
  assert(type(hz) == "number" and hz > 0, "timestep rate must be a positive number")
  self.rate = hz
  self.dt = 1 / hz
end

-- Adds a frame's time. Returns how many fixed steps to run now and the interpolation alpha.
function Timestep:advance(frame_dt)
  if frame_dt < 0 then frame_dt = 0 end
  if frame_dt > self.max_frame then frame_dt = self.max_frame end
  local dt = self.dt
  local acc = self.acc + frame_dt
  local n = floor(acc / dt + 1e-9)
  if n > self.max_steps then
    -- too slow to keep up: run max_steps and drop the rest instead of spiralling
    self.dropped = self.dropped + (acc - self.max_steps * dt)
    n, acc = self.max_steps, 0
  else
    acc = acc - n * dt
    if acc < 0 then acc = 0 end
  end
  self.acc = acc
  self.alpha = acc / dt
  self.tick = self.tick + n
  self.time = self.tick * dt
  return n, self.alpha
end

function Timestep:reset()
  self.acc, self.alpha = 0, 0
end

return M
