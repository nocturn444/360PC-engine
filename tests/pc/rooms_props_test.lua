-- examples/rooms: the new prop types wired into the play state. The catalog is up to date, a
-- broken crate persists and drops virus deterministically, spikes cost a heart and knock the
-- slime back, the slime hangs on a '=' edge but slides off a wide platform edge, a statue fires
-- on its interval without counting as an enemy, and the props update allocates nothing.
-- Usage, from the repository root: luajit -joff tests/pc/rooms_props_test.lua   (ends with OK:)
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

-- 1. The catalog the editors read is up to date
local pipe = assert(io.popen("luajit tools/props_catalog.lua examples/rooms rooms_props " ..
  "-o examples/rooms/props_catalog.lvl --check 2>&1"))
local catalog_out = pipe:read("*a")
local catalog_ok = pipe:close()
check(catalog_ok and catalog_out:find("up to date", 1, true), "props_catalog.lvl is up to date: " .. catalog_out)
check(read("examples/rooms/props_catalog.lvl"), "the catalog file exists")

-- 2. On the fake love
local F = require("fake_love")
F.install({ width = 1280, height = 720 })
assert(loadfile("examples/rooms/main.lua"))()
love.load()
local engine = require("engine")
engine.states:switch("play")                -- the game starts on the title menu now
local play = engine.states:top()
local function frames(n) for _ = 1, n do love.update(1 / 60); love.draw() end end
local function find_hall()
  for n = 1, 10 do
    if n > 1 then play.new_floor(play, n) end
    for i, r in ipairs(play.map.rooms) do
      if r.template.id == "hall" then return i end
    end
  end
end
local function prop_of(kind, flag)
  for i = 1, play.props:count() do
    local p = play.props:at(i)
    if (kind and p.type == kind) or (flag and p.flags[flag]) then return p end
  end
end
local function virus_pickup()
  for i = 1, #play.pickups do
    local p = play.pickups[i]
    if p.kind == "virus" then return p, i end
  end
end
local function no_enemies()
  for _, e in ipairs(play.fight.enemies) do e.fighter.dead, e.fighter.health = true, 0 end
end

local hall = find_hall()
check(hall, "a floor has a hall")
play:load_room(play.nav:enter(hall))

-- The crate: a solid prop, broken by the attack, dropping its virus and staying broken
local crate = prop_of(nil, "breakable")
check(crate and crate.def.collision == "solid", "the hall has a solid breakable crate")
check(play.grid:kind(crate.tx, crate.ty) == "solid", "the crate is stamped on the collision grid")
crate.fields.virus_chance, crate.fields.virus = 1, 2
play.fight.player.invuln = 10
play.facing, play.fight.box.facing = 1, 1
play.slime:move_to(crate.x - 12, crate.y + 6); play.slime:set_velocity(0, 0)
local wallet0 = play.wallet:get("virus")
F.keys.x = true; frames(2); F.keys.x = nil; frames(2)
check(crate.removed, "the attack breaks the crate")
local drawn_after = false
for i = 1, #play.prop_solid do
  local r = play.prop_solid[i]
  if r[1] == crate.x and r[2] == crate.y then drawn_after = true end
end
check(not drawn_after, "the broken crate is no longer drawn")
local dropped = virus_pickup()
check(dropped and dropped.amount == 2, "the crate drops its virus amount")
if dropped then
  play.slime:move_to(dropped.x, dropped.y); play.slime:set_velocity(0, 0)
  frames(2)
end
check(play.wallet:get("virus") == wallet0 + 2, "the dropped virus reaches the wallet")
local broken_index = crate.index
play:load_room(play.nav:enter(hall))
local rebuilt
for i = 1, play.props:count() do
  local p = play.props:at(i)
  if p.index == broken_index then rebuilt = p end
end
check(rebuilt and rebuilt.removed, "the broken crate stays broken on the next visit")
check(play.grid:kind(rebuilt.tx, rebuilt.ty) == nil, "a broken crate is off the collision grid")

-- The same run and seed give the same crate drop
play.restart(play)
hall = find_hall()
play:load_room(play.nav:enter(hall))
local crate2 = prop_of(nil, "breakable")
crate2.fields.virus_chance, crate2.fields.virus = 1, 2
play.fight.player.invuln = 10
play.facing, play.fight.box.facing = 1, 1
play.slime:move_to(crate2.x - 12, crate2.y + 6); play.slime:set_velocity(0, 0)
F.keys.x = true; frames(2); F.keys.x = nil; frames(2)
local dropped2 = virus_pickup()
check(crate2.removed and dropped2 and dropped2.amount == dropped.amount,
  "a new run with the same seed breaks its crate the same way")

-- Spikes: the hazard costs a heart through the damage path, with i-frames and knockback
play:load_room(play.nav:enter(hall))
local spikes = prop_of(nil, "hazard")
check(spikes, "the hall has spikes")
no_enemies()
play.fight.player.health = 5
play.fight.player.invuln = 0
play.slime:move_to(spikes.x + spikes.w / 2 - 4, spikes.y - 4); play.slime:set_velocity(0, 0)
local health0 = play.fight.player.health
frames(1)
check(play.fight.player.health == health0 - spikes.fields.damage,
  "spikes cost " .. spikes.fields.damage .. " heart(s)")
check(play.fight.player.invuln > 0, "the hit grants the usual i-frames")
local vx = play.slime:velocity()
check(vx < 0, "the spikes knock the slime away from them (" .. vx .. ")")
local hurt_health = play.fight.player.health
frames(5)
check(play.fight.player.health == hurt_health, "i-frames keep the spikes from hitting again")

-- A statue: fires after its delay, is on the enemy team, cannot be hit and is not an enemy
play:load_room(play.nav:enter(hall))
local statue = prop_of(nil, "turret")
check(statue, "the hall has a statue")
no_enemies()
play.fight.player.invuln = 100
statue.fields.delay, statue.fields.interval = 0.2, 1.0
statue.state.timer = statue.fields.delay
frames(10)
check(play.fight.arsenal:count() == 0 and play.fight:alive() == 0,
  "the statue waits for its delay and is not an enemy")
frames(6)
check(play.fight.arsenal:count() > 0, "after the delay the statue fires")
local is_enemy = false
for _, e in ipairs(play.fight.enemies) do if e.owner == statue then is_enemy = true end end
check(not is_enemy, "the statue is not in the room's enemies")
check(play.props:hit(statue, 1) == false and not statue.removed, "the statue cannot be destroyed")

-- Hanging on a '=' edge, sliding off a wide platform edge: an open test room with one of each
local template = play.map.rooms[hall].template
local saved_rows, saved_props = template.rows, template.props
local rows = { "####################", "#..................#", "#..................#", "#...=..............#" }
for i = 5, 11 do rows[i] = "#..................#" end
rows[12] = "####################"
template.rows = rows
template.props = { { type = "wide_platform", tx = 10, ty = 4, w = 4 } }
play.rooms_state[hall] = nil
local function place_and_measure(x, y)
  play:load_room(play.nav:enter(hall))
  no_enemies()
  play.fight.player.invuln = 100
  local slime = play.slime
  slime:move_to(x, y); slime:set_velocity(0, 0)
  frames(120)
  return slime:center()
end
-- the one-way tile: x 64..80, top 48; the centre just before its right edge hangs
local hx, hy = place_and_measure(78, 42)
check(hy < 120, "the slime hangs on the '=' edge (cy " .. hy .. ")")
-- the wide platform: x 144..208, top 48; with its centre past the right edge it slides off
local wx, wy = place_and_measure(210, 42)
check(wy > 140, "the slime slides off the wide platform edge (cy " .. wy .. ")")
check(wx > 208, "the slide takes it outward (cx " .. wx .. ")")
template.rows, template.props = saved_rows, saved_props
play.rooms_state[hall] = nil

-- The game's own props update allocates nothing per frame
play:load_room(play.nav:enter(hall))
statue = prop_of(nil, "turret")
statue.fields.delay, statue.fields.interval = 0, 0.3
statue.state.timer = 0
play.update_props(play, 1 / 60)
collectgarbage(); collectgarbage("stop")
local before = collectgarbage("count")
for _ = 1, 240 do
  play.update_props(play, 1 / 60)
  play.props:update(1 / 60, play)
end
local grown = collectgarbage("count") - before
collectgarbage("restart")
check(grown < 1, "the props update allocates nothing per frame (" .. grown .. " KB)")

print(string.format("OK: %d checks; rooms props", checks))
