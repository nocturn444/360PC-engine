-- engine/modules/combat: hitboxes and hurtboxes (facing, teams, once per activation, active
-- time), the damage pipeline with engine.modifiers (stats and events), i-frames, knockback
-- with resistance, hitstop, the order of hits, the state machine and the enemy behaviours, and
-- a static check that the module uses nothing the console lacks.
local T = ...
local F = require("fake_love")
F.install()
local globals = {}
for k in pairs(_G) do globals[k] = true end
local Modifiers = require("engine.modifiers")
local Timestep = require("engine.timestep")
local Rng = require("engine.rng")
local C = require("engine.modules.combat")

local dt = Timestep.new({ rate = 60 }).dt
local function body(x, y, facing)
  return { x = x, y = y or 0, w = 10, h = 10, facing = facing or 1, vx = 0, vy = 0 }
end
-- A fighter with one hurtbox over its body
local function fighter(world, x, team, opts)
  opts = opts or {}
  opts.body, opts.team = opts.body or body(x), team
  local f = world:fighter(opts)
  f.box = f:hurtbox({ w = 10, h = 10 })
  return f
end
local function steps(world, n)
  local landed = 0
  for _ = 1, n or 1 do landed = landed + world:step(dt) end
  return landed
end

---------------------------------------------------------------------------
-- Stats as data
---------------------------------------------------------------------------
T.check(C.stats.defaults.max_health == 10 and C.stats.new({ defense = 2 }).defense == 2
  and C.stats.new().defense == 0, "stats.new: defaults and overrides")
T.check(not pcall(C.stats.new, { strength = 1 }), "an unknown stat is an error")
T.check(C.stats.resolve(C.stats.source(C.stats.new({ attack_damage = 4 }))).attack_damage == 4, "source and resolve")

---------------------------------------------------------------------------
-- Boxes: offsets that follow the facing, overlap, teams
---------------------------------------------------------------------------
local w = C.world.new()
local a = fighter(w, 0, "player", { params = C.stats.new({ attack_damage = 3, invuln_time = 0 }) })
local b = fighter(w, 14, "enemy", { params = C.stats.new({ invuln_time = 0 }) })
local sword = a:hitbox({ ox = 10, oy = 2, w = 8, h = 6 })
local x, y, bw, bh = sword:rect()
T.check(x == 10 and y == 2 and bw == 8 and bh == 6, "facing right: the offset as given")
a.body.facing = -1
x, y = sword:rect()
T.check(x == -8 and y == 2, "facing left: mirrored inside the body's width")
a.body.facing = 1
T.check(a.health == 10 and b.health == 10 and not a.dead, "health starts at max_health")

T.check(steps(w) == 0 and b.health == 10, "an inactive hitbox hits nothing")
sword:activate()
T.check(steps(w) == 1 and b.health == 7, "an active hitbox over a hurtbox: attack_damage taken")
T.check(a.health == 10, "a fighter does not hit itself")
T.check(steps(w, 10) == 0 and b.health == 7, "once per activation, however long it overlaps")
T.check(sword:hasHit(b), "the hit list remembers")
sword:activate()
T.check(not sword:hasHit(b) and steps(w, 3) == 1 and b.health == 4, "activating again clears the hit list")
sword:deactivate()

-- edges touching is not an overlap; facing away misses
b.body.x = 18
sword:activate()
T.check(steps(w) == 0, "touching edges do not overlap")
b.body.x = 14; a.body.facing = -1
T.check(steps(w) == 0, "facing away: the box is on the other side")
a.body.facing = 1
b.box.enabled = false
T.check(steps(w) == 0, "a disabled hurtbox is not hit")
b.box.enabled = true
T.check(steps(w) == 1 and b.health == 1, "and it was not put in the hit list meanwhile")

-- teams
local friend = fighter(w, 12, "player", { params = C.stats.new({ invuln_time = 0 }) })
sword:activate()
T.check(steps(w) == 1 and friend.health == 10 and b.dead and b.health == 0, "same team: not hit; the enemy dies at 0")
T.check(steps(w, 3) == 0, "the dead are not hit")
local ffa = C.world.new({ can_hit = function() return true end })
local p1 = fighter(ffa, 0, "red")
local p2 = fighter(ffa, 12, "red")
p1:hitbox({ ox = 10, w = 8, h = 8, damage = 2 }):activate()
T.check(steps(ffa) == 1 and p2.health == 8 and p1.health == 10, "can_hit decides (friendly fire); never itself; a fixed damage")

-- active time, in fixed steps
w = C.world.new()
a = fighter(w, 0, "player")
local far = fighter(w, 500, "enemy")
sword = a:hitbox({ ox = 10, w = 8, h = 8 })
sword:activate(3 * dt)
local active_steps = 0
for _ = 1, 10 do
  if sword.active then active_steps = active_steps + 1 end
  w:step(dt)
end
T.check(active_steps == 3 and not sword.active, "activate(3 steps) is active for 3 steps: " .. active_steps)
sword:activate(0.5)
steps(w, 29)
T.check(sword.active, "0.5 s: still active after 29 steps")
steps(w, 1)
T.check(not sword.active, "and off after 30 (no drift)")

-- removing
sword:activate()
far.body.x = 12
far.box:remove()
T.check(steps(w) == 0 and #w.hurtboxes == 1 and #far.hurtboxes == 0, "a removed box is gone")
w:remove(a)
steps(w)
T.check(#w.fighters == 1 and #w.hitboxes == 0 and #w.hurtboxes == 0, "a removed fighter takes its boxes")

---------------------------------------------------------------------------
-- I-frames
---------------------------------------------------------------------------
w = C.world.new()
a = fighter(w, 0, "player", { params = C.stats.new({ attack_damage = 1 }) })
b = fighter(w, 12, "enemy", { params = C.stats.new({ invuln_time = 0.5 }) })
sword = a:hitbox({ ox = 10, w = 8, h = 8 })
sword:activate()
steps(w)
T.check(b.health == 9 and b:invulnerable(), "a hit starts the i-frames")
local hits_at
for i = 1, 40 do
  sword:activate()                     -- a new activation every step: only i-frames protect
  if w:step(dt) == 1 then hits_at = hits_at or i end
end
T.check(hits_at == 30 and b.health == 8, "invuln_time 0.5 s: the next hit lands 30 steps later (" .. tostring(hits_at) .. ")")
-- a hit ignored by i-frames is not in the hit list: a long activation hits again afterwards
w = C.world.new()
a = fighter(w, 0, "hazard")
b = fighter(w, 5, "player", { params = C.stats.new({ invuln_time = 0.25 }) })
a:hitbox({ w = 10, h = 10, damage = 1 }):activate()
T.check(steps(w, 14) == 1, "an always active hitbox: one hit while the i-frames last")
a.hitboxes[1]:activate()
T.check(steps(w, 1) == 0 and steps(w, 1) == 1 and b.health == 8, "and the next one right when they end")

---------------------------------------------------------------------------
-- Knockback and resistance
---------------------------------------------------------------------------
w = C.world.new()
a = fighter(w, 0, "player")
b = fighter(w, 12, "enemy", { params = C.stats.new({ invuln_time = 0 }) })
local heavy = fighter(w, 12, "enemy", { params = C.stats.new({ invuln_time = 0, knockback_resist = 0.75 }) })
local rock = fighter(w, 12, "enemy", { params = C.stats.new({ invuln_time = 0, knockback_resist = 1 }) })
rock.body.vx = 5
local push = a:hitbox({ ox = 10, w = 8, h = 8, knockback = 200, kx = 1, ky = -0.5 })
local seen = {}
w.on_hit = function(hit) seen[#seen + 1] = { hit.target, hit.knock_x, hit.knock_y } end
push:activate()
T.check(steps(w) == 3, "one hitbox, three targets")
T.check(b.body.vx == 200 and b.body.vy == -100, "knockback: direction * force into the body's velocity")
T.check(heavy.body.vx == 50 and heavy.body.vy == -25, "scaled by 1 - knockback_resist")
T.check(rock.body.vx == 5 and rock.body.vy == 0, "full resistance: not pushed")
T.check(seen[1][1] == b and seen[1][2] == 200 and seen[1][3] == -100 and seen[3][2] == 0, "the hit record has the knockback")
-- mirrored by the attacker's facing; "away" by the positions
a.body.facing = -1
b.body.x = -12
push:activate()
steps(w)
T.check(b.body.vx == -200 and b.body.vy == -100, "facing left: kx mirrored")
local bomb = a:hitbox({ ox = -20, w = 50, h = 10, knockback = 100, away = true })
b.body.x, heavy.body.x, rock.body.x = -14, 14, 500
bomb:activate()
steps(w)
T.check(b.body.vx == -100 and heavy.body.vx == 25, "away: each one pushed from the attacker's centre")
-- a body without velocities: only the record
local still = w:fighter({ body = { x = 12, y = 0 }, team = "enemy" })
still:hurtbox({ w = 10, h = 10 })
a.body.facing = 1
heavy.body.x = 500
push:activate()
seen = {}
steps(w)
T.check(still.body.vx == nil and #seen == 1 and seen[1][2] == 200, "no vx in the body: the game reads hit.knock_x")

---------------------------------------------------------------------------
-- Hitstop
---------------------------------------------------------------------------
w = C.world.new()
a = fighter(w, 0, "player")
b = fighter(w, 12, "enemy", { params = C.stats.new({ invuln_time = 0.5 }) })
local other = fighter(w, 300, "enemy")
sword = a:hitbox({ ox = 10, w = 8, h = 8, hitstop = 3 * dt })
T.check(not a:frozen() and not w:frozen(), "nothing frozen at first")
sword:activate(5 * dt)
steps(w)
T.check(a:frozen() and b:frozen() and not other:frozen() and not w:frozen(), "a hit freezes both fighters, nobody else")
local frozen_steps, invuln_before, time_before = 0, b.invuln, sword.time
while a:frozen() do
  frozen_steps = frozen_steps + 1
  w:step(dt)
end
T.check(frozen_steps == 3, "hitstop of 3 steps: the game skips 3 updates (" .. frozen_steps .. ")")
T.check(b.invuln == invuln_before and sword.time == time_before, "the freeze does not eat i-frames or active time")
steps(w)
T.check(b.invuln < invuln_before and sword.time < time_before, "they run again afterwards")
-- global
w = C.world.new({ default_hitstop = 2 * dt })
a = fighter(w, 0, "player")
b = fighter(w, 12, "enemy", { params = C.stats.new({ invuln_time = 0 }) })
other = fighter(w, 300, "enemy")
sword = a:hitbox({ ox = 10, w = 8, h = 8, global_hitstop = 4 * dt })
sword:activate()
steps(w)
T.check(w:frozen() and other:frozen() and a.hitstop == 2 * dt, "global hitstop freezes everyone; default_hitstop for the two")
frozen_steps = 0
while w:frozen() do
  sword:activate()                       -- nothing is searched while the world is frozen
  frozen_steps = frozen_steps + 1
  T.check(w:step(dt) == 0, "no hits during the global freeze")
end
T.check(frozen_steps == 4 and not a:frozen() and b.health == 9, "4 steps, and the module never stops stepping")
w:stop(2 * dt); other:stop(5 * dt)
T.check(w.hitstop == 2 * dt and other.hitstop == 5 * dt, "stop() by hand")
w:stop(dt)
T.check(w.hitstop == 2 * dt, "stop() never shortens a freeze")

---------------------------------------------------------------------------
-- Modifiers: stats and events
---------------------------------------------------------------------------
local mods = Modifiers.new()
local log = {}
mods:defineAll({
  { id = "sharp", stats = { { "attack_damage", "add", 2 } } },
  { id = "armor", stats = { { "defense", "add", 1 } } },
  { id = "anchor", stats = { { "knockback_resist", "set", 0.5 } } },
  { id = "crit", events = { on_hit = function(_, hit, m)
      m.state.n = (m.state.n or 0) + 1
      if m.state.n % 2 == 0 then return hit.amount * 2 end       -- every second hit
    end } },
  { id = "vampire", events = { on_hit = function(owner, hit) owner.fighter:heal(1) end,
      on_kill = function(owner, hit) log[#log + 1] = "kill" end } },
  { id = "shield", events = { on_damaged = function(_, hit, m)
      if not m.state.used then m.state.used = true; hit.cancel = true end
    end } },
  { id = "thorns", events = { on_damaged = function(owner, hit)
      if hit.attacker then owner.fighter.world:strike(owner.fighter, hit.attacker, { damage = 1 }) end
    end } },
  { id = "soft", events = { on_damaged = function(_, hit) return hit.amount * 0.5 end } },
})
w = C.world.new()
local hero, foe = {}, {}
local hset = mods:attach(hero, C.stats.new({ attack_damage = 2, invuln_time = 0 }))
local fset = mods:attach(foe, C.stats.new({ max_health = 20, invuln_time = 0 }))
hero.fighter = fighter(w, 0, "player", { mods = hset, owner = hero })
foe.fighter = fighter(w, 12, "enemy", { mods = fset, owner = foe })
a, b = hero.fighter, foe.fighter
T.check(b.health == 20 and a.stats == hset and a.owner == hero, "the set is the stat source; max_health from it")
sword = a:hitbox({ ox = 10, w = 8, h = 8, power = 2, knockback = 100 })
local function swing()
  local before = b.health
  sword:activate(); steps(w)
  return before - b.health
end
T.check(swing() == 4, "attack_damage * power")
hset:add("sharp")
T.check(swing() == 8, "a modifier on attack_damage changes the damage")
fset:add("armor")
T.check(swing() == 7, "a modifier on defense")
hset:remove("sharp"); fset:remove("armor")
fset:add("anchor")
swing()
T.check(b.body.vx == 50, "a modifier on knockback_resist")
fset:remove("anchor")
-- events
b:revive()
hset:add("crit")
T.check(swing() == 4 and swing() == 8 and swing() == 4, "on_hit reacts and changes the amount (every second hit doubled)")
hset:remove("crit")
a.health = 5
hset:add("vampire")
swing()
T.check(a.health == 6, "on_hit can act on its owner")
b:revive()
fset:add("soft")
T.check(swing() == 2, "on_damaged changes what the target takes")
fset:remove("soft"); fset:add("shield")
T.check(swing() == 0 and b.body.vx == 100, "on_damaged can cancel a hit")
b.body.vx = 0
sword:activate()                        -- the cancelled hit is in the hit list: this is a new swing
T.check(steps(w) == 1 and b.body.vx == 100, "once")
fset:remove("shield"); fset:add("thorns")
a.health = 5
T.check(swing() == 4 and a.health == 5, "a hit from a handler: the pipeline is re-entrant (vampire +1, thorns -1)")
hset:remove("vampire")
T.check(swing() == 4 and a.health == 4, "thorns alone")
hset:add("vampire")
fset:remove("thorns")
-- death
local died
b.on_death = function(f, hit) died = hit.attacker end
local hurt = 0
b.on_hurt = function() hurt = hurt + 1 end
b.health = 3
foe.fighter:hitbox({ w = 10, h = 10 }):activate()
T.check(swing() == 3 and b.dead and died == a and hurt == 1 and log[1] == "kill", "death: on_death, on_hurt, and the attacker's on_kill")
T.check(not b.hitboxes[1].active and b:heal(5) == 0, "the dead stop hitting and do not heal")
b:revive(4)
T.check(not b.dead and b.health == 4 and b:heal(100) == 20, "revive; heal stops at max_health")

---------------------------------------------------------------------------
-- The order of hits: by hitbox, then by hurtbox, in creation order; wherever they stand
---------------------------------------------------------------------------
local function melee(xs, seed)
  local world = C.world.new()
  local order, list = {}, {}
  world.on_hit = function(hit) order[#order + 1] = hit.hitbox.id .. ">" .. hit.hurtbox.id end
  local rng = seed and Rng.new(seed)
  for i = 1, #xs do
    local f = fighter(world, xs[i], i % 2 == 0 and "even" or "odd", { params = C.stats.new({ invuln_time = 0 }) })
    f.hit = f:hitbox({ ox = -30, oy = 0, w = 70, h = 10 })
    list[i] = f
  end
  for round = 1, 3 do
    for i = 1, #list do
      list[i].hit:activate()
      if rng then list[i].body.x = rng:int(0, 60) end
    end
    world:step(dt)
  end
  return table.concat(order, " ")
end
local first = melee({ 0, 10, 20, 30 })
T.check(first:sub(1, 23) == "2>3 2>7 4>1 4>5 6>3 6>7", "hitbox by hitbox, hurtboxes by id: " .. first)
T.check(melee({ 30, 20, 10, 0 }) == first and melee({ 12, 5, 28, 3 }) == first, "the positions do not change the order")
local r1, r2 = melee({ 0, 0, 0, 0, 0, 0, 0, 0 }, 42), melee({ 0, 0, 0, 0, 0, 0, 0, 0 }, 42)
T.check(r1 == r2 and #r1 > 100, "the same seed gives the same hits in the same order")
-- two hitboxes on one target in the same step: the older one lands, i-frames stop the other
w = C.world.new()
b = fighter(w, 0, "enemy")
local late = fighter(w, 5, "player", { params = C.stats.new({ attack_damage = 5 }) })
local early = fighter(w, -5, "player", { params = C.stats.new({ attack_damage = 2 }) })
local h_early = early:hitbox({ w = 20, h = 10 })
local h_late = late:hitbox({ ox = -10, w = 20, h = 10 })
h_late:activate(); h_early:activate()
T.check(steps(w) == 1 and b.health == 8, "creation order, not activation order or position, decides who lands")
-- against brute force, on random boxes
do
  local world = C.world.new({ can_hit = function() return true end })
  local rng = Rng.new("sweep")
  local list, hit_n = {}, 0
  for i = 1, 40 do
    local f = world:fighter({ body = { x = 0, y = 0, w = 8, h = 8, facing = 1 }, team = i,
      params = C.stats.new({ invuln_time = 0, max_health = 1e9 }) })
    f.box = f:hurtbox({ w = rng:int(2, 30), h = rng:int(2, 30) })
    f.hit = f:hitbox({ ox = rng:int(-10, 10), oy = rng:int(-10, 10), w = rng:int(2, 30), h = rng:int(2, 30) })
    list[i] = f
  end
  world.on_hit = function() hit_n = hit_n + 1 end
  local same = true
  for round = 1, 30 do
    local expected = 0
    for i = 1, #list do
      local f = list[i]
      f.body.x, f.body.y, f.body.facing = rng:int(0, 200), rng:int(0, 120), rng:chance(0.5) and 1 or -1
      f.hit:activate()
    end
    for i = 1, #list do
      local hx, hy, hw, hh = list[i].hit:rect()
      for j = 1, #list do
        local ux, uy, uw, uh = list[j].box:rect()
        if i ~= j and hx < ux + uw and ux < hx + hw and hy < uy + uh and uy < hy + hh then expected = expected + 1 end
      end
    end
    if world:step(dt) ~= expected then same = false end
  end
  T.check(same and hit_n > 300, "the sweep finds exactly the overlaps a brute force finds (" .. hit_n .. " hits)")

  -- and a step creates no tables (once its lists have grown to the size they need)
  world.on_hit = nil
  local function rounds()
    for i = 1, #list do list[i].body.x = i * 5 end
    for round = 1, 100 do
      for i = 1, #list do
        local f = list[i]
        f.body.x = (f.body.x + i * 7 + round) % 200
        f.hit:activate()
      end
      world:step(dt)
    end
  end
  rounds()
  collectgarbage(); collectgarbage("stop")
  local before = collectgarbage("count")
  rounds()
  local grown = collectgarbage("count") - before
  collectgarbage("restart")
  T.check(grown == 0, "activate and step allocate nothing (" .. grown .. " KB)")
end

---------------------------------------------------------------------------
-- The state machine
---------------------------------------------------------------------------
local trace = {}
local def = {
  initial = "idle",
  states = {
    idle = {
      enter = function(m, o, prev) trace[#trace + 1] = "enter idle from " .. tostring(prev) end,
      exit = function(m, o, to) trace[#trace + 1] = "exit idle to " .. to end,
      transitions = { { to = "alert", when = function(m, o) return o.sees end },
        { to = "nap", after = 0.5 } },
    },
    nap = { transitions = { { to = "idle", after = 0.25, when = function(m, o) return o.noise end } } },
    alert = {
      enter = function(m, o) m.phase = "look"; o.count = 0 end,
      update = function(m, o, step_dt)
        o.count = o.count + 1
        if o.count == 3 then return "idle" end
      end,
    },
  },
}
local owner = {}
local m = C.fsm.new(def, owner)
T.check(m.state == "idle" and m:is("idle") and trace[1] == "enter idle from nil" and m.time == 0, "starts in the initial state")
for _ = 1, 29 do m:update(dt) end
T.check(m.state == "idle", "an `after` transition waits")
T.check(m:update(dt) == "nap" and m.state == "nap" and m.previous == "idle" and trace[2] == "exit idle to nap", "0.5 s is 30 steps; exit is told where it goes")
T.check(m.time == 0, "the time starts again in the new state")
owner.noise = true
for _ = 1, 14 do m:update(dt) end
T.check(m.state == "nap", "after and when: both are needed")
m:update(dt)
T.check(m.state == "idle" and trace[3] == "enter idle from nap", "then it goes")
owner.sees = true
m:update(dt)
T.check(m.state == "alert" and m.phase == "look", "transitions are tried in order: the first that holds wins")
m:update(dt); m:update(dt)
T.check(m.state == "alert" and m:update(dt) == "idle" and m.phase == nil, "update returns the next state; phase is cleared")
owner.sees = false
m:set("nap")
T.check(m.state == "nap" and m.changes == 6, "set by hand")
T.check(not pcall(C.fsm.new, { initial = "x", states = {} }, {}), "an unknown initial state is an error")
T.check(not pcall(C.fsm.new, { initial = "a", states = { a = { transitions = { { to = "b", after = 1 } } } } }, {}),
  "a transition to an unknown state is an error")
T.check(not pcall(m.set, m, "nowhere"), "set to an unknown state is an error")
-- two machines share one definition
local m2 = C.fsm.new(def, { sees = true })
m2:update(dt)
T.check(m2.state == "alert" and m.state == "nap", "machines of one definition are independent")

---------------------------------------------------------------------------
-- Behaviours: patrol, chase, attack
---------------------------------------------------------------------------
local B = C.behaviours
w = C.world.new()
local player = fighter(w, 300, "player", { params = C.stats.new({ invuln_time = 0 }) })
local function enemy(x, rng)
  local e = { body = body(x), patrol_points = { { x = 20 }, { x = 60 } }, rng = rng }
  e.fighter = w:fighter({ body = e.body, team = "enemy", params = C.stats.new({ attack_damage = 2 }) })
  e.fighter:hurtbox({ w = 10, h = 10 })
  e.hitboxes = { bite = e.fighter:hitbox({ ox = 10, w = 8, h = 10, knockback = 90 }) }
  return e
end
local brain = {
  initial = "patrol",
  states = {
    patrol = B.patrol({ speed = 60, pause = { 0.1, 0.3 }, blocked = function(agent) return agent.wall end }),
    chase = B.chase({ speed = 120, stop = 14 }),
    attack = B.attack({ hitbox = "bite", windup = 6 * dt, active = 3 * dt, recovery = 9 * dt, next = "chase" }),
  },
}
brain.states.patrol.transitions = { { to = "chase", when = B.target_within(50) } }
brain.states.chase.transitions = {
  { to = "attack", when = B.target_within(14) },
  { to = "patrol", when = B.target_beyond(80) },
}
-- One step of the game: think, move, fight
local function tick(e, machine)
  if not e.fighter:frozen() then
    machine:update(dt)
    B.move(e, dt)
  end
  return w:step(dt)
end
local function run(seed, n)
  local e = enemy(15 - 5, Rng.new(seed))          -- centre at x = 15
  local machine = C.fsm.new(brain, e)
  local out = {}
  for i = 1, n do
    tick(e, machine)
    out[i] = e.body.x
  end
  w:remove(e.fighter)
  return out, e, machine
end

-- patrol
local xs, e = run(7, 400)
local lo, hi, turns, waits = math.huge, -math.huge, 0, 0
for i = 100, #xs do                  -- once it is between them
  if xs[i] < lo then lo = xs[i] end
  if xs[i] > hi then hi = xs[i] end
  if xs[i] == xs[i - 1] then waits = waits + 1 end
end
T.check(lo >= 14 and lo <= 16 and hi >= 54 and hi <= 56, "patrol walks between its points (centre 20..60): " .. lo .. ".." .. hi)
T.check(waits > 20, "and waits at each one")
T.check(e.body.facing == 1 or e.body.facing == -1, "facing follows the way it walks")
local again = run(7, 400)
local other_seed = run(8, 400)
local same, differs = true, false
for i = 1, 400 do
  if xs[i] ~= again[i] then same = false end
  if xs[i] ~= other_seed[i] then differs = true end
end
T.check(same and differs, "the pauses come from the rng stream: same seed, same walk; another seed, another walk")
-- blocked turns it round, once
do
  local agent = enemy(35)
  agent.patrol_points = { { x = 0 }, { x = 200 } }
  local machine = C.fsm.new({ initial = "patrol", states = { patrol = B.patrol({ speed = 60,
    blocked = function(ag) return ag.wall end }) } }, agent)
  machine:update(dt)
  T.check(agent.move_x == -1 and agent.body.facing == -1 and agent.move_speed == 60, "patrol heads for its first point")
  agent.wall = true
  machine:update(dt); machine:update(dt)
  T.check(agent.move_x == 1 and agent.patrol_i == 2, "blocked: it goes for the next point")
  machine:update(dt)
  T.check(agent.move_x == 1, "and does not flip again while the block lasts")
  agent.wall = false
  machine:update(dt)
  agent.wall = true
  machine:update(dt); machine:update(dt)
  T.check(agent.move_x == -1, "a new block turns it again")
  -- the input adapter for a platformer controller
  local input = B.input(agent)
  T.check(input:axis("move_x") == -1 and not input:down("jump") and not input:pressed("jump"), "input(): the wish as an axis")
  agent.jump = true
  T.check(input:pressed("jump") and not input:down("down"), "and a jump")
  w:remove(agent.fighter)
end

-- chase, attack phases, back to patrol
e = enemy(10, Rng.new(1))
local machine = C.fsm.new(brain, e)
e.target = player.body
player.body.x = 60
tick(e, machine)
T.check(machine.state == "chase", "the target within range: chase")
tick(e, machine)
T.check(e.move_x == 1 and e.move_speed == 120, "chase heads for the target")
player.body.x = -40
tick(e, machine)
T.check(e.move_x == -1 and e.body.facing == -1, "wherever it goes")
player.body.x = 60
local guard = 0
while machine.state == "chase" and guard < 200 do tick(e, machine); guard = guard + 1 end
T.check(machine.state == "attack" and machine.phase == "windup" and e.move_x == 0, "close enough: attack, standing still")
T.check(B.distance(e) <= 14, "at the stop distance")
local bite = e.hitboxes.bite
local phases, hits, health = {}, 0, player.health
for i = 1, 18 do
  hits = hits + tick(e, machine)
  phases[i] = (machine.state == "attack" and machine.phase or machine.state) .. (bite.active and "+" or "")
end
T.check(table.concat(phases, " ", 1, 5) == "windup windup windup windup windup", "windup: 6 steps with the hitbox off (1 on entering, 5 here)")
T.check(phases[6] == "active+" and phases[7] == "active+" and phases[8] == "active+" and phases[9] == "recovery",
  "active: 3 steps with the hitbox on, then recovery: " .. table.concat(phases, " ", 6, 9))
T.check(phases[17] == "recovery" and phases[18] == "chase", "recovery: 9 steps, then the next state")
T.check(hits == 1 and player.health == health - 2 and player.body.vx == 90, "the attack hit once, with the enemy's stats and knockback")
-- interrupted in the active phase: the hitbox goes off
player.body.vx = 0
guard = 0
while not bite.active and guard < 100 do tick(e, machine); guard = guard + 1 end
T.check(machine.state == "attack" and bite.active, "attacking again")
machine:set("patrol")
T.check(not bite.active, "leaving the attack turns the hitbox off")
-- the target gone or far: back to patrol
machine:set("chase")
e.target = nil
tick(e, machine)
T.check(machine.state == "patrol" and B.distance(e) == math.huge, "no target counts as beyond the range")
-- hitstop: the game skips the frozen enemy, the phases wait
e.target = player.body
e.hitboxes.bite.hitstop = 4 * dt
guard = 0
while w.hit_count == 0 and guard < 300 do tick(e, machine); guard = guard + 1 end
T.check(e.fighter:frozen() and machine.phase == "active", "the bite landed with hitstop")
local time = machine.time
tick(e, machine); tick(e, machine)
T.check(machine.time == time and bite.active, "frozen: the machine is not updated and the attack waits")
-- xy
local fly = { x = 0, y = 0, w = 0, h = 0, target = { x = 30, y = 40 } }
local fm = C.fsm.new({ initial = "chase", states = { chase = B.chase({ speed = 50, axis = "xy", stop = 5 }) } }, fly)
fm:update(dt)
T.near(fly.move_x, 0.6, "xy: a straight line to the target (x)")
T.near(fly.move_y, 0.8, "(y)")
T.check(B.distance(fly, "xy") == 50 and B.distance(fly) == 30, "distance along the line, or along x")
for _ = 1, 60 do fm:update(dt); B.move(fly, dt) end
T.check(fly.move_x == 0 and fly.move_y == 0 and B.distance(fly, "xy") <= 5, "it stops at the stop distance; the agent can be its own body")

---------------------------------------------------------------------------
-- Static checks: nothing the console lacks, nothing random, no clock, no other module
---------------------------------------------------------------------------
local function read(path)
  local f = assert(io.open(path, "rb"))
  local src = f:read("*a"); f:close()
  return src
end
for _, name in ipairs({ "init", "stats", "world", "fsm", "behaviours" }) do
  local path = "engine/modules/combat/" .. name .. ".lua"
  local src = read(path):gsub("%-%-[^\n]*", "")
  T.check(not src:find("%f[%w]goto%f[%W]") and not src:find("require%(?%s*[\"']ffi[\"']")
    and not src:find("%f[%w_]jit%."), path .. ": no goto, no FFI, no jit")
  T.check(not src:find("%f[%w_]love%f[%W]"), path .. ": calls nothing in love")
  T.check(not src:find("math%.random") and not src:find("os%.time") and not src:find("os%.clock"),
    path .. ": nothing random, no clock")
  T.check(not src:find("platformer") and not src:find("bump") and not src:find("engine%.modifiers")
    and not src:find("engine%.rng"), path .. ": needs no other module, and requires neither modifiers nor rng")
  if name ~= "init" then
    T.check(not src:find("[^%w_]pairs%(") or name == "stats" or name == "fsm", path .. ": no pairs() in the step")
  end
end
for _, name in ipairs({ "init", "state", "timestep", "input", "camera", "pixel", "layers", "anim", "entity",
    "modifiers", "rng", "save", "ui" }) do
  local src = read("engine/" .. name .. ".lua"):gsub("%-%-[^\n]*", "")
  T.check(not src:find("combat"), "engine/" .. name .. ".lua does not need the combat module")
end
for _, name in ipairs({ "init", "grid", "collision", "params", "controller" }) do
  local src = read("engine/modules/platformer/" .. name .. ".lua"):gsub("%-%-[^\n]*", "")
  T.check(not src:find("combat"), "platformer/" .. name .. ".lua does not need the combat module")
end
T.no_new_globals(globals)
