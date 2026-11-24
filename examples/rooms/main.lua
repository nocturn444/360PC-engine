-- examples/rooms: a generated map (procgen) walked room by room (rooms) by the soft-body slime,
-- with the camera inside each room, a short fade at each door, a key that opens the locked
-- doors and a minimap. See README.md.
--
-- The base (engine/ and lib/) is found in this folder (a copy), in base/ (a submodule), or,
-- for this example, two folders up: the repository it ships in.
if love.filesystem.setRequirePath then      -- official LÖVE on PC only
  love.filesystem.setRequirePath("?.lua;?/init.lua;base/?.lua;base/?/init.lua")
  local source = love.filesystem.getSource()
  package.path = source .. "/../../?.lua;" .. source .. "/../../?/init.lua;" .. package.path
end
local engine = require("engine")
-- The permanent profile (discoveries, record, options), loaded once at startup.
require("rooms_profile").open()

engine.run({
  rate = 60,
  pixel = { width = 320, height = 180, background = { 0.07, 0.08, 0.12 } },
  input = {
    deadzone = 0.25,
    actions = {
      left = { keys = { "left", "a" }, buttons = { "dpleft" } },
      right = { keys = { "right", "d" }, buttons = { "dpright" } },
      up = { keys = { "up", "w" }, buttons = { "dpup" }, axes = { "lefty-" } },
      down = { keys = { "down", "s" }, buttons = { "dpdown" } },
      jump = { keys = { "space", "up", "w" }, buttons = { "a" } },
      attack = { keys = { "x", "j" }, buttons = { "x" } },
      switch = { keys = { "c", "k", "tab" }, buttons = { "y" } },
      interact = { keys = { "e", "f" }, buttons = { "b" } },
      pause = { keys = { "escape", "p" }, buttons = { "start" } },  -- on the console, hold Back 3 s to quit
    },
    axes = {
      move_x = { negative = "left", positive = "right", stick = "leftx" },
    },
  },
  states = {
    title = require("rooms_title"),
    play = require("rooms_play"),
    pause = require("rooms_pause"),
    gameover = require("rooms_gameover"),
    cutscene = require("rooms_cutscene"),
  },
  start = "title",
  autopause = { state = "pause" },
})
