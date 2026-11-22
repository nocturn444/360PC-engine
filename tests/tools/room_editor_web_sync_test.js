// tools/room_editor_web: the pure helpers of the sync screen (changed projects, changed
// rooms and the default pull request title).
// Usage, from the repository root: node tests/tools/room_editor_web_sync_test.js
"use strict";

var assert = require("assert");
var path = require("path");

var ROOT = path.resolve(__dirname, "../..");
var M = require(path.join(ROOT, "tools/room_editor_web/js/model.js"));
var Sync = require(path.join(ROOT, "tools/room_editor_web/js/sync.js"));

var checks = 0;
function check(cond, what) {
  checks++;
  if (!cond) throw new Error("FAILED: " + what);
}
function eq(actual, expected, what) {
  checks++;
  assert.strictEqual(actual, expected, what);
}

// A small level from a list of { id, solid }, so two texts can be compared by room.
function levelText(rooms) {
  var level = M.newLevel({ tileSize: 16, cellW: 10, cellH: 6 });
  rooms.forEach(function (spec) {
    var room = M.addRoom(level, spec.id, 1, 1);
    if (spec.solid) M.set(room, 2, 2, M.SOLID);
  });
  return M.toText(level);
}

// --- changed rooms ------------------------------------------------------------------------

var twoRooms = levelText([{ id: "A" }, { id: "B" }]);
eq(Sync.changedRooms(twoRooms, twoRooms), 0, "the same text has no changed rooms");
eq(Sync.changedRooms(twoRooms, levelText([{ id: "B" }, { id: "A" }])), 0,
  "room order does not count as a change");
eq(Sync.changedRooms(twoRooms, levelText([{ id: "A" }, { id: "B", solid: true }])), 1,
  "one edited room");
eq(Sync.changedRooms(twoRooms, levelText([{ id: "A" }, { id: "B", solid: true },
  { id: "C" }])), 2, "an edit and an added room");
eq(Sync.changedRooms(twoRooms, levelText([{ id: "B" }])), 1, "a removed room counts");
eq(Sync.changedRooms(twoRooms, levelText([{ id: "C" }])), 3, "two removed ids and one added");
eq(Sync.changedRooms("", twoRooms), 2, "an empty before copy means every room is new");
eq(Sync.changedRooms(twoRooms, ""), 2, "an empty after copy means every room was removed");
eq(Sync.changedRooms(twoRooms, "not a level"), 0, "a text that does not parse gives no count");
eq(Sync.changedRooms("not a level", twoRooms), 0, "the other text that does not parse too");

// --- changed projects ---------------------------------------------------------------------

var local = [
  { name: "same.lvl", text: "unchanged" },
  { name: "edited.lvl", text: "new copy" },
  { name: "new.lvl", text: "never uploaded" }
];
var repo = { "same.lvl": "unchanged", "edited.lvl": "old copy" };
var changed = Sync.changedProjects(local, repo);
eq(changed.length, 2, "only the edited and the new project changed");
check(changed[0].name === "edited.lvl", "the edited project is first");
check(changed[1].name === "new.lvl", "a project without a repository copy is changed");
eq(local.length, 3, "changedProjects does not mutate its input");
eq(Sync.changedProjects([{ name: "x.lvl", text: "t" }], {}).length, 1,
  "an empty repository map marks everything as changed");
eq(Sync.changedProjects([{ name: "x.lvl", text: "t" }], { "x.lvl": "t" }).length, 0,
  "an empty project text matching an empty copy is unchanged");

// --- default title ------------------------------------------------------------------------

eq(Sync.defaultTitle(["alpha", "beta"], 3),
  "Rooms: alpha, beta (3 rooms changed)", "the default title lists the names and the count");
eq(Sync.defaultTitle(["one"], 1), "Rooms: one (1 rooms changed)",
  "the default title keeps the documented wording");

// --- the pieces together ------------------------------------------------------------------

var before = levelText([{ id: "A" }, { id: "B" }]);
var after = levelText([{ id: "A" }, { id: "B", solid: true }, { id: "C" }]);
var projects = [{ name: "rooms.lvl", text: after }];
var copies = { "rooms.lvl": before };
var dirty = Sync.changedProjects(projects, copies);
eq(dirty.length, 1, "the project is dirty");
eq(Sync.changedRooms(copies[dirty[0].name], dirty[0].text), 2,
  "the default title would count two changed rooms");

console.log("OK: " + checks + " checks");
