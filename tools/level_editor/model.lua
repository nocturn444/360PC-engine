-- The level editor's data: a level in the file format of engine/level.lua (docs/LEVELS.md),
-- edited in place, with undo, checks and the text written back. No love calls here: the
-- editor's window (main.lua) and the tests (tests/pc/level_editor_test.lua) both use it.
--
-- A level is the table the file holds: { format, version, tile_size, cell = { w, h },
-- tilesets, rooms }. A room: id, w, h (map cells), tiles_w, tiles_h, type, weight, tags,
-- fields, exits, item, entities, layers, collision (flat, 0 empty / 1 solid / 2 one-way).
local Save = require("engine.save")
local level = require("engine.level")

local floor, max, min = math.floor, math.max, math.min

local M = {}

M.EMPTY, M.SOLID, M.ONE_WAY = 0, 1, 2
M.SIDES = { "left", "right", "up", "down" }
local SIDE_ORDER = { left = 1, right = 2, up = 3, down = 4 }

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end
M.copy = copy

---------------------------------------------------------------------------
-- Levels and rooms
---------------------------------------------------------------------------

-- A new empty level: opts.tile_size (16), opts.cell_w (20), opts.cell_h (12) tiles per map cell.
function M.new_level(opts)
  opts = opts or {}
  return { format = level.FORMAT, version = level.VERSION, ldtk_version = "",
    tile_size = opts.tile_size or 16, cell = { w = opts.cell_w or 20, h = opts.cell_h or 12 },
    tilesets = {}, rooms = {} }
end

-- The level of a file's text, or nil and the reason (the checks of engine.level).
function M.from_text(text)
  local ok, why = level.from_text(text)       -- validates; its rooms get a grid we do not keep
  if not ok then return nil, why end
  local parsed, data = Save.parse(text)
  if not parsed then return nil, data end
  for _, room in ipairs(data.rooms) do
    room.tags = room.tags or {}
    room.fields = room.fields or {}
    room.type = room.type or "normal"
    room.weight = room.weight or 1
  end
  return data
end

-- The file's text (keys sorted: the same level gives the same bytes).
function M.to_text(data)
  local out = {}
  for k, v in pairs(data) do out[k] = v end
  out.rooms = {}
  for i, room in ipairs(data.rooms) do
    local r = {}
    for k, v in pairs(room) do if k ~= "grid" then r[k] = v end end
    out.rooms[i] = r
  end
  return Save.serialize(out) .. "\n"
end

function M.find_room(data, id)
  for i, room in ipairs(data.rooms) do if room.id == id then return room, i end end
  return nil
end

-- A room id not used yet: base, base_2, base_3...
function M.free_id(data, base)
  base = base or "Room"
  if not M.find_room(data, base) then return base end
  local n = 2
  while M.find_room(data, base .. "_" .. n) do n = n + 1 end
  return base .. "_" .. n
end

-- Adds an empty room of w x h map cells (with a solid border) after index `at` (default: at
-- the end). Returns the room.
function M.add_room(data, id, w, h, at)
  w, h = w or 1, h or 1
  local tw, th = w * data.cell.w, h * data.cell.h
  local room = { id = M.free_id(data, id), w = w, h = h, tiles_w = tw, tiles_h = th, type = "normal",
    weight = 1, tags = {}, fields = {}, exits = {}, entities = {}, layers = {}, collision = {} }
  for ty = 1, th do
    for tx = 1, tw do
      local border = tx == 1 or ty == 1 or tx == tw or ty == th
      room.collision[(ty - 1) * tw + tx] = border and M.SOLID or M.EMPTY
    end
  end
  table.insert(data.rooms, at and at + 1 or #data.rooms + 1, room)
  return room
end

function M.duplicate_room(data, room)
  local _, i = M.find_room(data, room.id)
  local c = copy(room)
  c.grid = nil
  c.id = M.free_id(data, room.id)
  for _, e in ipairs(c.entities) do e.iid = nil end
  M.fix_iids(data, c)
  table.insert(data.rooms, i + 1, c)
  return c
end

function M.remove_room(data, room)
  local _, i = M.find_room(data, room.id)
  if i then table.remove(data.rooms, i) end
  return i
end

-- Renames a room; false and the reason when the id is empty or taken.
function M.rename_room(data, room, id)
  id = tostring(id or ""):match("^%s*(.-)%s*$")
  if id == "" then return false, "a room needs an id" end
  if id ~= room.id and M.find_room(data, id) then return false, "another room is called " .. id end
  room.id = id
  return true
end

-- Moves a room in the list by delta (the order is part of what a seed generates).
function M.move_room(data, room, delta)
  local _, i = M.find_room(data, room.id)
  local j = i + delta
  if j < 1 or j > #data.rooms then return false end
  data.rooms[i], data.rooms[j] = data.rooms[j], data.rooms[i]
  return true
end

-- Resizes a room to w x h map cells. The top left part is kept; what falls outside (tiles,
-- exits, the item, entities) is dropped; new tiles are empty, and the new border is solid
-- where nothing was there before.
function M.resize_room(data, room, w, h)
  w, h = max(1, floor(w)), max(1, floor(h))
  if w == room.w and h == room.h then return false end
  local ow, oh = room.tiles_w, room.tiles_h
  local tw, th = w * data.cell.w, h * data.cell.h
  local old, new = room.collision, {}
  for ty = 1, th do
    for tx = 1, tw do
      local v
      if tx <= ow and ty <= oh then v = old[(ty - 1) * ow + tx] else v = M.EMPTY end
      if (tx > ow or ty > oh) and (tx == tw or ty == th) then v = M.SOLID end
      new[(ty - 1) * tw + tx] = v
    end
  end
  room.collision, room.w, room.h, room.tiles_w, room.tiles_h = new, w, h, tw, th
  local ts = data.tile_size
  local kept = {}
  for _, e in ipairs(room.exits) do
    -- kept while its border did not move and it is still inside
    local same = (e.side == "left" or e.side == "up") or (e.side == "right" and tw == ow)
      or (e.side == "down" and th == oh)
    if same and e.tx <= tw and e.ty <= th then kept[#kept + 1] = e end
  end
  room.exits = kept
  M.sort_exits(room)
  if room.item and (room.item.tx > tw or room.item.ty > th) then room.item = nil end
  local ents = {}
  for _, e in ipairs(room.entities) do
    if e.x + e.w <= tw * ts and e.y + e.h <= th * ts then ents[#ents + 1] = e end
  end
  room.entities = ents
  if room.props then
    local kept_props = {}
    for _, p in ipairs(room.props) do
      local pw, ph = p.w or 1, p.h or 1
      if p.tx + pw - 1 <= tw and p.ty + ph - 1 <= th then kept_props[#kept_props + 1] = p end
    end
    room.props = #kept_props > 0 and kept_props or nil
  end
  for _, layer in ipairs(room.layers) do
    local t, out = layer.tiles, {}
    for i = 1, #t, 5 do
      if t[i] < tw * ts and t[i + 1] < th * ts then
        for k = 0, 4 do out[#out + 1] = t[i + k] end
      end
    end
    layer.tiles = out
  end
  return true
end

---------------------------------------------------------------------------
-- Collision tiles
---------------------------------------------------------------------------

function M.inside(room, tx, ty) return tx >= 1 and ty >= 1 and tx <= room.tiles_w and ty <= room.tiles_h end

function M.get(room, tx, ty)
  if not M.inside(room, tx, ty) then return nil end
  return room.collision[(ty - 1) * room.tiles_w + tx]
end

-- Sets one tile; returns true if it changed.
function M.set(room, tx, ty, v)
  if not M.inside(room, tx, ty) then return false end
  local i = (ty - 1) * room.tiles_w + tx
  if room.collision[i] == v then return false end
  room.collision[i] = v
  return true
end

-- Every tile of the rectangle between two corners (in any order); returns how many changed.
function M.fill_rect(room, x1, y1, x2, y2, v)
  local n = 0
  for ty = max(1, min(y1, y2)), min(room.tiles_h, max(y1, y2)) do
    for tx = max(1, min(x1, x2)), min(room.tiles_w, max(x1, x2)) do
      if M.set(room, tx, ty, v) then n = n + 1 end
    end
  end
  return n
end

-- The 4-connected area of tiles like (tx, ty) set to v; returns how many changed.
function M.flood(room, tx, ty, v)
  local from = M.get(room, tx, ty)
  if from == nil or from == v then return 0 end
  local stack, n = { tx, ty }, 0
  while #stack > 0 do
    local y = table.remove(stack)
    local x = table.remove(stack)
    if M.get(room, x, y) == from then
      M.set(room, x, y, v)
      n = n + 1
      stack[#stack + 1] = x + 1; stack[#stack + 1] = y
      stack[#stack + 1] = x - 1; stack[#stack + 1] = y
      stack[#stack + 1] = x; stack[#stack + 1] = y + 1
      stack[#stack + 1] = x; stack[#stack + 1] = y - 1
    end
  end
  return n
end

-- The rows of a room as strings ("#" solid, "=" one-way, "." empty), top to bottom.
function M.rows(room)
  local out, ch = {}, { [0] = ".", [1] = "#", [2] = "=" }
  for ty = 1, room.tiles_h do
    local row = {}
    for tx = 1, room.tiles_w do row[tx] = ch[M.get(room, tx, ty)] or "." end
    out[ty] = table.concat(row)
  end
  return out
end

-- A grid for engine/modules/platformer and procgen.reach (the platformer grid interface).
local KINDS = { [1] = "solid", [2] = "one_way" }
function M.grid(data, room)
  return { width = room.tiles_w, height = room.tiles_h, tile_size = data.tile_size, cells = room.collision,
    kind = function(self, tx, ty)
      if tx < 1 or ty < 1 or tx > self.width or ty > self.height then return nil end
      return KINDS[self.cells[(ty - 1) * self.width + tx]]
    end }
end

---------------------------------------------------------------------------
-- Exits, the item, entities
---------------------------------------------------------------------------

-- The side a border tile is on; a corner tile answers its horizontal side unless `vertical`.
function M.exit_side(data, room, tx, ty, vertical)
  if not M.inside(room, tx, ty) then return nil end
  local l, r, u, d = tx == 1, tx == room.tiles_w, ty == 1, ty == room.tiles_h
  if vertical then
    if u then return "up" elseif d then return "down" end
  end
  if l then return "left" elseif r then return "right" elseif u then return "up" elseif d then return "down" end
  return nil
end

-- side and offset (the map cell along that side, from 0) of a door at a border tile
function M.side_offset(data, room, tx, ty, side)
  side = side or M.exit_side(data, room, tx, ty)
  if not side then return nil end
  if side == "left" or side == "right" then return side, floor((ty - 1) / data.cell.h) end
  return side, floor((tx - 1) / data.cell.w)
end

function M.sort_exits(room)
  table.sort(room.exits, function(a, b)
    if a.side ~= b.side then return SIDE_ORDER[a.side] < SIDE_ORDER[b.side] end
    return a.offset < b.offset
  end)
end

function M.exit_at(room, tx, ty)
  for i, e in ipairs(room.exits) do if e.tx == tx and e.ty == ty then return e, i end end
  return nil
end

-- Puts a door at a border tile, or takes away the one there. A door on the same side of the
-- same map cell moves here (one door per cell side). Returns "added", "moved", "removed", or
-- nil and the reason.
function M.toggle_exit(data, room, tx, ty, vertical)
  local here, i = M.exit_at(room, tx, ty)
  if here then table.remove(room.exits, i); return "removed" end
  local side, offset = M.side_offset(data, room, tx, ty, M.exit_side(data, room, tx, ty, vertical))
  if not side then return nil, "a door goes on the room's border" end
  for _, e in ipairs(room.exits) do
    if e.side == side and e.offset == offset then
      e.tx, e.ty = tx, ty
      return "moved"
    end
  end
  room.exits[#room.exits + 1] = { side = side, offset = offset, tx = tx, ty = ty, requires = {} }
  M.sort_exits(room)
  return "added"
end

-- "a, b" or {"a","b"} -> the exit's ability tags
function M.set_requires(exit, tags)
  local list = {}
  if type(tags) == "string" then
    for t in tags:gmatch("[^,%s]+") do list[#list + 1] = t end
  else
    for _, t in ipairs(tags or {}) do list[#list + 1] = t end
  end
  exit.requires = list
end

-- Places the ability item at (tx, ty), or removes it when it is already there.
function M.toggle_item(room, tx, ty)
  if room.item and room.item.tx == tx and room.item.ty == ty then room.item = nil; return "removed" end
  local had = room.item ~= nil
  room.item = { tx = tx, ty = ty, fields = room.item and room.item.fields or nil }
  return had and "moved" or "added"
end

-- Gives every entity of the room without one an iid unique in the level ("ed-1", "ed-2"...).
function M.fix_iids(data, room)
  local used, n = {}, 0
  for _, r in ipairs(data.rooms) do
    for _, e in ipairs(r.entities) do if e.iid then used[e.iid] = true end end
  end
  for _, e in ipairs(room.entities) do
    if not e.iid then
      repeat n = n + 1 until not used["ed-" .. n]
      e.iid = "ed-" .. n
      used[e.iid] = true
    end
  end
end

-- Adds an entity one tile big on tile (tx, ty). Returns it.
function M.add_entity(data, room, name, tx, ty)
  local ts = data.tile_size
  local e = { name = name, x = (tx - 1) * ts, y = (ty - 1) * ts, w = ts, h = ts, tx = tx, ty = ty, fields = {} }
  room.entities[#room.entities + 1] = e
  M.fix_iids(data, room)
  return e
end

-- The top-most entity under room pixel (px, py), and its index
function M.entity_at(room, px, py)
  for i = #room.entities, 1, -1 do
    local e = room.entities[i]
    if px >= e.x and py >= e.y and px < e.x + e.w and py < e.y + e.h then return e, i end
  end
  return nil
end

-- Moves an entity so its top left corner is on tile (tx, ty).
function M.move_entity(data, room, e, tx, ty)
  local ts = data.tile_size
  tx = max(1, min(room.tiles_w, tx))
  ty = max(1, min(room.tiles_h, ty))
  e.x, e.y = (tx - 1) * ts, (ty - 1) * ts
  e.tx = min(room.tiles_w, floor((e.x + e.w / 2) / ts) + 1)
  e.ty = min(room.tiles_h, floor((e.y + e.h / 2) / ts) + 1)
end

function M.remove_entity(room, e)
  for i, x in ipairs(room.entities) do
    if x == e then table.remove(room.entities, i); return true end
  end
  return false
end

-- "key=value, key=value" -> fields: numbers, true / false, otherwise text. nil and the reason
-- for a part without "=".
function M.parse_fields(text)
  local out = {}
  for part in tostring(text):gmatch("[^,]+") do
    local k, v = part:match("^%s*([%a_][%w_]*)%s*=%s*(.-)%s*$")
    if not k then
      if part:match("%S") then return nil, "write fields as key=value, separated by commas" end
    else
      if tonumber(v) then v = tonumber(v)
      elseif v == "true" then v = true
      elseif v == "false" then v = false
      else v = v:gsub('^"(.*)"$', "%1") end
      out[k] = v
    end
  end
  return out
end

function M.fields_text(fields)
  local keys = {}
  for k in pairs(fields or {}) do if type(k) == "string" then keys[#keys + 1] = k end end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = fields[k]
    if type(v) ~= "table" then parts[#parts + 1] = k .. "=" .. tostring(v) end
  end
  return table.concat(parts, ", ")
end

---------------------------------------------------------------------------
-- Props (docs/PROPS.md): the catalog entry has the type's defaults and limits
---------------------------------------------------------------------------
local function prop_size(prop) return prop.w or 1, prop.h or 1 end

-- The top-most prop covering a tile, and its index
function M.prop_at(room, tx, ty)
  for i = #(room.props or {}), 1, -1 do
    local p = room.props[i]
    local w, h = prop_size(p)
    if tx >= p.tx and ty >= p.ty and tx < p.tx + w and ty < p.ty + h then return p, i end
  end
  return nil
end

-- Adds a prop of a catalog type on tile (tx, ty), with the type's default size. Returns it.
function M.add_prop(room, type_, tx, ty, entry)
  if not entry then return nil, "no catalog entry for " .. tostring(type_) end
  local w, h = entry.w or 1, entry.h or 1
  local max_tx = max(1, room.tiles_w - w + 1)
  local max_ty = max(1, room.tiles_h - h + 1)
  local p = { type = type_, tx = max(1, min(max_tx, tx)), ty = max(1, min(max_ty, ty)), w = w, h = h }
  room.props = room.props or {}
  room.props[#room.props + 1] = p
  return p
end

-- Moves a prop so its top left corner is on tile (tx, ty), kept inside the room.
function M.move_prop(room, prop, tx, ty)
  local w, h = prop_size(prop)
  local nx = max(1, min(max(1, room.tiles_w - w + 1), tx))
  local ny = max(1, min(max(1, room.tiles_h - h + 1), ty))
  if nx == prop.tx and ny == prop.ty then return false end
  prop.tx, prop.ty = nx, ny
  return true
end

-- Resizes a prop to w x h tiles: only along its catalog entry's `resizable` axes, within
-- its min / max and inside the room. Returns true when the size changed.
function M.resize_prop(room, prop, entry, w, h)
  if not entry then return false end
  local res = entry.resizable
  local cw, ch = prop_size(prop)
  if res == "x" then h = ch
  elseif res == "y" then w = cw
  elseif res ~= "xy" then return false end
  local min_w = (entry.min and entry.min.w) or 1
  local min_h = (entry.min and entry.min.h) or 1
  local max_w = (entry.max and entry.max.w) or room.tiles_w
  local max_h = (entry.max and entry.max.h) or room.tiles_h
  max_w = min(max_w, room.tiles_w - prop.tx + 1)
  max_h = min(max_h, room.tiles_h - prop.ty + 1)
  w = max(min_w, min(max_w, floor(w or cw)))
  h = max(min_h, min(max_h, floor(h or ch)))
  if w == cw and h == ch then return false end
  prop.w, prop.h = w, h
  return true
end

-- Whether a value fits a catalog field spec; nil when it does, else the reason.
local function field_value_error(spec, value)
  local t = spec.type
  if t == "bool" then
    if type(value) ~= "boolean" then return "is true or false" end
  elseif t == "string" then
    if type(value) ~= "string" then return "is a string" end
  elseif t == "enum" then
    for _, option in ipairs(spec.options or {}) do if option == value then return nil end end
    return "is one of " .. table.concat(spec.options or {}, ", ")
  else
    if type(value) ~= "number" or value ~= value then return "is a number" end
    if t == "integer" and value ~= floor(value) then return "is a whole number" end
    if spec.min and value < spec.min then return "is >= " .. spec.min end
    if spec.max and value > spec.max then return "is <= " .. spec.max end
  end
  return nil
end

-- Sets one field of a prop, checked against its catalog entry. A value equal to the default
-- (or nil) is removed from the prop's fields. Returns true, or false and the reason.
function M.set_prop_field(prop, entry, key, value)
  local spec
  for _, f in ipairs(entry and entry.fields or {}) do if f.key == key then spec = f; break end end
  if not spec then return false, "the type has no field " .. tostring(key) end
  if value == nil or value == spec.default then
    if prop.fields then
      prop.fields[key] = nil
      if next(prop.fields) == nil then prop.fields = nil end
    end
    return true
  end
  local why = field_value_error(spec, value)
  if why then return false, "field " .. key .. " " .. why end
  prop.fields = prop.fields or {}
  prop.fields[key] = value
  return true
end

function M.remove_prop(room, prop)
  for i, p in ipairs(room.props or {}) do
    if p == prop then
      table.remove(room.props, i)
      if #room.props == 0 then room.props = nil end
      return true
    end
  end
  return false
end

---------------------------------------------------------------------------
-- Checks
---------------------------------------------------------------------------

-- The problems of one room, as a list of text: an exit whose tile is solid, a closed room,
-- exits not reached from each other with the jump `reach` (procgen.reach, if given).
function M.check_room(data, room, reach)
  local out = {}
  if #room.exits == 0 then out[#out + 1] = "no doors" end
  for _, e in ipairs(room.exits) do
    if M.get(room, e.tx, e.ty) == M.SOLID then
      out[#out + 1] = "the " .. e.side .. " door at " .. e.tx .. "," .. e.ty .. " is inside a wall"
    end
  end
  if room.item and M.get(room, room.item.tx, room.item.ty) == M.SOLID then out[#out + 1] = "the item is inside a wall" end
  if reach and #room.exits > 1 then
    local procgen_reach = require("engine.modules.procgen.reach")
    local tpl = { id = room.id, exits = room.exits, grid = M.grid(data, room) }
    local ok, why = procgen_reach.check(tpl, reach)
    if not ok then out[#out + 1] = (why:gsub("^template [^:]*: ", "")) end
  end
  return out
end

-- The problems of the whole level: { { room id or "", text }... }. Rooms that procgen needs:
-- a "start" room.
function M.check(data, reach)
  local out = {}
  local start = false
  for _, room in ipairs(data.rooms) do
    if room.type == "start" then start = true end
    for _, msg in ipairs(M.check_room(data, room, reach)) do out[#out + 1] = { room.id, msg } end
  end
  if #data.rooms > 0 and not start then out[#out + 1] = { "", "no room has type start (procgen needs one)" } end
  local ok, why = level.from_text(M.to_text(data))
  if not ok then out[#out + 1] = { "", why } end
  return out
end

---------------------------------------------------------------------------
-- Undo: snapshots of the whole level (rooms are small)
---------------------------------------------------------------------------
local History = {}
History.__index = History

function M.history(limit) return setmetatable({ undo = {}, redo = {}, limit = limit or 100 }, History) end

-- Call before a change: remembers the level as it is now.
function History:push(data, room_index)
  local s = self.undo
  s[#s + 1] = { rooms = copy(data.rooms), tilesets = copy(data.tilesets), at = room_index }
  if #s > self.limit then table.remove(s, 1) end
  self.redo = {}
end

local function swap(from, to, data, room_index)
  local snap = table.remove(from)
  if not snap then return nil end
  to[#to + 1] = { rooms = data.rooms, tilesets = data.tilesets, at = room_index }
  data.rooms, data.tilesets = snap.rooms, snap.tilesets
  return snap.at or 1
end

-- Each returns the room index to show, or nil when there is nothing to undo / redo.
function History:undo_step(data, room_index) return swap(self.undo, self.redo, data, room_index) end
function History:redo_step(data, room_index) return swap(self.redo, self.undo, data, room_index) end

return M
