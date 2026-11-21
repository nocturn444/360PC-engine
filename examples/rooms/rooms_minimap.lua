-- The run's minimap: explored cells coloured by room type, a tiny pixel icon for special
-- rooms, and a white outline around the room the slime is in. The engine's procgen map gives
-- the cells (nav:minimap()); this game-side module only decides how they look.
local floor = math.floor

local M = {}

M.TYPE_COLORS = {
  normal = { 0.5, 0.6, 0.8 }, start = { 0.5, 0.6, 0.8 }, boss = { 0.8, 0.3, 0.3 },
  treasure = { 0.95, 0.75, 0.2 }, super_treasure = { 0.98, 0.85, 0.35 },
  shop = { 0.35, 0.8, 0.45 }, casino = { 0.7, 0.4, 0.85 }, pact = { 0.75, 0.25, 0.6 },
  miniboss = { 0.9, 0.5, 0.25 }, trap = { 0.85, 0.3, 0.35 },
  obstacle = { 0.55, 0.5, 0.45 },
}

-- Icons are data: one entry per special type, so a new type only needs its pattern here.
-- "x" is a pixel, "." is empty; every row has the same width and fits inside a cell.
M.icons = {
  treasure = { "xxx", "x.x", "xxx" },
  super_treasure = { "x.x", "xxx", "x.x" },
  shop = { ".x.", "xxx", ".x." },
  casino = { "xx.", "x.x", ".xx" },
  pact = { "x.x", ".x.", "x.x" },
  miniboss = { ".x.", "xxx", "x.x" },
  trap = { "x.x", "x.x", "xxx" },
  obstacle = { "xxx", ".x.", ".x." },
  boss = { "xxx", "x.x", "xxx" },
}

local function draw_icon(g, pattern, x, y, cell)
  local h, w = #pattern, #pattern[1]
  local ox = x + floor((cell - 1 - w) / 2)
  local oy = y + floor((cell - 1 - h) / 2)
  g.setColor(1, 1, 1, 1)
  for row = 1, h do
    local line = pattern[row]
    for col = 1, w do
      if line:sub(col, col) == "x" then
        g.rectangle("fill", ox + col - 1, oy + row - 1, 1, 1)
      end
    end
  end
end

-- draw(g, mm, current_index, x0, y0, opts): g is love.graphics, mm is nav:minimap(),
-- current_index is nav.index, x0/y0 is the top left on screen and opts.cell is the cell size
-- in pixels (default 7, so the icons are readable). Only explored cells are drawn.
function M.draw(g, mm, current_index, x0, y0, opts)
  opts = opts or {}
  local cell = opts.cell or 7
  x0, y0 = floor(x0 or 0), floor(y0 or 0)
  local mincx, mincy, maxcx, maxcy
  for cy = 1, mm.h do
    for cx = 1, mm.w do
      local c = mm.cells[(cy - 1) * mm.w + cx]
      if c and c.explored then
        local x, y = x0 + (cx - 1) * cell, y0 + (cy - 1) * cell
        if c.room == current_index then
          g.setColor(0.95, 0.95, 0.6, 1)
          if not mincx or cx < mincx then mincx = cx end
          if not maxcx or cx > maxcx then maxcx = cx end
          if not mincy or cy < mincy then mincy = cy end
          if not maxcy or cy > maxcy then maxcy = cy end
        else
          local col = M.TYPE_COLORS[c.type] or M.TYPE_COLORS.normal
          g.setColor(col[1], col[2], col[3], 1)
        end
        g.rectangle("fill", x, y, cell - 1, cell - 1)
        local icon = M.icons[c.type]
        if icon then draw_icon(g, icon, x, y, cell) end
      end
    end
  end
  -- The current room is a rectangle of map cells, so its bounding box is its outline.
  if mincx then
    g.setColor(1, 1, 1, 1)
    g.rectangle("line", x0 + (mincx - 1) * cell, y0 + (mincy - 1) * cell,
      (maxcx - mincx + 1) * cell - 1, (maxcy - mincy + 1) * cell - 1)
  end
end

return M
