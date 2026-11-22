-- The hand-made rooms: procgen templates with their tiles as rows of strings (the form
-- platformer.grid takes). A map cell is 20 x 12 tiles of 16 pixels (320 x 192): a little more
-- than the screen (320 x 180), so the camera moves a little inside a one-cell room and more in
-- the bigger ones. "#" solid, "=" one-way, "." empty. Every room is closed by a border; the play
-- state opens rows 9 to 11 of a cell's first or last column for a left or right door, or the
-- middle three columns of the first or last row for an up or down door, and keeps a locked door
-- shut until the player has its ability.
--
-- enemies: the tiles enemies stand on at first (the tile above the floor), read by the play state.
-- obstacles: breakable props ({ tx, ty, kind = "crate" }); pickups: static hearts/virus
-- ({ tx, ty, kind, amount }); machine: a machine instance ({ tx, ty, kind = "healer" }).
--
-- Levels made in LDtk (engine.level) give templates of the same shape; these stay in code so the
-- example needs no level file.
local procgen = require("engine.modules.procgen")
local rooms_spawn = require("rooms_spawn")
local M = { cell_w = 20, cell_h = 12, tile_size = 16 }

-- Special rooms: a pedestal for the treasure, a counter for the shop, an arena for the miniboss.
-- The wave 2 rooms are only layouts here: their contents come later. "obstacle" is a short
-- platforming course whose goal is across from its door (the right variant mirrors the left).
local SPECIAL_ROWS = {
  treasure = {
    "####################", "#..................#", "#..................#", "#..................#",
    "#..................#", "#..................#", "#..................#", "#..................#",
    "#..................#", "#........##........#", "#.......####.......#", "####################",
  },
  super_treasure = {
    "####################", "#..................#", "#..................#", "#..................#",
    "#..................#", "#..................#", "#..................#", "#..................#",
    "#..................#", "#..................#", "#..................#", "#..###..###..###...#",
  },
  shop = {
    "####################", "#..................#", "#..................#", "#..................#",
    "#..................#", "#....==========....#", "#..................#", "#..................#",
    "#..................#", "#..................#", "#..................#", "####################",
  },
  casino = {
    "####################", "#..................#", "#..................#", "#..................#",
    "#..................#", "#....==========....#", "#..................#", "#..................#",
    "#..................#", "#..................#", "#..................#", "####################",
  },
  pact = {
    "####################", "#..................#", "#..................#", "#..................#",
    "#..................#", "#....==========....#", "#..................#", "#..................#",
    "#..................#", "#..................#", "#..................#", "####################",
  },
  miniboss = {
    "####################", "#..................#", "#..................#", "#..................#",
    "#..................#", "#..................#", "#..====......====..#", "#..................#",
    "#..................#", "#..................#", "#..................#", "####################",
  },
  trap = {
    "####################", "#..................#", "#..................#", "#..................#",
    "#..................#", "#..................#", "#..====......====..#", "#..................#",
    "#..................#", "#..................#", "#..................#", "####################",
  },
  obstacle = {
    "####################", "#...............####", "#..................#", "#.............==...#",
    "#..................#", "#..........==......#", "#..................#", "#......==..........#",
    "#..................#", "#...###............#", "#..................#", "####################",
  },
}
local SPECIAL_ENEMIES = {
  miniboss = { { tx = 10, ty = 11 }, { tx = 14, ty = 11 } },
  trap = { { tx = 4, ty = 11 }, { tx = 8, ty = 11 }, { tx = 12, ty = 11 }, { tx = 16, ty = 11 } },
}

-- The right obstacle room is the left one mirrored: its door is on the right and its goal on
-- the left, always across from the door.
local OBSTACLE_RIGHT_ROWS = {}
for i, row in ipairs(SPECIAL_ROWS.obstacle) do OBSTACLE_RIGHT_ROWS[i] = row:reverse() end

local function lr(...)
  local out = {}
  for i, e in ipairs({ ... }) do
    out[i] = { side = e[1], offset = e[2] or 0, tx = e[3], ty = e[4] }
  end
  return out
end

-- A room two cells high: one-way platforms three tiles apart up to ledges by the upper doors
local TALL = {
  "####################",
  "#..................#",
  "#..................#",
  "#..................#",
  "#..................#",
  "#..................#",
  "#..................#",
  "#..................#",
  "#..................#",
  "#..................#",
  "#..................#",
  "####....====....####",
  "#..................#",
  "#..................#",
  "#.......====.......#",
  "#..................#",
  "#..................#",
  "#...====....====...#",
  "#..................#",
  "#..................#",
  "#........==........#",
  "#..................#",
  "#..................#",
  "####################",
}

-- A room two cells wide and two high: the same climb on both halves, a bridge between them
local HUB = {}
for i, row in ipairs(TALL) do
  local middle = (i == 12) and "=====..........=====" or (i == 18) and "........====........" or "...................."
  HUB[i] = row:sub(1, 10) .. middle:sub(1, 10) .. middle:sub(11, 20) .. row:sub(11, 20)
end
HUB[1] = ("#"):rep(40); HUB[24] = ("#"):rep(40)

local FULL = "####################"
local PLATFORM = "#........===.......#"
-- Junction rooms keep a closed border: the play state opens the middle three columns of the top
-- or bottom row where the map put an up or down door, just like it opens the side doors. The
-- one-way platforms are three rows apart, so the slime can climb a shaft.
local VERTICAL_ROWS = {
  FULL, "#..................#", PLATFORM, "#..................#", "#..................#", PLATFORM,
  "#..................#", "#..................#", PLATFORM, "#..................#", "#..................#",
  FULL,
}
-- A new list each call: procgen.templates fills in defaults in place
function M.templates()
  local list = {
    { id = "start", type = "start", exits = lr({ "left" }, { "right" }), spawn = { tx = 10, ty = 10 },
      pickups = { { tx = 5, ty = 11, kind = "heart" }, { tx = 15, ty = 11, kind = "virus", amount = 2 } }, rows = {
      "####################",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#......======......#",
      "#..................#",
      "#..................#",
      "#..===........===..#",
      "#..................#",
      "#..................#",
      "####################",
    } },
    { id = "hall", weight = 3, exits = lr({ "left" }, { "right" }), enemies = { { tx = 7, ty = 11 }, { tx = 15, ty = 11 } },
      obstacles = { { tx = 5, ty = 11, kind = "crate" } }, rows = {
      "####################",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#....====..........#",
      "#..................#",
      "#..........====....#",
      "#..................#",
      "#..................#",
      "####################",
    } },
    { id = "steps", weight = 2, exits = lr({ "left" }, { "right" }), enemies = { { tx = 16, ty = 11 } },
      obstacles = { { tx = 4, ty = 11, kind = "crate" } }, rows = {
      "####################",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#.........##.......#",
      "#.........##.......#",
      "#......#####.......#",
      "#...########.......#",
      "####################",
    } },
    { id = "tall", weight = 2, h = 2, rows = TALL, enemies = { { tx = 10, ty = 23 } },
      exits = lr({ "left", 0 }, { "left", 1 }, { "right", 0 }, { "right", 1 }) },
    { id = "hub", w = 2, h = 2, rows = HUB, enemies = { { tx = 8, ty = 23 }, { tx = 32, ty = 23 }, { tx = 13, ty = 11 } },
      exits = lr({ "left", 0 }, { "left", 1 }, { "right", 0 }, { "right", 1 }) },
    -- Junction and vertical rooms: branches in both directions instead of one long corridor
    { id = "cross", weight = 2, rows = VERTICAL_ROWS, enemies = { { tx = 4, ty = 11 }, { tx = 16, ty = 11 } },
      exits = lr({ "left" }, { "right" }, { "up" }, { "down", 0, 7, 11 }) },
    { id = "shaft", weight = 2, rows = VERTICAL_ROWS, exits = lr({ "up" }, { "down", 0, 7, 11 }) },
    { id = "tee_u", weight = 2, rows = VERTICAL_ROWS, enemies = { { tx = 4, ty = 11 }, { tx = 16, ty = 11 } },
      exits = lr({ "left" }, { "right" }, { "up" }) },
    { id = "tee_d", weight = 2, rows = VERTICAL_ROWS, enemies = { { tx = 4, ty = 11 }, { tx = 16, ty = 11 } },
      exits = lr({ "left" }, { "right" }, { "down", 0, 7, 11 }) },
    { id = "corner_lu", weight = 1, rows = VERTICAL_ROWS, exits = lr({ "left" }, { "up" }) },
    { id = "corner_ru", weight = 1, rows = VERTICAL_ROWS, exits = lr({ "right" }, { "up" }) },
    { id = "corner_ld", weight = 1, rows = VERTICAL_ROWS, exits = lr({ "left" }, { "down", 0, 7, 11 }) },
    { id = "corner_rd", weight = 1, rows = VERTICAL_ROWS, exits = lr({ "right" }, { "down", 0, 7, 11 }) },
    { id = "vault_l", item = { tx = 10, ty = 11 }, exits = lr({ "left" }), rows = {
      "####################",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#.......####.......#",
      "#..................#",
      "#..................#",
      "####################",
    } },
    { id = "vault_r", item = { tx = 11, ty = 11 }, exits = lr({ "right" }), rows = {
      "####################",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#.......####.......#",
      "#..................#",
      "#..................#",
      "####################",
    } },
    { id = "vault_u", item = { tx = 10, ty = 11 }, exits = { { side = "up" } },
      rows = VERTICAL_ROWS },
    { id = "vault_d", item = { tx = 5, ty = 11 }, exits = { { side = "down", tx = 7, ty = 11 } },
      rows = VERTICAL_ROWS },
    { id = "lair_l", type = "boss", exits = lr({ "left" }), enemies = { { tx = 12, ty = 11 }, { tx = 16, ty = 11 } }, rows = {
      "####################",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#....====....====..#",
      "#..................#",
      "#..................#",
      "#..................#",
      "####################",
    } },
    { id = "lair_r", type = "boss", exits = lr({ "right" }), enemies = { { tx = 5, ty = 11 }, { tx = 9, ty = 11 } }, rows = {
      "####################",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..................#",
      "#..====....====....#",
      "#..................#",
      "#..................#",
      "#..................#",
      "####################",
    } },
    { id = "lair_u", type = "boss", exits = { { side = "up" } },
      enemies = { { tx = 4, ty = 11 }, { tx = 16, ty = 11 } },
      rows = VERTICAL_ROWS },
    { id = "lair_d", type = "boss", exits = { { side = "down", tx = 7, ty = 11 } },
      enemies = { { tx = 4, ty = 11 }, { tx = 16, ty = 11 } },
      rows = VERTICAL_ROWS },
  }
  -- The special rooms (procgen.roomtypes): one cell, one door, so each is a dead end
  local SPECIAL_KINDS = { "treasure", "shop", "miniboss", "super_treasure", "casino", "pact",
    "trap", "obstacle" }
  local VERTICAL_ENEMIES = { { tx = 4, ty = 11 }, { tx = 16, ty = 11 } }
  for _, kind in ipairs(SPECIAL_KINDS) do
    for _, side in ipairs({ "left", "right" }) do
      local rows = kind == "obstacle" and side == "right" and OBSTACLE_RIGHT_ROWS or SPECIAL_ROWS[kind]
      list[#list + 1] = { id = kind .. "_" .. side:sub(1, 1), type = kind, exits = lr({ side }),
        enemies = SPECIAL_ENEMIES[kind], rows = rows,
        machine = kind == "shop" and { tx = 10, ty = 11, kind = "healer" } or nil }
    end
    local enemies = kind == "miniboss" and VERTICAL_ENEMIES or SPECIAL_ENEMIES[kind]
    local rows = VERTICAL_ROWS
    list[#list + 1] = { id = kind .. "_u", type = kind, exits = { { side = "up" } },
      enemies = enemies, rows = rows,
      machine = kind == "shop" and { tx = 10, ty = 11, kind = "healer" } or nil }
    list[#list + 1] = { id = kind .. "_d", type = kind,
      exits = { { side = "down", tx = 7, ty = 11 } }, enemies = enemies, rows = rows,
      machine = kind == "shop" and { tx = 10, ty = 11, kind = "healer" } or nil }
  end
  return list
end

-- The special room types of a run: the base's Isaac-like set (a treasure room and a shop per
-- floor, a miniboss from floor 2 more likely the deeper the run goes), plus the new types and
-- their spawn rules from rooms_spawn.lua, in their definition order.
function M.types()
  local types = procgen.roomtypes.defaults()
  for _, entry in ipairs(rooms_spawn.defs) do
    types:define(entry.name, entry.def)
  end
  return types
end

return M
