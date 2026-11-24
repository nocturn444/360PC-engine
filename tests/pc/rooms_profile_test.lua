-- examples/rooms: the permanent profile. Defaults, kill / death counting, discovery sets, the
-- streak and the completion percentage, a save / load round trip through the fake love's
-- filesystem, the Options page (sliders change engine.audio and persist), and a loss and a
-- victory recorded at the end of a run.
-- Usage, from the repository root: luajit -joff tests/pc/rooms_profile_test.lua   (ends with OK:)
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./examples/rooms/?.lua;" .. package.path
local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print("FAILED: " .. what); os.exit(1) end
end

local F = require("fake_love")
F.install({ width = 1280, height = 720, identity = "rooms_profile_test" })
local engine = require("engine")
local profile = require("rooms_profile")
local options = require("rooms_options")
local endings = require("rooms_endings")

local function clear_files() for k in pairs(F.files) do F.files[k] = nil end end
local function frames(n) for _ = 1, n do love.update(1 / 60); love.draw() end end
local function tap(key)
  F.keys[key] = true; love.update(1 / 60)
  F.keys[key] = nil; love.update(1 / 60)
end

-- 1. Defaults
clear_files()
local data = profile.open()
check(data.runs == 0 and data.wins == 0 and data.losses == 0
  and data.streak == 0 and data.best_win_streak == 0, "a new profile has an empty record")
check(data.options.music_volume == 1 and data.options.sfx_volume == 1
  and data.options.fullscreen == false, "the options start at volume 1 and windowed")
check(next(data.discovered.enemies) == nil and next(data.discovered.bosses) == nil
  and next(data.discovered.biomes) == nil, "nothing is discovered yet")
check(next(data.achievements) == nil and next(data.endings) == nil
  and next(data.unlocked_items) == nil, "the achievement sets are there and empty")
check(profile.completion_counts() == 0, "the completion starts at 0 of the known things")

-- 2. Kills, deaths and discoveries
profile.kill("forest_mob"); profile.kill("forest_mob")
profile.death_by("spikes")
check(profile.get().kills.forest_mob == 2 and profile.get().deaths_by.spikes == 1,
  "kills and deaths are counted by id")
local biome = profile.known_biomes()[1]
check(profile.discover("biomes", biome.id) == true, "a first discovery is new")
check(profile.discover("biomes", biome.id) == false, "the same discovery is not new again")
check(profile.is_discovered("biomes", biome.id) and not profile.is_discovered("enemies", "forest_mob"),
  "the discovered sets are separate")
local n, total = profile.completion_counts()
check(n == 1 and total == #profile.known_enemies() + #profile.known_bosses()
  + #profile.known_biomes() + #endings.list + 5 + 2,           -- 5 achievements, 2 visible unlocks
  "completion counts the discovered and the known things, endings included (" .. n .. "/" .. total .. ")")
check(profile.completion() == math.floor(100 / total), "completion is the percentage")

-- 3. Endings and a save / load round trip
check(profile.see_ending("plush") == true, "a first ending is new")
check(profile.see_ending("plush") == false, "the same ending is not new again")
check(profile.get().endings.plush == true, "the ending is in the profile")
profile.set_option("music_volume", 0.3)
profile.set_option("sfx_volume", 0.7)
check(profile.write() == true, "the profile writes")
local back = profile.open()
check(back.kills.forest_mob == 2 and back.deaths_by.spikes == 1
  and back.discovered.biomes[biome.id] == true, "the counts and discoveries survive a reload")
check(back.options.music_volume == 0.3 and back.options.sfx_volume == 0.7,
  "the options survive a reload")
check(back.endings.plush == true, "the seen endings survive a reload")

-- 4. Streaks: win, win, loss -> -1 and a best of 2
clear_files(); profile.open()
profile.finish_run("win")
check(profile.get().streak == 1 and profile.get().best_win_streak == 1, "a win starts a win streak")
profile.finish_run("win")
check(profile.get().streak == 2 and profile.get().best_win_streak == 2, "two wins: streak 2, best 2")
profile.finish_run("loss")
local d = profile.get()
check(d.streak == -1 and d.best_win_streak == 2 and d.runs == 3
  and d.wins == 2 and d.losses == 1, "a loss after two wins: streak -1, best 2, 3 runs")
check(profile.streak_label() == "Loss streak: 1", "the streak line says Loss streak: 1")

-- 5. Completion reaches 100% when every known thing is discovered
for _, id in ipairs(profile.known_enemies()) do profile.discover("enemies", id) end
for _, id in ipairs(profile.known_bosses()) do profile.discover("bosses", id) end
for _, b in ipairs(profile.known_biomes()) do profile.discover("biomes", b.id) end
for _, e in ipairs(endings.list) do profile.see_ending(e.id) end
local tracker = require("rooms_progress")
for _, r in ipairs(tracker.achievements) do profile.get().achievements[r.id] = true end
for _, r in ipairs(tracker.unlocks) do if not r.hidden then profile.get().unlocks[r.id] = true end end
check(profile.completion() == 100, "discovering and seeing everything is 100%")

-- 6. The Options page: sliders change engine.audio live, Back writes the profile
clear_files(); profile.open()
local closed = false
local screen = options.new({ on_back = function() closed = true end })
check(screen:get("music") and screen:get("sfx") and screen:get("fullscreen"),
  "the Options page has music, SFX and fullscreen")
check(screen.focused == screen:get("music"), "Options opens on Music volume")
screen:get("music"):setValue(0.3)
check(math.abs(profile.audio:getVolume("music") - 0.3) < 1e-9,
  "the music slider sets the engine.audio music volume")
screen:get("sfx"):setValue(0.6)
check(math.abs(profile.audio:getVolume("sfx") - 0.6) < 1e-9,
  "the SFX slider sets the engine.audio sfx volume")
screen:get("fullscreen"):accept()
check(profile.get().options.fullscreen == true, "the fullscreen toggle changes the option")
screen:get("music"):setValue(0.9)
screen:back()
check(closed, "Back leaves the Options page")
back = profile.open()
check(math.abs(back.options.music_volume - 0.9) < 1e-9
  and math.abs(back.options.sfx_volume - 0.6) < 1e-9
  and back.options.fullscreen == true, "leaving Options saves the options")

-- 7. A loss and a victory are recorded through the play state
clear_files()
profile.open()
assert(loadfile("examples/rooms/main.lua"))()
love.load()
engine.states:switch("play")
local play = engine.states:top()
check(play == require("rooms_play"), "the play state is on top")
play.last_damage_source = "spikes"
play.dead = true
frames(30)
check(engine.states:top() == require("rooms_gameover"), "dying opens the end-of-run menu")
d = profile.get()
check(d.runs == 1 and d.losses == 1 and d.wins == 0 and d.streak == -1,
  "the death is recorded as a loss")
check(d.deaths_by.spikes == 1, "the last damage source is the death by")
check(play.new_discoveries and #play.new_discoveries.biomes > 0,
  "the run remembers what it discovered")
check(profile.is_discovered("biomes", "forest"), "the first biome is discovered")
tap("return")                                     -- Restart Run
check(engine.states:top() == play and play.floor == 1, "Restart Run starts again")
for n = 2, 10 do play.new_floor(play, n) end
play:load_room(play.nav:enter(play.map.start))
play:load_room(play.nav:enter(play.map.boss))
for _, e in ipairs(play.fight.enemies) do e.fighter.dead = true; e.fighter.health = 0 end
frames(2); frames(30)
check(engine.states:top() == require("rooms_cutscene"), "the victory plays the picked ending first")
local steps = 0
while engine.states:top() == require("rooms_cutscene") and steps < 1000 do
  tap("return"); steps = steps + 1
end
d = profile.get()
check(d.runs == 2 and d.wins == 1 and d.losses == 1 and d.streak == 1 and d.best_win_streak == 1,
  "the victory is recorded as a win, ending the loss streak")
check(d.endings.plush == true, "the ending is recorded in the profile")
check(profile.is_discovered("biomes", "catastrophe"), "the last biome was discovered on the way")
check(engine.states:top() == require("rooms_gameover"), "the victory opens the end-of-run menu")

print(string.format("OK: %d checks; the rooms profile saves, counts and records runs", checks))
