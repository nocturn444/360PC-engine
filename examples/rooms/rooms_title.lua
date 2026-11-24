-- The title menu: the first state of the game. Start Run starts a run, Challenges opens its
-- (empty) page, Progress opens the profile's pages, Options has the volumes and the PC
-- fullscreen toggle, and Exit asks before quitting. It is opaque: it draws its own background.
-- autopause = false, so losing the pad or the focus never pushes the pause menu over it.
local engine = require("engine")
local ui = engine.ui
local profile = require("rooms_profile")
local options = require("rooms_options")

local M = { autopause = false }

-- The built-in pixel font: the console has no TTF, so the menu draws its text with rectangles.
local theme = { font = engine.text.font(1) }
local W, H = 320, 180
local BACKGROUND = { 0.07, 0.08, 0.12 }

local main, challenges, progress_main, bestiary, biomes_page, achievements, items_page
local endings, runs_page, options_page, confirm_quit
local active

-- Each page opens on its safe default (Start Run, Back or No), whatever was focused the last
-- time, so a stray press after reopening the menu does nothing harmful. A page with a refresh
-- rebuilds its text from the profile first: strings are built when it opens, not per frame.
local function show(screen, focus)
  if screen.refresh then screen.refresh() end
  active = screen
  screen:enter()
  screen:focus(focus)
end

-- The page on screen (nil when the title state is not entered); for tests and debugging.
function M:page() return active end

local function back_main() show(main, "start") end
local function back_progress() show(progress_main, "back") end

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

-- A page with a scrolling list and Back. `fill` returns the strings, built when it opens.
local function list_page(title, fill)
  local list = ui.list({ id = "list", rows = 5 })
  local screen = ui.screen({
    theme = theme,
    on_back = back_progress,
    focus = "back",
    root = ui.vstack({ background = true, wrap = true, align = "stretch", spacing = 4,
      ui.label({ id = "title", text = title, align = "center" }),
      list,
      ui.button({ id = "back", label = "Back", on_press = back_progress }),
    }),
  })
  screen.refresh = function() list:setItems(fill()) end
  return screen
end

local function bestiary_row(set_name, id, d)
  local set = d.discovered and d.discovered[set_name]
  if not (set and set[id]) then return "???" end
  return profile.name(id) .. "  K:" .. (d.kills[id] or 0) .. "  D:" .. (d.deaths_by[id] or 0)
end

local function bestiary_items()
  local d = profile.get()
  local items = {}
  for _, id in ipairs(profile.known_enemies()) do
    items[#items + 1] = bestiary_row("enemies", id, d)
  end
  for _, id in ipairs(profile.known_bosses()) do
    items[#items + 1] = bestiary_row("bosses", id, d)
  end
  return items
end

-- The achievements, endings and unlocked items have no data yet; the pages still list whatever
-- the profile set holds, or "None yet.".
local function set_items(kind)
  local d = profile.get()
  local items = {}
  for id in pairs(d[kind] or {}) do items[#items + 1] = profile.name(id) end
  table.sort(items)
  if #items == 0 then items[1] = "None yet." end
  return items
end

local function ensure()
  if main then return end
  challenges = sub_page("Challenges", "No challenges yet.")
  bestiary = list_page("Bestiary", bestiary_items)
  achievements = list_page("Achievements", function() return set_items("achievements") end)
  items_page = list_page("Unlocked items", function() return set_items("unlocked_items") end)
  endings = list_page("Endings", function() return set_items("endings") end)

  local biome_count = ui.label({ id = "count", text = "" })
  local biome_list = ui.list({ id = "list", rows = 5 })
  biomes_page = ui.screen({
    theme = theme,
    on_back = back_progress,
    focus = "back",
    root = ui.vstack({ background = true, wrap = true, align = "stretch", spacing = 4,
      ui.label({ id = "title", text = "Biomes", align = "center" }),
      biome_count,
      biome_list,
      ui.button({ id = "back", label = "Back", on_press = back_progress }),
    }),
  })
  biomes_page.refresh = function()
    local d = profile.get()
    local known, items, seen = profile.known_biomes(), {}, 0
    for _, b in ipairs(known) do
      if d.discovered and d.discovered.biomes and d.discovered.biomes[b.id] then
        seen = seen + 1
        items[#items + 1] = b.name
      else
        items[#items + 1] = "???"
      end
    end
    biome_count:setText("Discovered: " .. seen .. "/" .. #known)
    biome_list:setItems(items)
  end

  local runs_runs = ui.label({ id = "runs", text = "" })
  local runs_wins = ui.label({ id = "wins", text = "" })
  local runs_losses = ui.label({ id = "losses", text = "" })
  local runs_streak = ui.label({ id = "streak", text = "" })
  local runs_best = ui.label({ id = "best", text = "" })
  runs_page = ui.screen({
    theme = theme,
    on_back = back_progress,
    focus = "back",
    root = ui.vstack({ background = true, wrap = true, align = "stretch", spacing = 4,
      ui.label({ id = "title", text = "Runs", align = "center" }),
      runs_runs, runs_wins, runs_losses, runs_streak, runs_best,
      ui.button({ id = "back", label = "Back", on_press = back_progress }),
    }),
  })
  runs_page.refresh = function()
    local d = profile.get()
    runs_runs:setText("Runs: " .. (d.runs or 0))
    runs_wins:setText("Wins: " .. (d.wins or 0))
    runs_losses:setText("Losses: " .. (d.losses or 0))
    runs_streak:setText(profile.streak_label())
    runs_best:setText("Best win streak: " .. (d.best_win_streak or 0))
  end

  local completion = ui.label({ id = "completion", text = "" })
  progress_main = ui.screen({
    theme = theme,
    on_back = back_main,
    focus = "back",
    root = ui.vstack({ background = true, wrap = true, align = "stretch", spacing = 4,
      ui.label({ id = "title", text = "Progress", align = "center" }),
      completion,
      ui.button({ id = "bestiary", label = "Bestiary", on_press = function() show(bestiary, "back") end }),
      ui.button({ id = "biomes", label = "Biomes", on_press = function() show(biomes_page, "back") end }),
      ui.button({ id = "achievements", label = "Achievements", on_press = function() show(achievements, "back") end }),
      ui.button({ id = "items", label = "Unlocked items", on_press = function() show(items_page, "back") end }),
      ui.button({ id = "endings", label = "Endings", on_press = function() show(endings, "back") end }),
      ui.button({ id = "runs", label = "Runs", on_press = function() show(runs_page, "back") end }),
      ui.button({ id = "back", label = "Back", on_press = back_main }),
    }),
  })
  progress_main.refresh = function()
    completion:setText("Completion: " .. profile.completion() .. "%")
  end

  options_page = options.new({ on_back = back_main, focus = "music" })

  main = ui.screen({
    theme = theme,
    on_back = function() end,                -- on the main page, Exit is the way out
    root = ui.vstack({ background = true, wrap = true, align = "stretch", spacing = 4,
      ui.button({ id = "start", label = "Start Run", on_press = function()
        engine.states:switch("play")
      end }),
      ui.button({ id = "challenges", label = "Challenges", on_press = function() show(challenges, "back") end }),
      ui.button({ id = "progress", label = "Progress", on_press = function() show(progress_main, "back") end }),
      ui.button({ id = "options", label = "Options", on_press = function() show(options_page, "music") end }),
      ui.button({ label = "Exit", on_press = function() show(confirm_quit, "no") end }),
    }),
  })

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
