-- The final bosses of the prototype: the boss of the last floor is one of these, picked when
-- that floor starts with engine.modules.progress.pick (the run so far and the profile decide;
-- the stream "final_boss" breaks ties). Each one is fought through combat.boss: two phases of
-- combat.brains data that reuse the enemy behaviours (chase, charge, shoot, hop, fly,
-- keep_away) and "rotate" to pick the next attack. ALL PLACEHOLDERS for the owner to replace:
-- names, conditions, numbers, patterns, and which ending each one leads to (rooms_endings.lua,
-- `final_boss` field). See docs/UNLOCKS.md, step 4.
--
-- Fields of an entry:
--   id, name           the boss (id for the bestiary and the kills; name for the HUD bar)
--   when, priority, weight   how it is picked (progress.pick: the highest priority whose `when`
--                      holds; a weighted draw among equals)
--   health, damage     absolute stats (the biome boss's are not used)
--   color              placeholder body colour
--   move, w, h, contact, hitboxes, attacks, look   the body, like an enemy type
--                      (rooms_enemy_types.lua)
--   phases             combat.boss phases: { at, brain, transition }
local M = {}

-- Predicates for conditions of kind "test" (progress.pick opts.tests)
M.tests = {
  won_before = function(ctx) return ctx.profile ~= nil and (ctx.profile.wins or 0) >= 1 end,
}

local PHASE_CHANGE = { time = 1.2, invulnerable = true }

M.list = {
  {
    id = "final_mutant", name = "THE MUTANT", priority = 0,
    health = 24, damage = 2, color = { 1.00, 0.25, 0.25 },
    move = "walk", w = 16, h = 12, contact = true,
    attacks = {
      ring = { name = "ring", kind = "ranged", cooldown = 0.2, power = 1, knockback = 60,
        count = 8, spread = 315, speed = 90, life = 1.8, w = 3, h = 3, ox = 0, oy = -2 },
    },
    look = { shape = "walker" },
    phases = {
      { at = 1, brain = { initial = "approach", states = {
          approach = { "chase", speed = 40, stop = 10 },
          pick = { "rotate", options = { { to = "dash" }, { to = "ring" } }, no_repeat = true, pause = 0.4 },
          dash = { "charge", speed = 150, time = 0.6, windup = 0.6, recovery = 0.5, stun = 1.0, next = "approach" },
          ring = { "shoot", attack = "ring", volleys = 1, windup = 0.6, recovery = 0.6, next = "approach" },
        }, transitions = { approach = { { to = "pick", after = 1.4 } } } } },
      { at = 0.5, transition = PHASE_CHANGE, brain = { initial = "approach", states = {
          approach = { "chase", speed = 55, stop = 10 },
          pick = { "rotate", options = { { to = "dash" }, { to = "spiral", weight = 2 }, { to = "slam" } },
            no_repeat = true, pause = 0.3 },
          dash = { "charge", speed = 190, time = 0.6, windup = 0.45, recovery = 0.4, stun = 0.8, next = "approach" },
          spiral = { "shoot", attack = "ring", volleys = 5, interval = 0.25, rotate = 15,
            windup = 0.5, recovery = 0.5, next = "approach" },
          slam = { "hop", wait = 0.3, speed = 80, toward = "target", jump_velocity = 300 },
        }, transitions = {
          approach = { { to = "pick", after = 1.0 } },
          slam = { { to = "approach", after = 1.6 } },
        } } },
    },
  },
  {
    id = "final_ai", name = "THE CARETAKER AI", priority = 1,
    -- the profile has a win and this run holds 3 or more mutations
    when = { "all", { "test", name = "won_before" }, { "count", key = "mutations", at_least = 3 } },
    health = 22, damage = 2, color = { 0.30, 0.85, 0.95 },
    move = "fly", w = 14, h = 10, contact = true,
    attacks = {
      zap = { name = "zap", kind = "ranged", cooldown = 0.2, power = 1, knockback = 60,
        speed = 150, life = 1.8, w = 3, h = 3, ox = 6, oy = 0 },
      ring = { name = "ring", kind = "ranged", cooldown = 0.2, power = 1, knockback = 50,
        count = 10, spread = 324, speed = 80, life = 2.0, w = 3, h = 3, ox = 0, oy = 0 },
    },
    look = { shape = "drone" },
    phases = {
      { at = 1, brain = { initial = "follow", states = {
          follow = { "fly", mode = "follow", speed = 50, keep = 70, band = 12, bob = 6 },
          pick = { "rotate", options = { { to = "volley", weight = 2 }, { to = "swoop" } },
            no_repeat = true, pause = 0.3 },
          volley = { "shoot", attack = "zap", aim = "target", volleys = 3, interval = 0.25,
            windup = 0.5, recovery = 0.4, next = "follow" },
          swoop = { "charge", speed = 170, time = 0.5, windup = 0.5, recovery = 0.5, stun = 0.3,
            axis = "xy", next = "follow" },
        }, transitions = { follow = { { to = "pick", after = 1.2 } } } } },
      { at = 0.5, transition = PHASE_CHANGE, brain = { initial = "follow", states = {
          follow = { "fly", mode = "follow", speed = 65, keep = 60, band = 12, bob = 6 },
          pick = { "rotate", options = { { to = "volley" }, { to = "swoop" }, { to = "ring", weight = 2 } },
            no_repeat = true, pause = 0.25 },
          volley = { "shoot", attack = "zap", aim = "target", volleys = 4, interval = 0.2,
            windup = 0.4, recovery = 0.3, next = "follow" },
          swoop = { "charge", speed = 220, time = 0.5, windup = 0.4, recovery = 0.4, stun = 0.3,
            axis = "xy", next = "follow" },
          ring = { "shoot", attack = "ring", volleys = 3, interval = 0.3, rotate = 18,
            windup = 0.5, recovery = 0.5, next = "follow" },
        }, transitions = { follow = { { to = "pick", after = 0.9 } } } } },
    },
  },
  {
    id = "final_scientist", name = "THE LAST SCIENTIST", priority = 2,
    -- this run never picked up a heart
    when = { "count", key = "hearts", at_most = 0 },
    health = 20, damage = 2, color = { 0.90, 0.90, 0.80 },
    move = "walk", w = 12, h = 14, contact = false,
    attacks = {
      bomb = { name = "bomb", kind = "explosive", cooldown = 0.3, power = 1, radius = 22,
        falloff = 0.5, knockback = 180, lift = 0.6, fuse = 0.9, blast_time = 0.2, w = 5, h = 5,
        ox = 6, oy = -4,
        throw = { speed = 150, angle = 35, gravity = 520, bounce = 0.35, friction = 0.7, contact = true } },
      shot = { name = "shot", kind = "ranged", cooldown = 0.2, power = 1, knockback = 70,
        speed = 170, life = 2.0, w = 3, h = 3, ox = 8, oy = -2 },
    },
    look = { shape = "sniper" },
    phases = {
      { at = 1, brain = { initial = "keep", states = {
          keep = { "keep_away", min = 56, max = 120, speed = 35 },
          pick = { "rotate", options = { { to = "throw" }, { to = "aim" } }, no_repeat = true, pause = 0.4 },
          throw = { "shoot", attack = "bomb", aim = "target", volleys = 1, windup = 0.6,
            recovery = 0.6, next = "keep" },
          aim = { "shoot", attack = "shot", aim = "target", volleys = 2, interval = 0.3,
            windup = 0.5, recovery = 0.5, next = "keep" },
        }, transitions = { keep = { { to = "pick", after = 1.4 } } } } },
      { at = 0.5, transition = PHASE_CHANGE, brain = { initial = "keep", states = {
          keep = { "keep_away", min = 48, max = 110, speed = 45 },
          pick = { "rotate", options = { { to = "throw" }, { to = "aim" }, { to = "dash" }, { to = "barrage" } },
            no_repeat = true, pause = 0.3 },
          throw = { "shoot", attack = "bomb", aim = "target", volleys = 1, windup = 0.5,
            recovery = 0.5, next = "keep" },
          aim = { "shoot", attack = "shot", aim = "target", volleys = 3, interval = 0.25,
            windup = 0.4, recovery = 0.4, next = "keep" },
          dash = { "charge", speed = 160, time = 0.5, windup = 0.5, recovery = 0.5, stun = 0.8, next = "keep" },
          barrage = { "shoot", attack = "bomb", aim = "target", volleys = 3, interval = 0.35,
            rotate = 12, windup = 0.6, recovery = 0.6, next = "keep" },
        }, transitions = { keep = { { to = "pick", after = 1.0 } } } } },
    },
  },
}

M.by_id = {}
for i = 1, #M.list do M.by_id[M.list[i].id] = M.list[i] end

return M
