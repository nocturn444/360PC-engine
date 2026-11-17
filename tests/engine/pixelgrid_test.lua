-- engine/pixelgrid: rasterizing rectangles, circles and polygons (concave too) at cell centres,
-- the outline, drawing as one SpriteBatch or as merged rectangles, whole-pixel positions, and
-- nothing allocated per frame.
local T = ...
local F = require("fake_love")
F.install()
local PG = require("engine.pixelgrid")

local function rows(g)
  local out = {}
  for y = 1, g.h do
    local r = {}
    for x = 1, g.w do r[x] = g:get(x, y) == 0 and "." or tostring(g:get(x, y)) end
    out[y] = table.concat(r)
  end
  return table.concat(out, "/")
end

local g = PG.new(6, 4)
T.check(g:filled() == 0 and g:get(0, 0) == 0 and g:get(7, 1) == 0, "a new grid is empty; outside reads 0")
g:rect(1, 1, 3, 2, 1)
T.check(rows(g) == "....../.111../.111../......", "rect: the cells whose centres it covers")
g:clear(); g:rect(0.6, 0.4, 1, 1, 2)
T.check(rows(g) == ".2..../....../....../......", "rect at fractions: centre sampling: " .. rows(g))
g:set(6, 4, 3); g:set(9, 9, 3)
T.check(g:get(6, 4) == 3, "set and get; set outside is ignored")

local c = PG.new(9, 9)
c:circle(4.5, 4.5, 3.2, 1)
T.check(rows(c) == "........./...111.../..11111../.1111111./.1111111./.1111111./..11111../...111.../.........",
  "circle: " .. rows(c))

-- A concave polygon (a U shape)
local u = PG.new(6, 5)
u:polygon({ 0, 0, 6, 0, 6, 5, 4, 5, 4, 2, 2, 2, 2, 5, 0, 5 }, 1)
T.check(rows(u) == "111111/111111/11..11/11..11/11..11", "polygon: concave shapes fill by the even-odd rule")
u:clear()
u:polygon({ 1, 1 }, 1)
T.check(u:filled() == 0, "fewer than three points draw nothing")

-- Outline
local o = PG.new(5, 5)
o:rect(2, 2, 1, 1, 1)
o:outline(2)
T.check(rows(o) == "...../..2../.212./..2../.....", "outline: 4 neighbours")
o:clear(); o:rect(2, 2, 1, 1, 1); o:outline(2, nil, true)
T.check(rows(o) == "...../.222./.212./.222./.....", "outline: 8 neighbours")

-- Drawing as rectangles: one per run of one colour
local d = PG.new(4, 2, { cell = 2, palette = { { 1, 0, 0 }, { 0, 0, 1, 0.5 } } })
d:rect(0, 0, 3, 1, 1); d:set(4, 1, 2); d:set(2, 2, 2)
F.reset_calls()
love.graphics.setColor(0.3, 0.3, 0.3, 1)
T.check(d:draw(10.4, 20.6) == 5, "draw returns the cells drawn")
local rects = F.find("rectangle")
T.check(#rects == 3, "runs are merged: 3 rectangles for 5 cells")
T.check(rects[1][3] == 10 and rects[1][4] == 21 and rects[1][5] == 6 and rects[1][6] == 2,
  "whole game pixels, cells of 2: " .. table.concat({ rects[1][3], rects[1][4], rects[1][5], rects[1][6] }, " "))
local r, gg, b = love.graphics.getColor()
T.check(r == 0.3 and gg == 0.3 and b == 0.3, "the colour is put back")

-- One draw call with a SpriteBatch
local added, colors = {}, {}
local fake_sb = {
  clear = function() added = {} end,
  setColor = function(_, r1, g1, b1, a1) colors[#colors + 1] = { r1, g1, b1, a1 } end,
  add = function(_, quad, x, y, rot, sx, sy) added[#added + 1] = { x, y, sx, sy } end,
}
love.graphics.newSpriteBatch = function(image, size) fake_sb.size = size; return fake_sb end
local atlas = love.graphics.newImage("atlas.png")
local white = love.graphics.newQuad(8, 0, 1, 1, 32, 16)
d:batch(atlas, white)
T.check(fake_sb.size == 8, "the batch holds every cell")
F.reset_calls()
T.check(d:draw(0, 0) == 5 and #added == 5 and #F.find("draw") == 1 and #F.find("rectangle") == 0, "one draw call")
T.check(added[1][3] == 2 and added[1][4] == 2 and added[4][1] == 6 and colors[4][3] == 1 and colors[4][4] == 0.5,
  "cells are the quad scaled to the cell size, tinted with the palette")

-- Nothing allocated per frame
local s = PG.new(32, 32, { palette = { { 1, 1, 1 }, { 0, 0, 0 } } })
local pts = {}
for i = 0, 15 do
  local a = i / 16 * 2 * math.pi
  pts[#pts + 1] = 16 + 12 * math.cos(a); pts[#pts + 1] = 16 + 9 * math.sin(a)
end
local function frame() s:clear(); s:polygon(pts, 1); s:circle(10, 10, 4, 1); s:outline(2); s:draw(5, 5) end
local real_graphics = love.graphics
local noop = function() end
love.graphics = { getColor = function() return 1, 1, 1, 1 end, setColor = noop, rectangle = noop, draw = noop,
  newSpriteBatch = function() return { clear = noop, setColor = noop, add = noop } end }
frame()
local batched = PG.new(32, 32)
batched:batch(atlas, white)
batched:rect(2, 2, 20, 20, 1)
batched:draw(0, 0)
collectgarbage(); collectgarbage("stop")
local before = collectgarbage("count")
for _ = 1, 50 do frame(); batched:draw(3, 3) end
local grown = collectgarbage("count") - before
collectgarbage("restart")
love.graphics = real_graphics
T.check(grown < 1, "clear, shapes, outline and draw allocate nothing per frame (" .. grown .. " KB)")
T.check(not pcall(PG.new, 0, 4) and not pcall(PG.new, 2.5, 4), "sizes are whole numbers >= 1")
