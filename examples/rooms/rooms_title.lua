-- The title menu: the first state of the game. Start Run starts a run, Challenges, Progress and
-- Options open their pages (placeholders for now) and Exit asks before quitting. It is opaque:
-- it draws its own background. autopause = false, so losing the pad or the focus never pushes the
-- pause menu over it.
local engine = require("engine")
local ui = engine.ui

local M = { autopause = false }

-- The built-in pixel font: the console has no TTF, so the menu draws its text with rectangles.
local theme = { font = engine.text.font(1) }
local W, H = 320, 180
local BACKGROUND = { 0.07, 0.08, 0.12 }

local main, challenges, progress, options, confirm_quit
local active

-- Each page opens on its safe default (Start Run, Back or No), whatever was focused the last
-- time, so a stray press after reopening the menu does nothing harmful.
local function show(screen, focus)
  active = screen
  screen:enter()
  screen:focus(focus)
end

-- The page on screen (nil when the title state is not entered); for tests and debugging.
function M:page() return active end

local function back_main() show(main, "start") end

local function quit_game()
  love.event.quit()
end

local function sub_page(title, line)
  return ui.screen({
    theme = theme,
    on_back = back_main,
    root = ui.vstack({ background = true, wrap = true, align = "stretch", spacing = 4,
      ui.label({ id = "title", text = title, align = "center" }),
      ui.label({ id = "message", text = line, align = "center" }),
      ui.button({ id = "back", label = "Back", on_press = back_main }),
    }),
  })
end

local function ensure()
  if main then return end
  main = ui.screen({
    theme = theme,
    on_back = function() end,                -- on the main page, Exit is the way out
    root = ui.vstack({ background = true, wrap = true, align = "stretch", spacing = 4,
      ui.button({ id = "start", label = "Start Run", on_press = function()
        engine.states:switch("play")
      end }),
      ui.button({ label = "Challenges", on_press = function() show(challenges, "back") end }),
      ui.button({ label = "Progress", on_press = function() show(progress, "back") end }),
      ui.button({ label = "Options", on_press = function() show(options, "back") end }),
      ui.button({ label = "Exit", on_press = function() show(confirm_quit, "no") end }),
    }),
  })
  challenges = sub_page("Challenges", "No challenges yet.")
  progress = sub_page("Progress", "Coming soon.")
  options = sub_page("Options", "Coming soon.")
  local no = ui.button({ id = "no", label = "No", on_press = back_main })
  confirm_quit = ui.screen({
    theme = theme,
    on_back = back_main,
    root = ui.vstack({ background = true, wrap = true, align = "stretch", spacing = 4,
      ui.label({ text = "Quit game?", align = "center" }),
      ui.hstack({ spacing = 4, align = "center",
        ui.button({ label = "Yes", on_press = quit_game }),
        no,
      }),
    }),
  })
end

function M:enter(previous, reason, joystick)
  ensure()
  show(main, "start")
end

function M:exit()
  active = nil
end

function M:input(input)
  if active then active:input(input) end
end

function M:update(dt)
  if active then active:update(dt) end
end

function M:draw(alpha)
  local g = love.graphics
  g.setColor(BACKGROUND[1], BACKGROUND[2], BACKGROUND[3], 1)
  g.rectangle("fill", 0, 0, W, H)
  g.setColor(1, 1, 1, 1)
  if active then active:draw(alpha) end
end

return M
