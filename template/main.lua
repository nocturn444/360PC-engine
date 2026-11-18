-- New game on 360PC-Engine. The base (engine/ and lib/) is found either in this folder (a
-- pinned copy) or in base/ (the 360PC-Engine repository as a git submodule). On the console
-- the packaging puts engine/ and lib/ next to this file, so the same require works there.
-- Run from inside the 360PC-Engine repository (template/), the base one folder up is used too.
if love.filesystem.setRequirePath then      -- official LÖVE on PC only
  love.filesystem.setRequirePath("?.lua;?/init.lua;base/?.lua;base/?/init.lua")
  local source = love.filesystem.getSource()
  package.path = source .. "/../?.lua;" .. source .. "/../?/init.lua;" .. package.path
end
local engine = require("engine")

engine.run({
  rate = 60,                                  -- fixed logic steps per second
  pixel = { width = 320, height = 180 },      -- game resolution, scaled by a whole number
  input = {
    deadzone = 0.25,
    actions = {
      left = { keys = { "left", "a" }, buttons = { "dpleft" } },
      right = { keys = { "right", "d" }, buttons = { "dpright" } },
      up = { keys = { "up", "w" }, buttons = { "dpup" } },
      down = { keys = { "down", "s" }, buttons = { "dpdown" } },
      action = { keys = { "space", "return" }, buttons = { "a" } },
      quit = { keys = { "escape" } },         -- on the console, hold Back for 3 s
    },
    axes = {
      move_x = { negative = "left", positive = "right", stick = "leftx" },
      move_y = { negative = "up", positive = "down", stick = "lefty" },
    },
  },
  states = { play = require("states.play") },
  start = "play",
})
