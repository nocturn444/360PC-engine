# engine/modules/

Optional genre modules. A game loads only the modules it needs; nothing in `engine/` requires
one, and a module knows nothing about a specific game.

| Folder | What it is |
|---|---|
| [`platformer/`](platformer/README.md) | Objective 12: tile collisions with bump.lua (`lib/bump`) from a minimal grid interface, one-way platforms, a character controller (coyote time, jump buffer, variable jump height) whose parameters are data, and the jump's reach for level generation. It does not load level files: the Tiled / LDtk loader is objective 11. |
| [`combat/`](combat/README.md) | Objective 13: hitboxes and hurtboxes (teams, active time, once per activation, a search that needs no bump), a damage pipeline that reads stats and emits `engine.modifiers` events, i-frames, knockback, hitstop counters, a small state machine and enemy behaviours (patrol, chase, attack). It needs no other module. |
| [`procgen/`](procgen/README.md) | Objective 14: a room graph of hand-made templates matched by their exits, zones locked by ability tags with each key before its lock, breadth-first validation, minimap data, a stable layout hash and a generator that can be spread over frames. It reads room templates as plain tables (what the objective 11 loader must produce) and needs no other module; `reach.lua` checks a room's exits with the platformer jump reach. |
| [`items/`](items/README.md) | Objective 15: weighted item pools drawn with an `engine.rng` stream (the run's `"loot"`), filtered by room type, the run's tags or a game rule, with a weight hook for luck, `max` per run (unique items), entries added by permanent unlocks, and the run state for saves. It needs no other module. |
