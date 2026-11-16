-- The hand-made rooms the level is built from: procgen templates (engine/modules/procgen) with
-- their tiles as rows of strings, the form platformer.grid takes. They stay in code because
-- the level file format (objective 11) is not decided yet.
--
-- A room is one map cell: 20 x 12 tiles of 16 pixels (320 x 192), a little more than a screen
-- (320 x 180). "#" is solid, "=" a one-way platform, "." empty. Every room is closed by a
-- border; level.lua opens it where the map put a door:
--   left / right   rows 9 to 11 of the first / last column (a doorway on the floor)
--   up             columns 9 to 12 of the first row
--   down           columns 9 to 12 of the last row become one-way platforms
-- so a room with an "up" exit has one-way platforms up the middle, two tiles apart, and a
-- room with a "down" exit a floor to stand on over the hole.
local M = { width = 20, height = 12, tile_size = 16 }

local LADDER = {                       -- the rows of a room with an "up" exit
  "####################",
  "#.......====.......#",
  "#..................#",
  "#.......====.......#",
  "#..................#",
  "#.......====.......#",
  "#..................#",
  "#.......====.......#",
  "#..................#",
  "#.......====.......#",
  "#..................#",
  "####################",
}

local function exits(...)
  local out = {}
  for i, side in ipairs({ ... }) do out[i] = { side = side } end
  return out
end

-- A new list each call: procgen.templates fills in defaults in place
function M.templates()
  return {
    { id = "start", type = "start", exits = exits("left", "right"), rows = {
      "####################",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#......======......#",
      "#..................#",
      "#..===........===..#",
      "#..................#",
      "#..................#",
      "#..................#",
      "####################",
    } },
    { id = "hall", weight = 3, exits = exits("left", "right"), rows = {
      "####################",
      "#..................#",
      "#..................#",
      "#..................#",
      "#....====..........#",
      "#..................#",
      "#..........====....#",
      "#..................#",
      "#...===............#",
      "#..................#",
      "#..................#",
      "####################",
    } },
    { id = "steps", weight = 2, exits = exits("left", "right"), rows = {
      "####################",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..............==..#",
      "#.........##.......#",
      "#.........##.......#",
      "#......#####.......#",
      "#......#####.......#",
      "#...########.......#",
      "####################",
    } },
    { id = "blocks", weight = 2, exits = exits("left", "right"), rows = {
      "####################",
      "#..................#",
      "#..................#",
      "#..................#",
      "#....==......==....#",
      "#..................#",
      "#.......====.......#",
      "#..................#",
      "#..................#",
      "#...##........##...#",
      "#...##........##...#",
      "####################",
    } },
    { id = "attic", weight = 2, exits = exits("left", "right", "down"), rows = {
      "####################",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..====....====....#",
      "#..................#",
      "#..................#",
      "#......##..##......#",
      "#..................#",
      "#..................#",
      "####################",
    } },
    { id = "cellar", weight = 2, exits = exits("left", "right", "up"), rows = LADDER },
    { id = "shaft", weight = 2, exits = exits("left", "right", "up", "down"), rows = LADDER },
    { id = "tower", exits = exits("up", "down"), rows = LADDER },
  }
end

return M
