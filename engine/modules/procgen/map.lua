-- procgen.map: what the generator returns, its minimap data and a stable hash of its layout.
--
-- map.rooms[i]:  index, id, template, x, y (top left map cell), w, h, type, zone (0 = before any
--                lock), grants (the ability tag whose item is here, or nil), doors (one entry per
--                exit of the template: a door index, or false when the exit leads nowhere),
--                closed (the exit indices without a door, in order: the game walls them up)
-- map.doors[i]:  index, a, b (room indices), ea, eb (exit indices in a and b), requires (sorted
--                ability tags, empty for a free door), lock (the zone's tag, for the door into a
--                zone), loop (true for a door added between neighbours of the same zone)
-- map.start, map.boss (room indices; boss is nil without boss templates), map.abilities,
-- map.attempts (tries it took)
local rng = require("engine.rng")
local templates = require((...):gsub("map$", "templates"))

local concat, tostring = table.concat, tostring

local M = {}

function M.new(rooms, doors, abilities)
  return { rooms = rooms, doors = doors, abilities = abilities, start = 1 }
end

-- map.hash(map) -> a whole number (32 bits): the same on every platform for the same layout.
-- It covers room ids, positions, zones and items, and doors with their tags. Use it to compare
-- a seed's map on the PC and on the console, or to store "this seed gave this map" in tests.
function M.hash(m)
  local parts = {}
  for i = 1, #m.rooms do
    local r = m.rooms[i]
    parts[#parts + 1] = "r" .. r.id .. "," .. r.x .. "," .. r.y .. "," .. r.zone .. "," .. tostring(r.grants)
  end
  for i = 1, #m.doors do
    local d = m.doors[i]
    parts[#parts + 1] = "d" .. d.a .. "," .. d.b .. "," .. d.ea .. "," .. d.eb .. "," .. concat(d.requires, "+")
  end
  parts[#parts + 1] = "s" .. m.start .. "," .. tostring(m.boss)
  return rng.hash(concat(parts, ";"))
end

-- map.room_at(map, x, y) -> the room covering that map cell, or nil
function M.room_at(m, x, y)
  for i = 1, #m.rooms do
    local r = m.rooms[i]
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then return r end
  end
  return nil
end

-- map.minimap(map) -> { x, y (the top left cell), w, h, cells }. cells[(cy - 1) * w + cx] for
-- cx = 1..w, cy = 1..h is false (empty) or a table:
--   room (index), type, zone, explored (false: the game sets it), item (the tag, on the room's
--   top left cell only), and per side ("left", "right", "up", "down") nil or a door table
--   { door = index, requires = the tags (shared with the door: do not change it) }.
-- No drawing: the game decides how a cell looks.
function M.minimap(m)
  local minx, miny, maxx, maxy = 0, 0, 0, 0
  for i = 1, #m.rooms do
    local r = m.rooms[i]
    if r.x < minx then minx = r.x end
    if r.y < miny then miny = r.y end
    if r.x + r.w - 1 > maxx then maxx = r.x + r.w - 1 end
    if r.y + r.h - 1 > maxy then maxy = r.y + r.h - 1 end
  end
  local w, h = maxx - minx + 1, maxy - miny + 1
  local cells = {}
  for i = 1, w * h do cells[i] = false end
  for i = 1, #m.rooms do
    local r = m.rooms[i]
    for cx = r.x, r.x + r.w - 1 do
      for cy = r.y, r.y + r.h - 1 do
        cells[(cy - miny) * w + (cx - minx) + 1] = { room = i, type = r.type, zone = r.zone, explored = false }
      end
    end
    if r.grants then cells[(r.y - miny) * w + (r.x - minx) + 1].item = r.grants end
    local exits = r.template.exits
    for e = 1, #exits do
      local di = r.doors[e]
      if di then
        local ox, oy = templates.exit_cell(r.template, exits[e])
        local cell = cells[(r.y + oy - miny) * w + (r.x + ox - minx) + 1]
        cell[exits[e].side] = { door = di, requires = m.doors[di].requires }
      end
    end
  end
  return { x = minx, y = miny, w = w, h = h, cells = cells }
end

return M
