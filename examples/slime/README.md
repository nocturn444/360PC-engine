# examples/slime

A soft-body slime in a small room: the body is `engine/modules/softbody`, and every frame its
outline is rasterized into a 40 x 40 `engine.pixelgrid` (body, a one-pixel outline, eyes that
look where it moves) and drawn on the game's pixel grid. No sprite.

| Action | Keyboard | Controller |
|---|---|---|
| Move | Left / Right, A / D | Left stick |
| Jump | Space, Up, W | A |
| Squash (let go on the ground: a higher jump) | Down, S | Left stick down |
| Tuning overlay: open / close | Tab | LB |
| Choose a number / change it | Page Up / Page Down, [ / ] | D-pad |
| Save the numbers (loaded at the next start) | F5 | RB |
| Quit | Escape | Hold Back 3 s |

The overlay (`engine.tune`) changes the body's stiffness, pressure, damping, friction, gravity
and passes, and the controls' move, air move, jump, charged jump and squash, while the slime
runs. F5 / RB writes them to `tune_slime.txt` in the save folder; they are loaded at the next
start, on the PC or on the console. Copy the values you like into the code when they are final.

Run it on PC from the repository root: `love examples/slime`. On the console: package it like
any game (`python tools/package.py examples/slime --xex <xex>`, see
[docs/NEW_GAME.md](../../docs/NEW_GAME.md)).

What to look at on the console: the body stays crisp at x4 with no shimmer, its edge moves one
whole pixel at a time, it rests without creeping sideways, and the frame stays at 30 FPS.

Test: `luajit -joff tests/pc/slime_test.lua` (boots on the console's boot and plays a short run
on the fake love).
