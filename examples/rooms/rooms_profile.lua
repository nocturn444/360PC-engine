-- The permanent profile of the prototype: what the player has discovered, how many enemies and
-- bosses they killed or died to, the run record and the options. It is one engine.save progress
-- slot (`profile.sav`), loaded once at startup and written only at meaningful moments (a first
-- discovery, the end of a run, leaving the Options page), never per frame. The game data that
-- the Progress page lists (enemy, boss and biome types) is read from rooms_biomes.lua.
local engine = require("engine")
local biomes = require("rooms_biomes")
local endings = require("rooms_endings")
local final_bosses = require("rooms_final_bosses")

local M = {}

local VERSION = 1
local FILE = "profile.sav"

-- The shape of a new profile. engine.save fills whatever a file does not have, so adding a
-- field here needs no migration.
local DEFAULTS = {
  discovered = { enemies = {}, bosses = {}, biomes = {} },
  kills = {},
  deaths_by = {},
  runs = 0, wins = 0, losses = 0,
  streak = 0, best_win_streak = 0,
  achievements = {}, endings = {}, unlocked_items = {},
  counters = {},                 -- lifetime totals of the run counters (rooms_progress.lua)
  unlocks = {},                  -- unlock tags earned (content with `unlock = tag` opens)
  challenges = {},               -- challenges won (none exist yet)
  options = { music_volume = 1, sfx_volume = 1, fullscreen = false },
}

local store, data, audio

local function clamp01(v)
  if type(v) ~= "number" or v ~= v then return 0 end
  return v < 0 and 0 or (v > 1 and 1 or v)
end

-- Is this the PC? The console is detected the way the engine does elsewhere (love.system.getOS).
function M.is_pc()
  local love = rawget(_G, "love")
  return not (love and love.system and love.system.getOS
    and love.system.getOS() == "Xbox 360")
end

-- A readable name for an id from the game data ("forest_mob" -> "FOREST MOB").
function M.name(id) return tostring(id):gsub("_", " "):upper() end

-- The enemy, boss and biome ids the game data knows, in its order.
local known_enemies, known_bosses, known_biomes

local function collect_known()
  known_enemies, known_bosses, known_biomes = {}, {}, {}
  for _, b in ipairs(biomes.list) do
    if b.mobs and b.mobs.id then known_enemies[#known_enemies + 1] = b.mobs.id end
    if b.boss and b.boss.id then known_bosses[#known_bosses + 1] = b.boss.id end
    known_biomes[#known_biomes + 1] = { id = b.id, name = b.name or M.name(b.id) }
  end
  for _, f in ipairs(final_bosses.list) do known_bosses[#known_bosses + 1] = f.id end
end

function M.known_enemies() if not known_enemies then collect_known() end; return known_enemies end
function M.known_bosses() if not known_bosses then collect_known() end; return known_bosses end
function M.known_biomes() if not known_biomes then collect_known() end; return known_biomes end

-- Loads the profile (once at startup, or again in a test with another filesystem). Returns the
-- data; the audio instance used for the volume options is left in M.audio.
function M.open(opts)
  opts = opts or {}
  local log = opts.log or function(text) print(text) end
  store = engine.save.new({
    identity = opts.identity,
    fs = opts.fs,
    log = log,
    progress = { version = VERSION, file = opts.file or FILE, defaults = DEFAULTS },
  })
  data = store:load_progress()
  M.store, M.data = store, data
  audio = opts.audio or engine.audio.new({ log = log })
  M.audio = audio
  M.apply_options()
  return data
end

-- The profile data, opening it on first use (a test or a tool that skipped main.lua).
function M.get()
  if not data then M.open() end
  return data
end

function M.write()
  if store and data then return store:save_progress(data) end
end

-- Applies the saved options now: the two volume buses and, on PC, the fullscreen flag.
function M.apply_fullscreen(on)
  if not M.is_pc() then return end
  local love = rawget(_G, "love")
  if love and love.window and love.window.setFullscreen then
    love.window.setFullscreen(on and true or false)
  end
end

function M.apply_options()
  local d = M.get()
  local o = d.options or {}
  if audio then
    audio:setVolume("music", clamp01(o.music_volume or 1))
    audio:setVolume("sfx", clamp01(o.sfx_volume or 1))
  end
  M.apply_fullscreen(o.fullscreen == true)
end

-- Changes one option and applies it live (it is written by M.save_options).
function M.set_option(name, value)
  local d = M.get()
  d.options = d.options or {}
  if name == "music_volume" or name == "sfx_volume" then
    value = clamp01(value)
    d.options[name] = value
    if audio then audio:setVolume(name == "music_volume" and "music" or "sfx", value) end
  elseif name == "fullscreen" then
    value = value and true or false
    d.options.fullscreen = value
    M.apply_fullscreen(value)
  end
  return value
end

function M.save_options() return M.write() end

-- First time only: adds id to a discovered set and writes the profile. Returns true if new.
function M.discover(kind, id)
  local d = M.get()
  local set = d.discovered and d.discovered[kind]
  if not set or id == nil or set[id] then return false end
  set[id] = true
  M.write()
  return true
end

function M.is_discovered(kind, id)
  local d = M.get()
  return d.discovered ~= nil and d.discovered[kind] ~= nil and d.discovered[kind][id] == true
end

-- First time only: marks an ending as seen and writes the profile. Returns true if it is new.
function M.see_ending(id)
  if id == nil then return false end
  local d = M.get()
  d.endings = d.endings or {}
  if d.endings[id] then return false end
  d.endings[id] = true
  M.write()
  return true
end

function M.kill(id)
  if id == nil then return end
  local d = M.get()
  d.kills[id] = (d.kills[id] or 0) + 1
end

function M.death_by(id)
  if id == nil then return end
  local d = M.get()
  d.deaths_by[id] = (d.deaths_by[id] or 0) + 1
end

-- Ends a run: "win" / "loss" updates the counters and the current/best streak. Saves once.
function M.finish_run(result)
  local d = M.get()
  d.runs = (d.runs or 0) + 1
  if result == "win" then
    d.wins = (d.wins or 0) + 1
    local s = d.streak or 0
    if s < 0 then s = 0 end
    s = s + 1
    d.streak = s
    if s > (d.best_win_streak or 0) then d.best_win_streak = s end
  elseif result == "loss" then
    d.losses = (d.losses or 0) + 1
    local s = d.streak or 0
    if s > 0 then s = 0 end
    d.streak = s - 1
  else
    d.runs = d.runs - 1                  -- nothing to record
    return
  end
  M.write()
end

-- A line for the current streak, e.g. "Win streak: 2" or "Loss streak: 3".
function M.streak_label(result)
  local s = M.get().streak or 0
  if s > 0 then return "Win streak: " .. s end
  if s < 0 then return "Loss streak: " .. -s end
  if result == "win" then return "Win streak: 0" end
  if result == "loss" then return "Loss streak: 0" end
  return "No streak"
end

-- Discovered and total known things, and the completion percentage (rounded down).
function M.completion_counts()
  local d = M.get()
  local n, total = 0, 0
  local function add(set_name, ids)
    for _, id in ipairs(ids) do
      total = total + 1
      if d.discovered[set_name] and d.discovered[set_name][id] then n = n + 1 end
    end
  end
  add("enemies", M.known_enemies())
  add("bosses", M.known_bosses())
  local biome_ids = {}
  for i, b in ipairs(M.known_biomes()) do biome_ids[i] = b.id end
  add("biomes", biome_ids)
  for _, ending in ipairs(endings.list) do
    total = total + 1
    if d.endings and d.endings[ending.id] then n = n + 1 end
  end
  -- achievements and unlocks (rooms_progress.lua, required here to avoid a require loop)
  local an, at = require("rooms_progress").counts()
  return n + an, total + at
end

function M.completion()
  local n, total = M.completion_counts()
  if total == 0 then return 100 end
  return math.floor(n * 100 / total)
end

return M
