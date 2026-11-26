-- The enemy types of the rooms example, as data. A type says how its body moves ("walk": a
-- platformer controller with gravity; "fly": no gravity, moved with combat.behaviours.fly_move),
-- its size, its health and damage multipliers over the biome's mob stats, its attacks as
-- combat.attacks configs, its brain as a combat.brains spec and its placeholder look.
-- rooms_enemies.lua builds one brain and one combat.stats per type per room from this table;
-- rooms_play.lua picks a type for each template spot from the biome's weighted pool.
--
-- The numbers are first guesses for the owner to tune (see docs/ENEMY_AI_PLAN.md, step 3).
-- Adding a type: add an entry here, list it in M.order and give it a weight in a biome's
-- mobs.types (rooms_biomes.lua); only a new kind of movement needs a new behaviour.
local M = {}

-- The registry order: the weighted pick walks it, so the same seed gives the same type on PC
-- and on the console (table iteration order is not stable).
M.order = { "walker", "hopper", "charger", "shooter", "sniper", "sprayer", "bat", "drone" }

M.types = {
  walker = {
    move = "walk", w = 12, h = 10,
    health = 1.0, damage = 1.0, speed = 35,
    contact = false,
    hitboxes = { bite = { ox = 10, oy = 2, w = 9, h = 7, knockback = 160, ky = -0.6 } },
    brain = { initial = "patrol", states = {
      patrol = { "patrol", speed = 22, pause = { 0.3, 0.9 } },
      chase = { "chase", speed = 45, stop = 8 },
      attack = { "attack", hitbox = "bite", windup = 0.3, active = 0.12, recovery = 0.4, next = "chase" },
    }, transitions = {
      patrol = { { to = "chase", when = { "target_within", 80, "xy" } } },
      chase = {
        { to = "attack", when = { "target_within", 16, "xy" } },
        { to = "patrol", when = { "target_beyond", 120, "xy" } },
      },
    } },
    look = { shape = "walker" },
  },
  hopper = {
    move = "walk", w = 12, h = 10,
    health = 1.0, damage = 1.0, speed = 40, jump_velocity = 260,
    contact = true,
    -- short hops, and now and then a long leap (a 1.2 s crouch first) onto the slime or onto
    -- another platform
    brain = { initial = "hop", states = {
      hop = { "hop", wait = { 0.8, 1.4 }, speed = 60, toward = "target", jump_velocity = 260 },
      pick = { "rotate", pause = 0.05, options = {
        { to = "leap_target", weight = 1 }, { to = "leap_platform", weight = 1 } } },
      leap_target = { "leap", aim = "target", windup = 1.2, recovery = 0.4, next = "hop" },
      leap_platform = { "leap", aim = "platform", windup = 1.2, recovery = 0.4, next = "hop" },
    }, transitions = {
      hop = { { to = "pick", when = { "all", { "grounded" }, { "target_within", 220, "xy" } },
        after = 3.5 } },
    } },
    look = { shape = "hopper" },
  },
  charger = {
    move = "walk", w = 14, h = 10,
    health = 1.2, damage = 1.2, speed = 30,
    contact = true,
    brain = { initial = "patrol", states = {
      patrol = { "patrol", speed = 22, pause = { 0.3, 0.9 } },
      charge = { "charge", speed = 150, time = 0.7, windup = 0.45, recovery = 0.4,
        stun = 0.9, next = "patrol" },
    }, transitions = {
      patrol = { { to = "charge", when = { "all", { "target_in_sight", 120 },
        { "not", { "target_above", 24 } } } } },
    } },
    look = { shape = "charger" },
  },
  shooter = {
    move = "walk", w = 12, h = 10,
    health = 0.8, damage = 1.0, speed = 35,
    contact = false,
    attacks = { spit = { name = "spit", kind = "ranged", cooldown = 1.2, power = 1,
      knockback = 60, speed = 120, life = 1.6, w = 3, h = 3, ox = 8, oy = -1 } },
    brain = { initial = "keep", states = {
      keep = { "keep_away", min = 48, max = 110, speed = 35 },
      shoot = { "shoot", attack = "spit", aim = "facing", volleys = 1,
        windup = 0.25, recovery = 0.35, next = "keep" },
    }, transitions = {
      keep = { { to = "shoot", when = { "target_in_sight", 140 }, after = 1.2 } },
    } },
    look = { shape = "shooter" },
  },
  sniper = {
    move = "walk", w = 12, h = 10,
    health = 0.8, damage = 1.5, speed = 30,
    contact = false,
    attacks = { snipe = { name = "snipe", kind = "ranged", cooldown = 1.8, power = 1,
      knockback = 90, speed = 180, life = 2.0, w = 3, h = 3, ox = 10, oy = -1 } },
    brain = { initial = "keep", states = {
      keep = { "keep_away", min = 56, max = 130, speed = 30 },
      shoot = { "shoot", attack = "snipe", aim = "target", volleys = 1,
        windup = 0.6, recovery = 0.5, next = "keep" },
    }, transitions = {
      keep = { { to = "shoot", when = { "target_in_sight", 180 }, after = 1.8 } },
    } },
    look = { shape = "sniper" },
  },
  sprayer = {
    move = "walk", w = 14, h = 10,
    health = 1.3, damage = 0.75, speed = 22,
    contact = false,
    attacks = { spray = { name = "spray", kind = "ranged", cooldown = 0.2, power = 1,
      knockback = 50, count = 8, spread = 315, speed = 90, life = 1.8, w = 3, h = 3,
      ox = 8, oy = -1 } },
    brain = { initial = "patrol", states = {
      patrol = { "patrol", speed = 18, pause = { 0.4, 1.0 } },
      spray = { "shoot", attack = "spray", aim = "facing", volleys = 3, interval = 0.25,
        rotate = 22.5, windup = 0.5, recovery = 0.6, next = "patrol" },
    }, transitions = {
      patrol = { { to = "spray", when = { "target_in_sight", 120 }, after = 1.5 } },
    } },
    look = { shape = "sprayer" },
  },
  bat = {
    move = "fly", w = 10, h = 8,
    health = 0.75, damage = 1.0, speed = 45,
    contact = true,
    brain = { initial = "hover", states = {
      hover = { "fly", mode = "hover", speed = 45, radius = 10, period = 1.4 },
      follow = { "fly", mode = "follow", speed = 55, keep = 40, band = 10, bob = 6 },
      tell = { "charge", speed = 170, time = 0.45, windup = 0.35, recovery = 0.4,
        stun = 0.3, axis = "xy", next = "hover" },
    }, transitions = {
      hover = { { to = "follow", when = { "target_within", 120, "xy" } } },
      follow = {
        { to = "tell", when = { "target_within", 48, "xy" }, after = 1.0 },
        { to = "hover", when = { "target_beyond", 160, "xy" } },
      },
    } },
    look = { shape = "bat" },
  },
  drone = {
    move = "fly", w = 10, h = 8,
    health = 0.75, damage = 1.0, speed = 50,
    contact = false,
    attacks = { zap = { name = "zap", kind = "ranged", cooldown = 1.4, power = 1,
      knockback = 60, speed = 150, life = 1.8, w = 3, h = 3, ox = 6, oy = 0 } },
    brain = { initial = "follow", states = {
      follow = { "fly", mode = "follow", speed = 50, keep = 70, band = 10, bob = 6 },
      shoot = { "shoot", attack = "zap", aim = "target", windup = 0.3,
        recovery = 0.4, next = "follow" },
    }, transitions = {
      follow = { { to = "shoot", when = { "target_in_sight", 160 }, after = 1.2 } },
    } },
    look = { shape = "drone" },
  },
}

return M
