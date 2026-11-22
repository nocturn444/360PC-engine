# room_editor_web

A touch-friendly web room editor for the level files of `engine.level` (docs/LEVELS.md). It
runs from a phone: plain modern JavaScript loaded with `<script src>`, no dependencies, no npm,
no build step and no transpiler. It is a development tool and is never packaged for the console.

Files:

- `index.html`, `css/app.css`: the page (dark, touch first, 360 px wide and up).
- `js/app.js` (`App`): shared state, screens, sheets and dialogs, autosave, Android back.
- `js/storage.js` (`Storage`): projects, files, share and GitHub through the Android app's
  `window.Android` bridge (`android/room_editor/README.md`), or `localStorage` and downloads
  in a plain browser.
- `js/catalog.js` (`Catalog`): the props catalog (docs/PROPS.md); `default_catalog.lvl` is the
  built-in copy of `examples/rooms/props_catalog.lvl`.
- `js/render.js` (`Render`): draws a room (editor and cached thumbnails).
- `js/library.js`, `js/editor.js`, `js/sync.js`, `js/settings.js`: the four screens.

The data layer:

- `js/savefmt.js` (`SaveFmt`): reader and writer of the text format of `engine/save.lua`, byte
  compatible with the Lua serializer.
- `js/model.js` (`RoomModel`): a level and its rooms, collision, doors, the item, entities,
  props, biomes, undo/redo, checks, filters and importing rooms from another file.

Open `index.html` in a browser, or `require` the data files from Node.

Tests:

```sh
node tests/tools/room_editor_web_test.js
node tests/tools/room_editor_web_smoke.js   # needs Playwright; skipped without it
```

The tests cover the LDtk fixture round trip, the writer against `engine/save.lua` with LuaJIT,
a level made in JavaScript read by `engine.level` and `tools/level_editor/model.lua`, the
editing operations, props, undo, checks, filters, grouping and import conflicts.
