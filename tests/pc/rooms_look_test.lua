-- examples/rooms/rooms_look: the Blob's base look, mutation fragments (colours, eyes, shape,
-- limbs, stacks), rebuild with the last rest shape winning, the in-place outline scale, the
-- palette copy and the limb drawing. Deterministic.
-- Usage, from the repository root: luajit -joff tests/pc/rooms_look_test.lua   (ends with OK:)
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./examples/rooms/?.lua;" .. package.path
local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print("FAILED: " .. what); os.exit(1) end
end
local function near(a, b, what, eps)
  checks = checks + 1
  if math.abs(a - b) > (eps or 1e-9) then
    print(string.format("FAILED: %s (got %s, expected %s)", what, tostring(a), tostring(b)))
    os.exit(1)
  end
end
local function same_color(a, b, what)
  near(a[1], b[1], what .. " r"); near(a[2], b[2], what .. " g"); near(a[3], b[3], what .. " b")
end

local M = require("rooms_look")
local pixelgrid = require("engine.pixelgrid")

-- The base look matches the slime drawn today.
local look = M.new()
same_color(look.body, { 0.98, 0.90, 0.52 }, "body")
same_color(look.outline, { 0.10, 0.30, 0.16 }, "outline")
same_color(look.eye, { 0.95, 1.00, 0.95 }, "eye")
same_color(look.pupil, { 0.05, 0.08, 0.06 }, "pupil")
same_color(look.limb_color, { 0.75, 0.85, 0.60 }, "limb colour")
check(look.limb == 5, "the limb colour is palette index 5")
check(look.eye_count == 2, "two eyes")
near(look.shape.sx, 1, "shape sx"); near(look.shape.sy, 1, "shape sy")
check(#look.limbs == 0, "no limbs at the start")
check(M.physical(look) == nil, "no physical rest shape at the start")

-- A fragment sets colours, the eye count, the shape and appends a limb.
M.apply(look, {
  body_color = { 0.1, 0.2, 0.3 }, outline_color = { 0.4, 0.5, 0.6 },
  eye_color = { 0.7, 0.8, 0.9 }, limb_color = { 0.2, 0.9, 0.4 },
  eye_count = 3, shape = { sx = 1.5, sy = 0.75 },
  limbs = { { anchor = 0.5, side = 1, length = 4, width = 1, color = 5, kind = "spike" } },
})
same_color(look.body, { 0.1, 0.2, 0.3 }, "fragment body")
same_color(look.outline, { 0.4, 0.5, 0.6 }, "fragment outline")
same_color(look.eye, { 0.7, 0.8, 0.9 }, "fragment eye")
same_color(look.limb_colors[1], { 0.2, 0.9, 0.4 }, "fragment limb colour gets its own slot")
same_color(look.limb_color, { 0.75, 0.85, 0.60 }, "the base limb colour is kept")
check(look.eye_count == 3, "fragment eye count")
near(look.shape.sx, 1.5, "fragment shape sx"); near(look.shape.sy, 0.75, "fragment shape sy")
check(#look.limbs == 1, "one limb appended")
local l = look.limbs[1]
check(l.anchor == 0.5 and l.side == 1 and l.length == 4 and l.width == 1 and l.color == 6 and l.kind == "spike",
  "the limb keeps its fields, in its fragment's own colour (index 6)")

-- A limb_color as a palette index sets the index, not the colours.
M.apply(look, { limb_color = 2 })
check(look.limb == 2, "a numeric limb_color is a palette index")

-- Stacks add the limb once per stack (capped at 4) and grow the shape a little.
local stacked = M.new()
M.apply(stacked, {
  shape = { sx = 1, sy = 1 },
  limbs = { { anchor = 0.25, side = -1, length = 2, width = 1 } },
  stacks = 10,
})
check(#stacked.limbs == 4, "stacks cap at 4 limbs (" .. #stacked.limbs .. ")")
check(stacked.shape.sx > 1 and stacked.shape.sy > 1, "stacks intensify the shape")

-- Rebuild: every look applied in order, the last body wins.
local entries = {
  { look = { body_color = { 0.2, 0.2, 0.2 }, shape = { sx = 1.5 } },
    body = { radius = 9, width = 18, height = 10 } },
  { look = { eye_count = 4 }, body = { radius = 12, width = 24, height = 8 } },
}
local built = M.rebuild(entries)
same_color(built.body, { 0.2, 0.2, 0.2 }, "rebuild applies the first look")
check(built.eye_count == 4, "rebuild applies the last look")
near(built.shape.sx, 1.5, "rebuild keeps an applied shape"); near(built.shape.sy, 1, "rebuild shape sy")
local phys = M.physical(built)
check(phys and phys.radius == 12 and phys.width == 24 and phys.height == 8, "the last body wins")
check(M.rebuild({}) ~= nil and M.physical(M.rebuild({})) == nil, "rebuild with nothing: base look")

-- Determinism: the same entries give the same look.
local built2 = M.rebuild(entries)
same_color(built2.body, built.body, "deterministic body")
near(built2.shape.sx, built.shape.sx, "deterministic shape")
check(#built2.limbs == #built.limbs, "deterministic limbs")

-- shape(): scales a flat outline around its centre, in place.
local pts = { -2, -2, 2, -2, 2, 2, -2, 2 }
local shaped = M.shape(pts, { shape = { sx = 2, sy = 0.5 } })
check(shaped == pts, "shape writes into the same table")
near(pts[1], -4, "shape scales x (left)"); near(pts[2], -1, "shape scales y (top)")
near(pts[3], 4, "shape scales x (right)"); near(pts[6], 1, "shape scales y (bottom)")
local flat = { 3, 3, 3, 3 }
M.shape(flat, { shape = { sx = 5, sy = 5 } })
check(flat[1] == 3 and flat[2] == 3, "a zero-size outline is left alone")
local unchanged = { 1, 2, 3, 4 }
M.shape(unchanged, {})
check(unchanged[1] == 1 and unchanged[4] == 4, "a missing shape leaves the points alone")

-- palette(): writes the look into five existing entries, no tables made.
local px = pixelgrid.new(40, 40, { palette = {
  { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 },
} })
local before = px.palette
M.palette(look, px)
check(px.palette == before, "palette keeps the same table")
same_color(px.palette[1], look.body, "palette body")
same_color(px.palette[2], look.outline, "palette outline")
same_color(px.palette[3], look.eye, "palette eye")
same_color(px.palette[4], look.pupil, "palette pupil")
same_color(px.palette[5], look.limb_color, "palette limb")
same_color(px.palette[6], look.limb_colors[1], "palette entry 6: the fragment's limb colour")

-- Regression (console, 2026-11-23): the spring heel's light-blue limb colour painted every limb
-- taken after it (carapace shell, legs), so its "hairs" seemed to multiply on each floor. Each
-- mutation's limbs keep their own colour now.
do
  local byid = {}
  for _, e in ipairs(require("rooms_content").mutations) do byid[e.id] = e end
  local heel, shell, legs = byid.example_spring_heel, byid.example_carapace, byid.example_legs
  local run = M.rebuild({ heel, shell, legs })
  check(#run.limbs == 2 + 1 + 4, "spring heel, carapace and legs: 7 limbs (" .. #run.limbs .. ")")
  check(#run.limb_colors == 1, "one own limb colour (the spring heel's)")
  same_color(run.limb_color, { 0.75, 0.85, 0.60 }, "the default limb colour stays the base one")
  for i = 1, #run.limbs do
    local want = i <= 2 and 6 or 5
    check(run.limbs[i].color == want, "limb " .. i .. " (" .. run.limbs[i].kind .. ") uses palette index " .. want)
  end
  local grid = pixelgrid.new(40, 40, { palette = {
    { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 },
  } })
  M.palette(run, grid)
  same_color(grid.palette[6], heel.look.limb_color, "the spring heel's colour is in entry 6")
  same_color(grid.palette[5], { 0.75, 0.85, 0.60 }, "entry 5 is not overwritten")
  local again = M.rebuild({ heel, heel })
  check(#again.limb_colors == 1, "a repeated mutation reuses its colour slot")
end

-- draw_limbs(): draws outside the outline, inside the grid, deterministically.
local outline = {}
for i = 1, 16 do
  local a = 2 * math.pi * (i - 1) / 16
  outline[#outline + 1] = 20 + 8 * math.cos(a)
  outline[#outline + 1] = 20 + 8 * math.sin(a)
end
local limb_look = M.new()
M.apply(limb_look, {
  limbs = { { anchor = 0, side = 1, length = 5, width = 1, color = 5, kind = "leg" } },
})
M.draw_limbs(px, limb_look, outline)
local filled = px:filled()
check(filled > 0, "the limb draws cells (" .. filled .. ")")
local maxx = 0
for x = 1, px.w do if px:get(x, 20) > 0 then maxx = x end end
check(maxx > 28, "the limb grows outwards past the outline (" .. maxx .. ")")
local first = filled
px:clear()
M.draw_limbs(px, limb_look, outline)
check(px:filled() == first, "drawing the limbs twice gives the same cells")

-- An empty look draws nothing and does not error.
px:clear()
M.draw_limbs(px, M.new(), outline)
check(px:filled() == 0, "no limbs: nothing drawn")

print(string.format("OK: %d checks; the Blob's look", checks))
