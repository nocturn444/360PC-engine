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
for _, name in ipairs({ "game.lua", "conf.lua", "main.lua", "rooms_play.lua", "rooms_data.lua", "README.md" }) do
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
for i, r in ipairs(map.rooms) do if r.template.id == "hall" then hall = i; break end end
check(hall ~= nil, "seed 1 has a hall")
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
-- dying: back to the start room at full health
p.health = 1; p.invuln = 0
play.dead = true
frames(30)
check(nav.index == map.start and play.deaths == 1, "dying sends it back to the start room")
check(play.fight.player.health == play.fight.player.stats:get("max_health"), "with full health")

-- the room is drawn
F.reset_calls(); love.draw()
check(#F.find("rectangle") >= 5 and play.pixels.count > 150, "the room, the slime and the minimap are drawn")
F.keys.escape = true; love.update(1 / 60)
check(F.quit == true, "quit leaves the game")

print(string.format("OK: %d checks; the rooms example boots and walks its map", checks))
