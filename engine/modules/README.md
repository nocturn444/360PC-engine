# engine/modules/

Optional genre modules. A game loads only the modules it needs; nothing in `engine/` requires
one, and a module knows nothing about a specific game.

| Folder | What it is |
|---|---|
| [`platformer/`](platformer/README.md) | Objective 12: tile collisions with bump.lua (`lib/bump`) from a minimal grid interface, one-way platforms, a character controller (coyote time, jump buffer, variable jump height) whose parameters are data, and the jump's reach for level generation. It does not load level files: the Tiled / LDtk loader is objective 11. |
| [`combat/`](combat/README.md) | Objective 13: hitboxes and hurtboxes (teams, active time, once per activation, a search that needs no bump), a damage pipeline that reads stats and emits `engine.modifiers` events, i-frames, knockback, hitstop counters, a small state machine and enemy behaviours (patrol, chase, attack). It needs no other module. |
