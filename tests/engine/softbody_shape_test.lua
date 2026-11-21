-- engine/modules/softbody: set_rest_shape changes the rest offsets, spring rest lengths,
-- rest_length and rest_area in place, keeps omitted fields, validates its input, and the body
-- still steps (allocating nothing) with the new shape.
-- Usage, from the repository root: luajit -joff tests/engine/softbody_shape_test.lua
-- Also works as tests/engine/run.lua's `T`-taking style.
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;" .. package.path

local T = ...
if type(T) ~= "table" then
  T = { checks = 0 }
  function T.check(cond, what)
    T.checks = T.checks + 1
    if not cond then error("FAILED: " .. what, 2) end
  end
  function T.near(a, b, what, eps)
    T.checks = T.checks + 1
    if math.abs(a - b) > (eps or 1e-6) then
      error(string.format("FAILED: %s (got %s, expected %s)", what, tostring(a), tostring(b)), 2)
    end
  end
end

local softbody = require("engine.modules.softbody")
local DT = 1 / 60

local function rest_area_of(b)
  local rx, ry, n = b.rest_x, b.rest_y, b.n
  local a, px, py = 0, rx[n], ry[n]
  for i = 1, n do
    a = a + px * ry[i] - rx[i] * py
    px, py = rx[i], ry[i]
  end
  return 0.5 * a
end

local b = softbody.new({ x = 50, y = 40, radius = 10, points = 12 })
local old_x1, old_y1 = b.rest_x[1], b.rest_y[1]
local old_len, old_area = b.rest_length, b.rest_area
T.near(old_x1, 10, "new: rest offset x is the radius", 1e-9)
T.near(old_y1, 0, "new: rest offset y of point 1", 1e-9)

-- A long body: width changes the x offsets and the spring lengths, height stays the radius.
b:set_rest_shape({ width = 24 })
T.near(b.width, 24, "set_rest_shape keeps the width")
T.near(b.height, 0, "set_rest_shape keeps the omitted height")
T.near(b.radius, 10, "set_rest_shape keeps the omitted radius")
T.near(b.rest_x[1], 12, "width 24: rest offset x is 12", 1e-9)
T.near(b.rest_y[1], 0, "width 24: point 1 still on the axis", 1e-9)
T.check(b.rest_length > old_len, "width 24: longer springs (" .. b.rest_length .. " > " .. old_len .. ")")
T.check(b.rest_area > old_area, "width 24: a bigger rest area (" .. b.rest_area .. " > " .. old_area .. ")")
T.near(b.rest_area, rest_area_of(b), "rest_area is the rest ring's area", 1e-9)
T.check(b.rest_area > 0.9 * math.pi * 12 * 10 and b.rest_area < math.pi * 12 * 10,
  "roughly the ellipse's area")
T.near(b.x[1], 50 + old_x1, "the points do not move", 1e-9)

-- A tall, wider body: setting the radius with a width keeps the width and grows the height.
local area1 = b.rest_area
b:set_rest_shape({ radius = 14 })
T.near(b.width, 24, "radius change keeps the width")
T.near(b.radius, 14, "radius is the new one")
T.near(b.rest_x[1], 12, "width still drives the x offsets", 1e-9)
T.near(b.rest_y[4], 14, "height 0 uses the new radius", 1e-9)
T.check(b.rest_area > area1, "a taller rest ring has a bigger area")
T.near(b.rest_area, rest_area_of(b), "rest_area follows the new offsets", 1e-9)

-- An explicit height and then width/height back to 0 (radius for both axes).
b:set_rest_shape({ width = 30, height = 8 })
T.near(b.rest_x[1], 15, "width 30: x offset 15", 1e-9)
T.near(b.rest_y[4], 4, "height 8: y offset 4", 1e-9)
T.near(b.rest_area, rest_area_of(b), "rest_area with an explicit height", 1e-9)
b:set_rest_shape({ width = 0, height = 0 })
T.near(b.rest_x[1], 14, "width 0: radius on x", 1e-9)
T.near(b.rest_y[4], 14, "height 0: radius on y", 1e-9)

-- Bad input is refused before anything changes.
local rx_saved = b.rest_x[1]
T.check(not pcall(b.set_rest_shape, b, { radius = 0 }), "radius > 0")
T.check(not pcall(b.set_rest_shape, b, { radius = "big" }), "radius is a number")
T.check(not pcall(b.set_rest_shape, b, { width = -1 }), "width >= 0")
T.check(not pcall(b.set_rest_shape, b, { width = "long" }), "width is a number")
T.check(not pcall(b.set_rest_shape, b, { height = -2 }), "height >= 0")
T.check(not pcall(b.set_rest_shape, b, { height = {} }), "height is a number")
T.near(b.rest_x[1], rx_saved, "a refused call changes nothing", 1e-9)

-- An empty opts table is a no-op.
local len_saved, area_saved = b.rest_length, b.rest_area
b:set_rest_shape()
T.near(b.rest_length, len_saved, "set_rest_shape{} keeps rest_length", 1e-9)
T.near(b.rest_area, area_saved, "set_rest_shape{} keeps rest_area", 1e-9)

-- Step still works after the shape changes, and allocates nothing per step.
b:move_to(80, 20)
for _ = 1, 90 do b:step(DT) end
local cx, cy = b:center()
T.check(cx == cx and cy == cy, "step after set_rest_shape leaves finite points")
T.check(cy > 20, "it falls under gravity")
T.near(b:area(), b.rest_area, "the area settles to the new rest area", 0.1)

local out = {}
collectgarbage(); collectgarbage("stop")
local before = collectgarbage("count")
for step = 1, 200 do
  b:push(step % 40 < 20 and 200 or -200, 0)
  b:step(DT)
  b:outline(out, 0, 0, 1, 0.5)
end
local grown = collectgarbage("count") - before
collectgarbage("restart")
T.check(grown < 1, "a step with the new shape allocates nothing (" .. grown .. " KB)")

print(string.format("OK: %d checks; set_rest_shape", T.checks))
