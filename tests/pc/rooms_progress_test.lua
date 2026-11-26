-- examples/rooms: achievements and unlocks (rooms_progress.lua). Each placeholder achievement is
-- earned by the run that fits it and not by others; abstain rules wait for the floor or run end;
-- earned ids are saved and survive a reload; an achievement can trigger an unlock in the same
-- check; a locked mutation is never drawn before its tag and can be after; the locked biome
-- never appears before its unlock and can take floors 6-7 after.
-- Usage, from the repository root: luajit -joff tests/pc/rooms_progress_test.lua   (ends with OK:)
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./examples/rooms/?.lua;" .. package.path
local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print("FAILED: " .. what); os.exit(1) end
end

local F = require("fake_love")
F.install({ width = 1280, height = 720, identity = "rooms_progress_test" })
local engine = require("engine")
local profile = require("rooms_profile")
local tracker = require("rooms_progress")
local content = require("rooms_content")
local biomes = require("rooms_biomes")

local function clear_files() for k in pairs(F.files) do F.files[k] = nil end end
local function fresh()
  clear_files()
  profile.open()
  local play = {}
  tracker.new_run(play)
  tracker.new_floor(play, 1)
  return play
end
local function earned(id) return profile.get().achievements[id] == true end
local function unlocked(tag) return profile.get().unlocks[tag] == true end

-- 1. UNTOUCHABLE: a floor without a hit, only at the floor's end
do
  local play = fresh()
  tracker.kill(play, "forest_mob")
  check(not earned("untouchable"), "an abstain rule is not earned during the floor")
  tracker.floor_end(play)
  check(earned("untouchable"), "a floor with no hit earns UNTOUCHABLE at its end")
  check(play.message == "ACHIEVEMENT: UNTOUCHABLE", "the HUD shows the achievement")
  check(play.track.earned[1] == "ACHIEVEMENT: UNTOUCHABLE", "the run lists what it earned")
end
do
  local play = fresh()
  tracker.hit(play)
  tracker.floor_end(play)
  check(not earned("untouchable"), "a floor with a hit does not earn UNTOUCHABLE")
  tracker.new_floor(play, 2)
  tracker.floor_end(play)
  check(earned("untouchable"), "the floor counters reset: the next clean floor earns it")
end

-- 2. FIRST VICTORY and HEARTLESS (which also unlocks THORNS in the same check)
do
  local play = fresh()
  tracker.heart(play)
  tracker.run_end(play, "loss")
  check(not earned("first_win") and not earned("heartless"), "a loss earns no victory")
  play = fresh()
  tracker.heart(play)
  tracker.run_end(play, "win")
  check(earned("first_win") and not earned("heartless"), "a win with a heart: FIRST VICTORY only")
  check(not unlocked("unlock_thorns"), "THORNS stays locked")
  play = fresh()
  tracker.kill(play, "forest_mob")
  tracker.run_end(play, "win")
  check(earned("heartless"), "a win without hearts earns HEARTLESS")
  check(unlocked("unlock_thorns"), "HEARTLESS unlocks THORNS in the same check")
  -- saved: a reload keeps both
  profile.open()
  check(earned("heartless") and unlocked("unlock_thorns"), "achievements and unlocks are saved")
end

-- 3. BOUNCY BUILD: holding both mutations, at once (an event rule)
do
  local play = fresh()
  tracker.mutation(play, "example_spring_heel")
  check(not earned("bouncy_build"), "one of the two is not the build")
  tracker.mutation(play, "example_legs")
  check(earned("bouncy_build"), "both mutations earn BOUNCY BUILD as soon as the second is taken")
end

-- 4. EXTERMINATOR and the crystal cave: lifetime kill totals across runs
do
  local play = fresh()
  for _ = 1, 30 do tracker.kill(play, "forest_mob") end
  tracker.run_end(play, "loss")
  check(profile.get().counters["kills:forest_mob"] == 30, "kills are kept per type in the profile")
  check(not unlocked("unlock_crystal_cave"), "30 forest kills do not unlock the crystal cave")
  tracker.new_run(play); tracker.new_floor(play, 1)
  for _ = 1, 20 do tracker.kill(play, "forest_mob") end
  check(unlocked("unlock_crystal_cave"), "50 forest kills over two runs unlock the crystal cave")
  check(play.message ~= "UNLOCKED: CRYSTAL CAVE", "an unlock shows no HUD message during the run")
  local listed = false
  for _, line in ipairs(play.track.earned) do if line == "UNLOCKED: CRYSTAL CAVE" then listed = true end end
  check(listed, "the unlock is listed for the end-of-run screen")
  for _ = 1, 150 do tracker.kill(play, "grotto_mob") end
  check(earned("exterminator"), "200 kills in total earn EXTERMINATOR")
  check(play.track.run:get("kills") == 170, "the run counter counts only this run")
end

-- 5. The challenge unlock cannot be earned (no challenges yet) and is hidden
do
  local play = fresh()
  tracker.run_end(play, "win")
  check(not unlocked("unlock_challenge_example"), "the challenge example stays locked")
  local rows = tracker.rows(tracker.unlocks, profile.get().unlocks)
  check(rows[3] == "???", "a hidden unlock shows ???")
end

-- 6. A locked mutation is never drawn before its tag
do
  local function draws_thorns(unlocked_set)
    local pools = content.new_pools({ unlocked = unlocked_set })
    local rng = engine.rng.new(5)
    for _ = 1, 400 do
      local e = content.draw_mutation(pools.mutations, rng, { source = "treasure", floor = 3 })
      if e and e.id == "example_thorns" then return true end
    end
    return false
  end
  check(not draws_thorns({}), "THORNS never drops while locked")
  check(draws_thorns({ unlock_thorns = true }), "THORNS can drop once unlocked")
end

-- 7. The crystal cave takes floors 6-7 only once unlocked
do
  local function seen_on_6(unlock)
    local set = biomes.new(10)
    if unlock then set:unlock("unlock_crystal_cave") end
    local ids = {}
    for seed = 1, 40 do
      local path, streams = set:path(), engine.rng.streams(seed)
      for n = 1, 10 do
        local b = path:enter(n, { floor = n }, streams:get("biomes"))
        if n == 6 or n == 7 then ids[b.id] = true end
        if n == 8 then check(b.id == "catacombs", "floor 8 stays the catacombs") end
      end
    end
    return ids
  end
  local locked = seen_on_6(false)
  check(locked.fungal_cave and not locked.crystal_cave, "locked: floors 6-7 are always the fungal cave")
  local open = seen_on_6(true)
  check(open.fungal_cave and open.crystal_cave, "unlocked: floors 6-7 are the fungal or the crystal cave")
end

print("OK: " .. checks .. " checks; rooms achievements and unlocks")
