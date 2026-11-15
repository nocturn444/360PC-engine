-- procgen.templates: the room template data shape, checked and indexed.
--
-- A template is a plain table (what the level loader of objective 11 has to produce):
--   id        unique string
--   w, h      size in map cells (default 1, 1); a map cell is one screen of the minimap
--   type      "start", "boss", "normal" or any string of the game's (default "normal")
--   weight    whole number >= 0 (default 1): how often it is picked among its type
--   exits     array of { side = "left" | "right" | "up" | "down", offset = n, requires = { tag... },
--             tx = n, ty = n }
--             offset: which cell of that side, from 0 (rows from the top for left / right,
--             columns from the left for up / down; default 0). One exit per cell side.
--             requires: ability tags needed to use this exit (default none).
--             tx, ty: the tile of `grid` the body is in when it uses the exit (only for reach.check).
--   item      true, or { tx = n, ty = n }: the room has a place for an ability item (optional)
--   tags      anything of the game's; never read here
--   grid      optional tile grid (grid.width, grid.height, grid:kind(tx, ty)): only reach.lua reads it
-- Anything else in the table is the game's and is left alone.
local type, tostring, floor = type, tostring, math.floor

local M = {}

M.sides = { "left", "right", "up", "down" }
M.opposite = { left = "right", right = "left", up = "down", down = "up" }
M.dx = { left = -1, right = 1, up = 0, down = 0 }
M.dy = { left = 0, right = 0, up = -1, down = 1 }

local function whole(v, min) return type(v) == "number" and v == floor(v) and v >= min end

-- The cell of the room an exit is in, as an offset from the room's top left cell (from 0)
function M.exit_cell(tpl, exit)
  local side, o = exit.side, exit.offset
  if side == "left" then return 0, o end
  if side == "right" then return tpl.w - 1, o end
  if side == "up" then return o, 0 end
  return o, tpl.h - 1
end

local function check(tpl, n, ids)
  if type(tpl) ~= "table" then error("procgen: template " .. n .. " is not a table", 3) end
  local id = tpl.id
  if type(id) ~= "string" or id == "" then error("procgen: template " .. n .. " needs a string id", 3) end
  if ids[id] then error("procgen: two templates have the id " .. id, 3) end
  local where = "procgen: template " .. id .. ": "
  if tpl.w == nil then tpl.w = 1 end
  if tpl.h == nil then tpl.h = 1 end
  if tpl.type == nil then tpl.type = "normal" end
  if tpl.weight == nil then tpl.weight = 1 end
  if not whole(tpl.w, 1) or not whole(tpl.h, 1) then error(where .. "w and h are whole numbers >= 1", 3) end
  if type(tpl.type) ~= "string" then error(where .. "type is a string", 3) end
  if not whole(tpl.weight, 0) then error(where .. "weight is a whole number >= 0", 3) end
  if tpl.exits == nil then tpl.exits = {} end
  if type(tpl.exits) ~= "table" then error(where .. "exits is an array", 3) end
  local used = {}
  for i = 1, #tpl.exits do
    local e = tpl.exits[i]
    if type(e) ~= "table" or not M.opposite[e.side] then
      error(where .. "exit " .. i .. " needs side = left, right, up or down", 3)
    end
    if e.offset == nil then e.offset = 0 end
    local span = (e.side == "left" or e.side == "right") and tpl.h or tpl.w
    if not whole(e.offset, 0) or e.offset >= span then
      error(where .. "exit " .. i .. ": offset is a whole number from 0 to " .. (span - 1), 3)
    end
    local key = e.side .. e.offset
    if used[key] then error(where .. "two exits on the " .. e.side .. " side at offset " .. e.offset, 3) end
    used[key] = true
    if e.requires == nil then e.requires = {} end
    if type(e.requires) ~= "table" then error(where .. "exit " .. i .. ": requires is an array of tags", 3) end
    for j = 1, #e.requires do
      if type(e.requires[j]) ~= "string" then error(where .. "exit " .. i .. ": tags are strings", 3) end
    end
  end
end

-- templates.new(list): checks every template, fills in the defaults (in place) and returns
-- the set the generator works on: { list = the array, by_id = { id = template },
-- types = the types in order of first appearance, has_items = some template has `item` }.
-- The order of the list is part of the result of a generation: keep it stable.
function M.new(list)
  if type(list) == "table" and list.is_template_set then return list end
  if type(list) ~= "table" or #list == 0 then error("procgen: templates is a non-empty array", 2) end
  local set = { is_template_set = true, list = {}, by_id = {}, types = {}, has_items = false }
  local seen = {}
  for i = 1, #list do
    local tpl = list[i]
    check(tpl, i, set.by_id)
    set.list[i] = tpl
    set.by_id[tpl.id] = tpl
    if not seen[tpl.type] then
      seen[tpl.type] = true
      set.types[#set.types + 1] = tpl.type
    end
    if tpl.item then set.has_items = true end
  end
  return set
end

return M
