-- 360PC-Engine: levels. Reference: docs/LEVELS.md.
--
-- Reads the level file that tools/ldtk_convert.py writes from an LDtk project on the
-- development PC. The file is data in the text format of engine/save.lua (Save.parse), so it is
-- never handed to load()/loadstring(). Each LDtk level is a room: a plain table in the shape
-- engine/modules/procgen takes as a room template (id, w, h, type, weight, exits, item, tags),
-- with a `grid` that answers the platformer grid interface (width, height, tile_size,
-- grid:kind(tx, ty)), its entities and its tile layers. Nothing here knows about a genre module.
--
-- Only love.filesystem.read, love.graphics.newImage / newQuad / newSpriteBatch / draw and
-- SpriteBatch:add are used (docs/API_SUBSET.md). Loading allocates; drawing does not.
local prefix = (...):gsub("level$", "")
local Save = require(prefix .. "save")

local M = { FORMAT = "360pc-level", VERSION = 1 }

local type, tostring, floor = type, tostring, math.floor

---------------------------------------------------------------------------
-- The collision grid of a room (the platformer grid interface)
---------------------------------------------------------------------------
local Grid = {}
Grid.__index = Grid
local KINDS = { [1] = "solid", [2] = "one_way" }

-- "solid", "one_way" or nil; tx is 1..width, ty is 1..height, outside is nil
function Grid:kind(tx, ty)
  if tx < 1 or ty < 1 or tx > self.width or ty > self.height then return nil end
  return KINDS[self.cells[(ty - 1) * self.width + tx]]
end

local function whole(v, min) return type(v) == "number" and v == floor(v) and v >= min end

local function check_room(room, n, lvl)
  if type(room) ~= "table" or type(room.id) ~= "string" then return "room " .. n .. " has no id" end
  local where = "room " .. room.id .. ": "
  if lvl.by_id[room.id] then return "two rooms have the id " .. room.id end
  if not whole(room.w, 1) or not whole(room.h, 1) then return where .. "bad size in map cells" end
  local tw, th = room.tiles_w, room.tiles_h
  if tw ~= room.w * lvl.cell.w or th ~= room.h * lvl.cell.h then return where .. "bad size in tiles" end
  if type(room.collision) ~= "table" or #room.collision ~= tw * th then
    return where .. "the collision array does not have " .. tw * th .. " values"
  end
  for _, name in ipairs({ "exits", "entities", "layers", "tags", "fields" }) do
    if type(room[name]) ~= "table" then return where .. name .. " is missing" end
  end
  for i = 1, #room.layers do
    local layer = room.layers[i]
    if type(layer) ~= "table" or type(layer.tiles) ~= "table" or #layer.tiles % 5 ~= 0
      or not lvl.tilesets[layer.tileset] then
      return where .. "layer " .. i .. " is broken"
    end
  end
  room.grid = setmetatable({ width = tw, height = th, tile_size = lvl.tile_size, cells = room.collision }, Grid)
  return nil
end

-- level.from_text(text) -> the level, or nil and the reason.
--   lvl.rooms      the rooms in the project's order (ready for procgen.templates / generate)
--   lvl.by_id      { id = room }
--   lvl.tilesets   { { path, tile_size, w, h }... }: the images the tile layers draw with
--   lvl.tile_size  pixels per collision tile; lvl.cell = { w, h }: tiles per map cell
-- A room has: id, w, h (map cells), type, weight, tags, fields (the level's other custom
-- fields), exits { side, offset, requires, tx, ty }, item { tx, ty } or nil, entities
-- { name, iid, x, y, w, h, tx, ty, fields }, layers { name, tileset, tiles } from the bottom
-- one up, tiles_w, tiles_h, collision (the flat array, 0 / 1 solid / 2 one-way) and grid.
function M.from_text(text)
  local ok, data = Save.parse(text)
  if not ok then return nil, "level: " .. tostring(data) end
  if type(data) ~= "table" or data.format ~= M.FORMAT then
    return nil, "level: not a level file (convert the LDtk project with tools/ldtk_convert.py)"
  end
  if data.version ~= M.VERSION then
    return nil, "level: file version " .. tostring(data.version) .. ", this engine reads version " ..
      M.VERSION .. " (convert the project again)"
  end
  if not whole(data.tile_size, 1) or type(data.cell) ~= "table" or not whole(data.cell.w, 1)
    or not whole(data.cell.h, 1) or type(data.rooms) ~= "table" or type(data.tilesets) ~= "table" then
    return nil, "level: the file is incomplete"
  end
  local lvl = { rooms = data.rooms, by_id = {}, tilesets = data.tilesets, tile_size = data.tile_size,
    cell = data.cell, ldtk_version = data.ldtk_version }
  for i = 1, #lvl.tilesets do
    local ts = lvl.tilesets[i]
    if type(ts) ~= "table" or type(ts.path) ~= "string" or not whole(ts.tile_size, 1) then
      return nil, "level: tileset " .. i .. " is broken"
    end
  end
  for i = 1, #lvl.rooms do
    local room = lvl.rooms[i]
    local err = check_room(room, i, lvl)
    if err then return nil, "level: " .. err end
    lvl.by_id[room.id] = room
  end
  return lvl
end

-- level.load(path) -> the level, or nil and the reason. `path` is a file of the game's, as
-- love.filesystem sees it ("levels/world.lvl").
function M.load(path)
  local text, err = love.filesystem.read(path)
  if type(text) ~= "string" then return nil, "level: cannot read " .. tostring(path) .. " (" .. tostring(err) .. ")" end
  local lvl, why = M.from_text(text)
  if not lvl then return nil, why .. " [" .. tostring(path) .. "]" end
  return lvl
end

---------------------------------------------------------------------------
-- Drawing: one SpriteBatch per tile layer
---------------------------------------------------------------------------
-- level.load_images(lvl) -> the image set level.batches takes: [i] = the image of
-- lvl.tilesets[i] (love.graphics.newImage(path): PNG, relative to the game folder). Call it
-- once (in the engine config's `load`, or a loading state); the images are shared by every room.
function M.load_images(lvl)
  local images = { tilesets = lvl.tilesets, quads = {} }
  for i = 1, #lvl.tilesets do
    images[i] = love.graphics.newImage(lvl.tilesets[i].path)
  end
  return images
end

-- The quad of the tile at sx, sy of tileset i, made once per image set
local function quad_for(images, i, sx, sy)
  local ts = images.tilesets[i]
  local cache = images.quads[i]
  if not cache then cache = {}; images.quads[i] = cache end
  local key = sy * 65536 + sx
  local q = cache[key]
  if not q then
    local iw, ih = images[i]:getDimensions()
    q = love.graphics.newQuad(sx, sy, ts.tile_size, ts.tile_size, iw, ih)
    cache[key] = q
  end
  return q
end

-- level.batches(room, images) -> { { name = layer name, tileset = index, batch = SpriteBatch }... }
-- from the bottom layer up, in room pixels (the room's top left corner is 0, 0). `images` is
-- what load_images returned. Build them when the room is entered, not per frame.
function M.batches(room, images)
  local out = {}
  for l = 1, #room.layers do
    local layer = room.layers[l]
    local tiles, i = layer.tiles, layer.tileset
    local size = images.tilesets[i].tile_size
    local n = #tiles / 5
    local batch = love.graphics.newSpriteBatch(images[i], n > 0 and n or 1)
    for t = 0, n - 1 do
      local p = t * 5
      local flip = tiles[p + 5]
      local fx, fy = flip % 2 == 1, flip >= 2
      -- a flipped tile is drawn with a negative scale around its far edge, so it stays in place
      batch:add(quad_for(images, i, tiles[p + 3], tiles[p + 4]), tiles[p + 1], tiles[p + 2], 0,
        fx and -1 or 1, fy and -1 or 1, fx and size or 0, fy and size or 0)
    end
    out[l] = { name = layer.name, tileset = i, batch = batch }
  end
  return out
end

-- level.draw(batches, x, y): draws the layers in order with the room's top left corner at x, y
-- (default 0, 0). To put sprites between two layers, draw batches[i].batch yourself.
function M.draw(batches, x, y)
  x, y = x or 0, y or 0
  for i = 1, #batches do
    love.graphics.draw(batches[i].batch, x, y)
  end
end

return M
