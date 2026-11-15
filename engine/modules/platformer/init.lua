-- engine.modules.platformer: tile collisions with bump.lua (lib/bump), one-way platforms and a
-- character controller. A genre module: nothing in engine/ requires it, and it knows nothing
-- about a game or a level file format. Reference: engine/modules/platformer/README.md.
--
--   local platformer = require("engine.modules.platformer")
--   local grid = platformer.grid.new({ "....", ".==.", "####" }, { tile_size = 16 })
--   local world = platformer.collision.newWorld(grid)
--   local body = platformer.controller.new(world, { x = 8, y = 0, w = 10, h = 14 })
--   body:step(engine.controls, dt)                 -- once per fixed step
local prefix = (...):gsub("%.init$", "") .. "."

return {
  grid = require(prefix .. "grid"),
  collision = require(prefix .. "collision"),
  params = require(prefix .. "params"),
  controller = require(prefix .. "controller"),
}
