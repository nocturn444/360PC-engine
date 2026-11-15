-- procgen.reach: does a hand-made room let a platformer character go from each exit to every
-- other one? A breadth-first search over the room's tile grid (the platformer grid interface:
-- width, height, grid:kind(tx, ty)) with the jump's reach in tiles, such as what
-- engine.modules.platformer params.reach() returns ({ jump_height_tiles, jump_distance_tiles }).
-- The generator takes every room as joined inside (graph.lua); run this over the templates
-- once (at load time, or in a tool over all the rooms) with the reach of each set of abilities,
-- and give the generator only the templates that pass, or exits `requires` for the ones that
-- need an ability.
--
-- The approximation, on purpose simple and a little generous:
--   * the body is one tile; headroom and the shape of the arc are not looked at;
--   * a tile is a place to stand when it is empty and the tile under it is solid or one-way;
--   * from a place to stand, the body reaches any other place to stand up to
--     floor(jump_height_tiles) rows higher and floor(jump_distance_tiles) columns away, and any
--     lower one with |dx| <= floor(jump_distance_tiles) + the rows it falls (solid tiles in
--     between are ignored);
--   * an exit is its tile (exit.tx, exit.ty). Coming in, the body is there and falls straight
--     down to the first place to stand (or jumps from there if it stands). Going out, the exit
--     tile counts as a place to stand to aim at, even in the air (doors up in a wall, a hole in
--     the ceiling).
-- It says no to rooms a real run cannot cross less often than it says yes to rooms a real run
-- can: tune the reach down a little (for example floor of 90%) to be safe.
local floor, abs, type = math.floor, math.abs, type

local M = {}

local function standable(grid, tx, ty)
  if tx < 1 or ty < 1 or tx > grid.width or ty > grid.height then return false end
  if grid:kind(tx, ty) ~= nil then return false end
  local below = grid:kind(tx, ty + 1)
  return below == "solid" or below == "one_way"
end

local function can_move(x1, y1, x2, y2, H, D)
  local dx, dy = abs(x2 - x1), y2 - y1
  if dy <= 0 then return -dy <= H and dx <= D end
  return dx <= D + dy
end

-- reach.from(template, r, e) -> { [exit index] = true } for the exits reached from exit e
function M.from(tpl, r, e)
  local grid = tpl.grid
  if not grid then error("procgen.reach: template " .. tostring(tpl.id) .. " has no grid", 2) end
  local H, D = floor(r.jump_height_tiles or 0), floor(r.jump_distance_tiles or 0)
  local exits = tpl.exits
  local start = exits[e]
  if type(start.tx) ~= "number" or type(start.ty) ~= "number" then
    error("procgen.reach: template " .. tostring(tpl.id) .. ": exit " .. e .. " needs tx and ty", 2)
  end
  -- Places to stand, as a list in row order
  local spots, index = {}, {}
  for ty = 1, grid.height do
    for tx = 1, grid.width do
      if standable(grid, tx, ty) then
        spots[#spots + 1] = { tx, ty }
        index[(ty - 1) * grid.width + tx] = #spots
      end
    end
  end
  local seen, queue = {}, {}
  local function push(i)
    if not seen[i] then seen[i] = true; queue[#queue + 1] = i end
  end
  local sx, sy = start.tx, start.ty
  local i0 = index[(sy - 1) * grid.width + sx]
  if i0 and standable(grid, sx, sy) then
    push(i0)
  else
    for ty = sy + 1, grid.height do                -- fall straight down
      if grid:kind(sx, ty) == "solid" then break end
      local i = index[(ty - 1) * grid.width + sx]
      if i then push(i); break end
    end
    -- or jump from where it came in (a door below, or a ledge it hangs at)
    for i = 1, #spots do
      if can_move(sx, sy, spots[i][1], spots[i][2], H, D) and spots[i][2] <= sy then push(i) end
    end
  end
  local head = 1
  while head <= #queue do
    local s = spots[queue[head]]
    head = head + 1
    for i = 1, #spots do
      if not seen[i] then
        local o = spots[i]
        if can_move(s[1], s[2], o[1], o[2], H, D) then push(i) end
      end
    end
  end
  local out = { [e] = true }
  for x = 1, #exits do
    local ex = exits[x]
    if x ~= e and type(ex.tx) == "number" then
      for q = 1, #queue do
        local s = spots[queue[q]]
        if can_move(s[1], s[2], ex.tx, ex.ty, H, D) then out[x] = true; break end
      end
    end
  end
  return out
end

-- reach.check(template, r) -> true, or false and a message naming the first pair of exits
-- (in exit order) where the second cannot be reached from the first
function M.check(tpl, r)
  if not tpl.grid then error("procgen.reach: template " .. tostring(tpl.id) .. " has no grid", 2) end
  local exits = tpl.exits
  for a = 1, #exits do
    local got = M.from(tpl, r, a)
    for b = 1, #exits do
      if not got[b] then
        return false, "template " .. tostring(tpl.id) .. ": exit " .. b .. " (" .. exits[b].side ..
          ") is not reached from exit " .. a .. " (" .. exits[a].side .. ")"
      end
    end
  end
  return true
end

return M
