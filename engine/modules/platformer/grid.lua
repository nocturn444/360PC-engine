-- platformer.grid: the collision grid the module reads, and a helper that builds one by hand.
--
-- The module only asks a grid for four things, so a level loader can hand over its own object:
--   grid.width, grid.height   size in tiles
--   grid.tile_size            size of a (square) tile, in pixels
--   grid:kind(tx, ty)         "solid", "one_way" or nil; tx is 1..width, ty is 1..height
-- Tile (1, 1) is the top left one: it covers the pixels 0 <= x < tile_size, 0 <= y < tile_size
-- (plus the offset given to collision.add).
local type, floor = type, math.floor

local M = {}
local Grid = {}
Grid.__index = Grid

-- What a character of a string row, or a value of an array row, means. Anything else is empty.
M.legend = {
  ["#"] = "solid", ["="] = "one_way",
  [1] = "solid", [2] = "one_way",
  solid = "solid", one_way = "one_way",
}

local KINDS = { solid = true, one_way = true }

-- rows: the rows from top to bottom, each a string ("#..=") or an array ({ 1, 0, 0, 2 }).
-- Short rows are padded with empty tiles.
-- opts: tile_size (default 16), legend (default M.legend: { [character or value] = kind })
function M.new(rows, opts)
  opts = opts or {}
  local legend = opts.legend or M.legend
  local width = 0
  for i = 1, #rows do
    if #rows[i] > width then width = #rows[i] end
  end
  local self = setmetatable({ width = width, height = #rows, tile_size = opts.tile_size or 16,
    cells = {} }, Grid)
  for ty = 1, #rows do
    local row = rows[ty]
    local text = type(row) == "string"
    for tx = 1, width do
      local v
      if text then v = row:sub(tx, tx) else v = row[tx] end
      local kind = v ~= nil and legend[v] or nil
      if kind ~= nil and not KINDS[kind] then
        error("grid: unknown collision kind " .. tostring(kind), 2)
      end
      self.cells[(ty - 1) * width + tx] = kind or false
    end
  end
  return self
end

function Grid:kind(tx, ty)
  if tx < 1 or ty < 1 or tx > self.width or ty > self.height then return nil end
  return self.cells[(ty - 1) * self.width + tx] or nil
end

-- kind: "solid", "one_way" or nil. Tiles already added to a world do not change: add the
-- grid again (collision.remove, then collision.add).
function Grid:set(tx, ty, kind)
  if tx < 1 or ty < 1 or tx > self.width or ty > self.height then error("grid: tile out of range", 2) end
  if kind ~= nil and not KINDS[kind] then error("grid: unknown collision kind " .. tostring(kind), 2) end
  self.cells[(ty - 1) * self.width + tx] = kind or false
end

-- The tile under a pixel position (it may be outside the grid).
function Grid:toTile(x, y)
  local size = self.tile_size
  return floor(x / size) + 1, floor(y / size) + 1
end

return M
