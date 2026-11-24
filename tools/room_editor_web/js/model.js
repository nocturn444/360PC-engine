// The web room editor's data: a level in the format of engine/level.lua (docs/LEVELS.md),
// edited in place, with undo, checks and the text written back. No DOM or Node calls here.
"use strict";

var SaveFmt = (typeof module !== "undefined" && module.exports)
  ? require("./savefmt.js") : globalThis.SaveFmt;

var FORMAT = "360pc-level";
var VERSION = 1;
var MAX_HISTORY = 200;

var RoomModel = {};

RoomModel.EMPTY = 0;
RoomModel.SOLID = 1;
RoomModel.ONE_WAY = 2;
RoomModel.SIDES = ["left", "right", "up", "down"];

var SIDE_ORDER = { left: 1, right: 2, up: 3, down: 4 };
var KINDS = { 1: "solid", 2: "one_way" };

function isTable(v) {
  return v !== null && typeof v === "object";
}

function isWhole(v, min) {
  return typeof v === "number" && Number.isInteger(v) && v >= min;
}

function copy(v) {
  if (Array.isArray(v)) {
    var arr = new Array(v.length);
    for (var i = 0; i < v.length; i++) arr[i] = copy(v[i]);
    return arr;
  }
  if (isTable(v)) {
    var obj = {};
    var keys = Object.keys(v);
    for (var k = 0; k < keys.length; k++) obj[keys[k]] = copy(v[keys[k]]);
    return obj;
  }
  return v;
}
RoomModel.copy = copy;

function emptyToArray(v) {
  return (isTable(v) && !Array.isArray(v) && Object.keys(v).length === 0) ? [] : v;
}

function list(v) {
  return Array.isArray(v) ? v : [];
}

function deepEqual(a, b) {
  if (a === b) return true;
  if (typeof a === "number" && typeof b === "number" &&
    Number.isNaN(a) && Number.isNaN(b)) return true;
  if (!a || !b || typeof a !== "object" || typeof b !== "object") return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  var ka = Object.keys(a);
  var kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  for (var i = 0; i < ka.length; i++) {
    if (!Object.prototype.hasOwnProperty.call(b, ka[i]) ||
      !deepEqual(a[ka[i]], b[ka[i]])) return false;
  }
  return true;
}

// The check_room checks of engine/level.lua for one room: an error text or null.
function validateRoom(data, tilesets, room) {
  var where = "room " + room.id + ": ";
  if (!isWhole(room.w, 1) || !isWhole(room.h, 1)) {
    return where + "bad size in map cells";
  }
  var tw = room.w * data.cell.w;
  var th = room.h * data.cell.h;
  if (room.tiles_w !== tw || room.tiles_h !== th) {
    return where + "bad size in tiles";
  }
  if (!Array.isArray(room.collision) || room.collision.length !== tw * th) {
    return where + "the collision array does not have " + (tw * th) + " values";
  }
  var required = ["exits", "entities", "layers", "tags", "fields"];
  for (var n = 0; n < required.length; n++) {
    if (!isTable(room[required[n]])) return where + required[n] + " is missing";
  }
  var layers = list(room.layers);
  for (var l = 0; l < layers.length; l++) {
    var layer = layers[l];
    var tiles = list(layer && layer.tiles);
    if (!isTable(layer) || !isTable(layer.tiles) || tiles.length % 5 !== 0 ||
      !isTable(tilesets[layer.tileset - 1])) {
      return where + "layer " + (l + 1) + " is broken";
    }
  }
  return null;
}

function validateLevel(data) {
  if (!isTable(data) || data.format !== FORMAT) {
    return "not a level file (convert the LDtk project with tools/ldtk_convert.py)";
  }
  if (data.version !== VERSION) {
    return "file version " + data.version + ", this engine reads version " + VERSION +
      " (convert the project again)";
  }
  if (!isWhole(data.tile_size, 1) || !isTable(data.cell) ||
    !isWhole(data.cell.w, 1) || !isWhole(data.cell.h, 1) ||
    !isTable(data.rooms) || !isTable(data.tilesets)) {
    return "the file is incomplete";
  }
  var tilesets = list(emptyToArray(data.tilesets));
  for (var t = 0; t < tilesets.length; t++) {
    var ts = tilesets[t];
    if (!isTable(ts) || typeof ts.path !== "string" || !isWhole(ts.tile_size, 1)) {
      return "tileset " + (t + 1) + " is broken";
    }
  }
  var seen = new Set();
  var rooms = list(emptyToArray(data.rooms));
  for (var r = 0; r < rooms.length; r++) {
    var room = rooms[r];
    if (!isTable(room) || typeof room.id !== "string") {
      return "room " + (r + 1) + " has no id";
    }
    if (seen.has(room.id)) return "two rooms have the id " + room.id;
    seen.add(room.id);
    var err = validateRoom(data, tilesets, room);
    if (err) return err;
  }
  return null;
}

// The level of a file's text: { level } or { error } (the checks of engine/level.lua).
RoomModel.fromText = function (text) {
  var parsed = SaveFmt.parse(text);
  if (!parsed.ok) return { error: "level: " + parsed.error };
  var data = parsed.value;
  var error = validateLevel(data);
  if (error) return { error: "level: " + error };

  data.rooms = emptyToArray(data.rooms);
  data.tilesets = emptyToArray(data.tilesets);
  for (var i = 0; i < data.rooms.length; i++) {
    var room = data.rooms[i];
    room.tags = emptyToArray(room.tags);
    room.exits = emptyToArray(room.exits);
    room.entities = emptyToArray(room.entities);
    room.layers = emptyToArray(room.layers);
    if (room.props !== undefined) room.props = emptyToArray(room.props);
    if (room.type === undefined || room.type === null) room.type = "normal";
    if (room.weight === undefined || room.weight === null) room.weight = 1;
    for (var e = 0; e < list(room.exits).length; e++) {
      room.exits[e].requires = emptyToArray(room.exits[e].requires || []);
    }
    for (var l = 0; l < list(room.layers).length; l++) {
      room.layers[l].tiles = emptyToArray(room.layers[l].tiles);
    }
  }
  return { level: data };
};

// The file's text (keys sorted: the same level gives the same bytes), ending with "\n".
RoomModel.toText = function (level) {
  var out = {};
  var keys = Object.keys(level);
  for (var i = 0; i < keys.length; i++) out[keys[i]] = level[keys[i]];
  out.rooms = [];
  for (var r = 0; r < level.rooms.length; r++) {
    var room = {};
    var roomKeys = Object.keys(level.rooms[r]);
    for (var k = 0; k < roomKeys.length; k++) {
      if (roomKeys[k] !== "grid") room[roomKeys[k]] = level.rooms[r][roomKeys[k]];
    }
    out.rooms.push(room);
  }
  return SaveFmt.serialize(out) + "\n";
};

RoomModel.newLevel = function (opts) {
  opts = opts || {};
  return {
    format: FORMAT,
    version: VERSION,
    ldtk_version: "",
    tile_size: opts.tileSize === undefined ? 16 : opts.tileSize,
    cell: {
      w: opts.cellW === undefined ? 20 : opts.cellW,
      h: opts.cellH === undefined ? 12 : opts.cellH
    },
    tilesets: [],
    rooms: []
  };
};

// ---------------------------------------------------------------------------
// Levels and rooms
// ---------------------------------------------------------------------------

RoomModel.findRoom = function (level, id) {
  for (var i = 0; i < level.rooms.length; i++) {
    if (level.rooms[i].id === id) return level.rooms[i];
  }
  return null;
};

RoomModel.roomIndex = function (level, id) {
  for (var i = 0; i < level.rooms.length; i++) {
    if (level.rooms[i].id === id) return i;
  }
  return -1;
};

RoomModel.freeId = function (level, base) {
  base = base || "Room";
  if (!RoomModel.findRoom(level, base)) return base;
  var n = 2;
  while (RoomModel.findRoom(level, base + "_" + n)) n++;
  return base + "_" + n;
};

// Variants of "Hall" and of "Hall_v2" are both named "Hall_vN" with the next free N, so
// duplicating a variant does not stack suffixes ("Hall_v2_v2").
RoomModel.variantId = function (level, base) {
  base = String(base).replace(/_v\d+$/, "") || String(base);
  var n = 2;
  while (RoomModel.findRoom(level, base + "_v" + n)) n++;
  return base + "_v" + n;
};

RoomModel.addRoom = function (level, id, w, h, at) {
  w = (w === undefined || w === null) ? 1 : w;
  h = (h === undefined || h === null) ? 1 : h;
  var tw = w * level.cell.w;
  var th = h * level.cell.h;
  var room = {
    id: RoomModel.freeId(level, id), w: w, h: h, tiles_w: tw, tiles_h: th,
    type: "normal", weight: 1, tags: [], fields: {}, exits: [], entities: [],
    layers: [], collision: []
  };
  for (var ty = 1; ty <= th; ty++) {
    for (var tx = 1; tx <= tw; tx++) {
      var border = tx === 1 || ty === 1 || tx === tw || ty === th;
      room.collision.push(border ? RoomModel.SOLID : RoomModel.EMPTY);
    }
  }
  if (at) level.rooms.splice(at, 0, room);
  else level.rooms.push(room);
  return room;
};

RoomModel.duplicateRoom = function (level, room) {
  var i = RoomModel.roomIndex(level, room.id);
  if (i < 0) return null;
  var c = copy(room);
  delete c.grid;
  c.id = RoomModel.variantId(level, room.id);
  for (var e = 0; e < list(c.entities).length; e++) delete c.entities[e].iid;
  RoomModel.fixIids(level, c);
  level.rooms.splice(i + 1, 0, c);
  return c;
};

RoomModel.removeRoom = function (level, room) {
  var i = RoomModel.roomIndex(level, room.id);
  if (i >= 0) level.rooms.splice(i, 1);
  return i;
};
RoomModel.deleteRoom = RoomModel.removeRoom;

RoomModel.renameRoom = function (level, room, id) {
  id = String(id === undefined || id === null ? "" : id).trim();
  if (id === "") return false;
  if (id !== room.id && RoomModel.findRoom(level, id)) return false;
  room.id = id;
  return true;
};

RoomModel.moveRoom = function (level, room, delta) {
  var i = RoomModel.roomIndex(level, room.id);
  var j = i + delta;
  if (i < 0 || j < 0 || j >= level.rooms.length) return false;
  var tmp = level.rooms[i];
  level.rooms[i] = level.rooms[j];
  level.rooms[j] = tmp;
  return true;
};

RoomModel.resizeRoom = function (level, room, w, h) {
  w = Math.max(1, Math.floor(w));
  h = Math.max(1, Math.floor(h));
  if (w === room.w && h === room.h) return false;
  var ow = room.tiles_w;
  var oh = room.tiles_h;
  var tw = w * level.cell.w;
  var th = h * level.cell.h;
  var old = room.collision;
  var fresh = [];
  for (var ty = 1; ty <= th; ty++) {
    for (var tx = 1; tx <= tw; tx++) {
      var v;
      if (tx <= ow && ty <= oh) v = old[(ty - 1) * ow + tx - 1];
      else v = RoomModel.EMPTY;
      // new tiles on the border are wall, so growing a room never opens a gap (a door)
      if ((tx > ow || ty > oh) && (tx === 1 || ty === 1 || tx === tw || ty === th)) v = RoomModel.SOLID;
      fresh.push(v);
    }
  }
  room.collision = fresh;
  room.w = w;
  room.h = h;
  room.tiles_w = tw;
  room.tiles_h = th;

  var kept = [];
  for (var e = 0; e < list(room.exits).length; e++) {
    var exit = room.exits[e];
    var same = (exit.side === "left" || exit.side === "up") ||
      (exit.side === "right" && tw === ow) ||
      (exit.side === "down" && th === oh);
    if (same && exit.tx <= tw && exit.ty <= th) kept.push(exit);
  }
  room.exits = kept;
  RoomModel.sortExits(room);

  if (room.item && (room.item.tx > tw || room.item.ty > th)) delete room.item;

  if (room.props) {
    var fit = [];
    for (var q = 0; q < list(room.props).length; q++) {
      var prop = room.props[q];
      if (prop.tx + prop.w - 1 <= tw && prop.ty + prop.h - 1 <= th) fit.push(prop);
    }
    if (fit.length > 0) room.props = fit;
    else delete room.props;
  }

  var ts = level.tile_size;
  var ents = [];
  for (var n = 0; n < list(room.entities).length; n++) {
    var ent = room.entities[n];
    if (ent.x + ent.w <= tw * ts && ent.y + ent.h <= th * ts) ents.push(ent);
  }
  room.entities = ents;

  for (var l = 0; l < list(room.layers).length; l++) {
    var tiles = room.layers[l].tiles;
    var out = [];
    for (var i = 0; i + 4 < tiles.length; i += 5) {
      if (tiles[i] < tw * ts && tiles[i + 1] < th * ts) {
        out.push(tiles[i], tiles[i + 1], tiles[i + 2], tiles[i + 3], tiles[i + 4]);
      }
    }
    room.layers[l].tiles = out;
  }
  return true;
};

RoomModel.setType = function (room, type) {
  room.type = type;
  return room;
};
RoomModel.setWeight = function (room, weight) {
  room.weight = weight;
  return room;
};
RoomModel.setTags = function (room, tags) {
  if (typeof tags === "string") {
    var parsed = [];
    var found = tags.match(/[^,\s]+/g) || [];
    for (var i = 0; i < found.length; i++) parsed.push(found[i]);
    room.tags = parsed;
  } else {
    room.tags = copy(tags || []);
  }
  return room;
};

RoomModel.getBiome = function (room) {
  return room.fields && typeof room.fields.biome === "string" ? room.fields.biome : "";
};
RoomModel.setBiome = function (room, biome) {
  if (!room.fields) room.fields = {};
  var text = biome === undefined || biome === null ? "" : String(biome);
  if (text === "") delete room.fields.biome;
  else room.fields.biome = text;
  return room;
};

// ---------------------------------------------------------------------------
// Collision tiles
// ---------------------------------------------------------------------------

RoomModel.inside = function (room, tx, ty) {
  return tx >= 1 && ty >= 1 && tx <= room.tiles_w && ty <= room.tiles_h;
};

RoomModel.get = function (room, tx, ty) {
  if (!RoomModel.inside(room, tx, ty)) return null;
  return room.collision[(ty - 1) * room.tiles_w + tx - 1];
};

RoomModel.set = function (room, tx, ty, v) {
  if (!RoomModel.inside(room, tx, ty)) return false;
  var i = (ty - 1) * room.tiles_w + tx - 1;
  if (room.collision[i] === v) return false;
  room.collision[i] = v;
  return true;
};

RoomModel.fillRect = function (room, x1, y1, x2, y2, v) {
  var n = 0;
  var minY = Math.max(1, Math.min(y1, y2));
  var maxY = Math.min(room.tiles_h, Math.max(y1, y2));
  var minX = Math.max(1, Math.min(x1, x2));
  var maxX = Math.min(room.tiles_w, Math.max(x1, x2));
  for (var ty = minY; ty <= maxY; ty++) {
    for (var tx = minX; tx <= maxX; tx++) {
      if (RoomModel.set(room, tx, ty, v)) n++;
    }
  }
  return n;
};

RoomModel.flood = function (room, tx, ty, v) {
  var from = RoomModel.get(room, tx, ty);
  if (from === null || from === v) return 0;
  var stack = [tx, ty];
  var n = 0;
  while (stack.length > 0) {
    var y = stack.pop();
    var x = stack.pop();
    if (RoomModel.get(room, x, y) === from) {
      RoomModel.set(room, x, y, v);
      n++;
      stack.push(x + 1, y, x - 1, y, x, y + 1, x, y - 1);
    }
  }
  return n;
};

RoomModel.rows = function (room) {
  var chars = { 0: ".", 1: "#", 2: "=" };
  var out = [];
  for (var ty = 1; ty <= room.tiles_h; ty++) {
    var row = "";
    for (var tx = 1; tx <= room.tiles_w; tx++) {
      row += chars[RoomModel.get(room, tx, ty)] || ".";
    }
    out.push(row);
  }
  return out;
};

RoomModel.grid = function (level, room) {
  return {
    width: room.tiles_w, height: room.tiles_h, tile_size: level.tile_size,
    cells: room.collision,
    kind: function (self, tx, ty) {
      if (tx < 1 || ty < 1 || tx > self.width || ty > self.height) return null;
      return KINDS[self.cells[(ty - 1) * self.width + tx - 1]] || null;
    }
  };
};

// ---------------------------------------------------------------------------
// Exits, the item, entities
// ---------------------------------------------------------------------------

RoomModel.exitSide = function (level, room, tx, ty, vertical) {
  if (!RoomModel.inside(room, tx, ty)) return null;
  var l = tx === 1;
  var r = tx === room.tiles_w;
  var u = ty === 1;
  var d = ty === room.tiles_h;
  if (vertical) {
    if (u) return "up";
    if (d) return "down";
  }
  if (l) return "left";
  if (r) return "right";
  if (u) return "up";
  if (d) return "down";
  return null;
};

RoomModel.sideOffset = function (level, room, tx, ty, side) {
  side = side || RoomModel.exitSide(level, room, tx, ty);
  if (!side) return null;
  if (side === "left" || side === "right") {
    return [side, Math.floor((ty - 1) / level.cell.h)];
  }
  return [side, Math.floor((tx - 1) / level.cell.w)];
};

RoomModel.sortExits = function (room) {
  list(room.exits).sort(function (a, b) {
    if (a.side !== b.side) return SIDE_ORDER[a.side] - SIDE_ORDER[b.side];
    return a.offset - b.offset;
  });
};

RoomModel.exitAt = function (room, tx, ty) {
  var exits = list(room.exits);
  for (var i = 0; i < exits.length; i++) {
    if (exits[i].tx === tx && exits[i].ty === ty) return exits[i];
  }
  return null;
};

// Puts a door at a border tile, or takes away the one there. Returns "added", "moved",
// "removed", or null when the tile is not on the border.
RoomModel.toggleExit = function (level, room, tx, ty, vertical) {
  var here = RoomModel.exitAt(room, tx, ty);
  if (here) {
    room.exits.splice(room.exits.indexOf(here), 1);
    return "removed";
  }
  var side = RoomModel.exitSide(level, room, tx, ty, vertical);
  var so = RoomModel.sideOffset(level, room, tx, ty, side);
  if (!so) return null;
  var exits = list(room.exits);
  for (var i = 0; i < exits.length; i++) {
    if (exits[i].side === so[0] && exits[i].offset === so[1]) {
      exits[i].tx = tx;
      exits[i].ty = ty;
      return "moved";
    }
  }
  room.exits.push({ side: so[0], offset: so[1], tx: tx, ty: ty, requires: [] });
  RoomModel.sortExits(room);
  return "added";
};

// Border tiles of one stretch of edge (one map cell long), without the room's corners.
RoomModel.stretchTiles = function (level, room, side, offset) {
  var out = [];
  var tw = room.tiles_w, th = room.tiles_h, i;
  if (side === "left" || side === "right") {
    var x = side === "left" ? 1 : tw;
    for (i = 1; i <= level.cell.h; i++) {
      var y = offset * level.cell.h + i;
      if (y > 1 && y < th) out.push({ tx: x, ty: y });
    }
  } else {
    var yy = side === "up" ? 1 : th;
    for (i = 1; i <= level.cell.w; i++) {
      var xx = offset * level.cell.w + i;
      if (xx > 1 && xx < tw) out.push({ tx: xx, ty: yy });
    }
  }
  return out;
};

function findExit(room, side, offset) {
  var exits = list(room.exits);
  for (var i = 0; i < exits.length; i++) {
    if (exits[i].side === side && exits[i].offset === offset) return exits[i];
  }
  return null;
}

// A gap in the border is a door: every stretch of edge with an open (not solid) tile gets
// a door, and a stretch that is all wall loses its door. A door keeps its requirements and
// its tile while that tile stays open; otherwise it moves to the middle of the gap.
// Returns how many doors were added, moved or removed.
RoomModel.syncBorderDoors = function (level, room) {
  if (!room.exits) room.exits = [];
  var changes = 0;
  var sides = [["left", room.h], ["right", room.h], ["up", room.w], ["down", room.w]];
  for (var s = 0; s < sides.length; s++) {
    for (var k = 0; k < sides[s][1]; k++) {
      var side = sides[s][0];
      var tiles = RoomModel.stretchTiles(level, room, side, k);
      var open = [];
      for (var t = 0; t < tiles.length; t++) {
        if (RoomModel.get(room, tiles[t].tx, tiles[t].ty) !== RoomModel.SOLID) open.push(tiles[t]);
      }
      var exit = findExit(room, side, k);
      if (!open.length) {
        // a door on an open corner tile (corners are in no stretch) stays
        if (exit && RoomModel.get(room, exit.tx, exit.ty) === RoomModel.SOLID) {
          room.exits.splice(room.exits.indexOf(exit), 1);
          changes++;
        }
        continue;
      }
      var mid = open[Math.floor((open.length - 1) / 2)];
      if (!exit) {
        room.exits.push({ side: side, offset: k, tx: mid.tx, ty: mid.ty, requires: [] });
        changes++;
      } else if (RoomModel.get(room, exit.tx, exit.ty) === RoomModel.SOLID) {
        exit.tx = mid.tx;
        exit.ty = mid.ty;
        changes++;
      }
    }
  }
  if (changes) RoomModel.sortExits(room);
  return changes;
};

// Walls up the gap of a door's stretch of edge (taking a door away closes its gap).
RoomModel.closeStretch = function (level, room, side, offset) {
  var tiles = RoomModel.stretchTiles(level, room, side, offset);
  for (var t = 0; t < tiles.length; t++) RoomModel.set(room, tiles[t].tx, tiles[t].ty, RoomModel.SOLID);
};

RoomModel.setRequires = function (exit, tags) {
  var parsed = [];
  if (typeof tags === "string") {
    var found = tags.match(/[^,\s]+/g) || [];
    for (var i = 0; i < found.length; i++) parsed.push(found[i]);
  } else {
    parsed = copy(tags || []);
  }
  exit.requires = parsed;
  return exit;
};

RoomModel.toggleItem = function (room, tx, ty) {
  if (room.item && room.item.tx === tx && room.item.ty === ty) {
    delete room.item;
    return "removed";
  }
  var had = room.item !== undefined && room.item !== null;
  var fields = had ? room.item.fields : undefined;
  room.item = { tx: tx, ty: ty };
  if (fields !== undefined) room.item.fields = fields;
  return had ? "moved" : "added";
};

RoomModel.fixIids = function (level, room) {
  var used = new Set();
  for (var r = 0; r < level.rooms.length; r++) {
    var ents = list(level.rooms[r].entities);
    for (var i = 0; i < ents.length; i++) {
      if (ents[i].iid !== undefined && ents[i].iid !== null) used.add(ents[i].iid);
    }
  }
  var n = 0;
  var own = list(room.entities);
  for (var e = 0; e < own.length; e++) {
    if (own[e].iid === undefined || own[e].iid === null) {
      do { n++; } while (used.has("ed-" + n));
      own[e].iid = "ed-" + n;
      used.add(own[e].iid);
    }
  }
};

RoomModel.addEntity = function (level, room, name, tx, ty) {
  var ts = level.tile_size;
  var ent = {
    name: name, x: (tx - 1) * ts, y: (ty - 1) * ts, w: ts, h: ts,
    tx: tx, ty: ty, fields: {}
  };
  room.entities.push(ent);
  RoomModel.fixIids(level, room);
  return ent;
};

RoomModel.entityAt = function (room, px, py) {
  var ents = list(room.entities);
  for (var i = ents.length - 1; i >= 0; i--) {
    var e = ents[i];
    if (px >= e.x && py >= e.y && px < e.x + e.w && py < e.y + e.h) return e;
  }
  return null;
};

RoomModel.moveEntity = function (level, room, ent, tx, ty) {
  var ts = level.tile_size;
  tx = Math.max(1, Math.min(room.tiles_w, tx));
  ty = Math.max(1, Math.min(room.tiles_h, ty));
  ent.x = (tx - 1) * ts;
  ent.y = (ty - 1) * ts;
  ent.tx = Math.min(room.tiles_w, Math.floor((ent.x + ent.w / 2) / ts) + 1);
  ent.ty = Math.min(room.tiles_h, Math.floor((ent.y + ent.h / 2) / ts) + 1);
  return ent;
};

RoomModel.removeEntity = function (room, ent) {
  var i = list(room.entities).indexOf(ent);
  if (i < 0) return false;
  room.entities.splice(i, 1);
  return true;
};

RoomModel.parseFields = function (text) {
  var out = {};
  var parts = String(text).split(",");
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i];
    var m = part.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([\s\S]*?)\s*$/);
    if (!m) {
      if (/\S/.test(part)) return null;
      continue;
    }
    var key = m[1];
    var value = m[2];
    var num = Number(value);
    if (value !== "" && !Number.isNaN(num)) value = num;
    else if (value === "true") value = true;
    else if (value === "false") value = false;
    else value = value.replace(/^"(.*)"$/, "$1");
    out[key] = value;
  }
  return out;
};

RoomModel.fieldsText = function (fields) {
  var keys = Object.keys(fields || {}).filter(function (k) {
    return typeof fields[k] !== "object";
  }).sort();
  var parts = [];
  for (var i = 0; i < keys.length; i++) parts.push(keys[i] + "=" + String(fields[keys[i]]));
  return parts.join(", ");
};

// ---------------------------------------------------------------------------
// Props: a room's optional { type, tx, ty, w, h, fields } list. They are not entities.
// ---------------------------------------------------------------------------

RoomModel.addProp = function (room, prop) {
  var p = copy(prop);
  if (!p.fields) p.fields = {};
  if (!room.props) room.props = [];
  room.props.push(p);
  return p;
};

RoomModel.moveProp = function (room, prop, tx, ty) {
  prop.tx = tx;
  prop.ty = ty;
  return prop;
};

RoomModel.resizeProp = function (room, prop, w, h) {
  prop.w = w;
  prop.h = h;
  return prop;
};

RoomModel.removeProp = function (room, prop) {
  var props = list(room.props);
  var i = props.indexOf(prop);
  if (i < 0) return false;
  props.splice(i, 1);
  if (props.length === 0) delete room.props;
  return true;
};
RoomModel.deleteProp = RoomModel.removeProp;

// Stores only non-default field values: setting one to `defaultValue` removes it.
RoomModel.setPropField = function (prop, key, value, defaultValue) {
  if (!prop.fields) prop.fields = {};
  if (arguments.length >= 4 && deepEqual(value, defaultValue)) delete prop.fields[key];
  else prop.fields[key] = value;
  return prop;
};

RoomModel.propsAt = function (room, tx, ty) {
  var props = list(room.props);
  var out = [];
  for (var i = 0; i < props.length; i++) {
    var p = props[i];
    if (tx >= p.tx && ty >= p.ty && tx < p.tx + p.w && ty < p.ty + p.h) out.push(p);
  }
  return out;
};

// ---------------------------------------------------------------------------
// Checks
// ---------------------------------------------------------------------------

RoomModel.checkRoom = function (level, room) {
  var out = [];
  if (list(room.exits).length === 0) out.push({ message: "no doors" });
  for (var i = 0; i < list(room.exits).length; i++) {
    var e = room.exits[i];
    if (RoomModel.get(room, e.tx, e.ty) === RoomModel.SOLID) {
      out.push({
        message: "the " + e.side + " door at " + e.tx + "," + e.ty + " is inside a wall",
        tx: e.tx, ty: e.ty
      });
    }
  }
  // a file made elsewhere can have a gap the editor has not turned into a door yet
  var probe = { exits: copy(list(room.exits)), collision: room.collision, tiles_w: room.tiles_w,
    tiles_h: room.tiles_h, w: room.w, h: room.h };
  RoomModel.syncBorderDoors(level, probe);
  for (var g = 0; g < probe.exits.length; g++) {
    var pe = probe.exits[g];
    if (!findExit(room, pe.side, pe.offset)) {
      out.push({ message: "the gap at " + pe.tx + "," + pe.ty + " has no door yet: any edit adds it", tx: pe.tx, ty: pe.ty });
    }
  }
  if (room.item && RoomModel.get(room, room.item.tx, room.item.ty) === RoomModel.SOLID) {
    out.push({
      message: "the item is inside a wall", tx: room.item.tx, ty: room.item.ty
    });
  }
  return out;
};

// The checks of one room plus engine/level.lua's validation of that room, without writing
// the whole level: cheap enough to run after every edit. check(level) is the full check.
RoomModel.checkRoomFull = function (level, room) {
  var out = [];
  var problems = RoomModel.checkRoom(level, room);
  for (var p = 0; p < problems.length; p++) {
    var problem = { roomId: room.id, message: problems[p].message };
    if (problems[p].tx !== undefined) problem.tx = problems[p].tx;
    if (problems[p].ty !== undefined) problem.ty = problems[p].ty;
    out.push(problem);
  }
  for (var i = 0; i < level.rooms.length; i++) {
    if (level.rooms[i] !== room && level.rooms[i].id === room.id) {
      out.push({ roomId: room.id, message: "duplicate id " + room.id });
      break;
    }
  }
  var err = validateRoom(level, list(emptyToArray(level.tilesets)), room);
  if (err) out.push({ roomId: room.id, message: err });
  return out;
};

RoomModel.check = function (level) {
  var out = [];
  var start = false;
  var seen = new Set();
  for (var i = 0; i < level.rooms.length; i++) {
    var room = level.rooms[i];
    if (room.type === "start") start = true;
    if (seen.has(room.id)) out.push({ roomId: room.id, message: "duplicate id " + room.id });
    seen.add(room.id);
    var problems = RoomModel.checkRoom(level, room);
    for (var p = 0; p < problems.length; p++) {
      var problem = { roomId: room.id, message: problems[p].message };
      if (problems[p].tx !== undefined) problem.tx = problems[p].tx;
      if (problems[p].ty !== undefined) problem.ty = problems[p].ty;
      out.push(problem);
    }
  }
  if (level.rooms.length > 0 && !start) {
    out.push({ roomId: "", message: "no room has type start (procgen needs one)" });
  }
  var result = RoomModel.fromText(RoomModel.toText(level));
  if (result.error) out.push({ roomId: "", message: result.error });
  return out;
};

// ---------------------------------------------------------------------------
// Undo. A step keeps a shallow copy of the room list (cheap: the room objects are shared)
// and, when the step edits one room, a deep copy of that room only. Undo puts the list back
// and restores that room's contents in place, so a room object keeps its identity and the
// lists kept by older steps stay valid. Call push(level, roomIndex) before changing that
// room in place, or push(level) before an operation on the list (add, delete, move, import).
// ---------------------------------------------------------------------------

function restoreInPlace(target, saved) {
  var k;
  for (k in target) {
    if (Object.prototype.hasOwnProperty.call(target, k)) delete target[k];
  }
  for (k in saved) {
    if (Object.prototype.hasOwnProperty.call(saved, k)) target[k] = saved[k];
  }
}

function snapshot(level, roomIndex) {
  var room = (roomIndex !== undefined && roomIndex !== null) ? level.rooms[roomIndex] : null;
  var saved = null;
  if (room) {
    saved = copy(room);
    delete saved.grid;
  }
  return {
    rooms: level.rooms.slice(), room: room || null, saved: saved,
    tilesets: copy(level.tilesets), at: roomIndex === undefined || roomIndex === null ? 0 : roomIndex
  };
}

function apply(level, step) {
  level.rooms = step.rooms;
  level.tilesets = step.tilesets;
  if (step.room) restoreInPlace(step.room, step.saved);
}

RoomModel.history = function (limit) {
  return {
    undo: [], redo: [], limit: limit || MAX_HISTORY,
    push: function (level, roomIndex) {
      this.undo.push(snapshot(level, roomIndex));
      if (this.undo.length > this.limit) this.undo.shift();
      this.redo = [];
    },
    undoStep: function (level) {
      if (this.undo.length === 0) return null;
      var step = this.undo.pop();
      this.redo.push(snapshot(level, step.room ? level.rooms.indexOf(step.room) : null));
      if (step.room) this.redo[this.redo.length - 1].at = step.at;
      apply(level, step);
      return step.at;
    },
    redoStep: function (level) {
      if (this.redo.length === 0) return null;
      var step = this.redo.pop();
      this.undo.push(snapshot(level, step.room ? level.rooms.indexOf(step.room) : null));
      if (step.room) this.undo[this.undo.length - 1].at = step.at;
      if (this.undo.length > this.limit) this.undo.shift();
      apply(level, step);
      return step.at;
    }
  };
};

// ---------------------------------------------------------------------------
// Library helpers for many rooms
// ---------------------------------------------------------------------------

RoomModel.listRooms = function (level, filter) {
  filter = filter || {};
  var out = [];
  for (var i = 0; i < level.rooms.length; i++) {
    var room = level.rooms[i];
    if (filter.biome !== undefined && filter.biome !== null &&
      RoomModel.getBiome(room) !== filter.biome) continue;
    if (filter.type !== undefined && filter.type !== null && room.type !== filter.type) continue;
    if (filter.tag !== undefined && filter.tag !== null &&
      list(room.tags).indexOf(filter.tag) < 0) continue;
    if (filter.search !== undefined && filter.search !== null && filter.search !== "") {
      var hay = [room.id, RoomModel.getBiome(room), room.type]
        .concat(list(room.tags)).join(" ").toLowerCase();
      if (hay.indexOf(String(filter.search).toLowerCase()) < 0) continue;
    }
    out.push(room);
  }
  return out;
};

RoomModel.groupRooms = function (level) {
  var out = {};
  for (var i = 0; i < level.rooms.length; i++) {
    var room = level.rooms[i];
    var biome = RoomModel.getBiome(room);
    var type = room.type || "normal";
    if (!out[biome]) out[biome] = {};
    if (!out[biome][type]) out[biome][type] = [];
    out[biome][type].push(room.id);
  }
  return out;
};

RoomModel.counts = function (level) {
  var byType = {};
  var byBiome = {};
  for (var i = 0; i < level.rooms.length; i++) {
    var room = level.rooms[i];
    var type = room.type || "normal";
    var biome = RoomModel.getBiome(room);
    byType[type] = (byType[type] || 0) + 1;
    byBiome[biome] = (byBiome[biome] || 0) + 1;
  }
  return {
    rooms: level.rooms.length, total: level.rooms.length,
    types: Object.keys(byType).length, biomes: Object.keys(byBiome).length,
    byType: byType, byBiome: byBiome
  };
};

RoomModel.importRooms = function (level, other, opts) {
  opts = opts || {};
  var conflict = opts.onConflict || "rename";
  if (["rename", "replace", "skip"].indexOf(conflict) < 0) {
    return { error: "onConflict must be rename, replace or skip" };
  }
  if (!other || other.tile_size !== level.tile_size ||
    !other.cell || !level.cell || other.cell.w !== level.cell.w || other.cell.h !== level.cell.h) {
    return { error: "the levels need the same tile_size and cell" };
  }
  var result = { added: 0, renamed: 0, replaced: 0, skipped: 0 };
  var rooms = list(other.rooms);
  for (var i = 0; i < rooms.length; i++) {
    var src = rooms[i];
    var existing = RoomModel.findRoom(level, src.id);
    if (!existing) {
      var added = copy(src);
      delete added.grid;
      level.rooms.push(added);
      result.added++;
    } else if (conflict === "skip") {
      result.skipped++;
    } else if (conflict === "replace") {
      var idx = RoomModel.roomIndex(level, existing.id);
      var replaced = copy(src);
      delete replaced.grid;
      level.rooms[idx] = replaced;
      result.replaced++;
    } else {
      var renamed = copy(src);
      delete renamed.grid;
      renamed.id = RoomModel.freeId(level, src.id);
      level.rooms.push(renamed);
      result.renamed++;
    }
  }
  return result;
};

if (typeof module !== "undefined" && module.exports) module.exports = RoomModel;
if (typeof globalThis !== "undefined") globalThis.RoomModel = RoomModel;
