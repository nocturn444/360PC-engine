-- The pause menu: a transparent state over rooms_play (or any state) with Resume, Options,
-- Restart run (confirmed) and Main Menu (confirmed). engine.autopause pushes it when the
-- controller in use is disconnected or the window loses the focus; the controller hooks update
-- its message.
local engine = require("engine")
local ui = engine.ui
local options = require("rooms_options")
local profile = require("rooms_profile")

local M = { transparent = true }

-- The built-in pixel font: the console has no TTF, so the menu draws its text with rectangles.
local theme = { font = engine.text.font(1) }
local MESSAGE = "CONTROLLER DISCONNECTED. RECONNECT IT AND PRESS A."

local main, options_page, confirm_restart, confirm_menu
local active
local message
local audio

local function set_message(text)
  if not message then return end
  message.visible = text ~= nil
  message:setText(text or "")
  if main then main.dirty = true end        -- showing or hiding it changes the layout
end

-- Each page opens on its safe default (Resume, or No on a confirmation), whatever was focused
-- the last time, so a stray press after reopening the menu does nothing harmful.
local function show(screen, focus)
  active = screen
  screen:enter()
  screen:focus(focus)
end

-- The page on screen (nil when the pause state is not entered); for tests and debugging.
function M:page() return active end

local function restart_run()
  profile.write()                           -- keep the kills and discoveries of the run left
  engine.states:pop()
  local play = engine.states:top()
  if play and play.restart then play:restart() end
end

-- Ends the run without recording a loss: the play state is dropped with the whole stack.
local function main_menu()
  profile.write()                           -- keep the kills and discoveries, but no loss
  engine.states:reset("title")
end

local function confirm_screen(title, on_yes)
  local no = ui.button({ id = "no", label = "No", on_press = function() show(main, "resume") end })
  local screen = ui.screen({
    transparent = true,
    dim = true,
    theme = theme,
    on_back = function() show(main, "resume") end,
    root = ui.vstack({ background = true, wrap = true, align = "stretch", spacing = 4,
      ui.label({ text = title, align = "center" }),
      ui.hstack({ spacing = 4, align = "center",
        ui.button({ id = "yes", label = "Yes", on_press = on_yes }),
        no,
      }),
    }),
  })
  return screen
end

local function ensure()
  if main then return end
  message = ui.label({ id = "message", text = "", width = 140, align = "center", visible = false })
  options_page = options.new({ transparent = true, dim = true, focus = "music",
    on_back = function() show(main, "resume") end })
  main = ui.screen({
    transparent = true,
    dim = true,
    theme = theme,
    on_back = function() engine.states:pop() end,
    root = ui.vstack({ background = true, wrap = true, align = "stretch", spacing = 4,
      ui.label({ text = "Paused", align = "center" }),
      message,
      ui.button({ id = "resume", label = "Resume", on_press = function() engine.states:pop() end }),
      ui.button({ id = "options", label = "Options", on_press = function() show(options_page, "music") end }),
      ui.button({ id = "restart", label = "Restart run", on_press = function() show(confirm_restart, "no") end }),
      ui.button({ id = "menu", label = "Main Menu", on_press = function() show(confirm_menu, "no") end }),
    }),
  })
  confirm_restart = confirm_screen("Restart run?", restart_run)
  confirm_menu = confirm_screen("Return to main menu?", main_menu)
end

local function game_audio(previous)
  local a = previous and previous.audio
  if type(a) == "table" and a.pause and a.resume then return a end
  a = engine.audio
  if type(a) == "table" and a.pause and a.resume then return a end
end

function M:enter(previous, reason, joystick)
  ensure()
  self.reason = reason
  audio = game_audio(previous)
  if audio then audio:pause() end
  if reason == "controller" then
    set_message(MESSAGE)
  else
    set_message(nil)
  end
  show(main, "resume")
end

function M:exit()
  if audio then audio:resume(); audio = nil end
  active = nil
end

function M:input(input)
  if not active then return end
  if input:pressed("pause") then            -- Start / P / Escape again
    if active == main then
      engine.states:pop()
    else
      if active.save then active.save() end -- leaving Options writes them
      show(main, "resume")
    end
    return
  end
  active:input(input)
end

function M:update(dt)
  if active then active:update(dt) end
end

function M:draw(alpha)
  if active then active:draw(alpha) end
end

-- engine.autopause emits this after pushing us (a hint for the message below the title).
function M:controllerlost(joystick)
  set_message(MESSAGE)
end

function M:controllerback(joystick)
  set_message("CONTROLLER CONNECTED.")
end

return M
