-- engine.pixelgrid: a small grid of colour indices that shapes are rasterized into every frame
-- (a soft body, a blob, a trail, a mask), drawn as cells aligned to the game's pixel grid, all
-- in one draw call. Generic: it knows nothing about what the shape is.
--
--   local pixelgrid = require("engine.pixelgrid")
--   local g = pixelgrid.new(32, 32, { cell = 1, palette = { { 0.4, 0.9, 0.5 }, { 0.1, 0.3, 0.2 } } })
--   g:batch(atlas, atlas_white_quad)          -- optional: one draw call (see below)
--   function thing:draw()
--     g:clear()
--     g:polygon(outline_points, 1)            -- grid coordinates (cells), any simple polygon
--     g:outline(2)                            -- a one-cell border around what is filled
--     g:draw(self.x - 16, self.y - 16)        -- snapped to whole game pixels
--   end
--
-- Values: 0 is empty; 1..#palette are colours. Cell (1, 1) is the top-left one and covers grid
-- coordinates 0 <= x < 1, 0 <= y < 1; a shape covers a cell when the cell's centre is inside it
-- (strictly: a centre exactly on the edge is left out, which keeps symmetric shapes symmetric).
--
-- Drawing: with g:batch(image, quad) the cells go into one SpriteBatch drawn in a single call;
-- `quad` must show a white (or lightly tinted) area of `image`, such as one white pixel of the
-- game's atlas. Without it, each horizontal run of one colour is a rectangle (a few calls per
-- row). Nothing is allocated per frame once the grid and its batch exist.
local floor, ceil, max, min, sqrt = math.floor, math.ceil, math.max, math.min, math.sqrt

local M = {}
local Grid = {}
Grid.__index = Grid

-- pixelgrid.new(w, h, opts): opts.cell (game pixels per cell, default 1), opts.palette (array
-- of { r, g, b [, a] }, default one white colour)
function M.new(w, h, opts)
  assert(type(w) == "number" and type(h) == "number" and w >= 1 and h >= 1 and w == floor(w) and h == floor(h),
    "pixelgrid.new: width and height are whole numbers >= 1")
  opts = opts or {}
  local self = setmetatable({ w = w, h = h, cell = opts.cell or 1, palette = opts.palette or { { 1, 1, 1, 1 } },
    cells = {}, xs = {}, count = 0 }, Grid)
  for i = 1, w * h do self.cells[i] = 0 end
  return self
end

function Grid:clear(v)
  v = v or 0
  local cells = self.cells
  for i = 1, self.w * self.h do cells[i] = v end
end

function Grid:get(x, y)
  if x < 1 or y < 1 or x > self.w or y > self.h then return 0 end
  return self.cells[(y - 1) * self.w + x]
end

function Grid:set(x, y, v)
  if x < 1 or y < 1 or x > self.w or y > self.h then return end
  self.cells[(y - 1) * self.w + x] = v
end

-- The cells whose centres (c - 0.5) lie strictly between a0 and a1, clamped to 1..n
local function cells_between(a0, a1, n)
  return max(1, floor(a0 + 0.5) + 1), min(n, ceil(a1 + 0.5) - 1)
end

-- Fills the cells of row y whose centres lie strictly between x0 and x1
local function span(self, y, x0, x1, v)
  local a, b = cells_between(x0, x1, self.w)
  local row = (y - 1) * self.w
  local cells = self.cells
  for x = a, b do cells[row + x] = v end
end

function Grid:rect(x, y, w, h, v)
  local y0, y1 = cells_between(y, y + h, self.h)
  for cy = y0, y1 do span(self, cy, x, x + w, v) end
end

-- A filled circle; cx, cy, r in grid coordinates
function Grid:circle(cx, cy, r, v)
  local y0, y1 = cells_between(cy - r, cy + r, self.h)
  for y = y0, y1 do
    local dy = (y - 0.5) - cy
    local d = r * r - dy * dy
    if d > 0 then
      local dx = sqrt(d)
      span(self, y, cx - dx, cx + dx, v)
    end
  end
end

-- A filled polygon: points = { x1, y1, x2, y2, ... } in grid coordinates, closed, any simple
-- shape (concave too: the even-odd rule, sampled at the centre of each row). Up to n points,
-- with no table made per call after the first one of that size.
function Grid:polygon(points, v)
  local n = #points
  if n < 6 then return end
  local ymin, ymax = points[2], points[2]
  for i = 4, n, 2 do
    local y = points[i]
    if y < ymin then ymin = y end
    if y > ymax then ymax = y end
  end
  local xs = self.xs
  local y0, y1 = cells_between(ymin, ymax, self.h)
  for y = y0, y1 do
    local sy = y - 0.5
    local k = 0
    local px, py = points[n - 1], points[n]
    for i = 1, n, 2 do
      local qx, qy = points[i], points[i + 1]
      if (py <= sy and qy > sy) or (qy <= sy and py > sy) then
        k = k + 1
        xs[k] = px + (sy - py) * (qx - px) / (qy - py)
      end
      px, py = qx, qy
    end
    for i = 2, k do                                  -- insertion sort: k is small
      local x, j = xs[i], i - 1
      while j >= 1 and xs[j] > x do xs[j + 1] = xs[j]; j = j - 1 end
      xs[j + 1] = x
    end
    for i = 1, k - 1, 2 do span(self, y, xs[i], xs[i + 1], v) end
  end
end

-- Every empty cell that touches a filled one (4 neighbours; 8 with `diagonal`) becomes v.
-- `of`: only cells next to that value count as filled (default: any non-zero value but v).
local function solid(cells, w, h, x, y, v, of)
  if x < 1 or y < 1 or x > w or y > h then return false end
  local c = cells[(y - 1) * w + x]
  if of then return c == of end
  return c > 0 and c ~= v
end
function Grid:outline(v, of, diagonal)
  local w, h, cells = self.w, self.h, self.cells
  -- mark with -1 first, so new outline cells do not grow the outline
  for y = 1, h do
    for x = 1, w do
      local i = (y - 1) * w + x
      if cells[i] == 0 and (solid(cells, w, h, x - 1, y, v, of) or solid(cells, w, h, x + 1, y, v, of)
        or solid(cells, w, h, x, y - 1, v, of) or solid(cells, w, h, x, y + 1, v, of)
        or (diagonal and (solid(cells, w, h, x - 1, y - 1, v, of) or solid(cells, w, h, x + 1, y - 1, v, of)
          or solid(cells, w, h, x - 1, y + 1, v, of) or solid(cells, w, h, x + 1, y + 1, v, of)))) then
        cells[i] = -1
      end
    end
  end
  for i = 1, w * h do if cells[i] == -1 then cells[i] = v end end
end

-- Cells that are not empty
function Grid:filled()
  local n, cells = 0, self.cells
  for i = 1, self.w * self.h do if cells[i] ~= 0 then n = n + 1 end end
  return n
end

-- One draw call: a SpriteBatch over `image`, each cell a `quad` scaled to the cell size and
-- tinted with its colour. The batch is made once and refilled by draw().
function Grid:batch(image, quad)
  local _, _, qw, qh = quad:getViewport()
  self.image, self.quad, self.qw, self.qh = image, quad, qw, qh
  self.sb = love.graphics.newSpriteBatch(image, self.w * self.h)
end

-- Draws the grid with its top-left corner at x, y (game pixels, rounded to whole pixels)
function Grid:draw(x, y)
  local g = love.graphics
  local cell, w, h, cells, palette = self.cell, self.w, self.h, self.cells, self.palette
  x, y = floor(x + 0.5), floor(y + 0.5)
  local count = 0
  if self.sb then
    local sb, quad, sx, sy = self.sb, self.quad, cell / self.qw, cell / self.qh
    sb:clear()
    for cy = 1, h do
      local row = (cy - 1) * w
      for cx = 1, w do
        local v = cells[row + cx]
        if v > 0 then
          local c = palette[v]
          sb:setColor(c[1], c[2], c[3], c[4] or 1)
          sb:add(quad, x + (cx - 1) * cell, y + (cy - 1) * cell, 0, sx, sy)
          count = count + 1
        end
      end
    end
    sb:setColor(1, 1, 1, 1)
    if count > 0 then
      local r, gg, b, a = g.getColor()
      g.setColor(1, 1, 1, 1)
      g.draw(sb)
      g.setColor(r, gg, b, a)
    end
  else
    local r, gg, b, a = g.getColor()
    for cy = 1, h do
      local row = (cy - 1) * w
      local cx = 1
      while cx <= w do
        local v = cells[row + cx]
        if v > 0 then
          local run = cx
          while run < w and cells[row + run + 1] == v do run = run + 1 end
          local c = palette[v]
          g.setColor(c[1], c[2], c[3], c[4] or 1)
          g.rectangle("fill", x + (cx - 1) * cell, y + (cy - 1) * cell, (run - cx + 1) * cell, cell)
          count = count + run - cx + 1
          cx = run + 1
        else
          cx = cx + 1
        end
      end
    end
    g.setColor(r, gg, b, a)
  end
  self.count = count
  return count
end

return M
