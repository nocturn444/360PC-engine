# The Blob's look

> **Pending the owner's confirmation.** The design and the numbers here were chosen by an AI agent
> as examples. They are not decisions yet (see AGENTS.md, section 9).

Every mutation can change the slime's appearance, and some change its body. The data lives in the
mutation entries (`look` and `body`); `examples/rooms/rooms_look.lua` turns the run's acquired
entries into one look and draws it with `engine.pixelgrid`. Nothing is allocated in the per-frame
draw path.

## Look data

A mutation's `look` fragment can set:

| Field | Meaning |
|---|---|
| `body_color`, `outline_color`, `eye_color`, `pupil_color` | RGB colours; the palette uses indices 1 body, 2 outline, 3 eye, 4 pupil, 5 default limb |
| `limb_color` | RGB: this fragment's own limb colour, in its own palette slot (6, 7, ...), used only by this fragment's limbs whose `color` is 5 or unset; a number: the default limb palette index |
| `eye_count` | how many eyes to draw |
| `shape = { sx, sy }` | draw-only scale of the outline (stretchy, flat, tall); does not change the hitbox |
| `limbs` | array of `{ anchor = 0..1, side = -1/1, length, width, color, kind }` |
| `stacks` | how many times a stackable fragment applies (limbs repeat, capped at 4) |

`M.rebuild(entries)` starts from the base look and applies each acquired entry in order. A body
fragment is last-wins: `body = { radius, width, height }` (all optional) becomes
`look.physical` and is passed to the soft body.

## Physical bodies

`body` is separate from `look`: it changes the soft body's rest shape with
`Body:set_rest_shape(opts)` (engine module `softbody`). That changes the points, the springs and
the `softbody.box` used by the fighter, so the hitbox follows. A mutation without `body` only
changes the drawing and never the hitbox. The current examples are:

- `example_spring_heel`: colours and two antenna limbs, no hitbox change.
- `example_carapace`: a shell limb and a shield stat, no hitbox change.
- `example_legs`: a wider/taller body, four drawn legs and a speed stat. This changes both the
  hitbox and the movement (through the stat); it does not add a new walking locomotion model.

## Drawing

In `rooms_play.lua`:

1. `looks.palette(self.look, self.pixels)` copies the colours into the existing palette entries
   when the look changes (not every frame). The palette has five base entries plus one per
   mutation limb colour (created there, on acquisition).
2. Each frame: `slime:outline(self.points, ...)`, `looks.shape(self.points, self.look)`,
   `px:polygon(points, 1)`, `px:outline(2)`, `looks.draw_limbs(px, self.look, points)`.
3. Eyes use `look.eye_count` and the eye/pupil colours from the palette.

`draw_limbs` anchors each limb to an outline point, grows it outward and clips with `px:set`, so a
limb cannot escape the 40x40 grid. It uses only locals and numeric loops.

## Adding a cosmetic

1. Put a `look` fragment in the mutation entry; every mutation should be visible somehow.
2. Use `body` only when the mutation should change the soft body and hitbox; keep the changes
   moderate so the slime still fits doors and corridors.
3. If it is stackable, use `stacks` or data that scales with the count; `M.apply` already repeats
   limbs per stack.
4. Add a case to `tests/pc/rooms_look_test.lua` and, for physical changes, to
   `tests/engine/softbody_shape_test.lua`.
