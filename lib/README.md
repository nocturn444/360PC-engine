# lib/

Third-party Lua libraries (objective 16). Each one lives in its own folder with its LICENSE, at a
pinned version listed in `THIRD_PARTY_NOTICES.md`. `luajit tools/check_libs.lua` checks these rules
(run by `tests/pc/check_libs_test.lua`), and `tools/compat_check.lua` checks the library running
on LÖVE.

## Adding a library

1. Copy the files of a tagged release, unchanged, into `lib/<name>/`, together with its license
   file. Use only MIT, zlib, BSD or a similarly permissive license.
2. Add a row below with the version, the short commit, the license and what it does on the
   console. Fill in that last column after running it through the engine's tests or
   `compat_check` on LÖVE.
3. Add a section to `THIRD_PARTY_NOTICES.md`: a table row naming `lib/<name>/` with the full
   40-hex commit, and the license text.
4. Run `luajit tools/check_libs.lua`. If the library has to be changed for the console, say what
   changed in its row and keep the original license notice.

| Folder | Library | Version | License | On the console |
|---|---|---|---|---|
| `anim8/` | [anim8](https://github.com/kikito/anim8) | v2.3.1 (`c1c12ec`), unchanged | MIT (`anim8/MIT-LICENSE.txt`) | Works: it only calls `love.graphics.newQuad`, `love.graphics.draw` (image and quad) and `Quad:getViewport`, all in the subset. Checked by `tests/engine/anim_test.lua`. Used through `engine.anim`. |
| `bump/` | [bump.lua](https://github.com/kikito/bump.lua) | v3.1.7 (`72d6b13`), unchanged | MIT (`bump/MIT-LICENSE.txt`) | Works: plain Lua 5.1, no FFI, no `goto`, and it calls nothing in `love` (`tools/compat_check.lua` sees no call). `World:move` and `World:check` create tables on every call (the collision list and one table per collision). Checked by `tests/engine/platformer_test.lua`. Used through `engine/modules/platformer`. |
