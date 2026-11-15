# examples/engine_demo/

The smallest game that uses every module of `engine/` ([docs/ENGINE.md](../../docs/ENGINE.md)): a
menu, a play state and a pause state; a sprite made of two layers (one animated with anim8) that
moves with actions through two rooms; a camera that follows it, slides from room to room and
shakes; all drawn at 320x180 and scaled by a whole number. The sprite is an entity with two
modifiers on its speed: one that stays (+25%) and one that the action key gives for two seconds
(+60).

Keys: Enter / A to start, arrows or WASD / left stick or d-pad to move, X / mouse button / X or
right trigger to toggle the second layer and shake, P / Start to pause, Escape / B to quit while
paused.

To run it on LÖVE 11.x, put copies (or links) of the repository's `engine/` and `lib/` folders in
this folder, then `love examples/engine_demo`. The packaging script (objective 9) will do that
copy. Checks, from the repository root:

```sh
luajit -joff tests/engine/run.lua demo_test                 # on a fake love
luajit -joff tests/pc/boot_pc.lua examples/engine_demo      # on the console's boot, without a GPU
```

On the console the text is not drawn until the game sets `default_font` in `game.lua` (the
console has no built-in font); the demo ships no TTF.
