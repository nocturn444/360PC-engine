-- Achievements and unlocks of the prototype, built on engine.modules.progress. Everything here
-- is a PLACEHOLDER for the owner to replace: the rules are data (see examples/rooms/docs/UNLOCKS.md).
--
-- What a run did is kept in two progress.counters objects on the play state (play.track.run and
-- play.track.floor), fed by the events below. The profile keeps lifetime totals in
-- profile.counters, earned achievements in profile.achievements and unlock tags in
-- profile.unlocks. Content is locked with the `unlock = "<tag>"` field that engine.modules.items
-- (mutations) and procgen.biomes (biomes) already understand; a tag unlocked during a run opens
-- its content from the next run on (pools and biome sets read the tags at run start).
--
-- Counter keys used by the rules:
--   kills, kills:<mob id>   enemies killed (run, floor and profile)
--   hearts                  hearts picked up
--   damage                  hits taken
--   mutations               mutations taken; the set "items" holds their ids
-- Moments: "event" (after a kill, a heart, a hit, a mutation), "floor_end" (stairs taken, and
-- on victory), "run_end" (win or loss; leaving from the pause menu does not count).
local progress = require("engine.modules.progress")
local profile = require("rooms_profile")

local M = {}

M.achievements = {
  { id = "first_win", name = "FIRST VICTORY", hint = "Win a run.",
    when = { "result", value = "win" } },
  { id = "exterminator", name = "EXTERMINATOR", hint = "Kill 200 enemies in total.", at = "event",
    when = { "count", key = "kills", scope = "profile", at_least = 200 } },
  { id = "untouchable", name = "UNTOUCHABLE", hint = "Finish a floor without being hit.",
    at = "floor_end",
    when = { "count", key = "damage", scope = "floor", at_most = 0 } },
  { id = "heartless", name = "HEARTLESS", hint = "Win a run without picking up a heart.",
    when = { "all", { "result", value = "win" }, { "count", key = "hearts", at_most = 0 } } },
  { id = "bouncy_build", name = "BOUNCY BUILD", hint = "Hold Spring Heel and Legs together.",
    at = "event",
    when = { "build", all = { "example_spring_heel", "example_legs" } } },
}

-- Each unlock names what it opens (`gives`) so the Progress page can list it.
M.unlocks = {
  { id = "unlock_thorns", name = "THORNS", gives = { kind = "mutation", id = "example_thorns" },
    hint = "Earn the HEARTLESS achievement.",
    when = { "has", set = "achievements", id = "heartless" } },
  { id = "unlock_crystal_cave", name = "CRYSTAL CAVE", gives = { kind = "biome", id = "crystal_cave" },
    hint = "Kill 50 forest creatures.", at = "event",
    when = { "count", key = "kills:forest_mob", scope = "profile", at_least = 50 } },
  -- A challenge trigger, kept as an example: challenges do not exist yet, so it cannot be earned.
  { id = "unlock_challenge_example", name = "???", gives = { kind = "mutation", id = "none" },
    hint = "Win a challenge (coming later).", hidden = true,
    when = { "has", set = "challenges", id = "example_challenge" } },
}

local achievements = progress.rules.new(M.achievements)
local unlocks = progress.rules.new(M.unlocks)
M.achievement_rules, M.unlock_rules = achievements, unlocks

local function sets(d)
  d.counters = d.counters or {}
  d.achievements = d.achievements or {}
  d.unlocks = d.unlocks or {}
  d.challenges = d.challenges or {}
  return d
end

-- The unlock tags of the profile (a { tag = true } set), for the pools and the biome set.
function M.unlocked()
  return sets(profile.get()).unlocks
end

-- A new run: fresh counters (the same tables) and the run's list of earned things.
function M.new_run(play)
  local t = play.track
  if not t then
    t = { run = progress.counters.new(), floor = progress.counters.new(), earned = {} }
    t.ctx = { run = t.run, floor = t.floor, profile = nil, result = nil }
    play.track = t
  else
    t.run:reset()
    t.floor:reset()
    for i = #t.earned, 1, -1 do t.earned[i] = nil end
  end
  t.ctx.result = nil
  return t
end

function M.new_floor(play, n)
  local t = play.track or M.new_run(play)
  t.floor:reset()
  t.run:set("floor", n)
  t.floor:set("floor", n)
end

local function add(play, key, n)
  local t = play.track
  t.run:add(key, n)
  t.floor:add(key, n)
  local c = sets(profile.get()).counters
  c[key] = (c[key] or 0) + n
end

-- Tests both rule lists at a moment; anything new goes to the run's list and the save (written
-- at once). Achievements show on the HUD at once; unlocks only on the end-of-run screen (their
-- content opens from the next run on anyway).
local function check(play, moment)
  local t = play.track
  local d = sets(profile.get())
  t.ctx.profile = d
  local got = false
  local a = achievements:check(moment, t.ctx, d.achievements)
  for i = 1, #a do
    t.earned[#t.earned + 1] = "ACHIEVEMENT: " .. a[i].name
    play.message, play.message_time = "ACHIEVEMENT: " .. a[i].name, 2.0
    got = true
  end
  -- an achievement can be the trigger of an unlock, so unlocks are tested after it
  local u = unlocks:check(moment, t.ctx, d.unlocks)
  for i = 1, #u do
    t.earned[#t.earned + 1] = "UNLOCKED: " .. u[i].name
    got = true
  end
  if got then profile.write() end
end

-- Events from rooms_play
function M.kill(play, mob)
  if not play.track then return end
  add(play, "kills", 1)
  if mob then add(play, "kills:" .. mob, 1) end
  check(play, "event")
end

function M.heart(play)
  if not play.track then return end
  add(play, "hearts", 1)
  check(play, "event")
end

function M.hit(play)
  if not play.track then return end
  add(play, "damage", 1)
  check(play, "event")
end

function M.mutation(play, id)
  if not play.track then return end
  play.track.run:mark("items", id)
  play.track.floor:mark("items", id)
  add(play, "mutations", 1)
  check(play, "event")
end

function M.floor_end(play)
  if not play.track then return end
  check(play, "floor_end")
end

-- result: "win" or "loss". Called before the profile records the run, so its write saves both.
function M.run_end(play, result)
  if not play.track then return end
  play.track.ctx.result = result
  check(play, "run_end")
end

-- For the Progress pages: one row per rule, "???" for a hidden one not earned yet.
function M.rows(list, set)
  local rows = {}
  for i = 1, #list do
    local r = list[i]
    if set[r.id] then
      rows[#rows + 1] = r.name
    elseif r.hidden then
      rows[#rows + 1] = "???"
    else
      rows[#rows + 1] = "?? " .. (r.hint or "")
    end
  end
  return rows
end

-- Earned / total, for the completion percentage.
function M.counts()
  local d = sets(profile.get())
  local n, total = 0, 0
  for i = 1, #M.achievements do
    total = total + 1
    if d.achievements[M.achievements[i].id] then n = n + 1 end
  end
  for i = 1, #M.unlocks do
    if not M.unlocks[i].hidden or d.unlocks[M.unlocks[i].id] then
      total = total + 1
      if d.unlocks[M.unlocks[i].id] then n = n + 1 end
    end
  end
  return n, total
end

-- Preview builds (debug flag or a -test version): unlock every content tag, to test it on the
-- console. It is written with the next save like any other unlock.
function M.unlock_all()
  local d = sets(profile.get())
  for i = 1, #M.unlocks do d.unlocks[M.unlocks[i].id] = true end
end

return M
