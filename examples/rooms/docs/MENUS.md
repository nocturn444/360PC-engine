# Menus (title, pause, game over)

The prototype's menus. All of them are `engine.ui` screens drawn with the built-in pixel font
(`engine.text.font(1)`): the console has no TTF. They must fit the 320 x 180 screen. Labels are
in English, exactly as below.

The permanent data behind Progress and Options is the **profile** (`rooms_profile.lua`): one
`engine.save` progress slot (`profile.sav`), loaded once at startup and written only at
meaningful moments (a first discovery, the end of a run, leaving the Options page), never per
frame. It holds `discovered.enemies`, `discovered.bosses` and `discovered.biomes` (sets keyed by
id), `kills[id]`, `deaths_by[id]`, `runs`, `wins`, `losses`, the current `streak` (positive: wins,
negative: losses), `best_win_streak`, empty `achievements` / `endings` / `unlocked_items` sets,
and `options` (`music_volume`, `sfx_volume`, `fullscreen`).

## Title menu (`rooms_title.lua`)

The first state when the game starts (`start = "title"` in `main.lua`). Opaque (not
transparent): it draws its own background. `autopause = false` on the state, so losing the pad
or the focus never pushes the pause menu over it.

| Button | What it does |
|---|---|
| Start Run | `engine.states:switch("play")`: a new run from floor 1. |
| Challenges | Opens the Challenges page. Empty for now: the title "Challenges", the line "No challenges yet." and a Back button. |
| Progress | Opens the Progress main page (below). |
| Options | Opens the Options page (below). |
| Exit | `love.event.quit()`, with a "Quit game?" Yes/No confirmation (No focused by default). |

`ui_back` (B / Escape) on a sub page goes back to the main page; on the main page it does
nothing (Exit is the way out). The main page opens with Start Run focused; each sub page opens
on its Back button.

### Progress (`rooms_title.lua`)

The main page shows the completion percentage and one button per list; every list has a Back
button that returns to the main page.

- **Completion** = discovered things / total known in the game data, as one percentage.
  "Things" are enemies, bosses and biomes (read from `rooms_biomes.lua`) plus achievements,
  endings and unlocked items. The last three have no data yet, so they add 0 of 0; they will be
  counted then.
- **Bestiary**: one scrolling `ui.list` row per enemy and boss type in the game data.
  Undiscovered: `???`. Discovered: `Name  K:<kills>  D:<deaths_by>` (the profile's counts for
  that id). The first time the slime enters a room with enemies of a type, or a boss room with
  its boss, that type is discovered (and saved).
- **Biomes**: `Discovered: n/total` and a list of the biome names, `???` for undiscovered.
  Entering a floor discovers its biome.
- **Achievements**, **Unlocked items**, **Endings**: lists; `None yet.` while nothing awards
  them. The profile has the empty sets ready.
- **Runs**: runs, wins, losses, the current streak (`Win streak: n` / `Loss streak: n` / `No
  streak`) and the best win streak.

## Game over menu (`rooms_gameover.lua`)

Dying ends the run (it used to send the Blob back to the start room). When the player dies,
`rooms_play` pushes the `gameover` state after a short fade or delay; it is transparent and
dims the frozen room under it. `autopause = false`. The death records a loss in the profile
(`play.result = "loss"`), its damage source in `deaths_by` (the enemy/biome mob id, or
`"spikes"` for hazards) and the kills of the run.

The same menu ends a victory: clearing the boss room of the last floor (`FLOORS`) is the end of
the run. On that floor no stairs appear; after a short fade `rooms_play` records
`play.result = "win"` and pushes the menu, whose title is "Victory" instead of "Game Over". The
victory records a win and the streak in the profile. The buttons and the Stats page are the
same.

| Button | What it does |
|---|---|
| Restart Run | Pops itself and calls `play:restart()`: a new run from floor 1. |
| Main Menu | `engine.states:reset("title")`: clears the stack. |
| Stats | Opens the Stats page of the run that just ended, with a Back button. |

The page opens with Restart Run focused. `ui_back` on the main page does nothing (no way back
into a dead run); on Stats it goes back.

### Stats of the run

One line each: the floor reached, enemies killed (`play.kills`), the run time in m:ss
(`play.run_time`, reset by `play:enter`, counted while the play state updates), the virus
collected (`play.wallet`), and the current streak from the profile (`Win streak: 2` or
`Loss streak: 3`). Below them, **New this run** lists the enemies, bosses and biomes discovered
for the first time during this run, prefixed `ENEMY` / `BOSS` / `BIOME`; it is a scrolling
`ui.list` (`Nothing new` when the run found nothing). The strings are built when the page
opens.

## Options (`rooms_options.lua`)

The same page is reachable from the title menu and from the pause menu. It has:

- **Music volume** and **SFX volume**: `ui.slider` 0 to 1 in 0.1 steps, applied live through
  the profile's `engine.audio` instance (`music` and `sfx` buses).
- **Fullscreen**: a toggle shown only on PC. The console is detected like the engine does
  (`love.system.getOS() == "Xbox 360"`), where `love.window.setFullscreen` is a stub.
- **Back**: writes the options to the profile and returns to the caller.

No vibration: the console has no rumble.

## Pause menu (`rooms_pause.lua`)

A transparent state over `rooms_play`: while it is open the play state does not update. It has
Resume, Options (the page above, between Resume and Restart run), Restart run (confirmed) and
Main Menu (confirmed). Both confirmations open on No.

Main Menu ends the run without recording a loss: Yes calls `engine.states:reset("title")`, which
empties the stack and returns to the title. If the controller in use is disconnected (or the PC
window loses the focus), `engine.autopause` opens the menu with a message; reconnecting updates
the message, and A resumes. Leaving Options (Back or Start) saves the options.
