-- examples/rooms: boots on the console's boot (tests/pc/boot_pc.lua) and runs on the engine
-- tests' fake love: the slime starts in the start room, walks out through a door behind a fade,
-- arrives inside the next room, a locked door holds until the key is picked up, the minimap
-- marks what was explored, an enemy that falls through a pit turns up in the room below, and
-- the room is drawn.
-- Usage, from the repository root: luajit -joff tests/pc/rooms_example_test.lua   (must end with "OK:")
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./examples/rooms/?.lua;" .. package.path
local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print("FAILED: " .. what); os.exit(1) end
end
local function read(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local d = f:read("*a"); f:close(); return d
end

-- 1. Files and config
for _, name in ipairs({ "game.lua", "conf.lua", "main.lua", "rooms_play.lua", "rooms_data.lua", "rooms_biomes.lua",
  "rooms_art.lua", "rooms_stats.lua", "rooms_content.lua", "rooms_mutations.lua", "rooms_consumables.lua", "rooms_look.lua",
  "rooms_pickups.lua", "rooms_props.lua", "rooms_machines.lua", "rooms_pause.lua",
  "rooms_title.lua", "rooms_gameover.lua", "README.md" }) do
  check(read("examples/rooms/" .. name), "examples/rooms/" .. name .. " exists")
end
local Config = dofile("runtime/lua/config.lua")
local cfg, err = Config.load(read("examples/rooms/game.lua"), "examples/rooms/game.lua")
check(cfg and cfg.title_id and cfg.identity == "rooms_demo", "game.lua is valid: " .. tostring(err))

-- 2. The templates make maps with a key for every seed tried
local P = require("engine.modules.procgen")
local data = require("rooms_data")
local made = 0
for seed = 1, 50 do
  local m = P.generate({ templates = data.templates(), seed = seed, rooms = 10, abilities = { "key" } })
  if m then made = made + 1 end
end
check(made == 50, "50 seeds, 50 maps (" .. made .. ")")
-- the run: every floor of 20 seeds, growing, with a treasure room and a shop (no shop on the last)
local Rng = require("engine.rng")
local plan = require("rooms_play").plan
for seed = 1, 20 do
  local sizes = {}
  for n = 1, 10 do
    local m, why = plan:generate(n, Rng.streams(seed):get("floor" .. n))
    check(m, "seed " .. seed .. " floor " .. n .. ": " .. tostring(why))
    local kinds = {}
    for _, r in ipairs(m.rooms) do kinds[r.type] = (kinds[r.type] or 0) + 1 end
    check(kinds.treasure == 1 and kinds.boss == 1 and (kinds.shop == 1) == (n < 10),
      "seed " .. seed .. " floor " .. n .. ": a treasure room, a boss, a shop except on the last floor")
    check(n > 1 or not kinds.miniboss, "no miniboss on floor 1")
    sizes[n] = #m.rooms
  end
  check(sizes[10] > sizes[1] + 8, "seed " .. seed .. ": the last floor is much bigger (" .. table.concat(sizes, ",") .. ")")
end
-- the biomes of 200 runs: Blob's fixed path (forest 1-2, deep jungle 3-4, grotto 5,
-- fungal cave 6-7, catacombs 8, labs 9, catastrophe 10) on every seed; every floor generates
local B = require("rooms_biomes")
local set = require("rooms_play").biomes
local expected = { "forest", "forest", "deep_jungle", "deep_jungle", "grotto",
  "fungal_cave", "fungal_cave", "catacombs", "labs", "catastrophe" }
for seed = 1, 200 do
  local path, streams = set:path(), Rng.streams(seed)
  local kills = (seed % 2 == 0) and 20 or 0
  for n = 1, 10 do
    local b = path:enter(n, { kills = kills }, streams:get("biomes"))
    check(b.id == expected[n], "seed " .. seed .. " floor " .. n .. ": " .. expected[n] .. " (got " .. b.id .. ")")
    if seed <= 20 then
      local m, why = plan:generate(n, streams:get("floor" .. n), b)
      check(m and m.biome == b.id and m.difficulty == b.difficulty, "seed " .. seed .. " floor " .. n .. " in " .. b.id .. ": " .. tostring(why))
    end
  end
end
check(B.enemy_stats(B.list[#B.list], true).max_health > B.enemy_stats(B.list[1], true).max_health, "the catastrophe's boss is stronger")
for _, t in ipairs(data.templates()) do
  local rows = t.rows
  check(#rows == (t.h or 1) * data.cell_h and #rows[1] == (t.w or 1) * data.cell_w, t.id .. ": rows fit its cells")
  -- a special room's bottom row is its border: no holes to fall through (a down door is opened
  -- by the play state, not drawn in the rows)
  if t.type ~= "normal" and t.type ~= "start" and t.type ~= "boss" then
    check(not rows[#rows]:find(".", 1, true), t.id .. ": the bottom border has no holes")
  end
end

-- 2b. The new special types: four one-door templates each, and their spawn rules in the run
local S = require("rooms_spawn")
local by_id = {}
for _, t in ipairs(data.templates()) do by_id[t.id] = t end
for _, kind in ipairs({ "super_treasure", "casino", "pact", "trap", "obstacle" }) do
  for _, suffix in ipairs({ "_l", "_r", "_u", "_d" }) do
    local t = by_id[kind .. suffix]
    check(t and t.type == kind, kind .. suffix .. ": a template of its type")
    check(t and #t.exits == 1, kind .. suffix .. ": one exit, a dead end")
    if kind == "trap" then
      check(t and #(t.enemies or {}) == 4, kind .. suffix .. ": four enemies")
    elseif kind == "obstacle" then
      check(t and not t.enemies, kind .. suffix .. ": no enemies")
    end
  end
end
-- Forced spawn states: a casino almost always comes and never with a shop; a skipped treasure
-- brings a super treasure instead of a treasure; traps stay at two at most; floor 1 has no casino.
local SEEDS = 50
local casino_state = S.new_state()
casino_state.casino = 0.95
local casino_seen, casino_with_shop = 0, false
for seed = 1, SEEDS do
  local streams = Rng.streams(seed)
  for n = 1, 9 do
    local m, why = plan:generate(n, streams:get("floor" .. n), nil, { spawn = casino_state, luck = 5 })
    check(m, "casino: seed " .. seed .. " floor " .. n .. ": " .. tostring(why))
    local has_casino, has_shop = false, false
    for _, r in ipairs(m.rooms) do
      if r.type == "casino" then has_casino = true end
      if r.type == "shop" then has_shop = true end
    end
    if has_casino then casino_seen = casino_seen + 1 end
    if has_casino and has_shop then casino_with_shop = true end
  end
end
check(casino_seen > SEEDS * 9 / 2, "a 0.95 casino chance brings a casino to most floors (" .. casino_seen .. ")")
check(not casino_with_shop, "a casino never shares a floor with a shop")
local skip_state = S.new_state()
skip_state.treasure_skipped = true
local super_seen, super_with_treasure = 0, false
for seed = 1, SEEDS do
  local streams = Rng.streams(seed)
  for n = 1, 9 do
    local m, why = plan:generate(n, streams:get("floor" .. n), nil, { spawn = skip_state, luck = 5 })
    check(m, "super treasure: seed " .. seed .. " floor " .. n .. ": " .. tostring(why))
    local has_super, has_treasure = false, false
    for _, r in ipairs(m.rooms) do
      if r.type == "super_treasure" then has_super = true end
      if r.type == "treasure" then has_treasure = true end
    end
    if has_super then super_seen = super_seen + 1 end
    if has_super and has_treasure then super_with_treasure = true end
  end
end
check(super_seen > 0, "a skipped treasure brings a super treasure sometimes (" .. super_seen .. ")")
check(not super_with_treasure, "a super treasure never shares a floor with a treasure")
local default_state = S.new_state()
local floor1_casino, trap_max = false, 0
for seed = 1, SEEDS do
  local streams = Rng.streams(seed)
  for n = 1, 9 do
    local m, why = plan:generate(n, streams:get("floor" .. n), nil, { spawn = default_state, luck = 5 })
    check(m, "default spawn: seed " .. seed .. " floor " .. n .. ": " .. tostring(why))
    local traps = 0
    for _, r in ipairs(m.rooms) do
      if r.type == "trap" then traps = traps + 1 end
      if n == 1 and r.type == "casino" then floor1_casino = true end
    end
    if traps > trap_max then trap_max = traps end
    check(traps <= 2, "seed " .. seed .. " floor " .. n .. ": at most two traps (" .. traps .. ")")
  end
end
check(not floor1_casino, "a new run's floor 1 has no casino")
check(trap_max <= 2, "no floor has more than two traps (" .. trap_max .. ")")

-- 3. On the console's boot, without a GPU
local p = assert(io.popen("luajit -joff tests/pc/boot_pc.lua examples/rooms 2>&1"))
local out = p:read("*a"); p:close()
local last = out:match("([^\n]*)\n*$")
check(last:sub(1, 3) == "OK:", "boot_pc.lua examples/rooms ends with OK: " .. last)
check(not out:find("ERROR", 1, true), "and logs no error")

-- 4. On the fake love
local TS_HALF = 16
local F = require("fake_love")
F.install({ width = 1280, height = 720 })
assert(loadfile("examples/rooms/main.lua"))()
love.load()
love.update(1 / 60)                          -- a warm frame so the ui_* actions get defined
local engine = require("engine")
local title = require("rooms_title")
local gameover = require("rooms_gameover")
local function frames(n) for _ = 1, n do love.update(1 / 60); love.draw() end end
-- tap() releases the key for a frame so the next press is a new one.
local function tap(key) F.keys[key] = true; love.update(1 / 60); F.keys[key] = nil; love.update(1 / 60) end
-- Every menu page must fit the 320 x 180 screen and draw with the built-in pixel font.
local function menu_fits(state, what)
  local page = state:page()
  check(page and page.root.w <= 320 and page.root.h <= 180, what .. " fits the screen")
  local inside = true
  for _, w in ipairs(page.widgets) do
    if w.x < 0 or w.y < 0 or w.x + w.w > 320 or w.y + w.h > 180 then inside = false end
  end
  check(inside and #page.widgets >= 1, what .. ": its buttons stay inside the 320 x 180 screen")
  F.reset_calls(); state:draw(0)
  check(#F.find("printf") == 0 and #F.find("setFont") == 0,
    what .. " draws its text with engine.text rectangles, not love.graphics")
end

-- the title menu: the first state; Start Run enters the play state
check(engine.states:top() == title, "the game starts on the title menu")
check(title.autopause == false and gameover.autopause == false,
  "the title and game over menus never auto-pause")
local page = title:page()
check(page and page.focused == page:get("start"), "the title opens on Start Run")
menu_fits(title, "the title menu")
tap("down"); tap("return")                        -- Challenges
page = title:page()
check(page:get("title").text == "Challenges" and page:get("message").text == "No challenges yet.",
  "Challenges says there are no challenges yet")
menu_fits(title, "the Challenges page")
tap("return")                                     -- Back
check((title:page()).focused == title:page():get("start"), "Challenges Back returns to the title")
tap("down"); tap("down"); tap("return")           -- Progress
page = title:page()
check(page:get("title").text == "Progress" and page:get("message").text == "Coming soon.",
  "Progress is a placeholder page")
menu_fits(title, "the Progress page")
tap("return")
check((title:page()).focused == title:page():get("start"), "Progress Back returns to the title")
tap("down"); tap("down"); tap("down"); tap("return") -- Options
page = title:page()
check(page:get("title").text == "Options" and page:get("message").text == "Coming soon.",
  "Options is a placeholder page")
menu_fits(title, "the Options page")
tap("return")
check((title:page()).focused == title:page():get("start"), "Options Back returns to the title")
tap("down"); tap("down"); tap("down"); tap("down"); tap("return") -- Exit
page = title:page()
check(page:get("no") and page.focused == page:get("no"),
  "Exit asks before quitting, with No focused")
menu_fits(title, "the quit confirmation")
tap("return")                                     -- No
check((title:page()).focused == title:page():get("start"), "No goes back to the title menu")
tap("return")                                     -- Start Run
local play = engine.states:top()
check(play == require("rooms_play"), "Start Run enters the play state")
local nav, map, slime = play.nav, play.map, play.slime
check(nav.index == map.start, "it starts in the start room")
frames(60)
check(slime:on_ground(), "the slime lands in the start room")

-- the start room's right door: walk through it
local start = map.rooms[map.start]
local right
for e, exit in ipairs(start.template.exits) do if exit.side == "right" and start.doors[e] then right = start.doors[e] end end
check(right ~= nil, "seed 1: the start room has a door on the right")
local target = nav:through(right)
F.keys.right = true
local steps = 0
while nav.index == map.start and steps < 600 do love.update(1 / 60); steps = steps + 1 end
check(nav.index == target, "walking right leaves through the door into the next room (" .. steps .. " steps)")
check(play.fade:busy(), "behind a fade")
local cover = play.fade:cover(1)
frames(20)
F.keys.right = nil
local cx, cy = slime:center()
local w, h = nav:size()
check(cover > 0.9 and not play.fade:busy(), "the screen was covered at the swap, and is clear again")
check(cx > 0 and cx < w and cy > 0 and cy < h, "the slime is inside the new room")
check(nav:is_explored(target) and nav:is_explored(map.start), "both rooms explored")
local mm, seen = nav:minimap(), 0
for i = 1, #mm.cells do if mm.cells[i] and mm.cells[i].explored then seen = seen + 1 end end
check(seen >= 2, "the minimap shows them")

-- a locked door holds without the key and opens with it
local locked
for d, door in ipairs(map.doors) do if #door.requires > 0 then locked = d end end
local lock = map.doors[locked]
local side = map.rooms[lock.a].template.exits[lock.ea].side
local function edge(index, e)                         -- a point just past that exit's edge
  local r = map.rooms[index]
  local ex = r.template.exits[e]
  local ox, oy = P.templates.exit_cell(r.template, ex)
  local cw, ch = data.cell_w * data.tile_size, data.cell_h * data.tile_size
  local y = oy * ch + 10 * data.tile_size - 4         -- in the doorway (rows 9 to 11)
  if ex.side == "left" then return -6, y end
  return r.w * cw + 6, y
end
play.abilities = {}
play:load_room(nav:enter(lock.a))
check(#play.locked == 1, "the locked door is shut and drawn")
local ex, ey = edge(lock.a, lock.ea)
slime:move_to(ex, ey); love.update(1 / 60)
check(nav.index == lock.a and not play.fade:busy(), "past a locked door without the key: no way through")
play.abilities.key = true
play:load_room()
check(#play.locked == 0, "with the key the room is rebuilt with the door open")
slime:move_to(ex, ey); slime:set_velocity(0, 0); frames(25)
check(nav.index == lock.b, "and it leads to the next zone (" .. side .. ")")

-- the fight: enemies in a hall, a stomp, a bite, and dying sends the slime back to the start
local hall
for n = 1, 10 do                                       -- the first floor with a hall
  for i, r in ipairs(play.map.rooms) do if r.template.id == "hall" then hall = i; break end end
  if hall then break end
  play.new_floor(play, n + 1)
end
map, nav = play.map, play.nav
check(hall ~= nil, "a floor has a hall")
play:load_room(nav:enter(hall))
local fight = play.fight
check(#fight.enemies == 2 and fight:alive() == 2, "the hall has its two enemies")
local e1 = fight.enemies[1]
local hp0 = e1.fighter.health
frames(30)                                            -- let everything land
local ex1 = e1.body.x + e1.body.w / 2
slime:move_to(ex1, e1.body.y - 40); slime:set_velocity(0, 0)
local landed = false
for _ = 1, 60 do
  love.update(1 / 60)
  if fight.stomps > 0 then landed = true; break end
end
check(landed and e1.fighter.health < hp0, "falling onto an enemy stomps it (" .. e1.fighter.health .. " of " .. hp0 .. ")")
local _, bounce = slime:velocity()
check(bounce < 0, "and the slime bounces off")
-- stand beside an enemy until it bites
frames(60)
local p = fight.player
local hp = p.health
local bitten = false
for _ = 1, 300 do
  local alive
  for _, e in ipairs(fight.enemies) do if not e.fighter.dead then alive = e end end
  if not alive then break end
  if not play.fade:busy() then
    local b = alive.body
    local cx = slime:center()
    if math.abs(cx - (b.x + b.w / 2)) > 14 then
      slime:move_to(b.x + b.w / 2 + 12, b.y + b.h - 9); slime:set_velocity(0, 0)
    end
  end
  love.update(1 / 60)
  if p.health < hp then bitten = true; break end
end
check(bitten, "an enemy bites the slime when it is close (" .. p.health .. " of " .. hp .. ")")
-- the room remembers its fight: dead enemies do not come back and a hurt one keeps its health
play.rooms_state[hall] = nil
play:load_room(nav:enter(hall))
play.fight.enemies[1].fighter.dead = true
play.fight.enemies[1].fighter.health = 0
frames(1)
check(play.rooms_state[hall].enemies[1].dead, "the room saves the enemies it lost")
play.rooms_state[hall] = { cleared = false, enemies = {
  { dead = true, health = 0 },
  { dead = false, health = 1 },
} }
play:load_room(nav:enter(hall))
check(play.fight.enemies[1].fighter.dead and play.fight.enemies[2].fighter.health == 1,
  "a room remembers its dead enemies and their health")
play.rooms_state[hall] = nil

-- the slime's three attacks: the switch key cycles them, each one hurts an enemy
local names = {}
for i = 1, 3 do
  names[i] = play.fight:current().name
  F.keys.c = true; love.update(1 / 60); F.keys.c = nil; love.update(1 / 60)
end
check(names[1] == "melee" and names[2] == "ranged" and names[3] == "explosive"
  and play.fight:current().name == "melee", "switch cycles melee, ranged, explosive and back")
local reach = { melee = 14, ranged = 40, explosive = 40 }
for mode = 1, 3 do
  play.rooms_state[hall] = nil
  play:load_room(nav:enter(hall))
  local fight = play.fight
  fight.mode = mode
  frames(30)
  local name = fight:current().name
  local target
  for _, e in ipairs(fight.enemies) do if not e.fighter.dead then target = e; break end end
  local hp0 = target.fighter.health
  local hurt = false
  for k = 1, 240 do
    fight.player.invuln = 10                          -- keep the bites out of this check
    local b = target.body
    local side = b.x > 80 and -1 or 1                 -- stand on the side with more room
    if k % 20 == 1 then
      slime:move_to(b.x + b.w / 2 + side * reach[name], b.y + b.h - 9); slime:set_velocity(0, 0)
    end
    F.keys.right = (side < 0 and k % 20 == 2) or nil  -- face the enemy
    F.keys.left = (side > 0 and k % 20 == 2) or nil
    F.keys.x = (k % 20 == 5) or nil
    love.update(1 / 60); love.draw()
    if target.fighter.health < hp0 or target.fighter.dead then hurt = true; break end
  end
  F.keys.right, F.keys.left, F.keys.x = nil, nil, nil
  check(hurt, name .. ": the attack hurts an enemy")
  if name == "explosive" then check(fight.arsenal.blast_count > 0, "the bomb blew") end
end
play:load_room(nav:enter(hall))
check(play.fight:current().name == "explosive", "the attack chosen is kept from room to room")
fight = play.fight
p = fight.player

-- dying ends the run: after the fade, the game over menu over the frozen room
local death_room = nav.index
p.health = 1; p.invuln = 0
play.dead = true
frames(30)
check(engine.states:top() == gameover and play.deaths == 1 and nav.index == death_room,
  "dying ends the run and opens the game over menu over the same room")
check(play.fight.player.dead, "the dead run stays frozen under the menu")
page = gameover:page()
check(page and page.focused == page:get("restart"), "the game over menu opens on Restart Run")
menu_fits(gameover, "the game over menu")
-- Stats: the floor, the kills, the run time in m:ss and the virus of the run that ended
local stats_floor, stats_kills = play.floor, play.kills
local stats_time, stats_virus = play.run_time, play.wallet:get("virus")
tap("down"); tap("down"); tap("return")           -- Stats
page = gameover:page()
check(page:get("floor").text == "Floor: " .. stats_floor
  and page:get("kills").text == "Kills: " .. stats_kills, "the stats page shows the floor and the kills")
local secs = math.max(0, math.floor(stats_time))
check(page:get("time").text == string.format("Time: %d:%02d", math.floor(secs / 60), secs % 60),
  "the stats page shows the run time in m:ss (" .. page:get("time").text .. ")")
check(page:get("virus").text == "Virus: " .. stats_virus, "the stats page shows the virus collected")
menu_fits(gameover, "the stats page")
tap("return")                                     -- Back
check((gameover:page()).focused == gameover:page():get("restart"), "Stats Back returns to the game over menu")
-- Main Menu clears the stack: the dead play state is gone and the title is on top
tap("down"); tap("return")                        -- Main Menu
check(engine.states:top() == title and engine.states:depth() == 1 and engine.states:get("play") == play,
  "Main Menu returns to the title with the play state out of the stack")
check((title:page()).focused == title:page():get("start"), "the title opens on Start Run again")
menu_fits(title, "the title menu after Main Menu")
tap("return")                                     -- Start Run, a fresh run at floor 1
check(engine.states:top() == play and play.floor == 1, "Start Run starts at floor 1 again")
-- a second death, then Restart Run pops the menu and restarts the play state
play.fight.player.health = 1; play.fight.player.invuln = 0
play.dead = true
frames(30)
check(engine.states:top() == gameover and play.deaths == 1, "the new run's death opens it again")
tap("return")                                     -- Restart Run
check(engine.states:top() == play and play.floor == 1, "Restart Run starts at floor 1")
map, nav, slime = play.map, play.nav, play.slime

-- the floor is in its biome, the enemies are the biome's
check(play.biome and play.map.biome == play.biome.id and play.music == play.biome.music, "the floor has its biome and music")
check(play.floor > 2 or play.biome.id == "forest", "floors 1 and 2 are in the forest")
-- the treasure room: one mutation on the pedestal, the slime's for the run
local function find(kind)
  for i, r in ipairs(play.map.rooms) do if r.type == kind then return i end end
end
local tr = find("treasure")
check(tr, "the floor has a treasure room")
local carapace
for _, e in ipairs(require("rooms_content").mutations) do if e.id == "example_carapace" then carapace = e end end
check(carapace, "the carapace mutation exists")
play.loot[tr] = carapace
play.taken[tr] = nil
play:load_room(nav:enter(tr))
local item = play.treasure and play.treasure.entry
check(item == carapace, "the carapace on the pedestal")
local again = item
play:load_room(nav:enter(tr))
check(play.treasure and play.treasure.entry == again, "the same mutation when the slime comes back")
local before = { jump = play.stats:get("jump"), speed = play.stats:get("speed"),
  damage = play.stats:get("damage"), shield = play.stats:get("shield"),
  health = play.stats:get("health"), limbs = #play.look.limbs }
play.fight.player.health = 1
slime:move_to(play.treasure.x + 4, play.treasure.y); slime:set_velocity(0, 0)
frames(10)
check(not play.treasure and play.got == item and play.pools.mutations:taken_count(item.id) == 1,
  "the mutation is taken: " .. item.id)
check(play.mutations[#play.mutations] == item, "it joins the run's mutations")
check(play.fight.player.health == 1, "it does not heal the slime")
local changed = before.jump ~= play.stats:get("jump") or before.speed ~= play.stats:get("speed")
  or before.damage ~= play.stats:get("damage") or before.shield ~= play.stats:get("shield")
  or before.health ~= play.stats:get("health") or before.limbs ~= #play.look.limbs
check(changed, "its stats or its look changed")
local sh, shmax = play.stats:shield()
check(shmax == 2 and sh == 2, "the carapace fills two shield points")
play:load_room(nav:enter(tr))
check(not play.treasure, "and it is gone when the slime comes back")

-- the boss room: cleared, a mutation, a stairway, a new and bigger map
local floor0, rooms0 = play.floor, #play.map.rooms
play:load_room(nav:enter(play.map.boss))
check(play.fight:alive() > 0 and not play.stairs and play.sealed,
  "the boss room holds its enemies and its doors, no stairs yet")
for _, e in ipairs(play.fight.enemies) do e.fighter.dead = true end
frames(2)
check(play.stairs, "cleared: the stairway appears")
check(not play.sealed, "and the boss doors open")
play:load_room(nav:enter(play.map.boss))
check(play.fight:alive() == 0 and not play.sealed, "a cleared boss room stays cleared")
frames(1)
check(play.stairs, "and the stairs are still there")
play.fight.player.invuln = 10
slime:move_to(play.stairs.x + TS_HALF, play.stairs.y - 4); slime:set_velocity(0, 0)
frames(40)
check(play.floor == floor0 + 1 and play.nav.index == play.map.start, "down the stairs: floor " .. play.floor .. ", at its start")
check(#play.map.rooms >= rooms0 and play.map.floor == play.floor, "the next floor is generated (" .. #play.map.rooms .. " rooms)")
check(play.pools.mutations:taken_count(item.id) == 1, "the mutation stays for the run")
-- the biomes change along the run: by floor 10, the catastrophe
local ids = { play.biome.id }
while play.floor < 10 do
  play.new_floor(play, play.floor + 1)
  ids[#ids + 1] = play.biome.id
end
play:load_room(play.nav:enter(play.map.start))
check(play.biome.id == "catastrophe" and #play.map.rooms > 0, "the last floor is the catastrophe (" .. table.concat(ids, ",") .. ")")
play.new_floor(play, 1)
check(play.biome.id == "forest" and play.got == nil and play.stats:get("jump") == 1
  and play.stats:get("speed") == 1 and play.stats:get("shield") == 0
  and play.wallet:get("virus") == 0 and #play.mutations == 0
  and play.pools.mutations:taken_count(item.id) == 0, "a new run: the forest again, nothing taken")
play:load_room(play.nav:enter(play.map.start))
map, nav = play.map, play.nav

-- pickups: the start room has a heart (full health: one virus) and a virus pickup
local start_room = play.map.start
local function pickup_of(kind)
  for i, p in ipairs(play.pickups) do if p.kind == kind then return p, i end end
end
local heart = pickup_of("heart")
check(heart, "the start room has a heart")
local wallet0 = play.wallet:get("virus")
play.fight.player.health = play.stats:get("health")
slime:move_to(heart.x, heart.y); slime:set_velocity(0, 0)
frames(2)
check(play.wallet:get("virus") == wallet0 + 1, "a heart at full health becomes one virus")
check(not pickup_of("heart"), "the heart is gone")
local virus_pickup = pickup_of("virus")
check(virus_pickup, "the start room has a virus pickup")
local wallet1 = play.wallet:get("virus")
slime:move_to(virus_pickup.x, virus_pickup.y); slime:set_velocity(0, 0)
frames(2)
check(play.wallet:get("virus") == wallet1 + 2, "the virus pickup adds two")
check(not pickup_of("virus"), "the virus pickup is gone")

-- a breakable crate prop drops virus and stays broken
local crate_room
for n = 1, 10 do
  if n > 1 then play.new_floor(play, n); nav = play.nav end
  for i, r in ipairs(play.map.rooms) do
    for _, t in ipairs(r.template.props or {}) do
      if t.type == "crate" then crate_room = i; break end
    end
    if crate_room then break end
  end
  if crate_room then break end
end
check(crate_room, "a floor has a room with a crate")
play:load_room(nav:enter(crate_room))
local crate
for i = 1, play.props:count() do
  local p = play.props:at(i)
  if p.flags.breakable then crate = p; break end
end
check(crate, "the crate is a breakable prop")
crate.fields.virus_chance, crate.fields.virus = 1, 1
play.slime.facing = 1
play.slime:move_to(crate.x - 12, crate.y + 6); play.slime:set_velocity(0, 0)
F.keys.x = true; frames(2); F.keys.x = nil; frames(2)
check(crate.removed, "the attack breaks the crate")
local dropped = pickup_of("virus")
if dropped then play.slime:move_to(dropped.x, dropped.y); play.slime:set_velocity(0, 0); frames(2) end
check(not dropped or play.wallet:get("virus") > wallet1 + 2, "the crate drops virus")
play:load_room(nav:enter(crate_room))
local rebuilt
for i = 1, play.props:count() do
  local p = play.props:at(i)
  if p.index == crate.index then rebuilt = p; break end
end
check(rebuilt and rebuilt.removed, "the broken crate stays broken")

-- a machine with accepts_money: the healer spends virus and heals once
local shop = find("shop")
check(shop, "the floor has a shop")
play:load_room(nav:enter(shop))
local machine = play.machine
check(machine and machine.def.accepts_money, "the shop has a machine that accepts money")
play.wallet:add("virus", machine.def.price)
play.fight.player.health = 1
play.slime:move_to(machine.x + 6, machine.y + 6); play.slime:set_velocity(0, 0)
frames(1)
F.keys.e = true; frames(2); F.keys.e = nil; frames(2)
check(play.fight.player.health == play.stats:get("health"), "the healer fills the health")
check(machine.state.used == 1, "the machine remembers its use")
local price = machine.def.price
play.wallet:add("virus", price)
play.fight.player.health = 1
F.keys.e = true; frames(2); F.keys.e = nil; frames(2)
check(play.fight.player.health == 1 and machine.state.used == 1, "a used machine does not heal again")
play:load_room(nav:enter(play.map.start))
map, nav = play.map, play.nav

-- an up or down door opens the middle three columns of the border row
local vdoor, vroom, vexit, vfloor
for n = 2, 10 do
  play.new_floor(play, n); map, nav = play.map, play.nav
  for d, door in ipairs(map.doors) do
    for _, e in ipairs({ { door.a, door.ea }, { door.b, door.eb } }) do
      local ex = map.rooms[e[1]].template.exits[e[2]]
      if ex.side == "up" or ex.side == "down" then vdoor, vroom, vexit, vfloor = d, e[1], ex, n end
    end
    if vdoor then break end
  end
  if vdoor then break end
end
check(vdoor ~= nil, "a floor has an up or down door")
if vdoor then
  local door = map.doors[vdoor]
  nav:enter(door.a == vroom and door.b or door.a)
  local x, y = nav:go(vdoor)
  play:load_room(x, y)
  local row = vexit.side == "up" and 1 or play.grid.height
  local open = true
  for k = 9, 11 do open = open and play.grid:kind(vexit.offset * data.cell_w + k, row) == nil end
  check(open, "an up or down door opens the border (" .. vexit.side .. ")")
  local entered = nav.index
  play.fight.player.invuln = 100
  frames(30)
  check(nav.index == entered, "the arrival of an up or down door lands inside (" .. nav.index .. ")")
  play:load_room(nav:enter(map.start))
end

-- a miniboss room seals its doors too, and opens them when the fight is won
local mb, mb_floor
for n = 1, 10 do
  play.new_floor(play, n)
  for i, r in ipairs(play.map.rooms) do if r.type == "miniboss" then mb, mb_floor = i, n; break end end
  if mb then break end
end
if mb then
  play:load_room(play.nav:enter(mb))
  check(play.sealed and #play.fight.enemies > 0, "a miniboss room seals its doors (floor " .. mb_floor .. ")")
  play.fight.player.invuln = 100
  for _, e in ipairs(play.fight.enemies) do e.fighter.dead = true end
  frames(2)
  check(not play.sealed and play.fight:alive() == 0, "and opens them when it is cleared")
end

-- an enemy that falls out through a pit moves to the room below; past an edge with no door it dies
local pit_room, pit_exit, pit_floor
for n = 1, 10 do
  play.new_floor(play, n)
  for i, r in ipairs(play.map.rooms) do
    if #(r.template.enemies or {}) > 0 and r.type ~= "boss" and r.type ~= "miniboss" then
      for e, ex in ipairs(r.template.exits) do
        if ex.side == "down" and r.doors[e] then pit_room, pit_exit = i, e; break end
      end
    end
    if pit_room then break end
  end
  if pit_room then pit_floor = n; break end
end
check(pit_room ~= nil, "some floor has a room with enemies and a door down")
if pit_room then
  map, nav = play.map, play.nav
  play:load_room(nav:enter(pit_room))
  play.fight.player.invuln = 100
  local r = map.rooms[pit_room]
  local cw, ch = data.cell_w * data.tile_size, data.cell_h * data.tile_size
  local ox = P.templates.exit_cell(r.template, r.template.exits[pit_exit])
  local target, entry = nav:through(r.doors[pit_exit])
  local fe = play.fight.enemies[1]
  local before_alive, kills0 = play.fight:alive(), play.kills
  fe.fighter.health = fe.fighter.health - 1
  local hp = fe.fighter.health
  fe.body:teleport(ox * cw + cw / 2, r.h * ch + 4)
  frames(2)
  local arr = play.rooms_state[target] and play.rooms_state[target].arrivals
  check(fe.fighter.dead and play.room_state.enemies[1].dead, "an enemy past the pit is gone from its room")
  check(play.kills == kills0, "and it is not a kill")
  check(arr and #arr == 1 and arr[1].health == hp, "it is waiting in the room below with its health")
  local tcount = #(map.rooms[target].template.enemies or {})
  play:load_room(nav:enter(target, entry))
  local arrived = play.fight.enemies[tcount + 1]
  check(arrived and not arrived.fighter.dead and arrived.fighter.health == hp, "the room below has it")
  play:load_room(nav:enter(pit_room))
  check(play.fight:alive() == before_alive - 1, "it does not come back where it fell from")
  -- past an edge with no door: it just dies
  local other
  for _, e in ipairs(play.fight.enemies) do if not e.fighter.dead then other = e; break end end
  if other then
    local kills1 = play.kills
    other.body:teleport(-40, -40)                        -- above the top left corner
    local _, door = nav:leaving(-40 + other.body.w / 2, -40 + other.body.h / 2)
    local n_arr = 0
    for _, st in pairs(play.rooms_state) do n_arr = n_arr + #(st.arrivals or {}) end
    frames(2)
    local n_arr2 = 0
    for _, st in pairs(play.rooms_state) do n_arr2 = n_arr2 + #(st.arrivals or {}) end
    check(other.fighter.dead and play.kills == kills1, "an enemy past an edge dies, not as a kill")
    check(door or n_arr2 == n_arr, "and with no door there it goes nowhere")
  end
end

-- the spawn state updates from the floor that ends: a shop left unentered raises the casino
-- chance, and damage resets the obstacle chance
play.restart(play)
play.spawn.casino = 0
local skipped_shop = find("shop")
check(skipped_shop, "a floor has a shop to leave unentered")
play.new_floor(play, 2)
check(math.abs(play.spawn.casino - 0.05) < 1e-9,
  "a shop left unentered raises the casino chance (" .. play.spawn.casino .. ")")
play.spawn.obstacle = 0.80
play:load_room(play.nav:enter(play.map.start))
frames(1)
play.last_health = play.fight.player.health
play.fight.player.health = play.last_health - 1
love.update(1 / 60)
check(play.floor_damaged, "losing health marks the floor damaged")
play.new_floor(play, 3)
check(math.abs(play.spawn.obstacle - 0.05) < 1e-9,
  "damage resets the obstacle chance (" .. play.spawn.obstacle .. ")")
check(play.floor_damaged == false, "the next floor starts undamaged")
play:load_room(play.nav:enter(play.map.start))

-- the pause menu: Escape pauses (the play state stops updating) and Resume pops it
local pause = require("rooms_pause")
check(engine.states:get("pause") == pause, "the pause state is registered")
if play.fade:busy() then frames(30) end
local updates = 0
local real_update = play.update
play.update = function(self, dt) updates = updates + 1; return real_update(self, dt) end
F.keys.escape = true; love.update(1 / 60); F.keys.escape = nil
check(engine.states:top() == pause, "Escape pushes the pause state")
frames(10)
check(updates == 0, "the play state does not update while paused")
F.keys["return"] = true; love.update(1 / 60); F.keys["return"] = nil
check(engine.states:top() == play, "Resume pops the pause state")
local before = updates
frames(2)
check(updates > before, "the play state updates again")
play.update = real_update

-- losing the pad in use auto-pauses with reason "controller"
local pad = F.add_pad()
love.joystickadded(pad)
love.gamepadpressed(pad, "a")
check(engine.controls.joystick == pad, "the pad is the one in use")
for i = #F.pads, 1, -1 do if F.pads[i] == pad then table.remove(F.pads, i) end end
love.joystickremoved(pad)
check(engine.states:top() == pause and pause.reason == "controller", "losing the pad in use auto-pauses")
local page = pause:page()
check(page and page.root.w <= 320 and page.root.h <= 180,
  "the controller message wraps: the pause menu fits the screen")
local inside = true
for _, w in ipairs(page.widgets) do
  if w.x < 0 or w.y < 0 or w.x + w.w > 320 or w.y + w.h > 180 then inside = false end
end
check(inside and #page.widgets >= 3, "its buttons stay inside the 320 x 180 screen")
F.reset_calls(); pause:draw(0)
check(#F.find("printf") == 0 and #F.find("setFont") == 0,
  "the menu draws its text with engine.text rectangles, not love.graphics")
F.keys["return"] = true; love.update(1 / 60); F.keys["return"] = nil
check(engine.states:top() == play, "Resume after the controller was lost")

-- Restart run: a confirmation, then Yes starts the run again at floor 1
-- (floors are entered in order, so start a fresh run and walk to floor 3)
play.restart(play)
play.new_floor(play, 2)
play.new_floor(play, 3)
play:load_room(play.nav:enter(play.map.start))
check(play.floor == 3, "a floor to leave behind")
F.keys.p = true; love.update(1 / 60); F.keys.p = nil
check(engine.states:top() == pause, "P pauses too")
F.keys.down = true; love.update(1 / 60); F.keys.down = nil
F.keys["return"] = true; love.update(1 / 60); F.keys["return"] = nil
check(play.floor == 3 and engine.states:top() == pause, "Restart run asks first")
F.keys.left = true; love.update(1 / 60); F.keys.left = nil
F.keys["return"] = true; love.update(1 / 60); F.keys["return"] = nil
check(engine.states:top() == play and play.floor == 1, "Yes restarts the run at floor 1")

-- reopening starts on Resume, not on the last button used; Quit game confirms (No focused),
-- then quits.
tap("escape")
check(engine.states:top() == pause, "Escape pauses again")
tap("return")
check(engine.states:top() == play, "the menu reopens with Resume focused")
tap("escape"); tap("down"); tap("down"); tap("return")
check(not F.quit and engine.states:top() == pause, "Quit game asks first")
tap("return")
check(not F.quit and engine.states:top() == pause, "No (focused by default) goes back to the menu")
tap("return")
check(engine.states:top() == play, "and the menu is back on Resume")
tap("escape"); tap("down"); tap("down"); tap("return"); tap("left"); tap("return")
check(F.quit == true, "Yes on Quit game leaves the game")

-- the room is drawn, the minimap through rooms_minimap
local minimap_mod = require("rooms_minimap")
local minimap_draw = minimap_mod.draw
local minimap_calls = 0
minimap_mod.draw = function(...) minimap_calls = minimap_calls + 1; return minimap_draw(...) end
F.reset_calls(); love.draw()
minimap_mod.draw = minimap_draw
check(minimap_calls == 1, "the minimap is drawn through rooms_minimap")
check(#F.find("rectangle") >= 5 and play.pixels.count > 150, "the room, the slime and the minimap are drawn")
check(play.art and play.art.quads and play.tile_batch and #play.fireflies == 8,
  "the biome has art, a tile batch and eight fireflies")
local drawn_batch = false
for _, c in ipairs(F.find("draw")) do if c[2] == play.tile_batch then drawn_batch = true end end
check(drawn_batch, "the tile batch is drawn inside the camera")

print(string.format("OK: %d checks; the rooms example boots and walks its map", checks))
