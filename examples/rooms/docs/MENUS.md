# Menus (title, pause, game over)

The prototype's menus. All of them are `engine.ui` screens drawn with the built-in pixel font
(`engine.text.font(1)`): the console has no TTF. They must fit the 320 x 180 screen. Labels are
in English, exactly as below.

## Title menu (`rooms_title.lua`)

The first state when the game starts (`start = "title"` in `main.lua`). Opaque (not
transparent): it draws its own background. `autopause = false` on the state, so losing the pad
or the focus never pushes the pause menu over it.

| Button | What it does |
|---|---|
| Start Run | `engine.states:switch("play")`: a new run from floor 1. |
| Challenges | Opens the Challenges page. Empty for now: the title "Challenges", the line "No challenges yet." and a Back button. |
| Progress | Opens the Progress page. Placeholder: "Coming soon." and Back. (Content to be decided by the owner.) |
| Options | Opens the Options page. Placeholder: "Coming soon." and Back. (Content to be decided by the owner.) |
| Exit | `love.event.quit()`, with a "Quit game?" Yes/No confirmation like the pause menu (No focused by default). |

`ui_back` (B / Escape) on a sub page goes back to the main page; on the main page it does
nothing (Exit is the way out). The main page opens with Start Run focused.

## Game over menu (`rooms_gameover.lua`)

Dying ends the run (it used to send the Blob back to the start room). When the player dies,
`rooms_play` pushes the `gameover` state after a short fade or delay; it is transparent and
dims the frozen room under it. `autopause = false`.

The same menu ends a victory: clearing the boss room of the last floor (`FLOORS`) is the end of
the run. On that floor no stairs appear; after a short fade `rooms_play` records
`play.result = "win"` and pushes the menu, whose title is "Victory" instead of "Game Over". The
buttons and the Stats page are the same.

| Button | What it does |
|---|---|
| Restart Run | Pops itself and calls `play:restart()`: a new run from floor 1. |
| Main Menu | `engine.states:switch("title")`. |
| Stats | Opens the Stats page of the run that just ended, with a Back button. |

The page opens with Restart Run focused. `ui_back` on the main page does nothing (no way back
into a dead run); on Stats it goes back.

### Stats of the run (placeholder until the owner defines them)

Floor reached, enemies killed (`play.kills`), run time in m:ss (a new `play.run_time` that
counts while the play state updates, reset by `play:enter()`), and virus collected
(`play.wallet`). One line each.

## Pause menu (`rooms_pause.lua`)

Unchanged, except "Quit game" may later become "Main Menu" (owner's call).
