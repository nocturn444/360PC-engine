-- The game over menu: a transparent state over rooms_play, which pushes it after the death fade.
-- Restart Run starts a new run, Main Menu clears the stack and returns to the title, and Stats
-- shows the run that just ended. autopause = false, so it is never covered by the pause menu.
local engine = require("engine")
local ui = engine.ui

local M = { transparent = true, autopause = false }

-- The built-in pixel font: the console has no TTF, so the menu draws its text with rectangles.
local theme = { font = engine.text.font(1) }

local main
local active
local game_play

-- Each page opens on its safe default (Restart Run or Back), whatever was focused the last time.
local function show(screen, focus)
  active = screen
  screen:enter()
  screen:focus(focus)
end

-- The page on screen (nil when the game over state is not entered); for tests and debugging.
function M:page() return active end

local function restart_run()
  engine.states:pop()
  local play = engine.states:top()
  if play and play.restart then play:restart() end
end

local function main_menu()
  engine.states:reset("title")               -- clears the dead play state under us
end

local function back_main() show(main, "restart") end

local function format_time(t)
  local secs = math.max(0, math.floor(t or 0))
  return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

-- The stats of the run that ended; the label strings are built here, only when the page opens.
local function stats_page(play)
  local floor = play and play.floor or 0
  local kills = play and play.kills or 0
  local time = format_time(play and play.run_time)
  local virus = play and play.wallet and play.wallet:get("virus") or 0
  return ui.screen({
    transparent = true,
    dim = true,
    theme = theme,
    on_back = back_main,
    root = ui.vstack({ background = true, wrap = true, align = "stretch", spacing = 4,
      ui.label({ text = "Run Stats", align = "center" }),
      ui.label({ id = "floor", text = "Floor: " .. floor }),
      ui.label({ id = "kills", text = "Kills: " .. kills }),
      ui.label({ id = "time", text = "Time: " .. time }),
      ui.label({ id = "virus", text = "Virus: " .. virus }),
      ui.button({ id = "back", label = "Back", on_press = back_main }),
    }),
  })
end

local function ensure()
  if main then return end
  main = ui.screen({
    transparent = true,
    dim = true,
    theme = theme,
    on_back = function() end,                -- no way back into a dead run
    root = ui.vstack({ background = true, wrap = true, align = "stretch", spacing = 4,
      ui.label({ text = "Game Over", align = "center" }),
      ui.button({ id = "restart", label = "Restart Run", on_press = restart_run }),
      ui.button({ label = "Main Menu", on_press = main_menu }),
      ui.button({ id = "stats", label = "Stats", on_press = function()
        show(stats_page(game_play), "back")
      end }),
    }),
  })
end

function M:enter(previous, reason, joystick)
  ensure()
  game_play = previous
  show(main, "restart")
end

function M:exit()
  active = nil
  game_play = nil
end

function M:input(input)
  if active then active:input(input) end
end

function M:update(dt)
  if active then active:update(dt) end
end

function M:draw(alpha)
  if active then active:draw(alpha) end
end

return M
