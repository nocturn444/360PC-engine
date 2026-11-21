-- The Blob's appearance, as data: the base look (colours, eyes, shape) and the helpers that
-- apply a run's cosmetic mutations to it. A mutation is a def with a `.look` fragment (and
-- optionally `.body` for the rest shape, `.stacks` for how many times it was taken); rebuild()
-- turns the run's list into one look on acquisition, and the draw path only reads it.
--
-- Palette indices used by the pixel grid: 1 body, 2 outline, 3 eye, 4 pupil, 5 limb.
-- Plain Lua 5.1, no love, no randomness. apply/rebuild allocate (they run on acquisition);
-- palette/shape/draw_limbs do not, so they are safe in the per-frame draw path.
local floor, sqrt = math.floor, math.sqrt

local M = {}

local BASE_BODY = { 0.98, 0.90, 0.52 }
local BASE_OUTLINE = { 0.10, 0.30, 0.16 }
local BASE_EYE = { 0.95, 1.00, 0.95 }
local BASE_PUPIL = { 0.05, 0.08, 0.06 }
local BASE_LIMB = { 0.75, 0.85, 0.60 }

-- The unmodified look (the slime as it is drawn today).
function M.new()
  return {
    body = { BASE_BODY[1], BASE_BODY[2], BASE_BODY[3] },
    outline = { BASE_OUTLINE[1], BASE_OUTLINE[2], BASE_OUTLINE[3] },
    eye = { BASE_EYE[1], BASE_EYE[2], BASE_EYE[3] },
    pupil = { BASE_PUPIL[1], BASE_PUPIL[2], BASE_PUPIL[3] },
    limb = 5,
    limb_color = { BASE_LIMB[1], BASE_LIMB[2], BASE_LIMB[3] },
    eye_count = 2,
    shape = { sx = 1, sy = 1 },
    limbs = {},
    physical = nil,
  }
end

-- Copies a colour into the look; keeps no reference to the fragment.
local function set_color(dst, src)
  dst[1], dst[2], dst[3] = src[1], src[2], src[3]
end

-- M.apply(look, fragment): applies one mutation's look fragment in place and returns the look.
-- fragment: body_color, outline_color, eye_color, limb_color ({ r, g, b } or a palette index),
-- eye_count, shape = { sx, sy }, limbs (appended), stacks. Colors and count are set; limbs are
-- added (once, or once per stack up to 4) and shape grows a little with the stacks.
function M.apply(look, fragment)
  if not fragment then return look end
  if fragment.body_color then set_color(look.body, fragment.body_color) end
  if fragment.outline_color then set_color(look.outline, fragment.outline_color) end
  if fragment.eye_color then set_color(look.eye, fragment.eye_color) end
  if fragment.pupil_color then set_color(look.pupil, fragment.pupil_color) end
  if fragment.limb_color then
    local c = fragment.limb_color
    if type(c) == "number" then
      look.limb = c
    else
      look.limb = 5
      set_color(look.limb_color, c)
    end
  end
  if fragment.eye_count then look.eye_count = fragment.eye_count end
  if fragment.shape then
    if fragment.shape.sx then look.shape.sx = fragment.shape.sx end
    if fragment.shape.sy then look.shape.sy = fragment.shape.sy end
  end
  local f = fragment
  if f.limbs then
    local stacks = f.stacks or 1
    if stacks > 4 then stacks = 4 end
    if stacks < 1 then stacks = 1 end
    for _ = 1, stacks do
      for i = 1, #f.limbs do
        local l = f.limbs[i]
        look.limbs[#look.limbs + 1] = {
          anchor = l.anchor, side = l.side, length = l.length,
          width = l.width, color = l.color, kind = l.kind,
        }
      end
    end
    if stacks > 1 then
      local k = 1 + 0.05 * (stacks - 1)
      look.shape.sx, look.shape.sy = look.shape.sx * k, look.shape.sy * k
    end
  end
  return look
end

-- M.rebuild(entries): a fresh base look with every entry's `.look` applied in order. An
-- entry.body (rest shape) replaces look.physical; the last one wins. Called on acquisition.
function M.rebuild(entries)
  local look = M.new()
  entries = entries or {}
  for i = 1, #entries do
    local e = entries[i]
    if e.look then M.apply(look, e.look) end
    if e.body then
      local b = e.body
      look.physical = { radius = b.radius, width = b.width, height = b.height }
    end
  end
  return look
end

-- M.physical(look): the rest shape the body should be given (or nil).
function M.physical(look) return look.physical end

-- M.palette(look, px): writes the look's colours into px.palette entries 1..5. The entries must
-- already exist (the draw path makes no tables).
function M.palette(look, px)
  local p = px.palette
  local e
  e = p[1]; if e then e[1], e[2], e[3] = look.body[1], look.body[2], look.body[3] end
  e = p[2]; if e then e[1], e[2], e[3] = look.outline[1], look.outline[2], look.outline[3] end
  e = p[3]; if e then e[1], e[2], e[3] = look.eye[1], look.eye[2], look.eye[3] end
  e = p[4]; if e then e[1], e[2], e[3] = look.pupil[1], look.pupil[2], look.pupil[3] end
  e = p[5]; if e then e[1], e[2], e[3] = look.limb_color[1], look.limb_color[2], look.limb_color[3] end
  return px
end

-- M.shape(points, look): scales the flat outline { x1, y1, ... } in place around its box centre
-- by look.shape.sx/sy. A flat or missing shape leaves the points alone. Allocates nothing.
function M.shape(points, look)
  local n = #points
  if n < 4 or not look then return points end
  local s = look.shape
  if not s then return points end
  local sx, sy = s.sx, s.sy
  if sx == nil or sy == nil or sx <= 0 or sy <= 0 or (sx == 1 and sy == 1) then return points end
  local x0, y0, x1, y1 = points[1], points[2], points[1], points[2]
  for i = 3, n, 2 do
    local x, y = points[i], points[i + 1]
    if x < x0 then x0 = x elseif x > x1 then x1 = x end
    if y < y0 then y0 = y elseif y > y1 then y1 = y end
  end
  local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
  for i = 1, n, 2 do
    points[i] = cx + (points[i] - cx) * sx
    points[i + 1] = cy + (points[i + 1] - cy) * sy
  end
  return points
end

-- M.draw_limbs(px, look, points): draws the look's limbs after the body and its outline.
-- `points` is the flat outline in grid coordinates (softbody:outline). Each limb picks a point
-- by its anchor (0..1 around the ring), grows outwards from the outline's centre, is nudged to
-- one side by `side`, and is a small capsule of `length` and `width` cells in `color` (a palette
-- index, or the look's limb index). px:set clips to the grid. Allocates nothing.
function M.draw_limbs(px, look, points)
  local n = #points / 2
  local limbs = look and look.limbs
  if n < 1 or not limbs or #limbs == 0 then return end
  local x0, y0, x1, y1 = points[1], points[2], points[1], points[2]
  for i = 2, n do
    local x, y = points[2 * i - 1], points[2 * i]
    if x < x0 then x0 = x elseif x > x1 then x1 = x end
    if y < y0 then y0 = y elseif y > y1 then y1 = y end
  end
  local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
  local default_color = look.limb or 5
  for k = 1, #limbs do
    local limb = limbs[k]
    local anchor = limb.anchor or 0
    if anchor < 0 then anchor = 0 elseif anchor > 1 then anchor = 1 end
    local idx = floor(anchor * (n - 1) + 0.5) + 1
    if idx < 1 then idx = 1 elseif idx > n then idx = n end
    local bx, by = points[2 * idx - 1], points[2 * idx]
    local ox, oy = bx - cx, by - cy
    local d = sqrt(ox * ox + oy * oy)
    if d > 1e-4 then
      ox, oy = ox / d, oy / d
    else
      ox, oy = 0, -1
    end
    local side = limb.side or 1
    if side >= 0 then side = 1 else side = -1 end
    local dx = ox - oy * 0.35 * side
    local dy = oy + ox * 0.35 * side
    d = sqrt(dx * dx + dy * dy)
    if d > 1e-4 then dx, dy = dx / d, dy / d end
    local tx, ty = -dy, dx
    local len = limb.length or 3
    local w = limb.width or 1
    local color = limb.color or default_color
    local steps = floor(len)
    if steps < 1 then steps = 1 end
    local hw = floor(w / 2)
    for s = 0, steps do
      local t = len * s / steps
      local ix = floor(bx + dx * t + 0.5)
      local iy = floor(by + dy * t + 0.5)
      if hw < 1 then
        px:set(ix, iy, color)
      else
        for j = -hw, hw do
          px:set(ix + floor(tx * j + 0.5), iy + floor(ty * j + 0.5), color)
        end
      end
    end
  end
end

return M
