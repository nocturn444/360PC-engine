# engine/modules/

Optional genre modules. A game loads only the modules it needs; nothing in `engine/` requires
one, and a module knows nothing about a specific game.

| Folder | What it is |
|---|---|
| [`platformer/`](platformer/README.md) | Objective 12: tile collisions with bump.lua (`lib/bump`) from a minimal grid interface, one-way platforms, a character controller (coyote time, jump buffer, variable jump height) whose parameters are data, and the jump's reach for level generation. It does not load level files: the Tiled / LDtk loader is objective 11. |
