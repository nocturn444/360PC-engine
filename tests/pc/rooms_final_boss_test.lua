-- examples/rooms: the placeholder final bosses (rooms_final_bosses.lua). The pick follows the
-- run and the profile (the default, the scientist when no heart was picked, the AI after a win
-- with three mutations) and is the same for the same seed; every boss builds through
-- combat.boss in a test room, fights for 20 s without errors (attacks fire, tells show),
-- reaches its second phase at half health and stays inside the room; each one leads to its
-- ending; and the final bosses are listed in the bestiary.
-- Usage, from the repository root: luajit -joff tests/pc/rooms_final_boss_test.lua   (ends with OK:)
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./examples/rooms/?.lua;" .. package.path

local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print("FAILED: " .. what); os.exit(1) end
end

local F = require("fake_love")
F.install({ width = 1280, height = 720, identity = "rooms_final_boss_test" })
local engine = require("engine")
local platformer = require("engine.modules.platformer")
local combat = require("engine.modules.combat")
local progress = require("engine.modules.progress")
local enemies = require("rooms_enemies")
local finals = require("rooms_final_bosses")
local endings = require("rooms_endings")
local profile = require("rooms_profile")

-- 1. The pick
local function pick(hearts, mutations, wins, seed)
  local run = progress.counters.new()
  run:set("hearts", hearts)
  run:set("mutations", mutations)
  local ctx = { run = run, floor = progress.counters.new(), profile = { wins = wins, counters = {} } }
  return progress.pick(finals.list, ctx, engine.rng.new(seed or 1), { tests = finals.tests })
end
check(pick(2, 0, 0).id == "final_mutant", "by default the final boss is the Mutant")
check(pick(2, 3, 0).id == "final_mutant", "three mutations without an earlier win: still the Mutant")
check(pick(2, 3, 1).id == "final_ai", "a win before and three mutations: the Caretaker AI")
check(pick(0, 3, 1).id == "final_scientist", "no heart picked up wins over the rest: the Last Scientist")
check(pick(0, 0, 0).id == "final_scientist", "no heart picked up: the Last Scientist")
for seed = 1, 10 do
  check(pick(2, 3, 1, seed).id == pick(2, 3, 1, seed).id, "the same seed gives the same final boss")
end

-- 2. Each boss in a test room: a 30 x 12 room with a floor, the slime a few tiles away
local rows = {}
for y = 1, 11 do rows[y] = string.rep(".", 30) end
rows[12] = string.rep("#", 30)
local grid = platformer.grid.new(rows, { tile_size = 16 })
local FLOOR = 11 * 16

local function fake_slime(x, y)
  local s = { x = x, y = y, w = 18, h = 18 }
  function s:bounds() return self.x, self.y, self.x + self.w, self.y + self.h end
  function s:center() return self.x + self.w / 2, self.y + self.h / 2 end
  function s:velocity() return 0, 0 end
  function s:set_velocity() end
  return s
end

for _, boss in ipairs(finals.list) do
  local phases_seen = {}
  local f = enemies.new(fake_slime(8 * 16, FLOOR - 18), grid,
    { { x = 18 * 16, y = FLOOR, type = boss.id, spec = boss } }, {
      enemy_stats = combat.stats.new({ max_health = boss.health, attack_damage = boss.damage,
        invuln_time = 0.4, knockback_resist = 0.8 }),
      slime_stats = combat.stats.new({ max_health = 100000, attack_damage = 1, invuln_time = 1 }),
      mob = boss.id, seed = 3,
      on_phase = function(_, i) phases_seen[#phases_seen + 1] = i end,
    })
  local e = f.enemies[1]
  check(f.director and e.director == f.director, boss.id .. ": driven by combat.boss")
  check(e.fighter.health == boss.health, boss.id .. ": its own health")
  local states, tells = {}, 0
  local ok, err = pcall(function()
    for _ = 1, 60 * 20 do
      f:step(1 / 60)
      local s = f.director:state()
      if s then states[s] = true end
      if f.director.telegraph then tells = tells + 1 end
    end
  end)
  check(ok, boss.id .. ": 20 s of fight without errors (" .. tostring(err) .. ")")
  local n = 0
  for _ in pairs(states) do n = n + 1 end
  check(n >= 3, boss.id .. ": goes through several states (" .. n .. ")")
  check(tells > 0, boss.id .. ": its attacks show a tell")
  local b = e.body
  check(b.x >= 0 and b.x + b.w <= 30 * 16 and b.y >= 0 and b.y + b.h <= 12 * 16,
    boss.id .. ": stays inside the room")
  -- half health: phase 2, after its transition
  e.fighter.health = boss.health / 2
  f:step(1 / 60)
  check(f.director.phase == 2 and phases_seen[1] == 2, boss.id .. ": phase 2 at half health")
  ok, err = pcall(function() for _ = 1, 60 * 10 do f:step(1 / 60) end end)
  check(ok, boss.id .. ": phase 2 fights without errors (" .. tostring(err) .. ")")
  check(f.director:state() ~= nil, boss.id .. ": phase 2 runs its brain after the transition")
end

-- 3. Endings and the bestiary
local mapped = { final_ai = "helpful_ai", final_scientist = "cryo_scientist", final_mutant = "plush" }
for id, ending in pairs(mapped) do
  check(endings.pick({ final_boss = finals.by_id[id] }).id == ending, id .. " leads to the " .. ending .. " ending")
end
check(endings.pick({}).id == "plush", "no final boss: the default ending")
local known = {}
for _, id in ipairs(profile.known_bosses()) do known[id] = true end
for _, boss in ipairs(finals.list) do check(known[boss.id], boss.id .. " is in the bestiary") end

print("OK: " .. checks .. " checks; the final bosses")
