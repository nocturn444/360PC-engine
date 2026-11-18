# Level editor

`tools/level_editor` is an interactive editor for the rooms of a level, made with LÖVE on the PC.
It reads and writes the same level file that `tools/ldtk_convert.py` writes ([LEVELS.md](LEVELS.md)),
so `engine.level`, `procgen` and `rooms` use what it saves as it is. It is a development tool
and never goes to the console (`tools/` is left out of a package).

```
love tools/level_editor levels/world.lvl [--root <game folder>] [--cell 20x12] [--tile 16]
```

On Windows, `level_editor.bat` at the root of the base finds LOVE and opens it. You can drag a
`.lvl` file onto the script, or double-click it and type a path. If the file does not exist, a
new level starts with one `start` room, and Ctrl+S creates the file. `--cell` (tiles per map
cell, default 20x12) and `--tile` (pixels per tile, default 16) only apply to a new level.

The tile layers of a level converted from LDtk are drawn under the collision. Their tileset
paths are relative to the game folder, which the editor looks for upwards from the file (the
first folder that holds a `game.lua` or `main.lua`). Use `--root` to give it directly. The
editor keeps tile layers as they are and does not paint them yet. Keep painting tiles in LDtk,
or leave them out for collision-only rooms.

## What it edits

| | |
|---|---|
| Collision | Solid and one-way tiles. Left drag paints, right drag erases, and Shift+drag fills a rectangle. F fills the area under the mouse. |
| Doors | Click a tile on the border to add a door, and click it again to remove it. Each map cell side holds one door, so a second door on the same side moves the first one. On a corner, Shift makes the door up or down instead of left or right. With a door selected, Enter edits the abilities it `requires` (comma separated). |
| Item | The room's ability item (at most one). Click to place or move it, and right click to remove it. |
| Entities | Click to place an entity with the current name. N changes the name, or renames the selected entity. Drag an entity to move it and right click to delete it. Enter edits its fields as `key=value, ...` (numbers, `true` / `false`, text). |
| Rooms | The panel on the left lists the rooms. New, Copy, Delete (press it twice), Move up / down (the order is part of what a seed generates), and the Id, Type, Tags, Weight and size in map cells. Resizing keeps the top left part of the room and adds a solid border to new space. Doors, entities and tiles that end up outside the room are dropped, along with right and bottom doors when that side moves. |

The panel on the right shows the selection and the **checks**, which update after every change:

- A room without doors.
- A door or the item inside a wall.
- A pair of doors not reachable from each other with the default jump (`procgen.reach`, at
  90 % of `platformer.params.reach`).
- No room of type `start`.
- Anything `engine.level` would refuse.

Click a check to go to its room.

## Play test

P drops a platformer body (`engine/modules/platformer`, default parameters) into the room and
runs it at 60 steps a second. It starts on an entity named `Spawn`, `Player` or `Start` if the
room has one. Otherwise it starts under the mouse, or at the first door. Arrows or WASD move,
Space jumps, R puts the body back at the start, and Esc or P returns to editing. Falling out of
the room also puts it back.

## Keys

| Key | |
|---|---|
| 1 to 7 | Tools: Solid, One-way, Erase, Door, Item, Entity, Select |
| Ctrl+S, Ctrl+Shift+S | Save, save as. The previous file is kept as `<file>.bak`. |
| Ctrl+Z, Ctrl+Y (or Ctrl+Shift+Z) | Undo, redo. Every change can be undone, a deleted room too. |
| Ctrl+N, Ctrl+D | New room, copy of this room |
| PgUp, PgDn / Tab | Previous, next room |
| Delete | Delete the selection, or the room if nothing is selected (press it twice) |
| Mouse wheel, middle drag (or Space+drag) | Zoom, pan. Home or 0 fits the room in the window. |
| L, G | Show or hide the tile layers and the grid |
| Esc | Clear the selection. With unsaved changes, it asks once before quitting. |

## LDtk and this editor

Both write the same level file:

- `tools/ldtk_convert.py` turns an LDtk project into a level file.
- This editor opens a level file, edits it in place, and saves it again. The same file always
  gives the same bytes.

Rooms changed here are not written back to the `.ldtk` project. If the project is converted
again, it replaces the file and the changes made here are lost. Pick one source for each level
file.

## Tests

`luajit -joff tests/pc/level_editor_test.lua` must end with `OK:`. It tests the model
(`tools/level_editor/model.lua`) and drives the window on the fake love: painting, rectangles,
undo, doors and their abilities, the item, entities, rooms from the panel, saving, the file
read back by `engine.level`, the play test, and quitting with unsaved changes. The LDtk fixture
is converted, opened and saved back.
