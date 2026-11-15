-- platformer.collision: a grid's tiles as rectangles in a bump.lua world, and the filter that
-- makes one-way platforms work. See engine/modules/platformer/README.md.
--
-- Every rectangle this module adds is a table with a `kind` field ("solid" or "one_way"). A
-- game can add its own items with the same field (a moving platform, a crate): the filter
-- treats them like tiles.
local function find_bump()
  for _, name in ipairs({ "lib.bump.bump", "bump.bump", "bump" }) do
    local ok, lib = pcall(require, name)
    if ok and type(lib) == "table" and lib.newWorld then return lib end
  end
  error("platformer: bump.lua not found (copy lib/bump/ into the game folder)", 3)
end

local bump = find_bump()
local M = { bump = bump }

-- A body whose bottom is this close to a platform's top (pixels) stands on it.
local EPS = 1e-6

-- The grid as a list of rectangles, in pixels: { x, y, w, h, kind }. A horizontal run of tiles
-- of one kind is one rectangle; solid runs that sit exactly on top of each other (same columns)
-- are joined too, so a wall or a filled block is one rectangle. One-way runs are never joined
-- vertically: each one's top is a surface. ox, oy: where the grid's top left corner is (0, 0).
function M.rects(grid, ox, oy)
  ox, oy = ox or 0, oy or 0
  local size, width = grid.tile_size, grid.width
  local out, n = {}, 0
  local above = {}          -- solid runs of the row above, by first column and length
  for ty = 1, grid.height do
    local here = {}
    local tx = 1
    while tx <= width do
      local kind = grid:kind(tx, ty)
      if kind then
        local first = tx
        repeat tx = tx + 1 until tx > width or grid:kind(tx, ty) ~= kind
        local key = first * (width + 1) + (tx - first)
        local r = kind == "solid" and above[key] or nil
        if r then
          r.h = r.h + size
        else
          r = { x = ox + (first - 1) * size, y = oy + (ty - 1) * size, w = (tx - first) * size,
            h = size, kind = kind }
          n = n + 1
          out[n] = r
        end
        if kind == "solid" then here[key] = r end
      else
        tx = tx + 1
      end
    end
    above = here
  end
  return out
end

-- Adds the grid's rectangles to a bump world. Returns the list (for M.remove).
function M.add(world, grid, ox, oy)
  local list = M.rects(grid, ox, oy)
  for i = 1, #list do
    local r = list[i]
    world:add(r, r.x, r.y, r.w, r.h)
  end
  return list
end

function M.remove(world, list)
  for i = 1, #list do
    if world:hasItem(list[i]) then world:remove(list[i]) end
  end
end

-- A new bump world holding the grid's tiles. Returns the world and the list of rectangles.
-- opts: cell_size (bump's cell size, default 4 tiles), x, y (the grid's top left corner)
function M.newWorld(grid, opts)
  opts = opts or {}
  local world = bump.newWorld(opts.cell_size or grid.tile_size * 4)
  return world, M.add(world, grid, opts.x, opts.y)
end

-- The bump filter of a body (a table with y, h and world; see controller.lua):
--   kind "solid"     always blocks
--   kind "one_way"   blocks only a body that starts the move with its bottom at or above the
--                    platform's top, and is not dropping through (item.drop)
--   anything else    item.filter(item, other) if the body has one; otherwise ignored
function M.filter(item, other)
  local kind = other.kind
  if kind == "solid" then return "slide" end
  if kind == "one_way" then
    if item.drop then return nil end
    local _, top = item.world:getRect(other)
    if item.y + item.h <= top + EPS then return "slide" end
    return nil
  end
  local custom = item.filter
  if custom then return custom(item, other) end
  return nil
end

return M
