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
5. **Compatibility.**
   - `docs/API_SUBSET.md`: exact list of implemented LÖVE functions and their
     limits.
   - `tools/compat_check.lua`: loaded in official LÖVE on PC, logs a warning
     when a game or library uses something outside that subset.
6. **Generic engine layer (`engine/`).** State machine, fixed timestep
   (configurable rate), simple entities, action-based input (configured per
   game), camera, animations with anim8, saves in the folder each game
   declares.
7. **Optional platformer module (`engine/modules/platformer/`).** Tiled maps
   with STI (needs SpriteBatch), AABB collisions with bump.lua, a basic
   platformer character controller. Games of other genres do not load it.
8. **Libraries.** bump.lua, anim8, STI (and an external camera if used):
   pinned versions in `lib/` with their LICENSE, listed in
   `THIRD_PARTY_NOTICES.md`, checked with `compat_check.lua`, with notes on
   what works on the 360.
9. **Game tools.** `template/` with a minimal game that starts on PC and on
   the 360; a packaging script (base + game folder) for the console; a generic
   FTP installer that takes name and cover art from the game config;
   `docs/NEW_GAME.md` (creating a game, updating the base version in a game).
10. **Performance test (`examples/perf_platformer/`).** A Tiled level with
    16x16 tiles, at least 4 screens wide, with scrolling; the player and N
    animated enemies with collisions; scenes with N = 0, 50, 100 and 200; an
    overlay with FPS, update ms, draw ms and draw calls; a table for console
    measurements.
11. **Semantic versioning.** `CHANGELOG.md` and tags so each game pins a
    version.
