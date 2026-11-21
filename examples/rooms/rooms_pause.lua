-- The pause menu: a transparent state over rooms_play (or any state) with Resume, Restart run
-- (confirmed) and Quit game (confirmed). engine.autopause pushes it when the controller in use
-- is disconnected or the window loses the focus; the controller hooks update its message.
local engine = require("engine")
local ui = engine.ui

local M = { transparent = true }

local main, confirm_restart, confirm_quit
local active
local message
local audio

local function set_message(text)
  if not message then return end
  message.visible = text ~= nil
  message:setText(text or "")
  if main then main.dirty = true end        -- showing or hiding it changes the layout
end

local function show(screen)
  active = screen
  screen:enter()
end

local function restart_run()
  engine.states:pop()
  local play = engine.states:top()
  if play and play.restart then play:restart() end
end

local function quit_game()
  engine.states:pop()
  love.event.quit()
end

local function confirm_screen(title, on_yes)
  local no = ui.button({ id = "no", label = "No", on_press = function() show(main) end })
  local screen = ui.screen({
    transparent = true,
    dim = true,
    on_back = function() show(main) end,
    root = ui.vstack({ background = true, wrap = true, align = "stretch", spacing = 4,
      ui.label({ text = title, align = "center" }),
      ui.hstack({ spacing = 4, align = "center",
        ui.button({ label = "Yes", on_press = on_yes }),
        no,
      }),
    }),
  })
  screen:focus("no")                        -- No by default, so a stray press is harmless
  return screen
end

local function ensure()
  if main then return end
  message = ui.label({ id = "message", text = "", align = "center", visible = false })
  main = ui.screen({
    transparent = true,
    dim = true,
    on_back = function() engine.states:pop() end,
    root = ui.vstack({ background = true, wrap = true, align = "stretch", spacing = 4,
      ui.label({ text = "Paused", align = "center" }),
      message,
      ui.button({ label = "Resume", on_press = function() engine.states:pop() end }),
      ui.button({ label = "Restart run", on_press = function() show(confirm_restart) end }),
      ui.button({ label = "Quit game", on_press = function() show(confirm_quit) end }),
    }),
  })
  confirm_restart = confirm_screen("Restart run?", restart_run)
  confirm_quit = confirm_screen("Quit game?", quit_game)
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
    set_message("Controller disconnected. Reconnect it and press A to continue.")
  else
    set_message(nil)
  end
  show(main)
end

function M:exit()
  if audio then audio:resume(); audio = nil end
  active = nil
end

function M:input(input)
  if not active then return end
  if input:pressed("pause") then            -- Start / P / Escape again
    if active == main then engine.states:pop() else show(main) end
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
  set_message("Controller disconnected. Reconnect it and press A to continue.")
end

function M:controllerback(joystick)
  set_message("Controller connected.")
end

return M
