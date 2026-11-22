-- 360PC-Engine level editor: rooms for engine/level.lua, edited with the mouse and played on
-- the spot. A PC tool (official LÖVE 11), never shipped to the console. docs/LEVEL_EDITOR.md.
--
--   love tools/level_editor <file.lvl> [--root <game folder>] [--cell 20x12] [--tile 16]
--
-- It opens the file (or starts a new level there), shows one room at a time, and writes the
-- same file format the LDtk converter writes, so engine.level and procgen read it as they are.
if love.filesystem and love.filesystem.getSource then
  local source = love.filesystem.getSource()
  package.path = source .. "/?.lua;" .. source .. "/../../?.lua;" .. source .. "/../../?/init.lua;" .. package.path
end
local M = require("model")
local engine_level = require("engine.level")
local Save = require("engine.save")

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local g = love.graphics

local E = {
  data = nil, path = nil, root = nil, room_i = 1, dirty = false,
  tool = "solid", zoom = 2, ox = 0, oy = 0,
  show_layers = true, show_grid = true,
  message = "", message_t = 0, problems = {},
  selected = nil,           -- { kind = "exit" | "entity" | "item", ref }
  prompt = nil,             -- { label, text, on_done }
  drag = nil, play = nil, images = nil, batches = nil,
  quit_armed = false, delete_armed = false,
  history = M.history(200),
  entity_names = { "Spawn", "Enemy", "Pickup", "Trigger" },
  entity_name = "Enemy",
  catalog = nil, catalog_by_id = nil, prop_categories = nil, prop_category_order = nil, prop_type = nil,
}

E.TOOLS = {
  { id = "solid", key = "1", label = "Solid" },
  { id = "one_way", key = "2", label = "One-way" },
  { id = "erase", key = "3", label = "Erase" },
  { id = "exit", key = "4", label = "Door" },
  { id = "item", key = "5", label = "Item" },
  { id = "entity", key = "6", label = "Entity" },
  { id = "select", key = "7", label = "Select" },
  { id = "props", key = "8", label = "Props" },
}
local TILE_VALUE = { solid = M.SOLID, one_way = M.ONE_WAY, erase = M.EMPTY }
local LEFT_W, RIGHT_W, TOP_H, BOTTOM_H = 210, 250, 34, 26
local TYPES = { "normal", "start", "boss", "item", "shop", "secret" }

local COLORS = {
  bg = { 0.10, 0.11, 0.14 }, panel = { 0.15, 0.16, 0.20 }, text = { 0.90, 0.92, 0.95 },
  dim = { 0.55, 0.58, 0.65 }, button = { 0.25, 0.27, 0.34 }, accent = { 0.98, 0.80, 0.30 }, bad = { 1.0, 0.45, 0.40 },
  solid = { 0.42, 0.47, 0.58 }, one_way = { 0.35, 0.75, 0.55 }, empty = { 0.06, 0.07, 0.09 },
  grid = { 1, 1, 1, 0.06 }, cell = { 1, 1, 1, 0.22 }, exit = { 0.30, 0.65, 1.0 },
  item = { 1.0, 0.85, 0.20 }, entity = { 0.95, 0.45, 0.80 }, player = { 0.98, 0.90, 0.52 },
}
local function color(c, a) g.setColor(c[1], c[2], c[3], a or c[4] or 1) end

---------------------------------------------------------------------------
-- Files
---------------------------------------------------------------------------
local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write_file(path, text)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "wb")
  if not f then return false, err end
  f:write(text)
  f:close()
  local old = read_file(path)
  if old then
    local b = io.open(path .. ".bak", "wb")
    if b then b:write(old); b:close() end
  end
  os.remove(path)
  local ok, rerr = os.rename(tmp, path)
  if not ok then return false, rerr end
  return true
end

local function dirname(path) return (path:match("^(.*)[/\\][^/\\]*$")) or "." end

-- The game folder of a level file: the nearest folder up from it with a game.lua or main.lua
-- (tileset paths are relative to it, docs/LEVELS.md), else the file's own folder.
function E.find_root(path)
  local dir = dirname(path)
  local d = dir
  for _ = 1, 8 do
    if read_file(d .. "/game.lua") or read_file(d .. "/main.lua") then return d end
    local up = dirname(d)
    if up == d then break end
    d = up
  end
  return dir
end

function E.say(text, bad)
  E.message, E.message_bad, E.message_t = text, bad, 6
end

function E.room() return E.data.rooms[E.room_i] end

-- the tilesets' images, read with io (the root is outside LÖVE's file system)
function E.load_images()
  E.images, E.batches = nil, nil
  if #E.data.tilesets == 0 then return end
  local images = { tilesets = E.data.tilesets, quads = {} }
  for i, ts in ipairs(E.data.tilesets) do
    local bytes = read_file(E.root .. "/" .. ts.path)
    local ok, img = false, nil
    if bytes and love.filesystem.newFileData then
      ok, img = pcall(function()
        return g.newImage(love.image.newImageData(love.filesystem.newFileData(bytes, ts.path)))
      end)
    end
    if not ok or not img then
      E.say("tileset " .. ts.path .. " not found under " .. E.root .. " (give --root): tiles hidden", true)
      return
    end
    img:setFilter("nearest", "nearest")
    images[i] = img
  end
  E.images = images
end

function E.rebuild_batches()
  E.batches = nil
  local room = E.room()
  if E.images and room and #room.layers > 0 then
    local ok, b = pcall(engine_level.batches, room, E.images)
    if ok then E.batches = b end
  end
end

function E.reach()
  local ok, platformer_params = pcall(require, "engine.modules.platformer.params")
  if not ok then return nil end
  local r = platformer_params.reach(platformer_params.new(), { tile_size = E.data.tile_size })
  return { jump_height_tiles = floor(r.jump_height_tiles * 0.9), jump_distance_tiles = floor(r.jump_distance_tiles * 0.9) }
end

function E.recheck()
  local ok, problems = pcall(M.check, E.data, E.reach())
  E.problems = ok and problems or { { "", tostring(problems) } }
end

-- The props catalog tools/props_catalog.lua writes (docs/PROPS.md). Without it the editor
-- keeps a room's props as they are and has no Props tool.
function E.load_catalog(path)
  E.catalog, E.catalog_by_id, E.prop_categories, E.prop_category_order, E.prop_type = nil, nil, nil, nil, nil
  if not path then return end
  local text = read_file(path)
  if not text then E.say("props catalog not found: " .. path, true); return end
  local ok, data = Save.parse(text)
  if not ok or type(data) ~= "table" or data.format ~= "360pc-props-catalog" then
    E.say(path .. " is not a props catalog (tools/props_catalog.lua)", true); return
  end
  if data.version ~= 1 then E.say(path .. ": catalog version " .. tostring(data.version) .. ", this editor reads version 1", true); return end
  if type(data.types) ~= "table" then E.say(path .. ": the catalog has no types", true); return end
  local by_id, categories, order = {}, {}, {}
  for _, entry in ipairs(data.types) do
    if type(entry) == "table" and type(entry.id) == "string" then
      by_id[entry.id] = entry
      local category = entry.category or "prop"
      if not categories[category] then categories[category] = {}; order[#order + 1] = category end
      categories[category][#categories[category] + 1] = entry
      if not E.prop_type then E.prop_type = entry.id end
    end
  end
  E.catalog, E.catalog_by_id, E.prop_categories, E.prop_category_order = data, by_id, categories, order
  E.say("props catalog: " .. #data.types .. " types from " .. path)
end

function E.open(path, opts)
  opts = opts or {}
  E.path = path
  E.root = opts.root or E.find_root(path)
  local text = read_file(path)
  if text then
    local data, why = M.from_text(text)
    if not data then
      E.data = M.new_level(opts)
      M.add_room(E.data, "Start", 1, 1).type = "start"
      E.say("could not open " .. path .. ": " .. tostring(why) .. " (saving will replace it)", true)
    else
      E.data = data
      E.say("opened " .. path .. ": " .. #data.rooms .. " rooms")
    end
  else
    E.data = M.new_level(opts)
    M.add_room(E.data, "Start", 1, 1).type = "start"
    E.say("new level: " .. path .. " (Ctrl+S saves it)")
  end
  if #E.data.rooms == 0 then M.add_room(E.data, "Start", 1, 1).type = "start" end
  for _, room in ipairs(E.data.rooms) do
    for _, e in ipairs(room.entities) do
      local known = false
      for _, n in ipairs(E.entity_names) do if n == e.name then known = true end end
      if not known then E.entity_names[#E.entity_names + 1] = e.name end
    end
  end
  E.room_i, E.dirty, E.selected = 1, false, nil
  E.history = M.history(200)
  E.load_catalog(opts.props)
  E.load_images()
  E.show_room(1)
end

function E.save(path)
  path = path or E.path
  local ok, err = write_file(path, M.to_text(E.data))
  if ok then
    E.path, E.dirty = path, false
    E.say("saved " .. path)
  else
    E.say("could not save " .. path .. ": " .. tostring(err), true)
  end
  return ok
end

---------------------------------------------------------------------------
-- Changes (each one can be undone)
---------------------------------------------------------------------------
function E.begin_change()
  E.history:push(E.data, E.room_i)
  E.dirty = true
end

function E.changed()
  E.dirty = true
  E.recheck()
end

function E.show_room(i)
  E.room_i = max(1, min(#E.data.rooms, i))
  E.selected = nil
  E.delete_armed = false
  E.fit()
  E.rebuild_batches()
  E.recheck()
end

function E.undo(redo)
  local i
  if redo then i = E.history:redo_step(E.data, E.room_i) else i = E.history:undo_step(E.data, E.room_i) end
  if not i then E.say(redo and "nothing to redo" or "nothing to undo"); return end
  E.dirty = true
  E.room_i = max(1, min(#E.data.rooms, i))
  E.selected = nil
  E.rebuild_batches()
  E.recheck()
  E.say(redo and "redone" or "undone")
end

---------------------------------------------------------------------------
-- View
---------------------------------------------------------------------------
function E.view_rect()
  local w, h = g.getDimensions()
  return LEFT_W, TOP_H, w - LEFT_W - RIGHT_W, h - TOP_H - BOTTOM_H
end

function E.fit()
  local room = E.room()
  if not room then return end
  local vx, vy, vw, vh = E.view_rect()
  local ts = E.data.tile_size
  local z = min((vw - 20) / (room.tiles_w * ts), (vh - 20) / (room.tiles_h * ts))
  E.zoom = max(0.25, z >= 1 and floor(z) or z)
  E.ox = floor(vx + (vw - room.tiles_w * ts * E.zoom) / 2)
  E.oy = floor(vy + (vh - room.tiles_h * ts * E.zoom) / 2)
end

-- screen -> room pixels and tile (from 1)
function E.to_room(sx, sy)
  local px, py = (sx - E.ox) / E.zoom, (sy - E.oy) / E.zoom
  local ts = E.data.tile_size
  return px, py, floor(px / ts) + 1, floor(py / ts) + 1
end

function E.in_view(sx, sy)
  local vx, vy, vw, vh = E.view_rect()
  return sx >= vx and sy >= vy and sx < vx + vw and sy < vy + vh
end

---------------------------------------------------------------------------
-- Tools
---------------------------------------------------------------------------
local function shift() return love.keyboard.isDown("lshift", "rshift") end
local function ctrl() return love.keyboard.isDown("lctrl", "rctrl", "lgui", "rgui") end

function E.set_tool(id)
  E.tool = id
  E.selected = nil
  if id == "entity" then E.say("Entity: click to place a " .. E.entity_name .. "; N picks another name") end
  if id == "exit" then E.say("Door: click a border tile; Shift on a corner makes it up/down; right click removes") end
  if id == "props" then
    if E.catalog then E.say("Props: pick a type, click to place, drag to move; [ and ] resize; right click removes")
    else E.say("Props need a catalog: run with --props <props_catalog.lvl>", true) end
  end
end

-- a press in the room view
function E.press(sx, sy, button)
  local room = E.room()
  local px, py, tx, ty = E.to_room(sx, sy)
  local value = TILE_VALUE[E.tool]
  if value then
    if button == 2 then value = M.EMPTY end
    E.begin_change()
    if shift() then
      E.drag = { kind = "rect", x1 = tx, y1 = ty, x2 = tx, y2 = ty, value = value }
    else
      M.set(room, tx, ty, value)
      E.drag = { kind = "paint", value = value, lx = tx, ly = ty }
    end
    return
  end
  if not M.inside(room, tx, ty) then return end
  if E.tool == "props" then
    if not (E.catalog and E.prop_type) then E.say("Props need a catalog: run with --props <props_catalog.lvl>", true); return end
    local hit = M.prop_at(room, tx, ty)
    if button == 2 then
      if hit then
        E.begin_change()
        M.remove_prop(room, hit)
        if E.selected and E.selected.ref == hit then E.selected = nil end
        E.changed()
      end
      return
    end
    E.begin_change()
    if hit then
      E.selected = { kind = "prop", ref = hit }
      E.drag = { kind = "move_prop", ref = hit }
      E.changed()
    else
      local p = M.add_prop(room, E.prop_type, tx, ty, E.catalog_by_id[E.prop_type])
      if p then
        E.selected = { kind = "prop", ref = p }
        E.changed()
      else
        E.history:undo_step(E.data, E.room_i)
        E.history.redo = {}
        E.say("could not add the prop", true)
      end
    end
    return
  end
  if E.tool == "exit" then
    if button == 2 then
      if M.exit_at(room, tx, ty) then E.begin_change(); M.toggle_exit(E.data, room, tx, ty); E.changed() end
      return
    end
    E.begin_change()
    local what, why = M.toggle_exit(E.data, room, tx, ty, shift())
    if what then
      E.say("door " .. what)
      local e = M.exit_at(room, tx, ty)
      E.selected = e and { kind = "exit", ref = e } or nil
      E.changed()
    else
      E.history:undo_step(E.data, E.room_i)
      E.history.redo = {}
      E.say(why, true)
    end
  elseif E.tool == "item" then
    E.begin_change()
    if button == 2 then room.item = nil else M.toggle_item(room, tx, ty) end
    E.changed()
  elseif E.tool == "entity" then
    local hit = M.entity_at(room, px, py)
    E.begin_change()
    if button == 2 then
      if hit then M.remove_entity(room, hit) end
    elseif hit then
      E.selected = { kind = "entity", ref = hit }
      E.drag = { kind = "move", ref = hit }
    else
      local e = M.add_entity(E.data, room, E.entity_name, tx, ty)
      E.selected = { kind = "entity", ref = e }
    end
    E.changed()
  elseif E.tool == "select" then
    local hit = M.entity_at(room, px, py)
    if hit then
      E.begin_change()
      E.selected = { kind = "entity", ref = hit }
      E.drag = { kind = "move", ref = hit }
    elseif M.exit_at(room, tx, ty) then
      E.selected = { kind = "exit", ref = (M.exit_at(room, tx, ty)) }
    elseif room.item and room.item.tx == tx and room.item.ty == ty then
      E.selected = { kind = "item", ref = room.item }
    elseif M.prop_at(room, tx, ty) then
      E.selected = { kind = "prop", ref = (M.prop_at(room, tx, ty)) }
    else
      E.selected = nil
    end
  end
end

-- tiles on the line between two tiles (so a fast stroke leaves no gaps)
local function line(x0, y0, x1, y1, fn)
  local n = max(abs(x1 - x0), abs(y1 - y0))
  for i = 0, n do
    local t = n == 0 and 0 or i / n
    fn(floor(x0 + (x1 - x0) * t + 0.5), floor(y0 + (y1 - y0) * t + 0.5))
  end
end

function E.move(sx, sy)
  local d = E.drag
  if not d then return end
  local room = E.room()
  local _, _, tx, ty = E.to_room(sx, sy)
  if d.kind == "paint" then
    line(d.lx, d.ly, tx, ty, function(x, y) M.set(room, x, y, d.value) end)
    d.lx, d.ly = tx, ty
  elseif d.kind == "rect" then
    d.x2, d.y2 = tx, ty
  elseif d.kind == "move" then
    M.move_entity(E.data, room, d.ref, tx, ty)
  elseif d.kind == "move_prop" then
    M.move_prop(room, d.ref, tx, ty)
  elseif d.kind == "pan" then
    E.ox, E.oy = E.ox + sx - d.sx, E.oy + sy - d.sy
    d.sx, d.sy = sx, sy
  end
end

function E.release()
  local d = E.drag
  E.drag = nil
  if not d then return end
  if d.kind == "rect" then M.fill_rect(E.room(), d.x1, d.y1, d.x2, d.y2, d.value) end
  if d.kind ~= "pan" then E.changed() end
end

function E.flood_at_mouse()
  local value = TILE_VALUE[E.tool]
  if not value then E.say("F fills with the Solid, One-way or Erase tool"); return end
  local _, _, tx, ty = E.to_room(love.mouse.getPosition())
  E.begin_change()
  local n = M.flood(E.room(), tx, ty, value)
  E.changed()
  E.say(n .. " tiles filled")
end

---------------------------------------------------------------------------
-- Text prompts
---------------------------------------------------------------------------
function E.ask(label, text, on_done)
  E.prompt = { label = label, text = text or "", on_done = on_done, fresh = true }   -- typing replaces it
  if love.keyboard.setTextInput then love.keyboard.setTextInput(true) end
end

function E.room_action(what)
  local room = E.room()
  if what == "rename" then
    E.ask("Room id", room.id, function(t)
      E.begin_change()
      local ok, why = M.rename_room(E.data, room, t)
      if not ok then E.undo(); E.history.redo = {}; E.say(why, true) else E.changed() end
    end)
  elseif what == "type" then
    E.ask("Room type (normal, start, boss, treasure, shop, miniboss or the game's own)", room.type, function(t)
      t = t:lower():match("^%s*(.-)%s*$")
      if t == "" then return end
      E.begin_change(); room.type = t; E.changed()
    end)
  elseif what == "tags" then
    local tags = table.concat(room.tags, ", ")
    E.ask("Room tags (comma separated)", tags, function(t)
      E.begin_change()
      room.tags = {}
      for tag in t:gmatch("[^,%s]+") do room.tags[#room.tags + 1] = tag end
      E.changed()
    end)
  elseif what == "new" then
    E.begin_change()
    M.add_room(E.data, "Room", 1, 1, E.room_i)
    E.changed()
    E.show_room(E.room_i + 1)
  elseif what == "duplicate" then
    E.begin_change()
    M.duplicate_room(E.data, room)
    E.changed()
    E.show_room(E.room_i + 1)
  elseif what == "delete" then
    if #E.data.rooms == 1 then E.say("a level keeps at least one room", true); return end
    if not E.delete_armed then E.delete_armed = true; E.say("press again to delete room " .. room.id, true); return end
    E.begin_change()
    M.remove_room(E.data, room)
    E.changed()
    E.show_room(E.room_i)
    E.say("room deleted (Ctrl+Z brings it back)")
  elseif what == "up" or what == "down" then
    E.begin_change()
    if M.move_room(E.data, room, what == "up" and -1 or 1) then
      E.room_i = E.room_i + (what == "up" and -1 or 1)
    end
    E.changed()
  end
end

-- The value a prop field shows: its own value, or the catalog default.
function E.prop_field_value(prop, spec)
  local v = prop.fields and prop.fields[spec.key]
  if v == nil then v = spec.default end
  return v
end

-- One +/- step of a field: a number by 1, a bool toggled, an enum cycled.
function E.adjust_prop_field(prop, entry, spec, dir)
  local current = E.prop_field_value(prop, spec)
  local value
  if spec.type == "bool" then
    value = not current
  elseif spec.type == "enum" then
    local options = spec.options or {}
    local index
    for i, option in ipairs(options) do if option == current then index = i; break end end
    index = index or 1
    value = options[(index - 1 + dir) % #options + 1]
  elseif spec.type == "number" or spec.type == "integer" then
    value = current + dir
    if spec.type == "integer" then value = floor(value + 0.5) end
    if spec.min then value = max(spec.min, value) end
    if spec.max then value = min(spec.max, value) end
  else
    E.say("edit a string field with Enter", true)
    return
  end
  if value == current then return end
  E.begin_change()
  local ok, why = M.set_prop_field(prop, entry, spec.key, value)
  if not ok then
    E.history:undo_step(E.data, E.room_i)
    E.history.redo = {}
    E.say(why, true)
  else
    E.changed()
  end
end

-- Resizes the selected prop along its resizable axes: [ smaller, ] bigger; Shift picks the
-- other axis when it can resize both ways.
function E.resize_selected_prop(dir, other)
  local s = E.selected
  if not s or s.kind ~= "prop" then E.say("select a prop first", true); return end
  local entry = E.catalog_by_id and E.catalog_by_id[s.ref.type]
  if not entry then return end
  local res = entry.resizable
  if res ~= "x" and res ~= "y" and res ~= "xy" then E.say("this prop type has a fixed size", true); return end
  local vertical
  if res == "y" then vertical = true elseif res == "x" then vertical = false else vertical = other end
  local w, h = s.ref.w or 1, s.ref.h or 1
  if vertical then h = h + dir else w = w + dir end
  E.begin_change()
  if M.resize_prop(E.room(), s.ref, entry, w, h) then
    E.changed()
  else
    E.history:undo_step(E.data, E.room_i)
    E.history.redo = {}
  end
end

function E.edit_selected()
  local s = E.selected
  if not s then return end
  if s.kind == "exit" then
    E.ask("Abilities this door requires (comma separated, empty for none)", table.concat(s.ref.requires or {}, ", "),
      function(t) E.begin_change(); M.set_requires(s.ref, t); E.changed() end)
  elseif s.kind == "prop" then
    local entry = E.catalog_by_id and E.catalog_by_id[s.ref.type]
    if not entry then E.say("edit prop fields with --props <catalog>", true); return end
    E.ask("Prop fields (key=value, ...)", M.fields_text(s.ref.fields), function(t)
      local f, why = M.parse_fields(t)
      if not f then E.say(why, true); return end
      for key in pairs(f) do
        local spec
        for _, field in ipairs(entry and entry.fields or {}) do if field.key == key then spec = field; break end end
        if not spec then E.say("the type has no field " .. tostring(key), true); return end
      end
      E.begin_change()
      for key, value in pairs(f) do M.set_prop_field(s.ref, entry, key, value) end
      E.changed()
    end)
  else
    E.ask((s.kind == "entity" and s.ref.name or "Item") .. " fields (key=value, ...)", M.fields_text(s.ref.fields),
      function(t)
        local f, why = M.parse_fields(t)
        if not f then E.say(why, true); return end
        E.begin_change(); s.ref.fields = f; E.changed()
      end)
  end
end

function E.pick_entity_name()
  E.ask("Entity name (" .. table.concat(E.entity_names, ", ") .. ")", E.entity_name, function(t)
    t = t:match("^%s*(.-)%s*$")
    if t == "" then return end
    E.entity_name = t
    local known = false
    for _, n in ipairs(E.entity_names) do if n == t then known = true end end
    if not known then E.entity_names[#E.entity_names + 1] = t end
    if E.selected and E.selected.kind == "entity" then E.begin_change(); E.selected.ref.name = t; E.changed() end
    E.set_tool("entity")
  end)
end

---------------------------------------------------------------------------
-- Play test: a platformer body in the room, with the arrows / WASD and Space
---------------------------------------------------------------------------
function E.start_play()
  local ok, platformer = pcall(require, "engine.modules.platformer")
  if not ok then E.say("play test needs engine/modules/platformer and lib/bump: " .. tostring(platformer), true); return end
  local input = require("engine.input").new({ actions = {
    left = { keys = { "left", "a" }, buttons = { "dpleft" } },
    right = { keys = { "right", "d" }, buttons = { "dpright" } },
    down = { keys = { "down", "s" }, buttons = { "dpdown" } },
    jump = { keys = { "space", "up", "w", "z" }, buttons = { "a" } },
  } })
  local room, ts = E.room(), E.data.tile_size
  local grid = platformer.grid.new(M.rows(room), { tile_size = ts })
  local world = platformer.collision.newWorld(grid)
  -- where to start: an entity called Spawn / Player / Start, else the mouse, else the first door
  local sx, sy
  for _, e in ipairs(room.entities) do
    local n = e.name:lower()
    if n == "spawn" or n == "player" or n == "start" then sx, sy = e.x, e.y; break end
  end
  if not sx then
    local mx, my = love.mouse.getPosition()
    local px, py, tx, ty = E.to_room(mx, my)
    if M.get(room, tx, ty) == M.EMPTY then sx, sy = px - ts / 2, py - ts / 2
    elseif room.exits[1] then sx, sy = (room.exits[1].tx - 1) * ts, (room.exits[1].ty - 1) * ts
    else sx, sy = room.tiles_w * ts / 2, ts * 2 end
  end
  local w, h = floor(ts * 0.6), floor(ts * 0.85)
  local body = platformer.controller.new(world, { x = sx, y = sy, w = w, h = h })
  E.play = { input = input, body = body, acc = 0, dt = 1 / 60, start_x = sx, start_y = sy }
  E.say("play test: arrows / WASD, Space to jump, R back to the start, Esc or P to stop")
end

function E.update_play(dt)
  local p = E.play
  p.acc = min(p.acc + dt, 0.25)
  while p.acc >= p.dt do
    p.acc = p.acc - p.dt
    p.input:poll()
    p.input:step()
    p.body:step(p.input, p.dt)
    local ts, room = E.data.tile_size, E.room()
    if p.body.y > (room.tiles_h + 4) * ts then p.body:teleport(p.start_x, p.start_y) end
  end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
local function button(x, y, w, h, label, active)
  color(active and COLORS.accent or COLORS.button, active and 0.9 or 1)
  g.rectangle("fill", x, y, w, h)
  color(active and COLORS.bg or COLORS.text)
  g.print(label, x + 6, y + (h - 14) / 2)
end

E.buttons = {}
local function hot(id, x, y, w, h, fn) E.buttons[#E.buttons + 1] = { id = id, x = x, y = y, w = w, h = h, fn = fn } end

function E.draw_room()
  local room, ts, z = E.room(), E.data.tile_size, E.zoom
  g.push()
  g.translate(E.ox, E.oy)
  g.scale(z, z)
  color(COLORS.empty)
  g.rectangle("fill", 0, 0, room.tiles_w * ts, room.tiles_h * ts)
  if E.show_layers and E.batches then
    g.setColor(1, 1, 1, 1)
    engine_level.draw(E.batches, 0, 0)
  end
  local alpha = (E.show_layers and E.batches) and 0.45 or 1
  local d = E.drag
  for ty = 1, room.tiles_h do
    for tx = 1, room.tiles_w do
      local v = M.get(room, tx, ty)
      if d and d.kind == "rect" and tx >= min(d.x1, d.x2) and tx <= max(d.x1, d.x2)
        and ty >= min(d.y1, d.y2) and ty <= max(d.y1, d.y2) then v = d.value end
      if v == M.SOLID then
        color(COLORS.solid, alpha)
        g.rectangle("fill", (tx - 1) * ts, (ty - 1) * ts, ts, ts)
      elseif v == M.ONE_WAY then
        color(COLORS.one_way, alpha)
        g.rectangle("fill", (tx - 1) * ts, (ty - 1) * ts, ts, ts * 0.3)
      end
    end
  end
  g.setLineWidth(1 / z)
  if E.show_grid then
    color(COLORS.grid)
    for tx = 1, room.tiles_w - 1 do g.line(tx * ts, 0, tx * ts, room.tiles_h * ts) end
    for ty = 1, room.tiles_h - 1 do g.line(0, ty * ts, room.tiles_w * ts, ty * ts) end
  end
  color(COLORS.cell)                    -- map cell borders
  for cx = 1, room.w - 1 do local x = cx * E.data.cell.w * ts; g.line(x, 0, x, room.tiles_h * ts) end
  for cy = 1, room.h - 1 do local y = cy * E.data.cell.h * ts; g.line(0, y, room.tiles_w * ts, y) end
  for _, p in ipairs(room.props or {}) do
    local entry = E.catalog_by_id and E.catalog_by_id[p.type]
    local w, h = p.w or 1, p.h or 1
    local c = (entry and entry.color) or { 0.65, 0.65, 0.72 }
    local sel = E.selected and E.selected.ref == p
    g.setColor(c[1], c[2], c[3], sel and 0.85 or 0.55)
    g.rectangle("fill", (p.tx - 1) * ts, (p.ty - 1) * ts, w * ts, h * ts)
    color(sel and COLORS.accent or COLORS.text, 0.85)
    g.rectangle("line", (p.tx - 1) * ts + 0.5, (p.ty - 1) * ts + 0.5, w * ts - 1, h * ts - 1)
    if entry and entry.glyph and entry.glyph ~= "" then
      color(COLORS.bg, 0.9)
      g.print(entry.glyph, (p.tx - 1) * ts + 2, (p.ty - 1) * ts + 1)
    end
  end
  for _, e in ipairs(room.exits) do
    local sel = E.selected and E.selected.ref == e
    color(sel and COLORS.accent or COLORS.exit)
    g.rectangle("fill", (e.tx - 1) * ts + 2, (e.ty - 1) * ts + 2, ts - 4, ts - 4)
    if e.requires and #e.requires > 0 then
      color(COLORS.bad)
      g.rectangle("line", (e.tx - 1) * ts + 1, (e.ty - 1) * ts + 1, ts - 2, ts - 2)
    end
  end
  if room.item then
    color(E.selected and E.selected.ref == room.item and COLORS.accent or COLORS.item)
    g.circle("fill", (room.item.tx - 0.5) * ts, (room.item.ty - 0.5) * ts, ts * 0.35)
  end
  for _, e in ipairs(room.entities) do
    local sel = E.selected and E.selected.ref == e
    color(sel and COLORS.accent or COLORS.entity, 0.85)
    g.rectangle("line", e.x + 1, e.y + 1, e.w - 2, e.h - 2)
    g.rectangle("fill", e.x + e.w / 2 - 2, e.y + e.h / 2 - 2, 4, 4)
  end
  if E.play then
    local b = E.play.body
    color(COLORS.player)
    g.rectangle("fill", b.x, b.y, b.w, b.h)
  end
  g.setLineWidth(1)
  g.pop()
  -- names of entities, in screen pixels
  if z >= 1.5 then
    color(COLORS.text, 0.8)
    for _, e in ipairs(room.entities) do g.print(e.name, E.ox + e.x * z, E.oy + (e.y + e.h) * z) end
  end
  -- the tile under the mouse
  local mx, my = love.mouse.getPosition()
  if not E.play and E.in_view(mx, my) then
    local _, _, tx, ty = E.to_room(mx, my)
    if M.inside(room, tx, ty) then
      color(COLORS.accent, 0.8)
      g.rectangle("line", E.ox + (tx - 1) * ts * z, E.oy + (ty - 1) * ts * z, ts * z, ts * z)
      E.hover = tx .. "," .. ty
    else
      E.hover = nil
    end
  end
end

function E.draw_left()
  local _, h = g.getDimensions()
  color(COLORS.panel)
  g.rectangle("fill", 0, 0, LEFT_W, h)
  color(COLORS.dim)
  g.print("ROOMS  (PgUp / PgDn)", 10, TOP_H + 4)
  local y = TOP_H + 22
  local room = E.room()
  local list_end = h - 230
  local first = max(1, E.room_i - floor((list_end - y) / 18) + 1)
  for i = first, #E.data.rooms do
    if y > list_end then break end
    local r = E.data.rooms[i]
    local label = r.id .. "  " .. r.w .. "x" .. r.h .. (r.type ~= "normal" and ("  " .. r.type) or "")
    if i == E.room_i then color(COLORS.accent, 0.25); g.rectangle("fill", 4, y - 1, LEFT_W - 8, 17) end
    color(i == E.room_i and COLORS.accent or COLORS.text)
    g.print(label, 10, y)
    hot("room" .. i, 4, y - 1, LEFT_W - 8, 17, function() E.show_room(i) end)
    y = y + 18
  end
  y = list_end + 8
  local bw = (LEFT_W - 24) / 3
  button(8, y, bw, 22, "New"); hot("new", 8, y, bw, 22, function() E.room_action("new") end)
  button(12 + bw, y, bw, 22, "Copy"); hot("dup", 12 + bw, y, bw, 22, function() E.room_action("duplicate") end)
  button(16 + 2 * bw, y, bw, 22, "Delete", E.delete_armed); hot("del", 16 + 2 * bw, y, bw, 22, function() E.room_action("delete") end)
  y = y + 28
  button(8, y, bw * 1.5 + 2, 22, "Move up"); hot("up", 8, y, bw * 1.5 + 2, 22, function() E.room_action("up") end)
  button(14 + bw * 1.5, y, bw * 1.5 + 2, 22, "Move down"); hot("down", 14 + bw * 1.5, y, bw * 1.5 + 2, 22, function() E.room_action("down") end)
  y = y + 32
  local function row(label, value, action, minus, plus)
    color(COLORS.dim); g.print(label, 10, y)
    color(COLORS.text); g.print(value, 70, y)
    if action then hot(label, 4, y - 2, LEFT_W - 60, 18, action) end
    if minus then
      button(LEFT_W - 52, y - 2, 20, 18, "-"); hot(label .. "-", LEFT_W - 52, y - 2, 20, 18, minus)
      button(LEFT_W - 28, y - 2, 20, 18, "+"); hot(label .. "+", LEFT_W - 28, y - 2, 20, 18, plus)
    end
    y = y + 22
  end
  local function resize(dw, dh)
    return function()
      E.begin_change()
      if M.resize_room(E.data, room, room.w + dw, room.h + dh) then E.changed(); E.fit(); E.rebuild_batches() end
    end
  end
  row("Id", room.id, function() E.room_action("rename") end)
  row("Type", room.type, function() E.room_action("type") end)
  row("Tags", #room.tags > 0 and table.concat(room.tags, ",") or "-", function() E.room_action("tags") end)
  row("Weight", tostring(room.weight), nil,
    function() if room.weight > 0 then E.begin_change(); room.weight = room.weight - 1; E.changed() end end,
    function() E.begin_change(); room.weight = room.weight + 1; E.changed() end)
  row("Width", room.w .. (room.w == 1 and " cell" or " cells"), nil, resize(-1, 0), resize(1, 0))
  row("Height", room.h .. (room.h == 1 and " cell" or " cells"), nil, resize(0, -1), resize(0, 1))
end

function E.draw_right()
  local w, h = g.getDimensions()
  local x = w - RIGHT_W
  color(COLORS.panel)
  g.rectangle("fill", x, 0, RIGHT_W, h)
  local y = TOP_H + 4
  if E.tool == "props" then
    if not E.catalog then
      color(COLORS.bad); g.print("PROPS need --props <catalog>", x + 10, y); y = y + 22
    else
      color(COLORS.dim); g.print("PROP TYPES (click to pick)", x + 10, y); y = y + 18
      for _, category in ipairs(E.prop_category_order or {}) do
        color(COLORS.dim); g.print(category, x + 12, y); y = y + 15
        for _, entry in ipairs(E.prop_categories[category]) do
          if y > h - BOTTOM_H - 150 then break end
          local label = entry.label or entry.id
          button(x + 16, y - 2, RIGHT_W - 36, 17, label, E.prop_type == entry.id)
          hot("prop" .. entry.id, x + 16, y - 2, RIGHT_W - 36, 17, function()
            E.prop_type = entry.id
            E.say("prop type: " .. label)
          end)
          y = y + 19
        end
        if y > h - BOTTOM_H - 150 then break end
      end
      y = y + 4
    end
  end
  local s = E.selected
  color(COLORS.dim); g.print("SELECTED  (Enter edits)", x + 10, y); y = y + 18
  color(COLORS.text)
  if not s then
    g.print("nothing", x + 10, y); y = y + 18
  elseif s.kind == "exit" then
    g.print("door " .. s.ref.side .. " #" .. s.ref.offset .. " at " .. s.ref.tx .. "," .. s.ref.ty, x + 10, y); y = y + 18
    g.printf("requires: " .. (#(s.ref.requires or {}) > 0 and table.concat(s.ref.requires, ", ") or "nothing"), x + 10, y, RIGHT_W - 20)
    y = y + 34
  elseif s.kind == "prop" then
    local entry = E.catalog_by_id and E.catalog_by_id[s.ref.type]
    local label = entry and entry.label or s.ref.type
    g.print(label .. " at " .. s.ref.tx .. "," .. s.ref.ty .. "  " .. (s.ref.w or 1) .. "x" .. (s.ref.h or 1), x + 10, y)
    y = y + 18
    for _, spec in ipairs(entry and entry.fields or {}) do
      if y > h - BOTTOM_H - 90 then break end
      local value = E.prop_field_value(s.ref, spec)
      color(COLORS.dim); g.print(spec.key, x + 10, y)
      color(COLORS.text); g.print(tostring(value), x + 110, y)
      if spec.type ~= "string" then
        button(x + RIGHT_W - 58, y - 2, 20, 17, "-")
        hot("pf" .. spec.key .. "-", x + RIGHT_W - 58, y - 2, 20, 17,
          function() E.adjust_prop_field(s.ref, entry, spec, -1) end)
        button(x + RIGHT_W - 34, y - 2, 20, 17, "+")
        hot("pf" .. spec.key .. "+", x + RIGHT_W - 34, y - 2, 20, 17,
          function() E.adjust_prop_field(s.ref, entry, spec, 1) end)
      end
      y = y + 20
    end
    if entry and (entry.resizable == "x" or entry.resizable == "y" or entry.resizable == "xy") then
      color(COLORS.dim); g.print("[ / ] resize" .. (entry.resizable == "xy" and " (Shift: other axis)" or ""), x + 10, y)
      y = y + 16
    end
    y = y + 4
  else
    local name = s.kind == "entity" and s.ref.name or "item"
    g.print(name .. " at " .. s.ref.tx .. "," .. s.ref.ty, x + 10, y); y = y + 18
    g.printf(M.fields_text(s.ref.fields) ~= "" and M.fields_text(s.ref.fields) or "no fields", x + 10, y, RIGHT_W - 20)
    y = y + 34
  end
  y = y + 8
  color(COLORS.dim)
  g.print("CHECKS (" .. #E.problems .. ")", x + 10, y); y = y + 18
  if #E.problems == 0 then color(COLORS.one_way); g.print("all good", x + 10, y) end
  for _, p in ipairs(E.problems) do
    if y > h - BOTTOM_H - 40 then break end
    local mine = p[1] == E.room().id
    color(mine and COLORS.bad or COLORS.dim)
    local text = (p[1] ~= "" and (p[1] .. ": ") or "") .. p[2]
    local _, lines = g.getFont():getWrap(text, RIGHT_W - 20)
    g.printf(text, x + 10, y, RIGHT_W - 20)
    local found
    for i, r in ipairs(E.data.rooms) do if r.id == p[1] then found = i end end
    local lh = 15 * max(1, #lines)
    if found then hot("problem" .. y, x, y, RIGHT_W, lh, function() E.show_room(found) end) end
    y = y + lh + 4
  end
end

function E.draw_bars()
  local w, h = g.getDimensions()
  color(COLORS.panel)
  g.rectangle("fill", 0, 0, w, TOP_H)
  local x = 8
  for _, t in ipairs(E.TOOLS) do
    local label = t.key .. " " .. t.label
    local bw = g.getFont():getWidth(label) + 14
    button(x, 5, bw, 24, label, E.tool == t.id)
    hot("tool" .. t.id, x, 5, bw, 24, function() E.set_tool(t.id) end)
    x = x + bw + 4
  end
  local file = (E.path or "?") .. (E.dirty and "  *" or "")
  color(COLORS.dim)
  g.print(file, w - g.getFont():getWidth(file) - 10, 10)
  color(COLORS.panel)
  g.rectangle("fill", 0, h - BOTTOM_H, w, BOTTOM_H)
  if E.message_t > 0 then
    color(E.message_bad and COLORS.bad or COLORS.text)
    g.print(E.message, 10, h - BOTTOM_H + 6)
  else
    color(COLORS.dim)
    g.print("Shift+drag rectangle  F fill  right click erase  wheel zoom  middle drag pan  P play  L layers  G grid  "
      .. "Ctrl+Z / Ctrl+Y  Ctrl+S save", 10, h - BOTTOM_H + 6)
  end
  if E.hover then
    color(COLORS.dim)
    g.print(E.hover, w - RIGHT_W - 60, h - BOTTOM_H + 6)
  end
end

function E.draw_prompt()
  local p = E.prompt
  local w, h = g.getDimensions()
  g.setColor(0, 0, 0, 0.6)
  g.rectangle("fill", 0, 0, w, h)
  local bw = min(700, w - 40)
  local x, y = (w - bw) / 2, h / 2 - 40
  color(COLORS.panel)
  g.rectangle("fill", x, y, bw, 80)
  color(COLORS.dim)
  g.print(p.label .. "   (Enter accepts, Esc cancels)", x + 12, y + 10)
  color(COLORS.text)
  if p.fresh and p.text ~= "" then
    color(COLORS.accent, 0.3)
    g.rectangle("fill", x + 10, y + 38, g.getFont():getWidth(p.text) + 4, 18)
  end
  color(COLORS.text)
  g.print(p.text .. "_", x + 12, y + 40)
end

---------------------------------------------------------------------------
-- LÖVE callbacks
---------------------------------------------------------------------------
local function parse_args(args)
  local path, opts = nil, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--root" then opts.root = args[i + 1]; i = i + 1
    elseif a == "--cell" then
      local cw, ch = tostring(args[i + 1]):match("^(%d+)x(%d+)$")
      opts.cell_w, opts.cell_h = tonumber(cw), tonumber(ch); i = i + 1
    elseif a == "--tile" then opts.tile_size = tonumber(args[i + 1]); i = i + 1
    elseif a == "--props" then opts.props = args[i + 1]; i = i + 1
    elseif not a:match("^%-") and not path then path = a end
    i = i + 1
  end
  return path, opts
end
E.parse_args = parse_args

function love.load(args)
  if g.setDefaultFilter then g.setDefaultFilter("nearest", "nearest") end
  if love.keyboard.setKeyRepeat then love.keyboard.setKeyRepeat(true) end
  local path, opts = parse_args(args or {})
  E.open(path or "level.lvl", opts)
end

function love.update(dt)
  if E.message_t > 0 then E.message_t = E.message_t - dt end
  if E.play then E.update_play(dt) end
end

function love.draw()
  E.buttons = {}
  color(COLORS.bg)
  g.rectangle("fill", 0, 0, g.getDimensions())
  E.draw_room()
  E.draw_left()
  E.draw_right()
  E.draw_bars()
  if E.prompt then E.draw_prompt() end
end

function love.mousepressed(x, y, button)
  if E.prompt or E.play then return end
  if button ~= 3 then E.quit_armed = false end
  for i = #E.buttons, 1, -1 do
    local b = E.buttons[i]
    if button == 1 and x >= b.x and y >= b.y and x < b.x + b.w and y < b.y + b.h then
      if b.id ~= "del" then E.delete_armed = false end
      b.fn()
      return
    end
  end
  if not E.in_view(x, y) then return end
  E.delete_armed = false
  if button == 3 or (button == 1 and love.keyboard.isDown("space")) then
    E.drag = { kind = "pan", sx = x, sy = y }
    return
  end
  E.press(x, y, button)
end

function love.mousemoved(x, y) E.move(x, y) end
function love.mousereleased() E.release() end

function love.wheelmoved(_, wy)
  if E.prompt then return end
  local mx, my = love.mouse.getPosition()
  local old = E.zoom
  local z = wy > 0 and old * 1.25 or old / 1.25
  z = max(0.25, min(12, z))
  E.ox = mx - (mx - E.ox) * z / old
  E.oy = my - (my - E.oy) * z / old
  E.zoom = z
end

function love.textinput(t)
  if E.prompt then
    if E.prompt.fresh then E.prompt.text, E.prompt.fresh = "", false end
    E.prompt.text = E.prompt.text .. t
  end
end

function love.resize() E.fit() end

local function key_tool(key)
  for _, t in ipairs(E.TOOLS) do if t.key == key then return t.id end end
end

function love.keypressed(key)
  if E.prompt then
    local p = E.prompt
    if key == "return" or key == "kpenter" then
      E.prompt = nil
      if love.keyboard.setTextInput then love.keyboard.setTextInput(false) end
      p.on_done(p.text)
    elseif key == "left" or key == "right" or key == "end" or key == "home" then
      p.fresh = false                      -- keep the text and add to it
    elseif key == "escape" then
      E.prompt = nil
      if love.keyboard.setTextInput then love.keyboard.setTextInput(false) end
    elseif key == "backspace" then
      if p.fresh then p.text = "" end
      p.fresh = false
      p.text = p.text:sub(1, -2)
      while #p.text > 0 and p.text:byte(-1) >= 128 and p.text:byte(-1) < 192 do p.text = p.text:sub(1, -2) end
    end
    return
  end
  if E.play then
    if key == "escape" or key == "p" then E.play = nil; E.say("play test stopped")
    elseif key == "r" then E.play.body:teleport(E.play.start_x, E.play.start_y) end
    return
  end
  if key ~= "delete" then E.delete_armed = false end
  if key ~= "escape" then E.quit_armed = false end
  if ctrl() then
    if key == "s" then
      if shift() then E.ask("Save as", E.path, function(t) if t ~= "" then E.save(t) end end) else E.save() end
    elseif key == "z" then E.undo(shift())
    elseif key == "y" then E.undo(true)
    elseif key == "n" then E.room_action("new")
    elseif key == "d" then E.room_action("duplicate")
    end
    return
  end
  local tool = key_tool(key)
  if tool then E.set_tool(tool); return end
  if key == "pageup" then E.show_room(E.room_i - 1)
  elseif key == "pagedown" or key == "tab" then E.show_room(E.room_i % #E.data.rooms + 1)
  elseif key == "[" or key == "]" then E.resize_selected_prop(key == "]" and 1 or -1, shift())
  elseif key == "f" then E.flood_at_mouse()
  elseif key == "p" then E.start_play()
  elseif key == "l" then E.show_layers = not E.show_layers
  elseif key == "g" then E.show_grid = not E.show_grid
  elseif key == "home" or key == "0" then E.fit()
  elseif key == "n" then E.pick_entity_name()
  elseif key == "return" or key == "kpenter" then E.edit_selected()
  elseif key == "delete" or key == "backspace" then
    local s = E.selected
    if s then
      E.begin_change()
      local room = E.room()
      if s.kind == "entity" then M.remove_entity(room, s.ref)
      elseif s.kind == "item" then room.item = nil
      elseif s.kind == "prop" then M.remove_prop(room, s.ref)
      else
        for i, e in ipairs(room.exits) do if e == s.ref then table.remove(room.exits, i) break end end
      end
      E.selected = nil
      E.changed()
    elseif key == "delete" then
      E.room_action("delete")
    end
  elseif key == "escape" then
    if E.selected then E.selected = nil
    elseif E.dirty and not E.quit_armed then E.quit_armed = true; E.say("unsaved changes: Esc again quits without saving", true)
    else love.event.quit() end
  end
end

function love.quit()
  if E.dirty and not E.quit_armed then
    E.quit_armed = true
    E.say("unsaved changes: close again to quit without saving (Ctrl+S saves)", true)
    return true
  end
end

return E
