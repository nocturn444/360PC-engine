# Roadmap

Objectives, in order. Each one is delivered as its own pull request, with:
what changed, how to build it, what to test on PC and on the console, and
known risks.

1. **Repository layout and console build.** Documented build starting from
   Love360's: xsdk at the pinned commit, LuaJIT built for xsdk.
2. **Generic runtime.** The `.xex` loads `main.lua` and `conf.lua` from the
   game folder next to it. Each game declares in a config file: name,
   identifier, save folder, Aurora cover art and shaders. Nothing
   Balatro-specific.
3. **Generic shaders.** A registration mechanism so each game declares its
   shaders (`.psu`/`.vsu` plus metadata mapping uniforms to registers) without
   touching C. A documented build step that generates the console pair from the
   PC GLSL (adapting `glsl2hlsl.py` and xost).
4. **Extended LÖVE API**, generic for any 2D game:
   - SpriteBatch (`newSpriteBatch`, `add`, `set`, `clear`, `draw`), in C.
   - Real `print`/`printf` (font atlas), `line` and `circle`.
   - `love.timer.getTime`, `getDelta` and `getFPS`.
   - Keyboard on PC and controller on the 360 with a common mapping.
4b. **Extended LÖVE API, part two** (in C, compatible with official LÖVE):
    - ParticleSystem (subset): `emit`, `update`, `draw`; lifetime, speed,
      direction, spread, linear acceleration, damping, sizes, colors, rotation,
      quads, emission area. Fixed pool, no per-frame allocation.
    - `setBlendMode`: `"alpha"` and `"add"`.
5. **Compatibility.**
   - `docs/API_SUBSET.md`: exact list of implemented LÖVE functions and their
     limits.
   - `tools/compat_check.lua`: loaded in official LÖVE on PC, logs a warning
     when a game or library uses something outside that subset.
6. **Core (`engine/`).**
   - State machine.
   - Configurable fixed timestep.
   - Action-based input.
   - Camera with room bounds and room-to-room transitions.
   - Animations with anim8.
   - Pixel art pipeline: configurable low-resolution canvas, nearest filtering
     and integer scaling.
   - Layered sprites: extra visual layers per entity, in a fixed order.
7. **Entities and modifiers.** Entities made of components; modifiers defined
   as data in Lua, with stats (additions and multipliers, in a documented
   order of evaluation) and events (`on_jump`, `on_attack`, `on_hit`,
   `on_damaged`, `on_kill`, `on_update`...). A modifier never rewrites another.
8. **Seeded randomness.** Own generator (xorshift or PCG, integer arithmetic)
   with separate streams (`"level"`, `"loot"`, `"fx"`). Same seed, same result
   on PC and on the 360.
9. **Saves.** Run in progress (seed plus state) and permanent progress
   (unlocks), with a format version.
10. **Controller-first UI.** Focus, navigation with stick and buttons
    (mouse/keyboard on PC), buttons, lists, text and a generic "pick 1 of N"
    screen.
11. **Internal level format** (layers, tiles, entities with properties, room
    exits) and an own loader that hides the editor's library.
    OPEN DECISION: Tiled (STI) or LDtk as the initial editor. Pros and cons go
    to the owner first; the loader waits for the answer.
12. **`engine/modules/platformer/`.** bump.lua against the tilemap, one-way
    platforms, controller with configurable gravity, coyote time and jump
    buffering. Movement parameters exposed as data.
13. **`engine/modules/combat/`.** Hitboxes and hurtboxes, damage,
    invulnerability frames, knockback, hitstop and enemies with simple state
    machines.
14. **`engine/modules/procgen/`.**
    - Room graph, with hand-made rooms assigned by their exits.
    - Keys and locks through "abilities" (tags defined by the game).
    - Validation with BFS using the movement parameters.
    - Minimap data.
    - Generation spread over frames when done during play.
15. **`engine/modules/items/`.** Weighted pools, filters by room type and the
    `"loot"` stream; unlocks add entries to the pool.
16. **Libraries.** Pinned versions in `lib/` with their LICENSE, listed in
    `THIRD_PARTY_NOTICES.md` and checked with `compat_check.lua`.
17. **Tools.**
    - `template/`, packaging and a generic FTP installer.
    - Debug mode: visible seed that can be typed in, granting modifiers,
      hitbox overlay.
    - Bulk seed validator on PC.
    - Level hash test, PC against 360.
    - `docs/NEW_GAME.md`.
18. **Performance test (`examples/perf_platformer/`)**, with an overlay of
    FPS, update ms, draw ms, draw calls and active particles:
    - A generated level.
    - N enemies with combat (N = 0, 50, 100, 200).
    - 500, 1000 and 2000 particles.
    - A table for the owner's console measurements.
    Target: 30 FPS on PC and console alike (decided 2026-11-16, to be
    reviewed later). If it does not hold a steady 30 FPS with 50 enemies and
    500 particles:
    measure what weighs most and propose what to move to C.
19. **Semantic versioning.** `CHANGELOG.md` and tags.

The first game built on the base is a platformer roguevania, but nothing in
`engine/` or `runtime/` may depend on it: genre-specific code lives in
`engine/modules/` and game-specific code in the game's own repository.
