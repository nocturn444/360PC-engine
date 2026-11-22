-- engine/modules/props: type validation, placement checks, instances with field defaults,
-- collision stamped on a grid overlay and taken off on removal, persistent state across
-- visits, hooks, overlap and tile flag queries, the editor catalog, no allocation per frame
-- and no globals. Usage: luajit -joff tests/engine/props_test.lua  (ends with "OK:")
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;" .. package.path

local T = ...
local checks = 0
if not T then
  T = { check = function(cond, what)
    checks = checks + 1
    if not cond then print("FAILED: " .. what); os.exit(1) end
  end }
end

local globals = {}
for k in pairs(_G) do globals[k] = true end
local Save = require("engine.save")
local props = require("engine.modules.props")
local platformer = require("engine.modules.platformer")

local function refuses(f, what, pattern)
  local ok, err = pcall(f)
  T.check(not ok and tostring(err):find(pattern, 1, true), what .. " (" .. tostring(err) .. ")")
end

-- Types
local reg = props.registry()
local hits, updates, inits = 0, 0, 0
reg:define("ledge", { category = "platform", collision = "one_way", resize = "x", size = { w = 3, h = 1 },
  min = { w = 2, h = 1 }, max = { w = 8, h = 1 }, flags = { hangable = true } })
reg:define("vine", { category = "climb", resize = "y", size = { w = 1, h = 3 }, flags = { climbable = true },
  editor = { label = "Vine", glyph = "|", color = { 0.2, 0.7, 0.3 } } })
reg:define("crate", { category = "breakable", collision = "solid",
  fields = { { key = "health", type = "integer", default = 2, min = 1, max = 9 },
             { key = "drop", type = "enum", default = "virus", options = { "virus", "heart", "none" } } },
  init = function(p) inits = inits + 1; p.state.health = p.state.health or p.fields.health end,
  hit = function(p, amount) hits = hits + 1; p.state.health = p.state.health - amount; return p.state.health <= 0 end })
reg:define("spikes", { category = "hazard", flags = { hazard = true },
  fields = { { key = "damage", type = "number", default = 1, min = 0 }, { key = "send_back", type = "bool", default = false } },
  update = function(p, dt) updates = updates + 1 end })

refuses(function() reg:define("vine", {}) end, "a type defined twice", "defined twice")
refuses(function() reg:define("bad name", {}) end, "a bad type name", "letters, digits")
refuses(function() reg:define("x1", { collision = "water" }) end, "a bad collision", "collision is nil")
refuses(function() reg:define("x2", { resize = "z" }) end, "a bad resize", "resize is none")
refuses(function() reg:define("x3", { fields = { { key = "a", type = "float", default = 1 } } }) end, "a bad field type", "type is number")
refuses(function() reg:define("x4", { fields = { { key = "a", type = "integer", default = 1.5 } } }) end, "a bad default", "default is a whole")
refuses(function() reg:define("x5", { fields = { { key = "a", type = "enum", default = "q", options = { "p" } } } }) end, "an enum default not in options", "one of p")
refuses(function() reg:define("x6", { flags = { "climbable" } }) end, "flags as a list", "flags are")
refuses(function() reg:define("x7", { update = 3 }) end, "a hook that is not a function", "update is a function")
refuses(function() reg:define("x8", { editor = { glyph = "abc" } }) end, "a long glyph", "glyph 1 or 2")
T.check(reg:get("vine").editor.label == "Vine" and reg:get("ledge").editor.label == "ledge", "editor defaults")

-- Placement checks
T.check(reg:check({ type = "ledge", tx = 2, ty = 3, w = 5 }) == nil, "a resized ledge is fine")
T.check(reg:check({ type = "nope", tx = 1, ty = 1 }):find("unknown prop type"), "unknown type")
T.check(reg:check({ type = "ledge", tx = 0, ty = 1 }):find("tx, ty"), "tile from 1")
T.check(reg:check({ type = "ledge", tx = 1, ty = 1, h = 2 }):find("height cannot change"), "fixed height")
T.check(reg:check({ type = "ledge", tx = 1, ty = 1, w = 9 }):find("maximum"), "max size")
T.check(reg:check({ type = "ledge", tx = 1, ty = 1, w = 1 }):find("minimum"), "min size")
T.check(reg:check({ type = "crate", tx = 1, ty = 1, fields = { color = 1 } }):find("unknown field"), "unknown field")
T.check(reg:check({ type = "crate", tx = 1, ty = 1, fields = { health = 0 } }):find(">= 1"), "field min")
T.check(reg:check({ type = "crate", tx = 1, ty = 1, fields = { drop = "gold" } }):find("one of"), "enum value")

-- A room
local grid = platformer.grid.new({
  "##########",
  "#........#",
  "#........#",
  "#........#",
  "##########",
}, { tile_size = 16 })
local placements = {
  { type = "ledge", tx = 2, ty = 3, w = 4 },
  { type = "vine", tx = 8, ty = 2 },
  { type = "crate", tx = 7, ty = 4, fields = { health = 1 } },
  { type = "spikes", tx = 2, ty = 4 },
}
refuses(function() props.set(reg, { { type = "crate", tx = 1, ty = 1, fields = { health = "x" } } }) end,
  "a bad placement in a set", "placement 1")
local state = {}
local set = props.set(reg, placements, { tile_size = 16, state = state })
T.check(set:count() == 4 and inits == 1, "four props, one init")
local crate = set:at(3)
T.check(crate.fields.health == 1 and crate.fields.drop == "virus" and crate.state.health == 1, "fields merged with defaults")
T.check(crate.x == 96 and crate.y == 48 and crate.w == 16 and crate.h == 16, "pixel box")
T.check(set:at(2).th == 3 and set:at(2).h == 48, "default size")
local g = set:grid(grid)
T.check(g:kind(2, 3) == "one_way" and g:kind(5, 3) == "one_way" and g:kind(6, 3) == nil, "ledge stamped")
T.check(g:kind(7, 4) == "solid" and g:kind(1, 1) == "solid" and g:kind(8, 2) == nil, "crate stamped, base kept")
T.check(g:kind(0, 1) == nil and g.width == 10 and g.tile_size == 16, "grid interface")
local world = platformer.collision.newWorld(g)
T.check(world:countItems() > 0, "the overlay works as a platformer grid")

-- Queries
T.check(set:first(115, 20, 4, 4, "climbable") == set:at(2), "overlap with a flag")
T.check(set:first(115, 20, 4, 4, "hazard") == nil, "no hazard there")
local p, i = set:first(0, 0, 160, 80, nil, 0)
T.check(p == set:at(1) and i == 1, "first of all")
p, i = set:first(0, 0, 160, 80, nil, i)
T.check(p == set:at(2) and i == 2, "next one")
T.check(set:tile_flag(3, 3, "hangable") == set:at(1) and set:tile_flag(6, 3, "hangable") == nil, "tile flag")

-- Hooks, removal and persistence
set:update(1 / 30, nil)
T.check(updates == 1, "update only for types with the hook")
T.check(set:hit(set:at(1), 1) == false, "a type without hit ignores hits")
T.check(set:hit(crate, 1) == true and crate.removed and hits == 1, "a hit removes the crate")
T.check(g:kind(7, 4) == nil and state[3].removed == true, "removed: off the grid and saved")
T.check(set:first(96, 48, 16, 16, nil) == nil, "removed props are not found")
T.check(set:hit(crate, 1) == false and hits == 1, "a removed prop takes no hits")
local again = props.set(reg, placements, { tile_size = 16, state = state })
local g2 = again:grid(grid)
T.check(again:at(3).removed and g2:kind(7, 4) == nil and inits == 1, "the crate stays broken on the next visit")
local out = Save.serialize(state)
T.check(Save.parse(out), "the state saves with engine.save")

-- Catalog
local cat = reg:catalog()
T.check(cat.format == "360pc-props-catalog" and cat.version == 1 and #cat.types == 4, "catalog header")
local c1, c3 = cat.types[1], cat.types[3]
T.check(c1.id == "ledge" and c1.resizable == "x" and c1.w == 3 and c1.collision == "one_way"
  and c1.flags[1] == "hangable" and c1.max.w == 8 and c1.placement == "prop", "catalog ledge")
T.check(c3.fields[1].key == "health" and c3.fields[2].options[3] == "none", "catalog fields in order")
local ok, back = Save.parse(Save.serialize(cat))
T.check(ok and back.types[2].glyph == "|", "the catalog round-trips through engine.save")

-- Nothing allocated per frame
local function frame()
  set:update(1 / 30, nil)
  set:first(0, 0, 160, 80, "climbable", 0)
  set:tile_flag(3, 3, "hangable")
  g:kind(3, 3); g:kind(7, 4)
  set:draw(nil)
end
frame()
collectgarbage(); collectgarbage("stop")
local before = collectgarbage("count")
for _ = 1, 200 do frame() end
local grown = collectgarbage("count") - before
collectgarbage("restart")
T.check(grown < 1, "no allocation per frame (" .. grown .. " KB)")

for k in pairs(_G) do
  T.check(globals[k], "no new global " .. tostring(k))
end
if checks > 0 then print("OK: " .. checks .. " checks") end
