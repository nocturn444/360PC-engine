-- examples/perf_platformer: the performance test of 360PC-Engine (objective 18). A generated
-- level drawn with SpriteBatches, a player and N enemies with collisions (platformer module on
-- bump) and combat (combat module: hitboxes, a patrol / chase / attack state machine), a
-- ParticleSystem, and an overlay with the frame's timings. See README.md.
--
-- The base (engine/ and lib/) is found in this folder (a copy), in base/ (a submodule), or,
-- for this example, two folders up: the repository it ships in. On the console the packaging
-- puts engine/ and lib/ next to this file.
if love.filesystem.setRequirePath then      -- official LÖVE on PC only
  love.filesystem.setRequirePath("?.lua;?/init.lua;base/?.lua;base/?/init.lua")
  local source = love.filesystem.getSource()
  package.path = source .. "/../../?.lua;" .. source .. "/../../?/init.lua;" .. package.path
end
local engine = require("engine")
local settings = require("perf_settings")
local meter = require("perf.meter")
local play = require("perf.play")

engine.run({
  rate = 60,
  pixel = { width = 320, height = 180, background = { 0.05, 0.06, 0.10 } },
  input = {
    deadzone = 0.25,
    actions = {
      left = { keys = { "left", "a" }, buttons = { "dpleft" } },
      right = { keys = { "right", "d" }, buttons = { "dpright" } },
      down = { keys = { "down", "s" }, buttons = { "dpdown" }, axes = { { axis = "lefty", dir = 1, threshold = 0.6 } } },
      jump = { keys = { "space", "up", "w" }, buttons = { "a" } },
      attack = { keys = { "x", "j" }, buttons = { "x" } },
      enemies = { keys = { "e" }, buttons = { "rightshoulder" } },
      particles = { keys = { "p" }, buttons = { "leftshoulder" } },
      benchmark = { keys = { "b" }, buttons = { "start" } },
      overlay = { keys = { "o" }, buttons = { "y" } },
      quit = { keys = { "escape" } },         -- on the console, hold Back for 3 s
    },
    axes = { move_x = { negative = "left", positive = "right", stick = "leftx" } },
  },
  states = { play = play },
  start = "play",
  load = function() play:load(settings) end,
})

-- The timings wrap the whole of the engine's update and draw: every fixed step the frame ran,
-- and everything drawn (the pixel canvas or the bars included).
local now = love.timer.getTime
local engine_update, engine_draw = love.update, love.draw

-- The target frame rate is the same on PC and console (settings.target_fps, 30). The console's
-- runtime paces its loop itself (there love.timer.sleep returns at once, so this does nothing);
-- on PC the frame waits here, before the timings start, so they measure only the work.
local frame_period = (settings.target_fps or 0) > 0 and 1 / settings.target_fps or nil
local next_frame
local function pace()
  if not frame_period or not love.timer.sleep then return end
  local t = now()
  if next_frame and next_frame > t then
    love.timer.sleep(next_frame - t)
    t = now()
  end
  if not next_frame or t - next_frame > frame_period then next_frame = t end   -- fell behind: restart
  next_frame = next_frame + frame_period
end

function love.update(dt)
  pace()
  local t0 = now()
  engine_update(dt)
  meter:updated(dt, t0, now())
end
function love.draw()
  local t0 = now()
  local calls = love.graphics.getStats().drawcalls
  engine_draw()
  calls = love.graphics.getStats().drawcalls - calls
  play:frame(meter:drawn(t0, now(), calls))
end
