# room_editor_web

A touch-friendly web room editor for the level files of `engine.level` (docs/LEVELS.md). It
runs from a phone: plain modern JavaScript loaded with `<script src>`, no dependencies, no npm,
no build step and no transpiler. It is a development tool and is never packaged for the console.

This part has **no UI**: it is the data layer.

- `js/savefmt.js` (`SaveFmt`): reader and writer of the text format of `engine/save.lua`, byte
  compatible with the Lua serializer.
- `js/model.js` (`RoomModel`): a level and its rooms, collision, doors, the item, entities,
  props, biomes, undo/redo, checks, filters and importing rooms from another file.

Part 2 adds the UI on top of these two globals. Open `js/savefmt.js` and `js/model.js` in a
browser, or `require` them from Node.

Tests:

```sh
node tests/tools/room_editor_web_test.js
```

The tests cover the LDtk fixture round trip, the writer against `engine/save.lua` with LuaJIT,
a level made in JavaScript read by `engine.level` and `tools/level_editor/model.lua`, the
editing operations, props, undo, checks, filters, grouping and import conflicts.
