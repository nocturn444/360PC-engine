-- examples/rooms: boots on the console's boot (tests/pc/boot_pc.lua) and runs on the engine
-- tests' fake love: the slime starts in the start room, walks out through a door behind a fade,
-- arrives inside the next room, a locked door holds until the key is picked up, the minimap
-- marks what was explored, and the room is drawn.
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
for _, name in ipairs({ "game.lua", "conf.lua", "main.lua", "rooms_play.lua", "rooms_data.lua", "rooms_biomes.lua", "rooms_items.lua", "README.md" }) do
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
-- the biomes of 200 runs: the cellar first (2 floors), the core last, spans of 1 to 3 floors,
-- the forge never before floor 5, the ruins only after 12 kills; every floor generates
local B = require("rooms_biomes")
local set = require("rooms_play").biomes
local seen = {}
for seed = 1, 200 do
  local path, streams = set:path(), Rng.streams(seed)
  local kills = (seed % 2 == 0) and 20 or 0
  for n = 1, 10 do
    local b = path:enter(n, { kills = kills }, streams:get("biomes"))
    seen[b.id] = true
    if n <= 2 then check(b.id == "cellar", "seed " .. seed .. ": the run opens in the cellar") end
    if n == 10 then check(b.id == "core", "seed " .. seed .. ": the run ends in the core") end
    if b.id == "forge" then check(path.current.first >= 5, "the forge starts on floor 5 or later") end
    if b.id == "ruins" then check(kills >= 12, "the ruins need 12 kills") end
    check(path.current.last - path.current.first <= 2, "a biome lasts 1 to 3 floors")
    if seed <= 20 then
      local m, why = plan:generate(n, streams:get("floor" .. n), b)
      check(m and m.biome == b.id and m.difficulty == b.difficulty, "seed " .. seed .. " floor " .. n .. " in " .. b.id .. ": " .. tostring(why))
    end
  end
end
for _, id in ipairs({ "cellar", "caves", "garden", "forge", "ruins", "core" }) do check(seen[id], "biome " .. id .. " comes up") end
check(B.enemy_stats(B.list[6], true).max_health > B.enemy_stats(B.list[1], true).max_health, "the core's boss is stronger")
-- the treasure items: biome items only in their biomes
local pool = require("rooms_items").pool()
for _, id in ipairs({ "caves", "garden", "forge", "ruins" }) do
  local got = {}
  local r = Rng.new(7)
  for k = 1, 200 do local e = pool:draw(r, { room = "treasure", biome = id }); got[e.id] = true end
  for _, e in ipairs(require("rooms_items").entries) do
    if e.biomes and got[e.id] then
      local ok = false
      for _, x in ipairs(e.biomes) do ok = ok or x == id end
      check(ok, e.id .. " only in its biomes (" .. id .. ")")
    end
  end
end
for _, t in ipairs(data.templates()) do
  local rows = t.rows
  check(#rows == (t.h or 1) * data.cell_h and #rows[1] == (t.w or 1) * data.cell_w, t.id .. ": rows fit its cells")
end

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
local engine = require("engine")
local play = engine.states:top()
check(play == require("rooms_play"), "the state is entered")
local nav, map, slime = play.nav, play.map, play.slime
local function frames(n) for _ = 1, n do love.update(1 / 60); love.draw() end end
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

-- dying: back to the start room at full health
p.health = 1; p.invuln = 0
play.dead = true
frames(30)
check(nav.index == map.start and play.deaths == 1, "dying sends it back to the start room")
check(play.fight.player.health == play.fight.player.stats:get("max_health"), "with full health")

-- the floor is in its biome, the enemies are the biome's
check(play.biome and play.map.biome == play.biome.id and play.music == play.biome.music, "the floor has its biome and music")
check(play.floor > 2 or play.biome.id == "cellar", "floors 1 and 2 are in the cellar")
-- the treasure room: an item of the biome on the pedestal, the slime's for the run
local function find(kind)
  for i, r in ipairs(play.map.rooms) do if r.type == kind then return i end end
end
local tr = find("treasure")
check(tr, "the floor has a treasure room")
play:load_room(nav:enter(tr))
local item = play.treasure and play.treasure.entry
check(item, "an item on the pedestal")
local again = item
play:load_room(nav:enter(tr))
check(play.treasure and play.treasure.entry == again, "the same item when the slime comes back")
local before = { max = play.fight.player.stats:get("max_health"), bonus = {} }
for k, v in pairs(play.bonus) do before.bonus[k] = v end
play.fight.player.health = 1
slime:move_to(play.treasure.x + 4, play.treasure.y); slime:set_velocity(0, 0)
frames(10)
check(not play.treasure and play.got == item and play.pool:taken_count(item.id) == 1, "the item is taken: " .. item.id)
local changed = false
for k, v in pairs(play.bonus) do changed = changed or v ~= before.bonus[k] end
check(changed, "its bonus counts for the run")
check(play.fight.player.health == play.fight.player.stats:get("max_health"), "and the slime is healed")
if item.bonus.max_health then check(play.fight.player.stats:get("max_health") == before.max + item.bonus.max_health, "more max health") end
play:load_room(nav:enter(tr))
check(not play.treasure, "and is gone when the slime comes back")

-- the boss room: cleared, a stairway leads to the next floor, a new and bigger map
local floor0, rooms0 = play.floor, #play.map.rooms
play:load_room(nav:enter(play.map.boss))
check(play.fight:alive() > 0 and not play.stairs, "the boss room holds its enemies, no stairs yet")
for _, e in ipairs(play.fight.enemies) do e.fighter.dead = true end
frames(2)
check(play.stairs, "cleared: the stairway appears")
play.fight.player.invuln = 10
slime:move_to(play.stairs.x + TS_HALF, play.stairs.y - 4); slime:set_velocity(0, 0)
frames(40)
check(play.floor == floor0 + 1 and play.nav.index == play.map.start, "down the stairs: floor " .. play.floor .. ", at its start")
check(#play.map.rooms >= rooms0 and play.map.floor == play.floor, "the next floor is generated (" .. #play.map.rooms .. " rooms)")
check(play.got == item and play.pool:taken_count(item.id) == 1, "the item stays for the run")
-- the biomes change along the run: by floor 10, the core
local ids = { play.biome.id }
while play.floor < 10 do
  play.new_floor(play, play.floor + 1)
  ids[#ids + 1] = play.biome.id
end
play:load_room(play.nav:enter(play.map.start))
check(play.biome.id == "core" and #play.map.rooms > 0, "the last floor is the core (" .. table.concat(ids, ",") .. ")")
play.new_floor(play, 1)
check(play.biome.id == "cellar" and play.got == nil and play.bonus.max_health == 0 and play.pool:taken_count(item.id) == 0, "a new run: the cellar again, nothing taken")
play:load_room(play.nav:enter(play.map.start))
map, nav = play.map, play.nav

-- an up or down door opens the middle three columns of the border row
local vdoor, vroom, vexit
for d, door in ipairs(map.doors) do
  for _, e in ipairs({ { door.a, door.ea }, { door.b, door.eb } }) do
    local ex = map.rooms[e[1]].template.exits[e[2]]
    if ex.side == "up" or ex.side == "down" then vdoor, vroom, vexit = d, e[1], ex end
  end
  if vdoor then break end
end
check(vdoor ~= nil, "seed 1 floor 1 has an up or down door")
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

-- the room is drawn
F.reset_calls(); love.draw()
check(#F.find("rectangle") >= 5 and play.pixels.count > 150, "the room, the slime and the minimap are drawn")
F.keys.escape = true; love.update(1 / 60)
check(F.quit == true, "quit leaves the game")

print(string.format("OK: %d checks; the rooms example boots and walks its map", checks))
