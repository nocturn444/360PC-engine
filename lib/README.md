# lib/

Third-party Lua libraries (objective 8). Each one lives in its own folder with its LICENSE, at a
pinned version listed in `THIRD_PARTY_NOTICES.md`, and is checked with `tools/compat_check.lua`.

| Folder | Library | Version | License | On the console |
|---|---|---|---|---|
| `anim8/` | [anim8](https://github.com/kikito/anim8) | v2.3.1 (`c1c12ec`), unchanged | MIT (`anim8/MIT-LICENSE.txt`) | Works: it only calls `love.graphics.newQuad`, `love.graphics.draw` (image and quad) and `Quad:getViewport`, all in the subset. Checked by `tests/engine/anim_test.lua`. Used through `engine.anim`. |
