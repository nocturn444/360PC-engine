local T = ...
local Timestep = require("engine.timestep")

local ts = Timestep.new()
T.check(ts.rate == 60 and ts.max_steps == 5, "defaults: 60 Hz, 5 steps")
T.near(ts.dt, 1 / 60, "dt is 1 / rate")

-- 60 Hz logic on a 60 FPS screen: one step a frame; on the console's 30 FPS: two
local total = 0
for _ = 1, 600 do
  local n = ts:advance(1 / 60)
  if n ~= 1 then error("FAILED: 60 FPS frame ran " .. n .. " steps") end
  total = total + n
end
T.check(total == 600 and ts.tick == 600, "600 frames at 60 FPS are 600 steps")
ts = Timestep.new({ rate = 60 })
for _ = 1, 300 do
  local n = ts:advance(1 / 30)
  if n ~= 2 then error("FAILED: 30 FPS frame ran " .. n .. " steps") end
end
T.check(ts.tick == 600, "300 frames at 30 FPS are 600 steps")
T.near(ts.time, 10, "simulated time")

-- the same frame times give the same steps, frame by frame (two runs of an uneven sequence)
local function run(rate)
  local t = Timestep.new({ rate = rate })
  local seed, out = 7, {}
  for i = 1, 500 do
    seed = (seed * 16807) % 2147483647
    local n, alpha = t:advance(0.004 + (seed % 1000) / 1000 * 0.03)
    out[i] = n .. ":" .. string.format("%.9f", alpha)
    if alpha < 0 or alpha >= 1 then error("FAILED: alpha out of range " .. alpha) end
  end
  return table.concat(out, " "), t.tick
end
local a, ticks_a = run(60)
local b, ticks_b = run(60)
T.check(a == b and ticks_a == ticks_b, "same frame times, same steps and alphas")
local _, ticks_120 = run(120)
T.check(math.abs(ticks_120 - 2 * ticks_a) <= 2, "the rate is configurable: 120 Hz runs twice the steps")

-- alpha
ts = Timestep.new({ rate = 50 })
local n, alpha = ts:advance(0.03)
T.check(n == 1, "0.03 s at 50 Hz is one step")
T.near(alpha, 0.5, "and half a step left over")

-- the guard: a very long frame runs max_steps and drops the rest
ts = Timestep.new({ rate = 60, max_steps = 4 })
n, alpha = ts:advance(10)
T.check(n == 4 and alpha == 0 and ts.dropped > 0, "a 10 s frame runs max_steps steps")
T.check(ts:advance(1 / 60) == 1, "and the next frame is normal again")
T.check(ts:advance(-1) == 0, "a negative frame time is taken as 0")
ts:setRate(30)
T.near(ts.dt, 1 / 30, "setRate")
T.check(not pcall(ts.setRate, ts, 0), "a rate of 0 is an error")
