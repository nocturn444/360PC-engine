// tools/room_editor_web: the JavaScript level codec, the room model, props (not entities),
// undo, checks, filters, import and the round trip against Lua and the LDtk converter.
// Usage, from the repository root: node tests/tools/room_editor_web_test.js
"use strict";

var assert = require("assert");
var fs = require("fs");
var os = require("os");
var path = require("path");
var child = require("child_process");

var ROOT = path.resolve(__dirname, "../..");
var SaveFmt = require(path.join(ROOT, "tools/room_editor_web/js/savefmt.js"));
var M = require(path.join(ROOT, "tools/room_editor_web/js/model.js"));

var checks = 0;
function check(cond, what) {
  checks++;
  if (!cond) throw new Error("FAILED: " + what);
}
function eq(actual, expected, what) {
  checks++;
  assert.strictEqual(actual, expected, what);
}

var tmp = fs.mkdtempSync(path.join(os.tmpdir(), "360pc-room-editor-"));

function run(command, args, options) {
  var opt = { cwd: ROOT, encoding: "utf8", stdio: "pipe" };
  if (options) for (var k in options) opt[k] = options[k];
  return child.spawnSync(command, args, opt);
}

function haveCommand(command) {
  var r = child.spawnSync(command, ["-e", ""], { stdio: "ignore" });
  return !r.error;
}

// --- savefmt: the format itself -----------------------------------------------------------

var sample = SaveFmt.parse('{["a"]="x\\n\\"\\\\\\065",["n"]=0.1,["b"]=true,}');
check(sample.ok, "parse a small table");
eq(sample.value.a, 'x\n"\\A', "escapes in a string");
eq(sample.value.n, 0.1, "a number");
eq(sample.value.b, true, "a boolean");
check(!Array.isArray(SaveFmt.parse("{}").value), "an empty table is a plain object");
check(Array.isArray(SaveFmt.parse("{1,2,}").value), "a 1..n table is an array");
eq(SaveFmt.serialize([]), "{}", "an empty array is an empty table");
eq(SaveFmt.serialize({}), "{}", "an empty object is an empty table");
var bad = SaveFmt.parse('{["a"=1}');
check(!bad.ok && /byte 6/.test(bad.error), "a parse error names the byte position");

// --- 1. the LDtk fixture, converted, opens and saves back the same bytes ------------------

var fixture = path.join(tmp, "world.lvl");
var converted = run("python3", ["tools/ldtk_convert.py", "tests/fixtures/ldtk/world.ldtk",
  "-o", fixture, "-q"]);
if (converted.error) {
  console.log("warning: python3 not found, the LDtk fixture part is skipped");
} else {
  eq(converted.status, 0, "the LDtk fixture converts");
  var fixtureText = fs.readFileSync(fixture, "utf8");
  var opened = M.fromText(fixtureText);
  check(!opened.error, "the converted fixture opens: " + opened.error);
  var rewritten = M.toText(opened.level);
  var expectedFixture = fixtureText.endsWith("\n") ? fixtureText : fixtureText + "\n";
  check(rewritten === expectedFixture, "the LDtk fixture round trip is byte-identical");
  check(rewritten.endsWith("\n"), "toText ends with a newline");
}

// --- 2. the writer is byte-identical with engine/save.lua --------------------------------

var tricky = {
  zeros: [0, -0],
  numbers: [0.1, 1e20, -3, Math.pow(2, 53), 1 / 3, -1.5e-9, 1e-7, 1e-4,
    1e15, -1e15, 123456789012345.6, 1e16, Number.MAX_VALUE, Number.MIN_VALUE],
  special: [Infinity, -Infinity, NaN],
  text: 'quote " backslash \\ newline\n tab\t cr\r ctrl\u0001 del\u007f unicode \u00f1 \u6f22',
  nested: { b: 2, a: 1, list: [1, { x: true }, []], empty: {} }
};

var jsText = SaveFmt.serialize(tricky);
var jsFile = path.join(tmp, "js.lvl");
var luaFile = path.join(tmp, "lua.lvl");
fs.writeFileSync(jsFile, jsText, "utf8");

if (!haveCommand("luajit")) {
  console.log("warning: luajit not found, the byte-identical writer part is skipped");
} else {
  var roundtripLua = path.join(tmp, "roundtrip.lua");
  fs.writeFileSync(roundtripLua, [
    'local Save = require("engine.save")',
    'local input = assert(io.open(arg[1], "rb"))',
    'local text = input:read("*a"); input:close()',
    'local ok, value = Save.parse(text)',
    'assert(ok, tostring(value))',
    'local output = assert(io.open(arg[2], "wb"))',
    'output:write(Save.serialize(value)); output:close()'
  ].join("\n"), "utf8");
  var luaRun = run("luajit", [roundtripLua, jsFile, luaFile]);
  eq(luaRun.status, 0, "Lua parses and writes the JS file: " + luaRun.stderr);
  eq(fs.readFileSync(luaFile, "utf8"), jsText, "JS writes the same bytes as Lua");

  var luaMade = path.join(tmp, "lua-made.lvl");
  var luaWriter = path.join(tmp, "write.lua");
  fs.writeFileSync(luaWriter, [
    'local Save = require("engine.save")',
    'local value = {',
    '  numbers = {0.1, 1e20, -3, 2^53, 1/3, -1.5e-9, 1e-7, 1e-4,',
    '    1e15, -1e15, 123456789012345.6, 1e16, 1.7976931348623157e308,',
    '    4.9406564584124654e-324},',
    '  special = {math.huge, -math.huge, 0/0},',
    '  text = "quote \\" backslash \\\\ newline\\n tab\\t cr\\r ctrl\\1 del\\127 unicode "',
    '    .. string.char(195, 177) .. " " .. string.char(230, 188, 162),',
    '  nested = { b = 2, a = 1, list = {1, {x = true}, {}}, empty = {} },',
    '}',
    'local output = assert(io.open(arg[1], "wb"))',
    'output:write(Save.serialize(value)); output:close()'
  ].join("\n"), "utf8");
  var luaWrite = run("luajit", [luaWriter, luaMade]);
  eq(luaWrite.status, 0, "Lua writes its own file: " + luaWrite.stderr);
  var luaText = fs.readFileSync(luaMade, "utf8");
  var luaParsed = SaveFmt.parse(luaText);
  check(luaParsed.ok, "JS parses what Lua writes: " + luaParsed.error);
  eq(SaveFmt.serialize(luaParsed.value), luaText, "JS reads and writes Lua's bytes back");
}

// --- 3. a level made in JS loads with engine.level and the LÖVE editor's model -----------

var made = M.newLevel({ tileSize: 16, cellW: 10, cellH: 6 });
var start = M.addRoom(made, "Start", 2, 1);
M.fillRect(start, 4, 2, 6, 4, M.SOLID);
M.toggleExit(made, start, 1, 4);
M.toggleExit(made, start, 20, 4);
M.toggleItem(start, 8, 2);
M.setRequires(M.exitAt(start, 20, 4), "dash, double_jump");
var enemy = M.addEntity(made, start, "Enemy", 12, 4);
M.moveEntity(made, start, enemy, 14, 3);
var startBio = M.addProp(start, { type: "crate", tx: 3, ty: 2, w: 2, h: 2, fields: { hp: 3 } });
M.setPropField(startBio, "hp", 3, 3);
M.setPropField(startBio, "open", true, false);
M.setType(start, "start");
M.setBiome(start, "cellar");
var variant = M.duplicateRoom(made, start);
M.setType(variant, "normal");
var madeText = M.toText(made);
var madeFile = path.join(tmp, "made.lvl");
fs.writeFileSync(madeFile, madeText, "utf8");

if (haveCommand("luajit")) {
  var loadLua = path.join(tmp, "load.lua");
  fs.writeFileSync(loadLua, [
    'package.path = "./?.lua;./?/init.lua;./tools/level_editor/?.lua;" .. package.path',
    'local level = require("engine.level")',
    'local model = require("model")',
    'local input = assert(io.open(arg[1], "rb"))',
    'local text = input:read("*a"); input:close()',
    'local lvl, err = level.from_text(text)',
    'if not lvl then print("engine.level: " .. tostring(err)); os.exit(1) end',
    'local data, merr = model.from_text(text)',
    'if not data then print("model: " .. tostring(merr)); os.exit(1) end',
    'assert(#lvl.rooms == #data.rooms)',
    'print("OK")'
  ].join("\n"), "utf8");
  var loaded = run("luajit", [loadLua, madeFile]);
  eq(loaded.status, 0, "engine.level and model.lua read the JS level: " +
    loaded.stdout + loaded.stderr);
  eq((loaded.stdout || "").trim(), "OK", "the Lua load says OK");
}

// --- 4. rooms, collision, doors, items, entities, resize, checks --------------------------

var data = M.newLevel({ tileSize: 16, cellW: 10, cellH: 6 });
var a = M.addRoom(data, "Start", 2, 1);
check(a.tiles_w === 20 && a.tiles_h === 6 && a.collision.length === 120,
  "a 2x1 room of 10x6 cells");
check(M.get(a, 1, 1) === M.SOLID && M.get(a, 5, 3) === M.EMPTY &&
  M.get(a, 20, 6) === M.SOLID, "a solid border");
var b = M.addRoom(data, "Start", 1, 1);
eq(b.id, "Start_2", "ids stay unique");
check(M.renameRoom(data, b, "Hall") && b.id === "Hall", "rename");
check(!M.renameRoom(data, b, "Start") && !M.renameRoom(data, b, "  "),
  "a taken or empty id is refused");

check(M.set(a, 3, 5, M.ONE_WAY) && !M.set(a, 3, 5, M.ONE_WAY),
  "set reports a change once");
eq(M.fillRect(a, 6, 4, 4, 5, M.SOLID), 6, "a rectangle from any two corners");
check(M.flood(a, 10, 2, M.ONE_WAY) > 40 && M.get(a, 2, 2) === M.ONE_WAY &&
  M.get(a, 1, 2) === M.SOLID, "flood fills the open area, not the walls");
M.flood(a, 10, 2, M.EMPTY);
M.set(a, 3, 5, M.ONE_WAY);
eq(M.rows(a)[4].slice(0, 7), "#.=###.", "rows: # solid, = one-way, . empty");
M.set(a, 2, 2, 7);
eq(M.get(a, 2, 2), 7, "other integer tile values are kept");

eq(M.toggleExit(data, a, 1, 4), "added", "a left door");
eq(a.exits[0].side, "left", "the door's side");
eq(M.toggleExit(data, a, 1, 3), "moved", "one door per cell side: it moves");
eq(a.exits.length, 1, "the door moved, it was not added");
eq(M.toggleExit(data, a, 15, 1), "added", "an up door in the second cell");
eq(a.exits[1].side, "up", "the up door's side");
eq(M.toggleExit(data, a, 20, 6), "added", "a corner is horizontal");
eq(M.toggleExit(data, a, 20, 6), "removed", "toggled off");
eq(M.toggleExit(data, a, 1, 6, true), "added", "a corner made vertical");
eq(a.exits[a.exits.length - 1].side, "down", "the vertical corner door");
M.toggleExit(data, a, 1, 6);
eq(M.toggleExit(data, a, 5, 3), null, "not on the border");
M.setRequires(a.exits[1], "dash, double_jump");
check(a.exits[1].requires.length === 2 && a.exits[1].requires[1] === "double_jump",
  "requires from text");

eq(M.toggleItem(a, 8, 5), "added", "the item");
eq(M.toggleItem(a, 9, 5), "moved", "the item moves");
eq(a.item.tx, 9, "the item's new tile");
var e1 = M.addEntity(data, a, "Enemy", 12, 5);
var e2 = M.addEntity(data, b, "Enemy", 3, 3);
check(e1.x === 176 && e1.y === 64 && e1.iid !== e2.iid,
  "entities: position from the tile, unique iids");
eq(M.entityAt(a, 180, 70), e1, "entityAt");
eq(M.entityAt(a, 10, 10), null, "entityAt outside");
M.moveEntity(data, a, e1, 14, 4);
check(e1.x === 208 && e1.tx === 14 && e1.ty === 4, "move");
var fields = M.parseFields('hp=3, boss=true, kind="bat", note=slow');
check(fields.hp === 3 && fields.boss === true && fields.kind === "bat" &&
  fields.note === "slow", "fields from text");
check(M.parseFields("oops") === null, "a field without =");
e1.fields = fields;
eq(M.fieldsText(fields), "boss=true, hp=3, kind=bat, note=slow", "fields to text");

M.toggleExit(data, a, 20, 3);
check(M.resizeRoom(data, a, 3, 1), "grow");
check(a.tiles_w === 30 && a.collision.length === 180 && M.get(a, 30, 3) === M.SOLID &&
  M.get(a, 25, 3) === M.EMPTY, "new tiles: empty, with a solid border");
var right = a.exits.some(function (e) { return e.side === "right"; });
check(!right && a.exits.length === 2, "the right door left the border: dropped");
check(M.resizeRoom(data, a, 1, 1) && a.tiles_w === 10 && a.entities.length === 0 &&
  a.item.tx === 9, "shrink drops what is outside");

a.type = "start";
var problems = M.check(data);
var text = problems.map(function (p) { return p.roomId + ": " + p.message; }).join("\n");
check(/Hall: no doors/.test(text), "a closed room is reported");
M.set(a, 1, 3, M.SOLID);
check(M.checkRoom(data, a).some(function (p) {
  return /inside a wall/.test(p.message) && p.tx === 1 && p.ty === 3;
}), "a door in a wall, with its tile");
var noStart = M.newLevel({});
var quiet = M.addRoom(noStart, "Quiet", 1, 1);
M.toggleExit(noStart, quiet, 1, 3);
check(M.check(noStart).some(function (p) {
  return /no room has type start/.test(p.message);
}), "no start room is reported");

// --- 5. duplicate, order, undo, filters, grouping, import --------------------------------

var history = M.history(5);
var before = M.toText(data);
history.push(data, 0);
M.set(a, 4, 4, M.ONE_WAY);
var changed = M.toText(data);
check(changed !== before, "the change is visible");
eq(history.undoStep(data, 0), 0, "undo returns the room index");
eq(M.toText(data), before, "undo restores the bytes");
eq(history.redoStep(data, 0), 0, "redo returns the room index");
eq(M.toText(data), changed, "redo restores the change");
eq(history.redoStep(data, 0), null, "nothing more to redo");

history.push(data, 1);
M.removeRoom(data, data.rooms[0]);
history.undoStep(data, 1);
eq(data.rooms.length, 2, "undo brings a deleted room back");

var v2 = M.duplicateRoom(data, data.rooms[1]);
eq(v2.id, "Hall_v2", "the first variant id");
eq(data.rooms[2], v2, "the variant goes after its room");
check(v2.entities.length === 0 || v2.entities[0].iid !== data.rooms[1].entities[0].iid,
  "the variant gets fresh entity iids");
var v3 = M.duplicateRoom(data, data.rooms[1]);
eq(v3.id, "Hall_v3", "the next free variant id");
check(M.moveRoom(data, v3, -2) && data.rooms[0] === v3, "move in the list");
check(!M.moveRoom(data, v3, -1), "a move outside the list is refused");

M.setBiome(data.rooms[0], "cellar");
M.setType(data.rooms[0], "start");
M.setTags(data.rooms[0], "wide, damp");
M.setWeight(data.rooms[0], 3);
M.setBiome(data.rooms[1], "");
M.setType(data.rooms[1], "normal");
M.setTags(data.rooms[1], ["side"]);
eq(M.getBiome(data.rooms[0]), "cellar", "biome in fields.biome");
eq(M.getBiome(data.rooms[1]), "", "empty biome");
eq(M.listRooms(data, { biome: "cellar" }).length, 1, "filter by biome");
eq(M.listRooms(data, { type: "normal" }).length, 2, "filter by type");
eq(M.listRooms(data, { tag: "side" }).length, 1, "filter by tag");
eq(M.listRooms(data, { search: "hal" }).length, 3, "search by id");
var groups = M.groupRooms(data);
eq(groups.cellar.start.length, 1, "group by biome and type");
eq(groups[""].normal.length, 2, "rooms without a biome are under an empty key");
var count = M.counts(data);
eq(count.rooms, 4, "counts: rooms");
eq(count.byBiome.cellar, 1, "counts: by biome");
eq(count.byType.normal, 2, "counts: by type");

var other = M.newLevel({ tileSize: 16, cellW: 10, cellH: 6 });
M.addRoom(other, "Hall", 1, 1);
M.addRoom(other, "New", 1, 1);
var imported = M.importRooms(data, other, { onConflict: "rename" });
eq(imported.added, 1, "import adds a new room");
eq(imported.renamed, 1, "import renames a conflict");
check(M.findRoom(data, "Hall_2") !== null, "the renamed room gets a free id");
var skipped = M.importRooms(data, other, { onConflict: "skip" });
eq(skipped.skipped, 2, "import can skip conflicts");
var replaced = M.importRooms(data, other, { onConflict: "replace" });
eq(replaced.replaced, 2, "import can replace conflicts");
var wrongCell = M.newLevel({ tileSize: 16, cellW: 8, cellH: 6 });
check(M.importRooms(data, wrongCell, {}).error !== undefined,
  "import needs the same tile_size and cell");

// Every editing operation goes through the history and comes back exactly.
function undoOperation(name, setup, act) {
  var level = M.newLevel({ tileSize: 16, cellW: 10, cellH: 6 });
  var room = M.addRoom(level, "A", 1, 1);
  if (setup) setup(level, room);
  var h = M.history(10);
  var before = M.toText(level);
  h.push(level, 0);
  act(level, level.rooms[0]);
  var after = M.toText(level);
  check(after !== before, "undo/redo: " + name + " changes the level");
  eq(h.undoStep(level, 0), 0, "undo/redo: " + name + " undo");
  eq(M.toText(level), before, "undo/redo: " + name + " restores the bytes");
  eq(h.redoStep(level, 0), 0, "undo/redo: " + name + " redo");
  eq(M.toText(level), after, "undo/redo: " + name + " reapplies the bytes");
}

undoOperation("addRoom", null, function (level) { M.addRoom(level, "B", 1, 1); });
undoOperation("duplicateRoom", null, function (level, room) {
  M.duplicateRoom(level, room);
});
undoOperation("removeRoom", function (level) { M.addRoom(level, "B", 1, 1); },
  function (level) { M.removeRoom(level, level.rooms[1]); });
undoOperation("moveRoom", function (level) { M.addRoom(level, "B", 1, 1); },
  function (level) { M.moveRoom(level, level.rooms[0], 1); });
undoOperation("renameRoom", null, function (level, room) {
  M.renameRoom(level, room, "Renamed");
});
undoOperation("resizeRoom", null, function (level, room) {
  M.resizeRoom(level, room, 2, 1);
});
undoOperation("setType", null, function (level, room) { M.setType(room, "start"); });
undoOperation("setWeight", null, function (level, room) { M.setWeight(room, 4); });
undoOperation("setTags", null, function (level, room) { M.setTags(room, "a, b"); });
undoOperation("setBiome", null, function (level, room) { M.setBiome(room, "cellar"); });
undoOperation("set tile", null, function (level, room) {
  M.set(room, 2, 2, M.SOLID);
});
undoOperation("fillRect", null, function (level, room) {
  M.fillRect(room, 2, 2, 4, 3, M.SOLID);
});
undoOperation("flood", null, function (level, room) {
  M.flood(room, 2, 2, M.ONE_WAY);
});
undoOperation("toggleExit", null, function (level, room) {
  M.toggleExit(level, room, 1, 3);
});
undoOperation("toggleItem", null, function (level, room) {
  M.toggleItem(room, 3, 3);
});
undoOperation("addEntity", null, function (level, room) {
  M.addEntity(level, room, "Enemy", 3, 3);
});
undoOperation("moveEntity", function (level, room) {
  M.addEntity(level, room, "Enemy", 3, 3);
}, function (level, room) {
  M.moveEntity(level, room, room.entities[0], 5, 3);
});
undoOperation("removeEntity", function (level, room) {
  M.addEntity(level, room, "Enemy", 3, 3);
}, function (level, room) {
  M.removeEntity(room, room.entities[0]);
});
undoOperation("addProp", null, function (level, room) {
  M.addProp(room, { type: "crate", tx: 2, ty: 2, w: 1, h: 1 });
});
undoOperation("moveProp", function (level, room) {
  M.addProp(room, { type: "crate", tx: 2, ty: 2, w: 1, h: 1 });
}, function (level, room) {
  M.moveProp(room, room.props[0], 4, 3);
});
undoOperation("resizeProp", function (level, room) {
  M.addProp(room, { type: "crate", tx: 2, ty: 2, w: 1, h: 1 });
}, function (level, room) {
  M.resizeProp(room, room.props[0], 2, 2);
});
undoOperation("setPropField", function (level, room) {
  M.addProp(room, { type: "crate", tx: 2, ty: 2, w: 1, h: 1, fields: { hp: 3 } });
}, function (level, room) {
  M.setPropField(room.props[0], "hp", 3, 3);
});
undoOperation("removeProp", function (level, room) {
  M.addProp(room, { type: "crate", tx: 2, ty: 2, w: 1, h: 1 });
}, function (level, room) {
  M.removeProp(room, room.props[0]);
});
var importSource = null;
undoOperation("importRooms", function () {
  importSource = M.newLevel({ tileSize: 16, cellW: 10, cellH: 6 });
  M.addRoom(importSource, "B", 1, 1);
}, function (level) {
  M.importRooms(level, importSource, { onConflict: "rename" });
});

// --- 6. props: optional, kept, edited, not entities -------------------------------------

var propsLevel = M.newLevel({ tileSize: 16, cellW: 10, cellH: 6 });
var room = M.addRoom(propsLevel, "Store", 1, 1);
check(!Object.prototype.hasOwnProperty.call(room, "props"),
  "a room has no props until one is added");
var prop = M.addProp(room, { type: "crate", tx: 2, ty: 2, w: 2, h: 1,
  fields: { hp: 3, open: false } });
eq(room.props.length, 1, "addProp creates the list");
eq(room.entities.length, 0, "props are not entities");
eq(prop.type, "crate", "the prop keeps its type");
check(M.propsAt(room, 2, 2).indexOf(prop) >= 0, "propsAt the top left tile");
check(M.propsAt(room, 3, 2).indexOf(prop) >= 0, "propsAt the last tile of the width");
check(M.propsAt(room, 4, 2).length === 0, "propsAt outside the width");
check(M.propsAt(room, 2, 3).length === 0, "propsAt outside the height");

M.moveProp(room, prop, 5, 4);
eq(prop.tx, 5, "moveProp: tx");
eq(prop.ty, 4, "moveProp: ty");
check(M.propsAt(room, 5, 4).indexOf(prop) >= 0, "the prop is at its new tile");
M.resizeProp(room, prop, 1, 2);
eq(prop.w, 1, "resizeProp: w");
eq(prop.h, 2, "resizeProp: h");
check(M.propsAt(room, 5, 5).indexOf(prop) >= 0, "the prop is taller");

M.setPropField(prop, "hp", 5, 3);
eq(prop.fields.hp, 5, "a non-default field is stored");
M.setPropField(prop, "hp", 3, 3);
check(!Object.prototype.hasOwnProperty.call(prop.fields, "hp"),
  "setting a field to its default removes it");
M.setPropField(prop, "open", true, false);
eq(prop.fields.open, true, "a boolean field");
M.setPropField(prop, "open", false, false);
check(!Object.prototype.hasOwnProperty.call(prop.fields, "open"),
  "a boolean default removes the field");

var second = M.addProp(room, { type: "sign", tx: 8, ty: 1, w: 1, h: 1 });
eq(room.props.length, 2, "a second prop");
check(M.removeProp(room, second) && room.props.length === 1, "removeProp");
check(M.removeProp(room, prop) && !Object.prototype.hasOwnProperty.call(room, "props"),
  "removing the last prop removes the list again");

// round trip: props survive untouched, a room without them does not gain the field
M.addProp(room, { type: "crate", tx: 1, ty: 2, w: 1, h: 1, fields: { hp: 2 } });
var plain = M.addRoom(propsLevel, "Plain", 1, 1);
var propsText = M.toText(propsLevel);
var propsBack = M.fromText(propsText);
check(!propsBack.error, "a level with props opens: " + propsBack.error);
var propsRoom = propsBack.level.rooms[0];
var plainRoom = propsBack.level.rooms[1];
eq(propsRoom.props.length, 1, "props survive the round trip");
eq(propsRoom.props[0].type, "crate", "the prop type survives");
eq(propsRoom.props[0].fields.hp, 2, "the prop fields survive");
check(!Object.prototype.hasOwnProperty.call(plainRoom, "props"),
  "a room without props does not gain the field");
eq(M.toText(propsBack.level), propsText, "a file with props round trips byte-identically");

var propsHistory = M.history();
propsHistory.push(propsLevel, 0);
M.addProp(room, { type: "lamp", tx: 2, ty: 1, w: 1, h: 1 });
var withLamp = M.toText(propsLevel);
propsHistory.undoStep(propsLevel, 0);
eq(M.toText(propsLevel), propsText, "undo removes an added prop");
propsHistory.redoStep(propsLevel, 0);
eq(M.toText(propsLevel), withLamp, "redo adds it back");

// --- copy-on-write history: many rooms, many steps ---------------------------------------

(function () {
  var level = M.newLevel({ tileSize: 16, cellW: 20, cellH: 12 });
  for (var i = 0; i < 300; i++) M.addRoom(level, "R" + i, 1, 1);
  var h = M.history(250);
  var states = [M.toText(level)];
  var originals = level.rooms.slice();
  for (var s = 0; s < 200; s++) {
    var index = (s * 7) % 300;
    h.push(level, index);
    M.set(level.rooms[index], 2 + (s % 15), 2 + (s % 9), s % 2 ? M.SOLID : M.ONE_WAY);
    if (s % 50 === 25) { h.push(level); M.moveRoom(level, level.rooms[3], 1); }
    states.push(M.toText(level));
  }
  check(h.undo[10].rooms[5] === h.undo[150].rooms[5] || h.undo[10].rooms.indexOf(originals[5]) >= 0,
    "history: steps share room objects instead of copying them");
  var ok = true;
  // undo everything, step by step (each paint step and each move step is one entry)
  while (h.undo.length > 0) h.undoStep(level);
  ok = M.toText(level) === states[0];
  check(ok, "history: undoing every step gives the first state back");
  for (var r = 0; r < 300; r++) {
    if (level.rooms[r] !== originals[r]) { ok = false; break; }
  }
  check(ok, "history: rooms keep their identity across undo");
  while (h.redo.length > 0) h.redoStep(level);
  eq(M.toText(level), states[states.length - 1], "history: redoing every step gives the last state");
})();

(function () {
  var level = M.newLevel({ tileSize: 16, cellW: 10, cellH: 6 });
  var room = M.addRoom(level, "A", 1, 1);
  var h = M.history();
  h.push(level, 0);
  M.set(room, 2, 2, M.SOLID);
  var one = M.toText(level);
  h.push(level, 0);
  M.set(room, 3, 2, M.SOLID);
  h.undoStep(level);
  eq(M.toText(level), one, "history: one undo after two edits of the same room");
  h.push(level);
  M.removeRoom(level, room);
  h.undoStep(level);
  eq(M.toText(level), one, "history: an undone delete brings the room back as it was");
})();

// --- resize drops props that no longer fit, cheap per-room checks ----------------------

(function () {
  var level = M.newLevel({ tileSize: 16, cellW: 10, cellH: 6 });
  var room = M.addRoom(level, "A", 2, 1);
  M.addProp(room, { type: "crate", tx: 2, ty: 2, w: 2, h: 1 });
  M.addProp(room, { type: "vine", tx: 9, ty: 2, w: 1, h: 3 });
  M.addProp(room, { type: "slab", tx: 15, ty: 3, w: 2, h: 1 });
  M.resizeRoom(level, room, 1, 1);
  eq(room.props.length, 2, "resize keeps props that still fit");
  eq(room.props[1].type, "vine", "a prop on the last column still fits");
  var level2 = M.newLevel({ tileSize: 16, cellW: 10, cellH: 6 });
  var room2 = M.addRoom(level2, "B", 2, 1);
  M.addProp(room2, { type: "slab", tx: 15, ty: 3, w: 2, h: 1 });
  M.resizeRoom(level2, room2, 1, 1);
  check(!Object.prototype.hasOwnProperty.call(room2, "props"),
    "resize removes an empty props list");

  var checks1 = M.checkRoomFull(level2, room2);
  check(checks1.some(function (p) { return /no doors/.test(p.message); }),
    "checkRoomFull reports a room without doors");
  room2.collision.pop();
  check(M.checkRoomFull(level2, room2).some(function (p) { return /collision array/.test(p.message); }),
    "checkRoomFull runs the engine.level room validation");
  var dup = M.addRoom(level2, "C", 1, 1);
  dup.id = "B";
  check(M.checkRoomFull(level2, dup).some(function (p) { return /duplicate id/.test(p.message); }),
    "checkRoomFull reports a duplicate id");
})();

console.log("OK: " + checks + " checks");
