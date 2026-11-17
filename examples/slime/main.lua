-- examples/slime: a soft-body slime (engine/modules/softbody) drawn each frame into a pixel
-- grid (engine/pixelgrid) on a small room (platformer.grid). Move, jump, and hold down to
-- squash. See README.md.
--
-- The base (engine/ and lib/) is found in this folder (a copy), in base/ (a submodule), or,
-- for this example, two folders up: the repository it ships in.
if love.filesystem.setRequirePath then      -- official LÖVE on PC only
  love.filesystem.setRequirePath("?.lua;?/init.lua;base/?.lua;base/?/init.lua")
  local source = love.filesystem.getSource()
  package.path = source .. "/../../?.lua;" .. source .. "/../../?/init.lua;" .. package.path
end
local engine = require("engine")

engine.run({
  rate = 60,
  pixel = { width = 320, height = 180, background = { 0.07, 0.08, 0.12 } },
  input = {
    deadzone = 0.25,
    actions = {
      left = { keys = { "left", "a" }, buttons = { "dpleft" } },
      right = { keys = { "right", "d" }, buttons = { "dpright" } },
      down = { keys = { "down", "s" }, buttons = { "dpdown" } },
      jump = { keys = { "space", "up", "w" }, buttons = { "a" } },
      quit = { keys = { "escape" } },         -- on the console, hold Back for 3 s
    },
    axes = {
      move_x = { negative = "left", positive = "right", stick = "leftx" },
    },
  },
  states = { play = require("slime_play") },
  start = "play",
})
