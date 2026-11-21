-- examples/rooms/rooms_minimap: the run's minimap drawn from nav:minimap() on a recording
-- fake love.graphics. Explored cells only, the current room outlined in white, and a tiny data
-- icon for every special type. Deterministic.
-- Usage, from the repository root: luajit -joff tests/pc/rooms_minimap_test.lua   (ends with OK:)
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./examples/rooms/?.lua;" .. package.path
local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print("FAILED: " .. what); os.exit(1) end
end

local M = require("rooms_minimap")

local REQUIRED = {
  "treasure", "super_treasure", "shop", "casino", "pact", "miniboss", "trap", "obstacle", "boss",
}

-- A recording fake love.graphics: every rectangle keeps the colour set when it was drawn.
local function recorder()
  local calls, color = {}, { 1, 1, 1, 1 }
  local g = {
    setColor = function(r, gg, b, a) color = { r, gg, b, a or 1 } end,
    rectangle = function(mode, x, y, w, h)
      calls[#calls + 1] = { mode = mode, x = x, y = y, w = w, h = h,
        color = { color[1], color[2], color[3], color[4] } }
    end,
  }
  return g, calls
end

local function count(calls, pred)
  local n = 0
  for i = 1, #calls do if pred(calls[i]) then n = n + 1 end end
  return n
end

local function marks(pattern)
  local n = 0
  for _, row in ipairs(pattern) do
    for i = 1, #row do if row:sub(i, i) == "x" then n = n + 1 end end
  end
  return n
end

-- Every special type has an icon and a colour; every icon is well formed and fits a cell.
local CELL = 7
for _, name in ipairs(REQUIRED) do
  local pattern = M.icons[name]
  check(type(pattern) == "table" and #pattern > 0, name .. " has an icon")
  check(M.TYPE_COLORS[name] ~= nil, name .. " has a colour")
  local w = #pattern[1]
  check(w > 0 and w <= CELL - 1, name .. " icon width fits the cell")
  check(#pattern <= CELL - 1, name .. " icon height fits the cell")
  for row = 1, #pattern do
    check(#pattern[row] == w, name .. " row " .. row .. " has the same width")
    for col = 1, w do
      local ch = pattern[row]:sub(col, col)
      check(ch == "x" or ch == ".", name .. " uses only x and .")
    end
  end
end

-- A map with the current room across two cells, a treasure, an unexplored trap, an unknown
-- type and a boss: only explored cells are drawn.
local function cell(room, kind, explored) return { room = room, type = kind, explored = explored } end
local mm = { w = 3, h = 2, cells = {
  cell(1, "normal", true), cell(1, "normal", true), cell(2, "treasure", true),
  cell(3, "trap", false), cell(4, "mystery", true), cell(5, "boss", true),
} }

local g, calls = recorder()
M.draw(g, mm, 1, 4.7, 3.2, nil)
local x0, y0 = 4, 3

-- Five explored cells, at cell size 7, rounded to whole pixels.
local fills = count(calls, function(c) return c.mode == "fill" and c.w == CELL - 1 and c.h == CELL - 1 end)
check(fills == 5, "only the five explored cells are filled (" .. fills .. ")")
for i = 1, #calls do
  check(calls[i].x == math.floor(calls[i].x) and calls[i].y == math.floor(calls[i].y),
    "positions are whole pixels")
end

-- The current room (cells 1,1 and 2,1) gets one white outline around its bounding box.
local lines = {}
for i = 1, #calls do if calls[i].mode == "line" then lines[#lines + 1] = calls[i] end end
check(#lines == 1, "one outline for the current room")
local line = lines[1]
check(line.x == x0 and line.y == y0 and line.w == 2 * CELL - 1 and line.h == CELL - 1,
  "outline covers the current room's cells")
check(line.color[1] == 1 and line.color[2] == 1 and line.color[3] == 1, "outline is white")

-- Icons for the treasure and the boss, nothing for the normal current room or the unknown type.
local icons = count(calls, function(c) return c.mode == "fill" and c.w == 1 and c.h == 1 end)
local expected = marks(M.icons.treasure) + marks(M.icons.boss)
check(icons == expected, "treasure and boss icons are drawn (" .. icons .. "/" .. expected .. ")")
local normal_icons = count(calls, function(c)
  return c.mode == "fill" and c.w == 1 and c.h == 1
    and c.x >= x0 and c.x < x0 + 2 * CELL and c.y >= y0 and c.y < y0 + CELL - 1
end)
check(normal_icons == 0, "a normal room draws no icon")
local unknown_icons = count(calls, function(c)
  return c.mode == "fill" and c.w == 1 and c.h == 1
    and c.x >= x0 + CELL and c.x < x0 + 2 * CELL and c.y >= y0 + CELL and c.y < y0 + 2 * CELL - 1
end)
check(unknown_icons == 0, "an unknown type draws no icon")

-- The unexplored trap cell is not drawn at all, so the trap stays hidden until entered.
local hidden = count(calls, function(c)
  return c.x == x0 and c.y == y0 + CELL
end)
check(hidden == 0, "an unexplored cell is not drawn")

-- opts.cell changes the size and the outline; the icon still fits and stays whole pixels.
local g2, calls2 = recorder()
M.draw(g2, mm, 1, 0, 0, { cell = 9 })
local big = count(calls2, function(c) return c.mode == "fill" and c.w == 8 and c.h == 8 end)
check(big == 5, "opts.cell sizes the cells (" .. big .. ")")
local big_line
for i = 1, #calls2 do if calls2[i].mode == "line" then big_line = calls2[i] end end
check(big_line and big_line.w == 2 * 9 - 1 and big_line.h == 9 - 1, "the outline follows opts.cell")

print(string.format("OK: %d checks; the run's minimap", checks))
