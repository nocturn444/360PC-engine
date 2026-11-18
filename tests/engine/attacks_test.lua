-- engine/modules/combat/attacks.lua: configs (defaults and errors), melee sweeps (windup,
-- active steps, mirroring, once per activation, cooldown), ranged shots (travel, hits, pierce,
-- walls, lifetime, fans, aim, gravity, knockback along the shot), explosive bombs (fuse,
-- radius, falloff, radial knockback, self damage, thrown bombs that bounce or blow on contact,
-- blasts), hitstop pausing an attack, determinism, and no allocation once warm.
local T = ...
local F = require("fake_love")
F.install()
local globals = {}
for k in pairs(_G) do globals[k] = true end
local Timestep = require("engine.timestep")
local C = require("engine.modules.combat")
local A = C.attacks

local dt = Timestep.new({ rate = 60 }).dt

-- A grid of 8 px tiles: a floor on row 10 and a wall in column 20.
local rows = {}
for ty = 1, 12 do
  local r = {}
  for tx = 1, 40 do
    r[tx] = (ty >= 10 or tx == 20) and "#" or "."
  end
  rows[ty] = table.concat(r)
end
local grid = C and require("engine.modules.platformer").grid.new(rows, { tile_size = 8 })

local function body(x, y, facing)
  return { x = x, y = y or 40, w = 10, h = 10, facing = facing or 1, vx = 0, vy = 0 }
end
local function fighter(world, x, team, stats, y)
  local f = world:fighter({ body = body(x, y), team = team, params = C.stats.new(stats or { invuln_time = 0 }) })
  f.box = f:hurtbox({ w = 10, h = 10 })
  return f
end
local function steps(arsenal, n)
  local landed = 0
  for _ = 1, n or 1 do
    arsenal:step(dt)
    landed = landed + arsenal.world:step(dt)
  end
  return landed
end
local function errors(config, pattern, what)
  local ok, err = pcall(A.define, config)
  T.check(not ok and tostring(err):find(pattern, 1, true), what .. " (" .. tostring(err) .. ")")
end

---------------------------------------------------------------------------
-- Configs
---------------------------------------------------------------------------
local d = A.define({ kind = "ranged" })
T.check(d.cooldown == 0.3 and d.windup == 0 and d.speed == 200 and d.count == 1 and d.pierce == 1
  and d.walls == "stop" and d.damage == nil, "ranged: defaults filled in")
d = A.define({ kind = "explosive", throw = { speed = 90 } })
T.check(d.radius == 24 and d.fuse == 0.5 and d.throw.speed == 90 and d.throw.gravity == 500
  and d.throw.contact == false, "explosive: defaults, and the throw's")
d = A.define({ kind = "melee", boxes = { { ox = 2, w = 4, h = 4 } } })
T.check(d.active == 0.1 and d.boxes[1].oy == 0 and d.boxes[1].ox == 2, "melee: defaults, boxes copied")
errors({ kind = "laser" }, "unknown kind laser", "an unknown kind is an error")
errors({ kind = "ranged", radius = 3 }, "ranged has no field radius", "a field of another kind is an error")
errors({ kind = "ranged", speed = "fast" }, "speed is a number", "a wrong type is an error")
errors({ kind = "melee" }, "at least one box", "melee needs boxes")
errors({ kind = "ranged", walls = "bounce" }, "walls is", "walls is stop or pass")
errors({ kind = "explosive", throw = { spin = 1 } }, "throw has no field spin", "an unknown throw field is an error")
T.check(#A.kinds == 3, "three kinds")

---------------------------------------------------------------------------
-- Melee: a sweep through three boxes
---------------------------------------------------------------------------
local w = C.world.new()
local ars = A.new(w, { grid = grid })
local hero = fighter(w, 100, "player", { attack_damage = 2, invuln_time = 0 })
local foe = fighter(w, 114, "enemy", { max_health = 20, invuln_time = 0 })
local arc = ars:equip(hero, { kind = "melee", windup = 2 / 60, active = 6 / 60, cooldown = 0.5, power = 1.5,
  knockback = 100, boxes = { { ox = 0, oy = -12, w = 8, h = 6 }, { ox = 6, oy = -4, w = 8, h = 8 }, { ox = 0, oy = 6, w = 8, h = 6 } } })
T.check(arc:ready() and arc.name == "melee", "an attack starts ready, named after its kind")
T.check(arc:trigger() and not arc:trigger(), "trigger starts it once")
steps(ars, 2)
T.check(arc.phase == "windup" and not arc.hitbox.active, "a windup of 2 steps: nothing out yet")
steps(ars, 1)
T.check(arc.phase == "active" and arc.hitbox.active and arc.uses == 1, "then the hitbox is out")
local x, y, bw, bh = arc.hitbox:rect()
T.check(x == 105 and y == 33 and bw == 8 and bh == 6, "box 1: from the body's centre (" .. x .. ", " .. y .. ")")
local hp = foe.health
steps(ars, 2)
x, y = arc.hitbox:rect()
T.check(x == 111 and y == 41, "box 2 of the sweep (" .. x .. ", " .. y .. ")")
T.check(foe.health == hp - 3, "power 1.5 times attack_damage 2, hit once (" .. foe.health .. ")")
T.check(foe.body.vx == 100, "knocked along the facing")
steps(ars, 2)
x, y = arc.hitbox:rect()
T.check(y == 51 and arc.hitbox.active, "box 3")
local active_steps = 5
while true do
  steps(ars, 1)
  if not arc.hitbox.active then break end
  active_steps = active_steps + 1
end
T.check(active_steps == 6 and arc.phase == "idle", "active 6/60 s: 6 world steps (" .. active_steps .. ")")
T.check(foe.health == hp - 3, "once per activation")
T.check(not arc:trigger(), "the cooldown holds")
steps(ars, 30 - 9)
T.check(arc:ready() and arc:trigger(), "and runs out 0.5 s after the trigger")
hero.body.facing = -1
steps(ars, 3)
x = arc.hitbox:rect()
T.check(x == 97, "mirrored when facing left (" .. x .. ")")
arc:cancel()
T.check(not arc.hitbox.active and arc.phase == "idle", "cancel puts it away")

-- hitstop pauses an attack's windup
hero.body.facing = 1
steps(ars, 40)
arc:trigger()
hero:stop(3 / 60)
steps(ars, 3)
T.check(arc.phase == "windup", "a frozen fighter's windup waits")
steps(ars, 3)
T.check(arc.phase == "active", "and goes on after the freeze")

---------------------------------------------------------------------------
-- Ranged
---------------------------------------------------------------------------
w = C.world.new()
ars = A.new(w, { grid = grid })
hero = fighter(w, 20, "player", { attack_damage = 1, invuln_time = 0 })
local ally = fighter(w, 40, "player")
foe = fighter(w, 80, "enemy", { max_health = 10, invuln_time = 0 })
local far = fighter(w, 100, "enemy", { max_health = 10, invuln_time = 0 })
local gun = ars:equip(hero, { kind = "ranged", speed = 240, life = 2, damage = 2, knockback = 50, w = 4, h = 2, ox = 6, cooldown = 0 })
gun:trigger()
steps(ars, 1)
local p = ars.projectiles[1]
T.check(ars:count() == 1 and p.kind == "shot" and p.alive, "a shot is in flight")
T.check(p.y == 44 and p.x > 29, "from the body's centre plus its offset (" .. p.x .. ", " .. p.y .. ")")
local hits = steps(ars, 20)
T.check(hits == 1 and foe.health == 8 and ally.health == ally.stats:get("max_health"), "it passes its own team and hits the enemy")
T.check(foe.body.vx == 50, "knocked along the shot")
T.check(not p.alive and far.health == 10, "pierce 1: gone after one hit")
-- pierce 2
local lance = ars:equip(hero, { kind = "ranged", speed = 240, life = 2, damage = 1, pierce = 2, cooldown = 0 })
foe.health, far.health = 10, 10
lance:trigger()
steps(ars, 40)
T.check(foe.health == 9 and far.health == 9, "pierce 2: two fighters")
-- a wall in column 20 (x 152..160)
local probe = ars:equip(far, { kind = "ranged", speed = 300, life = 3, damage = 1, cooldown = 0 })
probe:trigger()
steps(ars, 2)
local shot
for _, q in ipairs(ars.projectiles) do if q.alive and q.source == far then shot = q end end
steps(ars, 30)
T.check(shot and not shot.alive and shot.x < 160, "walls stop a shot (" .. (shot and shot.x or -1) .. ")")
local ghost = ars:equip(far, { kind = "ranged", speed = 300, life = 0.5, damage = 1, walls = "pass", cooldown = 0 })
ghost:trigger()
steps(ars, 1)
for _, q in ipairs(ars.projectiles) do if q.alive and q.source == far then shot = q end end
steps(ars, 20)
T.check(shot.x > 160 and shot.alive, "walls = pass: through it")
steps(ars, 20)
T.check(not shot.alive, "and gone at the end of its life")
-- a fan of three, symmetric, and an aimed shot
w = C.world.new()
ars = A.new(w, { grid = grid })
hero = fighter(w, 20, "player")
local fan = ars:equip(hero, { kind = "ranged", count = 3, spread = 40, speed = 100, cooldown = 0 })
fan:trigger()
steps(ars, 2)
local list = ars.projectiles
T.near(list[1].vy, -list[3].vy, "the fan is symmetric")
T.near(list[2].vy, 0, "its middle shot is level")
T.near(list[1].vx, 100 * math.cos(20 * math.pi / 180), "each at speed, 20 degrees off")
ars:clear()
T.check(ars:count() == 0, "clear puts every shot away")
fan:trigger(0, -1)
steps(ars, 1)
T.near(list[2].vx, 0, "aimed straight up: the middle shot", 1e-9)
T.near(list[2].vy, -100, "goes up")
ars:clear()
local lob = ars:equip(hero, { kind = "ranged", speed = 100, gravity = 300, angle = 45, cooldown = 0 })
hero.body.facing = -1
lob:trigger()
steps(ars, 1)
local vy0 = list[1].vy
steps(ars, 10)
T.check(list[1].vx < 0 and list[1].vy > vy0, "facing left, an arc that falls")
hero.body.facing = 1
ars:clear()

---------------------------------------------------------------------------
-- Explosive
---------------------------------------------------------------------------
w = C.world.new()
ars = A.new(w, { grid = grid })
hero = fighter(w, 100, "player", { attack_damage = 4, invuln_time = 0 })
local near = fighter(w, 112, "enemy", { max_health = 20, invuln_time = 0 })
local left = fighter(w, 78, "enemy", { max_health = 20, invuln_time = 0 })
local out = fighter(w, 150, "enemy", { max_health = 20, invuln_time = 0 })
local blasts = 0
ars.on_blast = function() blasts = blasts + 1 end
local mine = ars:equip(hero, { kind = "explosive", fuse = 10 / 60, radius = 20, falloff = 0.5, knockback = 100,
  lift = 0.5, ox = 0, cooldown = 0 })
mine:trigger()
steps(ars, 10)
T.check(blasts == 0 and ars:count() == 1, "the bomb waits for its fuse")
steps(ars, 1)
T.check(blasts == 1 and ars:count() == 0, "and blows after 10 steps")
-- centre (105, 45); near's box starts at 112: 7 px away; left's ends at 88: 17 px; out: 45 px
T.check(near.health == 20 - 3, "near: 4 * (1 - 0.5 * 7 / 20) = 3.3 -> 3 (" .. near.health .. ")")
T.check(left.health == 20 - 2, "farther: 4 * (1 - 0.5 * 17 / 20) = 2.3 -> 2 (" .. left.health .. ")")
T.check(out.health == 20, "outside the radius: untouched")
T.check(hero.health == hero.stats:get("max_health"), "self = false: its owner is safe")
T.check(near.body.vx > 0 and left.body.vx < 0, "knocked away from the centre, both ways")
T.check(near.body.vy < 0, "and lifted")
local b = ars.blasts[1]
T.check(b.alive and b.hits == 2 and b.radius == 20, "a blast is kept to draw")
steps(ars, 12)
T.check(not b.alive, "for blast_time")
local self_bomb = ars:equip(hero, { kind = "explosive", fuse = 0, radius = 8, damage = 1, self = true, cooldown = 0 })
self_bomb:trigger()
steps(ars, 1)
T.check(hero.health == hero.stats:get("max_health") - 1, "self = true: it hurts its owner, fuse 0 blows at once")
-- thrown: it flies, falls, bounces on the floor (row 10: y 72)
w = C.world.new()
ars = A.new(w, { grid = grid })
hero = fighter(w, 20, "player")
local grenade = ars:equip(hero, { kind = "explosive", fuse = 3, radius = 10, damage = 1,
  throw = { speed = 120, angle = 60, gravity = 600, bounce = 0.5 } })
grenade:trigger()
steps(ars, 1)
p = ars.projectiles[1]
local top, bounced, prev = p.y, false, p.vy
for _ = 1, 120 do
  steps(ars, 1)
  if p.y < top then top = p.y end
  if prev > 0 and p.vy < 0 then bounced = true end
  prev = p.vy
end
T.check(top < 40 and bounced and p.y + p.h <= 72 and p.alive, "a thrown bomb rises, falls and bounces on the floor")
-- contact: blows on touching an enemy
foe = fighter(w, 60, "enemy", { max_health = 5, invuln_time = 0 })
local sticky = ars:equip(hero, { kind = "explosive", fuse = 3, radius = 10, damage = 2,
  throw = { speed = 150, angle = 0, gravity = 0, contact = true } })
sticky:trigger()
local n = 0
while foe.health == 5 and n < 60 do steps(ars, 1); n = n + 1 end
T.check(foe.health == 3 and n < 20, "contact: it blows on the enemy (" .. n .. " steps)")

---------------------------------------------------------------------------
-- Determinism and allocation
---------------------------------------------------------------------------
local function run()
  local world = C.world.new()
  local a = A.new(world, { grid = grid })
  local h = fighter(world, 20, "player")
  local e = fighter(world, 90, "enemy", { max_health = 1000, invuln_time = 0 })
  local list_ = {
    a:equip(h, { kind = "melee", cooldown = 0.2, active = 0.1, boxes = { { ox = 2, oy = -5, w = 10, h = 10 } } }),
    a:equip(h, { kind = "ranged", cooldown = 0.1, count = 3, spread = 30, speed = 150, gravity = 100 }),
    a:equip(h, { kind = "explosive", cooldown = 0.4, fuse = 0.3, radius = 30, throw = { speed = 140, angle = 40 } }),
  }
  local function rounds(k)
    for i = 1, k do
      list_[i % 3 + 1]:trigger()
      h.body.facing = (i % 50 < 25) and 1 or -1
      a:step(dt)
      world:step(dt)
    end
  end
  return a, e, rounds
end
local a1, e1, r1 = run()
local a2, e2, r2 = run()
r1(300); r2(300)
T.check(e1.health == e2.health and a1:count() == a2:count() and a1.blast_count == a2.blast_count
  and a1.blast_count > 0, "the same inputs, the same results")
collectgarbage(); collectgarbage("stop")
local before = collectgarbage("count")
r1(300)
local grown = collectgarbage("count") - before
collectgarbage("restart")
T.check(grown == 0, "warm: triggers and steps allocate nothing (" .. grown .. " KB)")

local px, py = A.position({ x = 10.6, y = 3.2, px = 9.6, py = 3.2 }, 0.5)
T.check(px == 10 and py == 3, "position: between steps, on the pixel grid")
T.no_new_globals(globals)
