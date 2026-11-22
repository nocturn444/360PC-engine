-- tools/level_editor: the model (rooms, tiles, doors, item, entities, resize, checks, undo,
-- the file round trip, the LDtk fixture opened and saved back) and the window on a fake love
-- (painting with the mouse, tools by key, undo, save, the play test).
-- Usage, from the repository root: luajit -joff tests/pc/level_editor_test.lua
package.path = "./?.lua;./?/init.lua;./tools/level_editor/?.lua;./tests/engine/?.lua;" .. package.path

local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then error("FAILED: " .. what, 2) end
end

local M = require("model")
local level = require("engine.level")

-- a new level and rooms
local data = M.new_level({ tile_size = 16, cell_w = 10, cell_h = 6 })
local a = M.add_room(data, "Start", 2, 1)
check(a.tiles_w == 20 and a.tiles_h == 6 and #a.collision == 120, "a 2x1 room of 10x6 cells")
check(M.get(a, 1, 1) == M.SOLID and M.get(a, 5, 3) == M.EMPTY and M.get(a, 20, 6) == M.SOLID, "a solid border")
local b = M.add_room(data, "Start", 1, 1)
check(b.id == "Start_2", "ids stay unique")
check(M.rename_room(data, b, "Hall") and b.id == "Hall", "rename")
check(not M.rename_room(data, b, "Start") and not M.rename_room(data, b, "  "), "a taken or empty id is refused")

-- tiles
check(M.set(a, 3, 5, M.ONE_WAY) and not M.set(a, 3, 5, M.ONE_WAY), "set reports a change once")
check(M.fill_rect(a, 6, 4, 4, 5, M.SOLID) == 6, "a rectangle from any two corners")
check(M.flood(a, 10, 2, M.ONE_WAY) > 40 and M.get(a, 2, 2) == M.ONE_WAY and M.get(a, 1, 2) == M.SOLID,
  "flood fills the open area, not the walls")
M.flood(a, 10, 2, M.EMPTY)
M.set(a, 3, 5, M.ONE_WAY)            -- the flood back took the one-way tile too
check(M.rows(a)[5]:sub(1, 7) == "#.=###.", "rows: # solid, = one-way, . empty")

-- doors
check(M.toggle_exit(data, a, 1, 4) == "added" and a.exits[1].side == "left" and a.exits[1].offset == 0, "a left door")
check(M.toggle_exit(data, a, 1, 3) == "moved" and #a.exits == 1 and a.exits[1].ty == 3, "one door per cell side: it moves")
check(M.toggle_exit(data, a, 15, 1) == "added" and a.exits[2].side == "up" and a.exits[2].offset == 1, "an up door in the second cell")
check(M.toggle_exit(data, a, 20, 6) == "added" and a.exits[2].side == "right", "a corner is horizontal; sorted by side")
check(M.toggle_exit(data, a, 20, 6) == "removed", "toggled off")
check(M.toggle_exit(data, a, 1, 6, true) == "added" and a.exits[#a.exits].side == "down", "a corner made vertical")
M.toggle_exit(data, a, 1, 6)
check(M.toggle_exit(data, a, 5, 3) == nil, "not on the border")
M.set_requires(a.exits[2], "dash, double_jump")
check(#a.exits[2].requires == 2 and a.exits[2].requires[2] == "double_jump", "requires from text")

-- item and entities
check(M.toggle_item(a, 8, 5) == "added" and M.toggle_item(a, 9, 5) == "moved" and a.item.tx == 9, "the item")
local e1 = M.add_entity(data, a, "Enemy", 12, 5)
local e2 = M.add_entity(data, b, "Enemy", 3, 3)
check(e1.x == 176 and e1.y == 64 and e1.iid ~= e2.iid, "entities: position from the tile, unique iids")
check(M.entity_at(a, 180, 70) == e1 and M.entity_at(a, 10, 10) == nil, "entity_at")
M.move_entity(data, a, e1, 14, 4)
check(e1.x == 208 and e1.tx == 14 and e1.ty == 4, "move")
local f = assert(M.parse_fields('hp=3, boss=true, kind="bat", note=slow'))
check(f.hp == 3 and f.boss == true and f.kind == "bat" and f.note == "slow", "fields from text")
check(M.parse_fields("oops") == nil, "a field without =")
e1.fields = f
check(M.fields_text(f) == "boss=true, hp=3, kind=bat, note=slow", "fields to text")

-- resize
M.toggle_exit(data, a, 20, 3)              -- a right door
check(M.resize_room(data, a, 3, 1), "grow")
check(a.tiles_w == 30 and #a.collision == 180 and M.get(a, 30, 3) == M.SOLID and M.get(a, 25, 3) == M.EMPTY,
  "new tiles: empty, with a solid border")
local right = false
for _, e in ipairs(a.exits) do if e.side == "right" then right = true end end
check(not right and #a.exits == 2, "the right door left the border: dropped")
check(M.resize_room(data, a, 1, 1) and a.tiles_w == 10 and #a.entities == 0 and a.item.tx == 9,
  "shrink drops what is outside")

-- checks
a.type = "start"
local problems = M.check(data, { jump_height_tiles = 3, jump_distance_tiles = 4 })
local text = {}
for _, p in ipairs(problems) do text[#text + 1] = p[1] .. ": " .. p[2] end
text = table.concat(text, "\n")
check(text:find("Hall: no doors"), "a closed room is reported")
M.set(a, 1, 3, M.SOLID)
check(table.concat(M.check_room(data, a), " "):find("inside a wall"), "a door in a wall")

-- the file
local saved = M.to_text(data)
local back = assert(M.from_text(saved))
check(M.to_text(back) == saved, "save, open, save: the same bytes")
check(level.from_text(saved), "engine.level reads what the editor writes")
check(back.rooms[1].id == "Start" and back.rooms[2].entities[1].name == "Enemy", "rooms and entities survive")
check(M.from_text("nonsense") == nil, "a broken file is refused")

-- undo
local h = M.history()
h:push(data, 1)
M.fill_rect(data.rooms[1], 2, 2, 5, 5, M.SOLID)
local changed = M.to_text(data)
check(h:undo_step(data, 1) == 1 and M.to_text(data) == saved, "undo")
check(h:redo_step(data, 1) == 1 and M.to_text(data) == changed, "redo")
check(h:redo_step(data, 1) == nil, "nothing more to redo")
h:push(data, 1)
M.remove_room(data, data.rooms[2])
h:undo_step(data, 1)
check(#data.rooms == 2, "undo brings a deleted room back")

-- duplicate and order
local d = M.duplicate_room(data, data.rooms[2])
check(d.id == "Hall_2" and data.rooms[3] == d and d.entities[1].iid ~= data.rooms[2].entities[1].iid, "duplicate")
check(M.move_room(data, d, -2) and data.rooms[1] == d and not M.move_room(data, d, -1), "move in the list")

-- props: a small catalog and the model's operations (docs/PROPS.md)
local catalog = { format = "360pc-props-catalog", version = 1, types = {
  { id = "vine", label = "Vine", glyph = "|", color = { 0.3, 0.7, 0.3 }, category = "climb",
    w = 1, h = 4, resizable = "y", min = { w = 1, h = 1 }, max = { w = 1, h = 4 },
    flags = { "climbable" }, fields = {}, placement = "prop" },
  { id = "spikes", label = "Spikes", glyph = "^", color = { 0.9, 0.3, 0.3 }, category = "hazard",
    w = 3, h = 1, resizable = "x", min = { w = 1, h = 1 }, max = { w = 6, h = 1 },
    flags = {}, placement = "prop", fields = {
      { key = "damage", type = "integer", default = 1, min = 1, max = 5 },
      { key = "armed", type = "bool", default = true },
      { key = "mode", type = "enum", default = "floor", options = { "floor", "ceiling" } },
    } },
} }
local function entry(id) for _, e in ipairs(catalog.types) do if e.id == id then return e end end end
local pr = M.add_room(data, "Props", 1, 1)
local vine = assert(M.add_prop(pr, "vine", 2, 1, entry("vine")))
check(vine.tx == 2 and vine.ty == 1 and vine.w == 1 and vine.h == 4, "a prop takes its type's default size")
check(M.prop_at(pr, 2, 3) == vine and M.prop_at(pr, 5, 3) == nil, "prop_at covers its box")
check(M.move_prop(pr, vine, 100, 100) and vine.tx == 10 and vine.ty == 3, "move keeps the prop inside the room")
check(M.move_prop(pr, vine, 2, 1) and vine.tx == 2 and vine.ty == 1, "move")
check(M.resize_prop(pr, vine, entry("vine"), 1, 1) and vine.h == 1
  and M.resize_prop(pr, vine, entry("vine"), 1, 99) and vine.h == 4, "resize along y up to max")
check(M.resize_prop(pr, vine, entry("vine"), 1, 0) and vine.h == 1, "resize down to min")
check(not M.resize_prop(pr, vine, entry("vine"), 4, 1) and vine.w == 1, "a type resizable only along y keeps its width")
local spikes = assert(M.add_prop(pr, "spikes", 2, 5, entry("spikes")))
check(spikes.w == 3 and spikes.h == 1, "spikes: 3x1")
check(M.resize_prop(pr, spikes, entry("spikes"), 99, 1) and spikes.w == 6, "resize along x up to max")
check(not M.resize_prop(pr, spikes, entry("spikes"), 6, 4) and spikes.h == 1, "and not along y")
check(M.resize_prop(pr, spikes, entry("spikes"), 0, 1) and spikes.w == 1, "and down to min")
check(M.set_prop_field(spikes, entry("spikes"), "damage", 3) and spikes.fields.damage == 3, "a field value")
check(M.set_prop_field(spikes, entry("spikes"), "damage", 1) and spikes.fields == nil, "a value equal to the default is removed")
check(not M.set_prop_field(spikes, entry("spikes"), "damage", 9), "a value over max is refused")
check(not M.set_prop_field(spikes, entry("spikes"), "damage", 1.5), "an integer field refuses a fraction")
check(M.set_prop_field(spikes, entry("spikes"), "armed", false) and spikes.fields.armed == false, "a bool")
check(M.set_prop_field(spikes, entry("spikes"), "armed", true) and spikes.fields == nil, "a bool back to its default")
check(M.set_prop_field(spikes, entry("spikes"), "mode", "ceiling") and spikes.fields.mode == "ceiling", "an enum")
check(not M.set_prop_field(spikes, entry("spikes"), "mode", "wall"), "an enum refuses an unknown option")
check(not M.set_prop_field(spikes, entry("spikes"), "nope", 1), "an unknown field is refused")
check(M.remove_prop(pr, spikes) and M.prop_at(pr, 2, 5) == nil and #pr.props == 1, "remove_prop")
local prop_copy = M.duplicate_room(data, pr)
check(prop_copy.props and #prop_copy.props == 1 and prop_copy.props[1] ~= pr.props[1]
  and prop_copy.props[1].type == "vine", "duplicate_room copies the props")
prop_copy.props[1].tx = 9
check(pr.props[1].tx == 2, "a duplicated room has its own props")
local props_back = assert(M.from_text(M.to_text(data)))
local props_room = M.find_room(props_back, "Props")
check(props_room and props_room.props and props_room.props[1].type == "vine", "props survive a save and open")
local rr = M.add_room(data, "PropResize", 2, 2)
local wide = assert(M.add_prop(rr, "spikes", 18, 3, entry("spikes")))
local stay = assert(M.add_prop(rr, "spikes", 2, 2, entry("spikes")))
check(M.resize_room(data, rr, 1, 1), "resize a room with props")
check(#rr.props == 1 and rr.props[1] == stay and not M.prop_at(rr, wide.tx, wide.ty),
  "props that no longer fit are dropped")

-- the LDtk fixture, converted, opens and saves back the same
local py = io.popen("python3 tools/ldtk_convert.py tests/fixtures/ldtk/world.ldtk -o /dev/stdout -q 2>/dev/null")
local converted = py and py:read("*a") or ""
if py then py:close() end
if converted:find("360pc%-level") then
  local lvl = assert(M.from_text(converted))
  local again = assert(M.from_text(M.to_text(lvl)))
  check(#again.rooms == #lvl.rooms and #again.rooms[1].layers == #lvl.rooms[1].layers, "an LDtk level opens and saves with its tile layers")
  check(level.from_text(M.to_text(lvl)), "and engine.level still reads it")
else
  print("note: python3 not found, the LDtk fixture part is skipped")
end

-- the window, on the fake love
local window = loadfile("tests/pc/level_editor_window.lua")
if window then checks = checks + window(check, M) end

print(string.format("OK: %d checks", checks))
