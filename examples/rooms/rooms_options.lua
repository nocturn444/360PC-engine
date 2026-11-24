-- The Options page, shared by the title menu and the pause menu. Music and SFX volumes are
-- engine.ui sliders applied live through the profile's engine.audio instance; the fullscreen
-- toggle is shown only on PC (love.window.setFullscreen is a stub on the console). Leaving the
-- page writes the options to the profile. No vibration: the console has no rumble.
local engine = require("engine")
local ui = engine.ui
local profile = require("rooms_profile")

local M = {}

local theme = { font = engine.text.font(1) }

-- opts: on_back (called after saving), transparent / dim (from the pause menu), focus
function M.new(opts)
  opts = opts or {}
  local data = profile.get()
  local o = data.options or {}
  local music = ui.slider({ id = "music", label = "Music volume", min = 0, max = 1, step = 0.1,
    value = o.music_volume or 1,
    on_change = function(_, v) profile.set_option("music_volume", v) end })
  local sfx = ui.slider({ id = "sfx", label = "SFX volume", min = 0, max = 1, step = 0.1,
    value = o.sfx_volume or 1,
    on_change = function(_, v) profile.set_option("sfx_volume", v) end })
  local children = {
    ui.label({ id = "title", text = "Options", align = "center" }),
    music,
    sfx,
  }
  local fullscreen
  if profile.is_pc() then
    fullscreen = ui.toggle({ id = "fullscreen", label = "Fullscreen",
      value = o.fullscreen == true,
      on_change = function(_, v) profile.set_option("fullscreen", v) end })
    children[#children + 1] = fullscreen
  end
  local function leave()
    profile.save_options()
    if opts.on_back then opts.on_back() end
  end
  children[#children + 1] = ui.button({ id = "back", label = "Back", on_press = leave })
  local screen = ui.screen({
    transparent = opts.transparent,
    dim = opts.dim,
    theme = theme,
    on_back = leave,
    focus = opts.focus or "music",
    root = ui.vstack({ background = true, wrap = true, align = "stretch", spacing = 4,
      children = children }),
  })
  screen.leave = leave                    -- a parent (the pause menu) may close the page itself
  screen.save = function() profile.save_options() end
  -- Opening the page again (from the title or from the pause menu) shows the saved values.
  screen.refresh = function()
    local now = profile.get().options or {}
    music:setValue(now.music_volume or 1)
    sfx:setValue(now.sfx_volume or 1)
    if fullscreen then fullscreen.value = now.fullscreen == true end
  end
  return screen
end

return M
