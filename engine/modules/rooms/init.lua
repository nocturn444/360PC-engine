-- engine.modules.rooms: playing a procgen map one room at a time. Which room the player is in,
-- where a body arrives when it comes through a door, when it leaves through an exit and where
-- that leads, which doors its abilities open, what has been explored (for the minimap and the
-- run's save), and a short screen transition (fade or slide) to cover the change of room.
-- A genre module: nothing in engine/ requires it; it reads maps made by engine/modules/procgen
-- and knows nothing about a game. Drawing and loading the room are the game's.
-- Reference: engine/modules/rooms/README.md.
--
--   local rooms = require("engine.modules.rooms")
--   local nav = rooms.nav.new(map, { cell_w = 320, cell_h = 192, tile_size = 16 })
--   local x, y = nav:enter(map.start)                   -- the start room; build its world
--   -- each step, with the body's centre in room pixels:
--   local exit, door = nav:leaving(cx, cy)
--   if door and nav:can_pass(door, abilities) then
--     fade:start(function() local x, y = nav:go(door); load_room(nav.room, x, y) end)
--   end
local prefix = (...):gsub("%.init$", "") .. "."

return {
  nav = require(prefix .. "nav"),
  transition = require(prefix .. "transition"),
}
