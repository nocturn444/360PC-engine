-- engine/modules/softbody: the ring at rest, falling onto a grid and settling without rolling,
-- walls, one-way tiles, pushes and impulses, squashing with inflate, the outline (and what
-- pixelgrid makes of it), determinism, nothing allocated per step, and a static check.
local T = ...
local globals = {}
for k in pairs(_G) do globals[k] = true end
local softbody = require("engine.modules.softbody")
local grid = require("engine.modules.platformer.grid")
local PG = require("engine.pixelgrid")

local DT = 1 / 60
-- 20 x 7 tiles of 16: walls on both sides, a floor on top of row 7 (y = 96), a one-way
-- platform over x 128..192 at y = 48
local function room()
  return grid.new({
    "#..................#",
    "#..................#",
    "#..................#",
    "#.......====.......#",
    "#..................#",
    "#..................#",
    "####################",
  }, { tile_size = 16 })
end
local function run(b, g, steps, each)
  for s = 1, steps do
    if each then each(s, b) end
    b:step(DT, g)
  end
end

-- The ring
local b = softbody.new({ x = 50, y = 40, radius = 10, points = 12 })
local cx, cy = b:center()
T.check(b.n == 12 and #b.x == 12, "12 points")
T.near(cx, 50, "centre x", 1e-9); T.near(cy, 40, "centre y", 1e-9)
T.near(b:area(), b.rest_area, "a new body has its rest area", 1e-6)
T.check(b.rest_area > 0.95 * math.pi * 100 and b.rest_area < math.pi * 100, "rest area: the polygon in the circle")
T.check(not pcall(softbody.new, { points = 5 }) and not pcall(softbody.new, { radius = 0 })
  and not pcall(softbody.new, { stiffness = "hard" }), "new refuses bad options")
local x0, y0, x1, y1 = b:bounds()
T.near(x1 - x0, 20, "bounds: the diameter across", 1e-9)

-- Falling with no grid: the shape holds
local free = softbody.new({ x = 0, y = 0 })
run(free, nil, 30)
local _, fy = free:center()
T.check(fy > 60 and fy < 80, "free fall: about g t^2 / 2 (" .. fy .. ")")
T.near(free:area() / free.rest_area, 1, "free fall keeps the area", 0.02)
local _, vy = free:velocity()
T.check(vy > 290 and vy < 300, "velocity after 0.5 s of gravity (" .. vy .. ")")

-- Onto the floor: it lands, squashes a little and stays where it landed
local g = room()
local s = softbody.new({ x = 80, y = 20, radius = 8 })
run(s, g, 120)
local sx, sy = s:center()
x0, y0, x1, y1 = s:bounds()
T.check(s:on_ground() and not s:on_wall() and not s:on_ceiling(), "it rests on the floor")
T.check(y1 <= 96 and y1 > 95.9, "no point below the floor (" .. y1 .. ")")
T.near(sx, 80, "no rolling while at rest", 0.01)
T.check(x1 - x0 > y1 - y0, "squashed: wider than tall at rest")
T.near(s:area() / s.rest_area, 1, "the area holds under its weight", 0.05)
run(s, g, 60)
local sx2, sy2 = s:center()
T.near(sx2, sx, "still at rest a second later (x)", 0.01)
T.near(sy2, sy, "still at rest a second later (y)", 0.05)

-- Push: it rolls along the floor and stops at the wall
run(s, g, 240, function(_, body) body:push(600, 0) end)
x0, y0, x1, y1 = s:bounds()
T.check(s:on_wall() and x1 <= 304 and x1 > 300, "a push brings it to the right wall, not through (" .. x1 .. ")")
run(s, g, 120)
x0, y0, x1, y1 = s:bounds()
T.check(x1 <= 304, "it stays out of the wall")

-- Impulse: a jump from the floor
local j = softbody.new({ x = 40, y = 80, radius = 8 })
run(j, g, 60)
local _, ground_y = j:center()
j:impulse(0, -300)
local top = ground_y
run(j, g, 40, function(_, body) local _, y = body:center(); if y < top then top = y end end)
T.check(ground_y - top > 50, "the impulse lifts it (" .. (ground_y - top) .. " px)")
run(j, g, 120)
T.check(j:on_ground(), "and it lands again")

-- One-way tiles: through from below, held from above
local o = softbody.new({ x = 160, y = 80, radius = 6 })
run(o, g, 30)
o:impulse(0, -420)
local highest = 1e9
run(o, g, 50, function(_, body) local _, y = body:center(); if y < highest then highest = y end end)
T.check(highest < 40, "it jumps up through a one-way platform (" .. highest .. ")")
run(o, g, 120)
x0, y0, x1, y1 = o:bounds()
T.check(o:on_ground() and y1 <= 48 and y1 > 47.9, "and lands on top of it (" .. y1 .. ")")

-- inflate squashes and swells it
local q = softbody.new({ x = 80, y = 80, radius = 8 })
run(q, g, 60)
q.inflate = 0.6
run(q, g, 60)
T.near(q:area() / q.rest_area, 0.6, "inflate 0.6: a smaller body", 0.06)
q.inflate = 1
run(q, g, 60)
T.near(q:area() / q.rest_area, 1, "inflate 1: back to its size", 0.05)

-- move_to: no velocity
local vx0, vy0 = q:velocity()
q:move_to(200, 30)
cx, cy = q:center()
T.near(cx, 200, "move_to x", 1e-9); T.near(cy, 30, "move_to y", 1e-9)
local vx
vx, vy = q:velocity()
T.check(math.abs(vx - vx0) < 1e-6 and math.abs(vy - vy0) < 1e-6, "move_to keeps the velocity")

-- The outline, and the pixelgrid it draws into
local shape = softbody.new({ x = 16, y = 16, radius = 10, points = 16 })
local pts = shape:outline(nil, 0, 0, 1)
T.check(#pts == 32 and pts[1] == 26 and math.abs(pts[2] - 16) < 1e-9, "outline: flat x, y pairs")
shape:outline(pts, 8, 8, 2)
T.check(#pts == 32 and pts[1] == 9, "outline with an origin and a cell size")
local longer = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34 }
T.check(#shape:outline(longer) == 32, "outline trims an older, longer array")
shape:step(DT)
local half = shape:outline(nil, 0, 0, 1, 0)
T.near(half[2], 16, "alpha 0: the previous step", 1e-9)
local pg = PG.new(32, 32)
pg:polygon(shape:outline(pts, 0, 0, 1), 1)
T.near(pg:filled() / shape:area(), 1, "pixelgrid fills about the body's area (" .. pg:filled() .. ")", 0.1)

-- Same inputs, same result
local function trace()
  local t = softbody.new({ x = 60, y = 20, radius = 7, points = 14 })
  run(t, room(), 300, function(step, body)
    if step % 50 < 20 then body:push(step % 100 < 50 and 500 or -500, 0) end
    if step % 90 == 0 and body:on_ground() then body:impulse(0, -250) end
  end)
  return table.concat(t:outline(), ",")
end
T.check(trace() == trace(), "same inputs, same points")

-- Nothing allocated per step
local a = softbody.new({ x = 80, y = 20 })
local out = {}
collectgarbage(); collectgarbage("stop")
local before = collectgarbage("count")
for step = 1, 200 do
  a:push(step % 60 < 30 and 300 or -300, 0)
  a:step(DT, g)
  a:outline(out, 0, 0, 1, 0.5)
end
local grown = collectgarbage("count") - before
collectgarbage("restart")
T.check(grown < 1, "step and outline allocate nothing (" .. grown .. " KB)")

-- set_velocity and the box for combat
local v = softbody.new({ x = 100, y = 30 })
run(v, nil, 10)
v:set_velocity(120, nil)
local svx, svy = v:velocity()
T.near(svx, 120, "set_velocity x", 1e-9)
local box = softbody.box(v)
local bx0, by0, bx1, by1 = v:bounds()
T.check(box.x == bx0 and box.y == by0 and box.w == bx1 - bx0 and box.h == by1 - by0 and box.facing == 1, "box: the points' box")
run(v, nil, 5); box:sync()
local nx0 = v:bounds()
T.check(box.x == nx0, "box:sync follows the body")
box:knock({ knock_x = -200, knock_y = -150 })
svx, svy = v:velocity()
T.near(svx, -200, "knock: x velocity", 1e-9); T.near(svy, -150, "knock: y velocity", 1e-9)
box:knock({ knock_x = 0, knock_y = 0 })
T.near(select(1, v:velocity()), -200, "no knockback: nothing changes", 1e-9)

-- Static checks
local f = assert(io.open("engine/modules/softbody/init.lua", "rb"))
local src = f:read("*a"):gsub("%-%-[^\n]*", ""); f:close()
T.check(not src:find("%f[%w]goto%f[%W]") and not src:find("ffi") and not src:find("%f[%w_]jit%."), "softbody: no goto, FFI or jit")
T.check(not src:find("%f[%w_]love%f[%W]") and not src:find("math%.random") and not src:find("os%.time"),
  "softbody: no love, nothing random, no clock")
T.check(not src:find("[^%w_]pairs%(") and not src:find("require"), "softbody: no pairs(), no other module")
T.no_new_globals(globals)
