-- The slime's attacks in this example, as combat.attacks configs. These are EXAMPLE values to
-- show the three kinds working; a game writes its own (see engine/modules/combat/README.md,
-- "Attacks as data"). Offsets are from the body's centre when it faces right; times in seconds.
-- `power` multiplies the slime's damage stat (rooms_stats.lua), so upgrades to it reach every
-- attack.
return {
  {
    name = "melee", kind = "melee",
    cooldown = 0.35, windup = 2 / 60, active = 0.15,
    power = 1, knockback = 150, ky = -0.4, hitstop = 2 / 60,
    -- an arc in front of the slime: over, in front, under
    boxes = {
      { ox = 2, oy = -16, w = 12, h = 10 },
      { ox = 7, oy = -7, w = 14, h = 14 },
      { ox = 2, oy = 6, w = 12, h = 10 },
    },
  },
  {
    name = "ranged", kind = "ranged",
    cooldown = 0.28, power = 1, knockback = 70,
    speed = 220, life = 0.9, w = 4, h = 3, ox = 10, oy = -2,
  },
  {
    name = "explosive", kind = "explosive",
    cooldown = 0.9, power = 2, radius = 28, falloff = 0.5, knockback = 220, lift = 0.6,
    fuse = 0.8, blast_time = 0.2, w = 5, h = 5, ox = 8, oy = 0,
    throw = { speed = 160, angle = 20, gravity = 520, bounce = 0.35, friction = 0.7, contact = true },
  },
}
