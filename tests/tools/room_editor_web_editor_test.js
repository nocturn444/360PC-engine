// Tests of the room editor's pure editor helpers (EditorMath in tools/room_editor_web/js/editor.js).
// Run: node tests/tools/room_editor_web_editor_test.js (must end with "OK:").
"use strict";
var path = require("path");
var web = path.join(__dirname, "../../tools/room_editor_web/js/");
global.RoomModel = require(web + "model.js");
global.Catalog = require(web + "catalog.js");
var M = require(web + "editor.js");

var checks = 0;
function check(cond, what) { if (!cond) throw new Error("FAILED: " + what); checks++; }
function eq(a, b, what) { check(JSON.stringify(a) === JSON.stringify(b), what + ": " + JSON.stringify(a) + " vs " + JSON.stringify(b)); }

var view = { scale: 10, ox: 5, oy: 20 };
eq(M.tileAt(view, 5, 20), { tx: 1, ty: 1 }, "top left corner is tile 1,1");
eq(M.tileAt(view, 24.9, 39.9), { tx: 2, ty: 2 }, "inside tile 2,2");
eq(M.tileAt(view, 0, 0), { tx: 0, ty: -1 }, "outside the room gives tiles below 1");

eq(M.line({ tx: 1, ty: 1 }, { tx: 4, ty: 1 }).length, 4, "a horizontal line");
var diag = M.line({ tx: 1, ty: 1 }, { tx: 3, ty: 5 });
eq(diag[0], { tx: 1, ty: 1 }, "a line starts at its first tile");
eq(diag[diag.length - 1], { tx: 3, ty: 5 }, "a line ends at its last tile");
for (var i = 1; i < diag.length; i++) {
  check(Math.abs(diag[i].tx - diag[i - 1].tx) <= 1 && Math.abs(diag[i].ty - diag[i - 1].ty) <= 1, "a line has no gaps");
}
eq(M.rect({ tx: 5, ty: 2 }, { tx: 1, ty: 7 }), { x1: 1, y1: 2, x2: 5, y2: 7 }, "a rectangle is normalised");

var fit = M.fit(20, 12, 360, 500);
check(fit.scale * 20 <= 360 && fit.ox >= 0 && fit.oy >= 0, "fit keeps the room inside");
var z = M.zoomAt({ scale: 10, ox: 0, oy: 0 }, 50, 50, 2);
eq(M.tileAt(z, 50, 50), M.tileAt({ scale: 10, ox: 0, oy: 0 }, 50, 50), "zoom keeps the tile under the fingers");

var cat = Catalog.parse(require("fs").readFileSync(path.join(__dirname, "../../tools/room_editor_web/default_catalog.lvl"), "utf8")).catalog;
var level = RoomModel.newLevel({ tileSize: 16, cellW: 20, cellH: 12 });
var room = RoomModel.addRoom(level, "A", 1, 1);
RoomModel.toggleExit(level, room, 1, 10, false);
RoomModel.toggleItem(room, 5, 5);
var ent = RoomModel.addEntity(level, room, "Enemy", 8, 8);
var vine = RoomModel.addProp(room, Catalog.newProp(cat, "vine", 8, 6));
eq(M.pick(room, cat, 16, 8, 8).kind, "prop", "a prop wins over an entity on the same tile");
check(M.pick(room, cat, 16, 8, 8).obj === vine, "the prop object is picked");
RoomModel.removeProp(room, vine);
check(M.pick(room, cat, 16, 8, 8).obj === ent, "then the entity");
eq(M.pick(room, cat, 16, 1, 10).kind, "door", "a door");
eq(M.pick(room, cat, 16, 5, 5).kind, "item", "the item");
check(M.pick(room, cat, 16, 3, 3) === null, "nothing on an empty tile");

console.log("OK: " + checks + " checks");
