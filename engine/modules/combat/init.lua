-- engine.modules.combat: hitboxes and hurtboxes, a damage pipeline that reads stats and emits
-- modifier events, invulnerability frames, knockback, hitstop, and a small state machine with
-- enemy behaviours. A genre module: nothing in engine/ requires it, it needs no other module
-- (no bump, no platformer) and it knows nothing about a game.
-- Reference: engine/modules/combat/README.md.
--
--   local combat = require("engine.modules.combat")
--   local world = combat.world.new()
--   local hero = world:fighter({ body = body, team = "player", mods = set })
--   hero:hurtbox({ ox = 0, oy = 0, w = 10, h = 14 })
--   local slash = hero:hitbox({ ox = 10, oy = 2, w = 12, h = 8, knockback = 150, hitstop = 0.05 })
--   slash:activate(0.1)                            -- 6 steps at 60 Hz
--   world:step(dt)                                 -- once per fixed step, after the bodies moved
--
--   local arsenal = combat.attacks.new(world, { grid = grid })   -- attacks as data (attacks.lua)
--   local shot = arsenal:equip(hero, { kind = "ranged", speed = 220, damage = 1 })
local prefix = (...):gsub("%.init$", "") .. "."

return {
  stats = require(prefix .. "stats"),
  world = require(prefix .. "world"),
  fsm = require(prefix .. "fsm"),
  behaviours = require(prefix .. "behaviours"),
  brains = require(prefix .. "brains"),
  attacks = require(prefix .. "attacks"),
}
