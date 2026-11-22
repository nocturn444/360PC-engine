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
node tests/tools/room_editor_web_editor_test.js
node tests/tools/room_editor_web_sync_test.js
node tests/tools/room_editor_web_smoke.js   # needs Playwright; skipped without it
node tests/tools/room_editor_web_flow.js    # touch click-through at phone size, needs Playwright
```

The tests cover the LDtk fixture round trip, the writer against `engine/save.lua` with LuaJIT,
a level made in JavaScript read by `engine.level` and `tools/level_editor/model.lua`, the
editing operations, props, undo, checks, filters, grouping and import conflicts.

## Using it

- **Library:** tap the project name to switch or create projects. Chips filter by biome and
  type, the search box by id, biome, type or tag. Rooms are grouped biome, then type; tap a
  header to fold it. Tap a room to edit it; hold it (or tap ...) for variant, rename, biome,
  type, move and delete. The + button makes a room in the current biome and type.
- **Editor:** one finger uses the tool, two fingers pan and zoom, a double two-finger tap fits
  the room. Painting shows the tile under your thumb magnified above it. The arrows at the top
  go to the previous/next room of the library filter; Variant duplicates the room and opens the
  copy. Tap the room id for its settings (id, biome, type, weight, tags, size) and checks.
  Tools: Solid, Way (one-way), Erase (Free/Rect/Fill mode), Door (tap a border tile; a new door
  opens its tile), Item, Ent (entity, pick the name on the button above), Prop (pick a type from
  the palette), Sel (select, drag to move, corner handle to resize a prop, Edit for its fields).
- **Sync:** export or share the file, import or merge one, and with the Android app open files
  from the repository and upload changed projects as a pull request (never to `main`).
- **Settings:** GitHub token (stored only in the app), folders, biome/type/entity lists, grid,
  left-handed layout.

Everything saves by itself about a second after each change.
