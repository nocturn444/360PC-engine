-- The prop types of the rooms example (engine.modules.props): platforms, vines, crates, spikes
-- and statues. EXAMPLE values chosen by an agent (2026-11-22); behaviour of spikes, vines and hanging confirmed by the owner. To
-- add a type, define it here: the play state reads its flags, the level editors read it from
-- props_catalog.lvl (luajit tools/props_catalog.lua examples/rooms rooms_props -o
-- examples/rooms/props_catalog.lvl). Flags the play state understands:
--   hangable    the slime can drape over its edge and hang there (what the soft body already
--               does on a one-way platform); without it the slime slides off the edge
--   climbable   the slime can grab it, climb it (up / down) and swing on it (left / right)
--   hazard      touching it costs hearts (field damage) and knocks the slime back
--   breakable   attacks and hard landings hit it (field health)
--   turret      fires an attack of its own (fields attack, interval, direction); not an enemy:
--               it cannot be hurt and does not keep a room from being cleared
-- The "=" tiles of the hand-made rows behave like a `platform` prop.
-- No love at load: only draw() touches love.graphics.
local props = require("engine.modules.props")

local types = props.registry()

types:define("platform", {
  category = "platform", collision = "one_way", resize = "x", size = { w = 3, h = 1 }, max = { w = 20, h = 1 },
  flags = { hangable = true },
  editor = { label = "Platform", glyph = "=", color = { 0.55, 0.45, 0.30 } },
})

types:define("wide_platform", {
  category = "platform", collision = "one_way", resize = "x", size = { w = 6, h = 1 },
  min = { w = 4, h = 1 }, max = { w = 20, h = 1 },
  flags = {},                                            -- the slime slides off its edges
  editor = { label = "Wide platform", glyph = "W", color = { 0.42, 0.40, 0.36 } },
})

types:define("vine", {
  category = "climb", resize = "y", size = { w = 1, h = 4 }, max = { w = 1, h = 24 },
  flags = { climbable = true },
  fields = {
    { key = "speed", type = "number", default = 60, min = 10, max = 200 },   -- climbing, pixels / s
    { key = "swing", type = "bool", default = true },                        -- can swing on it
  },
  editor = { label = "Vine", glyph = "|", color = { 0.25, 0.65, 0.30 } },
})

types:define("crate", {
  category = "breakable", collision = "solid",
  flags = { breakable = true },
  fields = {
    { key = "health", type = "integer", default = 1, min = 1, max = 9 },
    { key = "virus_chance", type = "number", default = 0.35, min = 0, max = 1 },
    { key = "virus", type = "integer", default = 1, min = 0, max = 99 },
  },
  init = function(p) if p.state.health == nil then p.state.health = p.fields.health end end,
  hit = function(p, amount)
    p.state.health = p.state.health - amount
    return p.state.health <= 0
  end,
  editor = { label = "Crate", glyph = "C", color = { 0.70, 0.50, 0.28 } },
})

types:define("spikes", {
  category = "hazard", resize = "x", size = { w = 1, h = 1 }, max = { w = 20, h = 1 },
  flags = { hazard = true },
  fields = {
    { key = "damage", type = "integer", default = 1, min = 0, max = 9 },     -- hearts
  },
  editor = { label = "Spikes", glyph = "^", color = { 0.80, 0.80, 0.85 } },
})

types:define("statue", {
  category = "turret", collision = "solid", size = { w = 1, h = 2 },
  flags = { turret = true },
  fields = {
    { key = "attack", type = "enum", default = "ranged", options = { "ranged", "explosive" } },
    { key = "interval", type = "number", default = 2.0, min = 0.3, max = 20 },   -- seconds
    { key = "direction", type = "enum", default = "left", options = { "left", "right" } },
    { key = "delay", type = "number", default = 0, min = 0, max = 20 },          -- before the first shot
  },
  editor = { label = "Statue", glyph = "S", color = { 0.55, 0.58, 0.62 } },
})

return { types = types }
