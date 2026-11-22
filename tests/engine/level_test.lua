-- engine/level.lua with tools/ldtk_convert.py: the LDtk fixture (tests/fixtures/ldtk) is
-- converted with python3 into a temporary file and loaded; grids, exits, items, entities and
-- tile layers are checked, the rooms go through procgen (a generated map, reach.check) and the
-- platformer collision, and the SpriteBatches are built on the fake love. Needs python3.
local T = ...
local F = require("fake_love")
local love = F.install({ image_w = 64, image_h = 32 })
local globals = {}
for k in pairs(_G) do globals[k] = true end
local Level = require("engine.level")
local Save = require("engine.save")
local Rng = require("engine.rng")
local procgen = require("engine.modules.procgen")
local platformer = require("engine.modules.platformer")

local function convert(project, extra)
  local out = os.tmpname()
  local cmd = string.format('python3 tools/ldtk_convert.py -q "%s" -o "%s" %s 2>%s', project, out, extra or "",
    package.config:sub(1, 1) == "\\" and "NUL" or "/dev/null")
  local code = os.execute(cmd)
  local f = io.open(out, "rb")
  local text = f and f:read("*a") or ""
  if f then f:close() end
  os.remove(out)
  return (code == 0 or code == true) and text ~= "" and text or nil
end

local text = convert("tests/fixtures/ldtk/world.ldtk")
T.check(text ~= nil, "python3 tools/ldtk_convert.py converts the fixture")

-- the converter writes exactly what Save.serialize would: nothing but data, in one canonical form
local ok, data = Save.parse(text)
T.check(ok and Save.serialize(data) == text, "the file is byte for byte what Save.serialize writes")
T.check(convert("tests/fixtures/ldtk/world.ldtk") == text, "converting twice gives the same bytes")

---------------------------------------------------------------------------
-- Loading
---------------------------------------------------------------------------
local files = { ["levels/world.lvl"] = text }
love.filesystem.read = function(path)
  if files[path] then return files[path], #files[path] end
  return nil, "no such file"
end
local lvl = assert(Level.load("levels/world.lvl"))
T.check(#lvl.rooms == 5 and lvl.tile_size == 16 and lvl.cell.w == 10 and lvl.cell.h == 6 and lvl.ldtk_version == "1.5.3",
  "five rooms, 16 px tiles, a map cell of 10x6 tiles (the smallest level)")
T.check(lvl.rooms[1].id == "Start" and lvl.rooms[2].id == "Hall" and lvl.rooms[5].id == "Boss"
  and lvl.by_id.Hall == lvl.rooms[2], "rooms keep the project's order and are indexed by id")
T.check(#lvl.tilesets == 1 and lvl.tilesets[1].path == "assets/tiles.png" and lvl.tilesets[1].tile_size == 16
  and lvl.tilesets[1].w == 64 and lvl.tilesets[1].h == 32, "only the tileset in use is listed")

local start, hall, well, treasure, boss = lvl.by_id.Start, lvl.by_id.Hall, lvl.by_id.Well, lvl.by_id.Treasure, lvl.by_id.Boss
T.check(start.type == "start" and boss.type == "boss" and hall.type == "normal" and hall.weight == 3 and start.weight == 1,
  "type (an Enum or a String, lower case) and weight, with their defaults")
T.check(hall.w == 2 and hall.h == 1 and boss.w == 2 and boss.h == 2 and start.w == 1, "sizes in map cells")
T.check(#hall.tags == 2 and hall.tags[1] == "wide" and hall.fields.music == "cave" and hall.fields.dark == false
  and hall.fields.Weight == nil and next(start.fields) == nil, "tags, and the other level fields under fields")

-- grids
local g = hall.grid
T.check(g.width == 20 and g.height == 6 and g.tile_size == 16, "the grid is in tiles")
T.check(g:kind(1, 1) == "solid" and g:kind(15, 1) == nil and g:kind(13, 4) == "one_way" and g:kind(12, 4) == nil
  and g:kind(1, 5) == nil and g:kind(20, 6) == "solid", "solid, one-way and empty tiles")
T.check(g:kind(0, 1) == nil and g:kind(21, 1) == nil and g:kind(1, 7) == nil, "outside the grid is empty")
T.check(well.grid:kind(4, 3) == nil, "an IntGrid value that is neither solid nor one-way is empty")
local rects = platformer.collision.rects(g)
T.check(#rects > 0 and rects[1].kind == "solid", "the platformer module takes the grid as it is")

-- exits
local function exit_text(room)
  local out = {}
  for i, e in ipairs(room.exits) do
    out[i] = e.side .. e.offset .. "@" .. e.tx .. "," .. e.ty .. (#e.requires > 0 and "!" .. table.concat(e.requires, "+") or "")
  end
  return table.concat(out, " ")
end
T.check(exit_text(start) == "left0@1,5 right0@10,5", "exits: the side comes from the border: " .. exit_text(start))
T.check(exit_text(hall) == "left0@1,5 right0@20,5 up1@15,1!double_jump",
  "a two-tile exit, an offset in the second cell, requires: " .. exit_text(hall))
T.check(exit_text(well) == "right0@10,5 down0@5,6", "an exit in the floor: " .. exit_text(well))
T.check(exit_text(boss) == "left1@1,11", "a side field, and the offset of the lower cell: " .. exit_text(boss))

-- items and entities
T.check(treasure.item.tx == 6 and treasure.item.ty == 2 and treasure.item.fields.pedestal == true and start.item == nil,
  "the Item entity is the room's item place")
local enemy = start.entities[1]
T.check(#start.entities == 1 and enemy.name == "Enemy" and enemy.iid == "enemy-start-1" and enemy.x == 80 and enemy.y == 64
  and enemy.w == 16 and enemy.h == 16 and enemy.tx == 6 and enemy.ty == 5,
  "other entities: name, the top left corner from the pivot, size, tile")
T.check(enemy.fields.hp == 3 and enemy.fields.patrol[2].cx == 7 and enemy.fields.note == nil, "entity fields; a null is left out")
T.check(#treasure.entities == 0 and #start.exits == 2, "exits and items are not in the entity list")

-- tile layers
T.check(#start.layers == 2 and start.layers[1].name == "Background" and start.layers[2].name == "Collision"
  and start.layers[1].tileset == 1, "tile layers from the bottom one up, auto-layer tiles included")
T.check(#start.layers[1].tiles == 20 and #well.layers == 1, "five numbers a tile; layers without tiles are left out")

---------------------------------------------------------------------------
-- Broken files
---------------------------------------------------------------------------
local function refuses(t, pattern, what)
  local l, err = Level.from_text(t)
  T.check(l == nil and tostring(err):find(pattern, 1, true), what .. " (" .. tostring(err) .. ")")
end
refuses("os.exit()", "level:", "code is not data")
refuses("{1,2,3,}", "not a level file", "another table")
refuses(text:gsub('%["version"%]=1,', '["version"]=2,'), "version 2", "a newer file version")
refuses(text:gsub('%["tiles_w"%]=20,', '["tiles_w"]=19,', 1), "bad size in tiles", "a room whose sizes disagree")
local missing, why = Level.load("levels/none.lvl")
T.check(missing == nil and why:find("cannot read levels/none.lvl", 1, true), "a missing file is reported, not raised")

-- props (docs/PROPS.md): the shape of a room's optional list
local function with_props(props)
  local _, data = Save.parse(text)
  data.rooms[1].props = props
  return Save.serialize(data)
end
local prop_lvl = assert(Level.from_text(with_props({
  { type = "vine", tx = 4, ty = 2, h = 6 },
  { type = "spikes", tx = 8, ty = 3, w = 3, fields = { damage = 2 } },
})))
T.check(#prop_lvl.rooms[1].props == 2 and prop_lvl.rooms[1].props[1].type == "vine"
  and prop_lvl.rooms[1].props[1].h == 6 and prop_lvl.rooms[1].props[2].fields.damage == 2,
  "a room's props list is read and kept")
refuses(with_props({ { tx = 1, ty = 1 } }), "prop 1 is broken", "a prop without a type")
refuses(with_props({ { type = "vine", tx = 0, ty = 1 } }), "prop 1 is broken", "a prop on tile 0")
refuses(with_props({ { type = "vine", tx = 1, ty = 1, w = 1.5 } }), "prop 1 is broken", "a prop of 1.5 tiles")
refuses(with_props({ { type = "vine", tx = 1, ty = 1, fields = 3 } }), "prop 1 is broken", "a prop whose fields are not a table")

---------------------------------------------------------------------------
-- procgen takes the rooms as templates
---------------------------------------------------------------------------
local map = assert(procgen.generate({ templates = lvl.rooms, rng = Rng.new(360), rooms = 5, abilities = { "double_jump" } }))
local again = assert(procgen.generate({ templates = assert(Level.from_text(text)).rooms, rng = Rng.new(360), rooms = 5,
  abilities = { "double_jump" } }))
T.check(#map.rooms == 5 and map.rooms[map.start].id == "Start" and map.rooms[map.boss].id == "Boss",
  "a map generated from the loaded rooms, from Start to Boss")
T.check(procgen.hash(map) == procgen.hash(again), "the same seed and the same file give the same map")
local has_item = false
for _, r in ipairs(map.rooms) do
  if r.grants then has_item = r.id == "Treasure" end
end
T.check(has_item, "the ability item is in the room with the Item entity")

local reach = { jump_height_tiles = 3, jump_distance_tiles = 4 }
for _, room in ipairs(lvl.rooms) do
  local good, msg = procgen.reach.check(room, reach)
  T.check(good, "reach.check passes on " .. room.id .. ": " .. tostring(msg))
end
local short, msg = procgen.reach.check(hall, { jump_height_tiles = 1, jump_distance_tiles = 4 })
T.check(short == false and msg:find("Hall", 1, true), "and fails on the hall with a jump too low for its ceiling exit")

---------------------------------------------------------------------------
-- Images and SpriteBatches
---------------------------------------------------------------------------
local images = Level.load_images(lvl)
T.check(#images == 1 and images[1].kind == "image", "one image per tileset")
local batches = Level.batches(start, images)
T.check(#batches == 2 and batches[1].name == "Background" and batches[2].name == "Collision"
  and batches[1].batch.image == images[1] and batches[1].batch.size == 4, "one SpriteBatch per layer, sized to its tiles")
local s = batches[1].batch.sprites
local function sprite(i) local p = s[i]; return table.concat({ p[2], p[3], p[5], p[6], p[7], p[8] }, " ") end
T.check(#s == 4 and sprite(1) == "16 16 1 1 0 0" and sprite(2) == "32 16 -1 1 16 0" and sprite(3) == "48 16 1 -1 0 16"
  and sprite(4) == "64 16 -1 -1 16 16", "flips are a negative scale with the offset that keeps the tile in place")
local qx, qy, qw, qh = s[2][1]:getViewport()
T.check(qx == 16 and qy == 16 and qw == 16 and qh == 16, "the quad is the tile's source rectangle")
T.check(batches[2].batch.sprites[2][1] == batches[2].batch.sprites[3][1]
  and Level.batches(start, images)[2].batch.sprites[2][1] == batches[2].batch.sprites[2][1],
  "one quad per source tile, shared by layers and rooms")
F.reset_calls()
Level.draw(batches, 8, 4)
local d = F.find("draw")
T.check(#d == 2 and d[1][2] == batches[1].batch and d[2][2] == batches[2].batch and d[1][3] == 8 and d[1][4] == 4,
  "draw: the layers in order at the room's position")

-- external level files (.ldtkl)
local ext = assert(Level.from_text(assert(convert("tests/fixtures/ldtk/external.ldtk"), "the external project converts")))
T.check(#ext.rooms == 1 and ext.rooms[1].id == "Vault" and ext.rooms[1].type == "shop" and #ext.rooms[1].exits == 2
  and ext.rooms[1].grid:kind(1, 1) == "solid", "a project with external levels reads its .ldtkl files")
T.check(convert("tests/fixtures/ldtk/world.ldtk", "--cell 7x6") == nil, "the converter fails on a cell the levels do not fit")

T.check(require("engine").level == Level, "engine.level is the module")
T.no_new_globals(globals)
