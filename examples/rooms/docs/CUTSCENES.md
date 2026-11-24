# Cutscenes and endings

The owner wants cutscenes for the game's endings. What they will look like is **not decided
yet**, so this builds a generic, data-driven player in the engine and plays placeholder ending
scripts in the prototype. Changing an ending later means editing data, not code.

Both steps are done on this branch:

1. **Engine (done):** `engine/cutscene.lua` (generic, knows nothing about a game), tests, docs.
2. **Game (done):** `examples/rooms/rooms_endings.lua` (ending list + placeholder scripts),
   `rooms_cutscene.lua` (the state that plays one), hooked into the victory of PR #88 and the
   profile's `endings` set; Progress > Endings can replay the ones already seen.

## 1. Engine: `engine/cutscene.lua`

Loaded on first use, like `engine.anim` (`engine.cutscene`). Plain Lua 5.1, only the console
LOVE subset, no allocation per step or per frame (allocate when a step starts, never in
`update` / `draw`). Text is drawn with `engine.text` (no TTF on the console). No scissor (it is
a stub on the console), no canvases, no video.

### API

```lua
local cs = engine.cutscene.new(script, opts)
cs:input(input)      -- once per fixed step (reads the advance and skip actions)
cs:update(dt)        -- once per fixed step
cs:draw()            -- in game pixels, inside the engine.pixel frame
cs:skip()            -- jump to the end (see Skip)
cs.done              -- true once the last step finished (or after skip)
cs.step_index        -- current step (for tests)
```

`opts`:

| Option | Meaning |
|---|---|
| `width`, `height` | Game resolution. Default `engine.screen`'s, else 320 x 180. |
| `audio` | An `engine.audio` (for `sound` / `music` steps). Optional: without it those steps do nothing. |
| `image` | `function(file)` returning a LOVE image. Default: `love.graphics.newImage` with a per-cutscene cache (the console caches textures by name and never frees them, so the cache only avoids repeated calls). |
| `actions` | `{ advance = "ui_accept", skip = "ui_back" }` by default. |
| `skippable` | Overrides `script.skippable`. |
| `on_finish(cs, skipped)` | Called once when it ends. |

A script is data:

```lua
{
  id = "ending_example",
  skippable = true,             -- default true
  background = { 0, 0, 0 },     -- clear colour drawn first (full-screen rectangle)
  steps = { ... },              -- run in order
}
```

### Steps

Every step is a table whose first array item is its kind. Scripts are linear (no labels or jumps). Steps run one after another; a step
with `wait = false` starts the next one at once (so moves, fades and text can run together).
Unknown kinds and missing required fields raise an error **when the cutscene is created**,
naming the step index and field.

| Kind | Fields | What it does |
|---|---|---|
| `wait` | `time` | Waits `time` seconds. |
| `fade` | `to` (0..1, 1 = fully covered), `time`, `color` (default black) | Tweens a full-screen overlay drawn on top of everything except the skip hint. A script usually starts with `{ "fade", to = 0, time = 1 }` after setting the overlay to 1 with `{ "fade", to = 1, time = 0 }`. |
| `show` | `id`, then either `image` (file) with optional `quad = { x, y, w, h }`, or `rect = { w, h }` with `color`; `x`, `y`, `layer` (draw order, default 0), `alpha` (default 1), `scale` (default 1), `parallax` (default 1: how much the view pan moves it; 0 = fixed to the screen) | Adds or replaces an element. Placeholder art uses `rect`. |
| `hide` | `id` | Removes an element. |
| `move` | `id`, `x`, `y` and/or `alpha`, `time`, `ease` (`"linear"`, `"in"`, `"out"`, `"inout"`; default `"inout"`) | Tweens an element. |
| `pan` | `x`, `y`, `time`, `ease` | Tweens the view offset (every element is drawn at `pos - view * parallax`, rounded to whole pixels). |
| `shake` | `amount` (pixels), `time` | Shakes the view, deterministic (no `math.random`: a fixed pattern or `engine.rng` with a fixed seed). |
| `text` | `text`, `x`, `y`, `w` (wrap width), `align`, `color`, `scale` (default 1), `speed` (characters per second, default 30; 0 = all at once), `id` (optional, to `hide` it later), `wait` (`"button"`, a number of seconds, or `false`) | Shows a text block, typed out. Default `wait = "button"`: the advance action first finishes the typing, a second press continues. The block stays on screen until hidden or until the next `text`/`say` with the same id. |
| `say` | `text`, `speaker` (optional name), `speed`, `wait` | A dialogue box at the bottom of the screen (full width minus margins, about 3 lines of `engine.text`), speaker name above the text. Same typing and waiting as `text`. The box is removed when the next step that is not a `say` starts. |
| `sound` | `name`, `volume`, `pitch` | `audio:play(...)`. Never waits. |
| `music` | `name` (nil = stop), `fade` | `audio:music(name, { fade = ... })`. Never waits. |
| `call` | `fn` | `fn(cs)`: a hook for the game (unlock something, set a flag). Never waits. |

Typing must not allocate per frame: when a `text` / `say` step starts, wrap it once
(`engine.text` wrap logic, `w` limit) and keep the lines; drawing shows the first N characters
by drawing whole lines plus a prefix of the current line taken from a table of prefixes built
at step start (or another allocation-free way). Do not call `string.sub` in `draw`.

### Input

- `advance` (default `ui_accept`, A / Enter / Space): finishes the current typing, or continues
  a `wait = "button"` step. A small blinking marker shows in the corner of the text box when it
  waits for the button.
- `skip` (default `ui_back`, B / Escape): if the cutscene is skippable, **holding** it for
  1 second skips (a short press does nothing, so a stray press does not throw away an ending).
  While held, a small "HOLD TO SKIP" label with a filling bar is drawn bottom right.

### Skip

`cs:skip()` stops every tween and ends at once: `done = true`, `on_finish(cs, true)`. Steps not
reached are not run, except `call` steps with `always = true` (so a game can mark something
that must happen even when skipped). Music is left as the script last set it.

### Docs and tests

- `docs/ENGINE.md`: a new `## engine.cutscene` section (API, steps table, input, skip), and the
  module list at the top.
- `engine/README.md` if it lists modules; `CHANGELOG.md` under `[Unreleased]` / Added.
- `tests/engine/cutscene_test.lua`, registered in `tests/engine/run.lua`: validation errors name
  the step and field; wait/fade/move/pan timing; `wait = false` runs steps together; typing
  speed and the two-press advance; hold-to-skip (short press does nothing, 1 s skips, not when
  `skippable = false`); `call` with `always`; `on_finish` once with the right `skipped`; sound and
  music go to a fake audio; draw uses no `printf`/`print`/`setFont` and no `setScissor`; no
  allocation in `update` and `draw` (same check other tests use, with `collectgarbage("count")`
  over many frames).

## 2. Game: endings in `examples/rooms`

Depends on PR #88 (victory when the final boss dies, `rooms_profile.lua` with `endings`).

### `rooms_endings.lua`

A list of endings as data. Names and order come from the owner's world-building drafts; every
script is a **placeholder** (coloured rectangles and short English text) until the owner
defines them. Each entry:

```lua
{ id = "plush", kind = "partial", name = "The Plush", script = { ... } }
```

The list, in order (all placeholders): partial `plush`, `clone_machine`, `lab_evidence`,
`cryo_scientist`, `helpful_ai`, `ai_vs_scientist`; true `true_natural`, `true_ai`,
`true_human`; secret `secret`. `M.get(id)` finds one. `M.pick(run)` chooses which ending a
victory plays: the rules are not defined yet, so it always returns `plush` (the first partial
ending); the function exists so the rules have one place to go.

Each script has 12 steps and uses one helper (`placeholder`): a background, two coloured
rectangles, a fade in, one move and one pan, a short hint line and "THIS IS A PLACEHOLDER
ENDING.", the final `ENDING: <NAME>` and `PLACEHOLDER` text, and a fade out. The single line
taken from the world-building drafts is the hint in each scene (the plush, the melting clone
machine, the lab evidence, the cryo scientist, the helpful AI, the AI against the scientist,
nature / AI / humanity, the secret under the lab); everything else is generic so the owner can
replace it.

### `rooms_cutscene.lua`

A state that plays a script: `enter(previous, script, on_finish)`. Opaque (draws its own
background), `autopause = false`, so a dead battery during an ending does not open the pause
menu over it. It forwards input, update and draw to the `engine.cutscene` it builds with the
game's `engine.audio` (`profile.audio`, or nil when there is none) and ticks that audio. When
the cutscene ends it calls `on_finish(skipped)` once. It is registered as `cutscene` in
`main.lua`.

### Hooks

- Victory (PR #88): when the final boss dies, after the existing short delay, `rooms_play`
  pushes the cutscene with `rooms_endings.pick(play)`. When it finishes (played or skipped)
  the callback records the ending with `profile.see_ending(id)` (which writes the save only
  the first time), pops the cutscene and pushes the end-of-run menu titled "Victory". The play
  state stays under the menu exactly as after a death, so Stats and Restart Run still work.
- Progress > Endings: one row per ending in `rooms_endings.list` order; seen ones show their
  name and can be selected to replay (the cutscene pops back to the page when it ends); unseen
  ones show "???". Completion % counts the endings (see below).
- Preview mode: every ending is listed by name and playable, and the page title says
  "Endings (PREVIEW)". It is on when `engine.debug.flag()` is true or when the build version
  (`rooms_version.lua`) contains "-test", so the owner can preview them on the console without
  winning a run.
- Profile completion: `completion_counts()` adds the endings from `rooms_endings.list`.

### Tests

In `tests/pc/rooms_example_test.lua`: victory plays the picked ending, then the Victory menu
with the play state under it; the ending is saved in the profile even when skipped (hold Back
1 s); Progress > Endings shows "???" for unseen and the name for seen ones, replays a seen one
and returns to the page; preview mode lists every ending by name and plays an unseen one; every
ending script validates (`engine.cutscene.new` on each); each script runs to the end with
simulated presses within 120 s; draws fit 320 x 180 with no printf / print / setFont.
`tests/pc/rooms_profile_test.lua` covers `see_ending` and the endings in the completion.
