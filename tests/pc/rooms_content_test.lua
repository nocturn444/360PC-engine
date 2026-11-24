-- examples/rooms content pools: the mutation/consumable schemas and their `max`, the game's
-- source/mob/floor filter, synergy/anti weight math, luck, deterministic draws, unique and
-- stackable limits, and drops with luck.
-- Usage, from the repository root: luajit -joff tests/pc/rooms_content_test.lua   (must end "OK:")
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./examples/rooms/?.lua;" .. package.path
local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print("FAILED: " .. what); os.exit(1) end
end

local Rng = require("engine.rng")
local items = require("engine.modules.items")
local C = require("rooms_content")

-- 1. Schema: the example mutations, all unique, with well-formed fields
check(type(C.mutations) == "table" and #C.mutations == 11, "eleven example mutations (4 stat, one locked, 7 ability)")
check(type(C.consumables) == "table" and #C.consumables == 3, "three example consumables")
check(#C.bombs == 1 and C.bombs[1].kind == "bomb", "the bomb is a consumable")
local rarities = { common = true, rare = true, epic = true }
local jump, legs
for _, e in ipairs(C.mutations) do
  check(type(e.id) == "string" and e.id ~= "", "mutation id: " .. tostring(e.id))
  check(type(e.name) == "string" and e.name ~= "", e.id .. ": name")
  check(type(e.weight) == "number" and e.weight >= 0, e.id .. ": weight >= 0")
  check(rarities[e.rarity], e.id .. ": rarity is common, rare or epic")
  check(type(e.sources) == "table" and #e.sources > 0, e.id .. ": sources")
  check(e.unique == true and e.max == 1, e.id .. ": unique -> max 1")
  check(type(e.tags) == "table" and #e.tags > 0, e.id .. ": tags")
  check(type(e.synergy) == "table" and type(e.anti) == "table", e.id .. ": synergy/anti arrays")
  check((type(e.stats) == "table" and #e.stats > 0) or type(e.ability) == "table" or type(e.shot) == "table",
    e.id .. ": stats, an ability or a shot change")
  if e.stats then
    local s = e.stats[1]
    check(type(s) == "table" and type(s[1]) == "string" and type(s[2]) == "string" and type(s[3]) == "number",
      e.id .. ": stats are { stat, op, value }")
  end
  check(type(e.look) == "table" and (e.look.body_color or e.look.outline_color or e.look.limbs), e.id .. ": look fragment")
  check(type(e.color) == "table" and #e.color == 3, e.id .. ": colour")
  check(e.example == true, e.id .. ": marked as an example")
  if e.tags[1] == "jump" then jump = e elseif e.tags[1] == "speed" then legs = e end
end
check(jump and jump.stats[1][1] == "jump" and jump.stats[1][2] == "mul_base" and jump.stats[1][3] == 0.2,
  "the jump mutation adds 0.2 to the jump multiplier base")
check(jump.sources[1] == "treasure" or jump.sources[2] == "treasure", "jump: from treasure")
check(jump.sources[1] == "shop" or jump.sources[2] == "shop" or jump.sources[3] == "shop", "jump: from shop")
check(legs and legs.stats[1][1] == "speed" and legs.stats[1][2] == "mul_base" and legs.stats[1][3] == 0.15,
  "the legs mutation adds 0.15 to the speed multiplier base")
check(legs.body and legs.body.width and legs.body.height, "legs: a wider, taller body")
check(#legs.sources == 1 and legs.sources[1] == "treasure", "legs: only from treasure")

local kinds = {}
for _, e in ipairs(C.consumables) do
  check(type(e.id) == "string" and type(e.name) == "string", "consumable id/name")
  check(type(e.weight) == "number" and e.weight >= 0, e.id .. ": weight")
  check(type(e.sources) == "table" and #e.sources > 0, e.id .. ": sources")
  kinds[e.kind] = (kinds[e.kind] or 0) + 1
  if e.kind == "heart" then
    check(e.heal == 1, "heart: heal 1")
    check(e.sources[1] == "mob" and e.sources[2] == "room_clear" and e.sources[3] == "obstacle",
      "heart: from mob, room clear and obstacle")
  elseif e.kind == "virus" then
    check(e.amount == 1, "virus: amount 1")
    check(e.sources[1] == "obstacle" and e.sources[2] == "machine" and e.sources[3] == "room_clear",
      "virus: from obstacle, machine and room clear")
  end
end
check(kinds.heart == 1, "one normal heart only")
check(kinds.virus == 1, "one virus")

-- 2. Filter: sources, mobs and floors (rooms/biomes/requires are items' job)
check(C.filter(jump, { source = "treasure" }), "filter: a listed source")
check(C.filter(jump, { source = "shop" }), "filter: the other listed source")
check(not C.filter(jump, { source = "mob" }), "filter: a source not listed")
check(not C.filter(jump, {}), "filter: sources but no source in the context")
check(C.filter({ id = "s", sources = { "boss" } }, { source = "boss" }), "filter: boss source")
check(C.filter({ id = "any" }, { source = "boss" }), "filter: no sources means anywhere")
local mob_entry = { id = "m", mobs = { "slime", "bat" } }
check(C.filter(mob_entry, { mob = "slime" }), "filter: a listed mob")
check(not C.filter(mob_entry, { mob = "ghost" }), "filter: a mob not listed")
check(not C.filter(mob_entry, {}), "filter: mobs but no mob in the context")
local floor_entry = { id = "f", floors = { min = 3, max = 5 } }
check(C.filter(floor_entry, { floor = 3 }), "filter: first floor of the range")
check(C.filter(floor_entry, { floor = 5 }), "filter: last floor of the range")
check(not C.filter(floor_entry, { floor = 2 }), "filter: below the range")
check(not C.filter(floor_entry, { floor = 6 }), "filter: above the range")
check(not C.filter(floor_entry, {}), "filter: floors but no floor in the context")
check(C.filter({ id = "lo", floors = { min = 3 } }, { floor = 10 }), "filter: only a minimum")
check(not C.filter({ id = "hi", floors = { max = 2 } }, { floor = 3 }), "filter: only a maximum")
check(C.filter(jump, { source = "treasure", build = { tags = { jump = true } } }),
  "filter: build tags do not filter (they only weigh)")

-- 3. Synergy and anti weight math
local combo = { id = "c", synergy = { "jump" }, anti = { "heavy" } }
check(math.abs(C.weigh(combo, 2, { build = { tags = { jump = true } } }) - 3) < 1e-9,
  "weigh: one synergy tag is x1.5")
check(math.abs(C.weigh(combo, 2, { build = { tags = {} } }) - 2) < 1e-9,
  "weigh: no tags means the base weight")
check(math.abs(C.weigh({ synergy = { "a", "b" } }, 2, { build = { tags = { a = true, b = true } } }) - 4.5) < 1e-9,
  "weigh: two synergy tags are x2.25")
check(math.abs(C.weigh({ synergy = { "a", "b", "c", "d" } }, 2, { build = { tags = { a = true, b = true, c = true, d = true } } }) - 6) < 1e-9,
  "weigh: synergy is capped at x3")
check(math.abs(C.weigh(combo, 2, { build = { tags = { heavy = true } } }) - 1) < 1e-9,
  "weigh: one anti tag is x0.5")
check(math.abs(C.weigh({ anti = { "a", "b" } }, 2, { build = { tags = { a = true, b = true } } }) - 0.5) < 1e-9,
  "weigh: two anti tags are x0.25")
check(math.abs(C.weigh({ anti = { "a", "b", "c", "d", "e" } }, 2,
  { build = { tags = { a = true, b = true, c = true, d = true, e = true } } }) - 0.2) < 1e-9,
  "weigh: anti floor is x0.1")
check(math.abs(C.weigh({ synergy = { "a" }, anti = { "b" } }, 2, { build = { tags = { a = true, b = true } } }) - 1.5) < 1e-9,
  "weigh: synergy and anti both apply")
check(math.abs(C.weigh({ synergy = { "jump" } }, 2, { build = { tags = { "jump" } } }) - 3) < 1e-9,
  "weigh: tags may be a plain array too")

-- 4. Luck
check(C.luck_multiplier(0) == 0.5, "luck 0: x0.5")
check(C.luck_multiplier(5) == 1.0, "luck 5: neutral")
check(C.luck_multiplier(10) == 1.5, "luck 10: x1.5")
check(C.luck_multiplier() == 1.0, "no luck: neutral")

-- 5. Pools are split by content, with items' taken state
local pools = C.new_pools()
check(type(pools.mutations) == "table" and type(pools.mutations.draw) == "function", "a mutation pool")
check(#pools.mutations.entries == #C.mutations, "the mutation pool has every mutation")
check(#pools.hearts.entries == 1 and pools.hearts.entries[1].kind == "heart", "the heart pool")
check(#pools.virus.entries == 1 and pools.virus.entries[1].kind == "virus", "the virus pool")
check(pools.mutations ~= C.new_pools().mutations, "new_pools makes fresh pools")

-- 6. Same seed, same draws; the source filter applies inside a draw
local function sequence(seed, source)
  local p = C.new_pools().mutations
  local r = Rng.new(seed)
  local ctx = { source = source, floor = 1, build = { tags = {}, luck = 5 } }
  local out = {}
  for i = 1, 12 do
    local e = C.draw_mutation(p, r, ctx)
    out[i] = e and e.id or "nil"
  end
  return table.concat(out, ",")
end
check(sequence(42, "treasure") == sequence(42, "treasure"), "same seed, same mutation draws")
check(sequence(42, "treasure") ~= sequence(43, "treasure"), "a different seed draws differently")
check(sequence(1, "machine") == ("nil,"):rep(11) .. "nil", "no mutation from a source none lists")

-- 7. Unique mutations are excluded once taken; a stackable entry respects its max
local p = C.new_pools().mutations
local r = Rng.new(7)
local ctx = { source = "treasure", floor = 1, build = { tags = {} } }
local first = C.draw_mutation(p, r, ctx)
check(first ~= nil, "a mutation comes out")
C.take(p, first)
check(p:taken_count(first.id) == 1, "take counts the mutation")
local second = C.draw_mutation(p, r, ctx)
check(second ~= nil and second.id ~= first.id, "a second unique mutation still comes out")
C.take(p, second)
local third = C.draw_mutation(p, r, ctx)
check(third ~= nil and third.id ~= first.id and third.id ~= second.id, "the third unique mutation still comes out")
C.take(p, third)
for _ = 4, #C.mutations do                       -- every treasure mutation, each once
  local e = C.draw_mutation(p, r, ctx)
  if e then C.take(p, e) end
end
check(C.draw_mutation(p, r, ctx) == nil, "all uniques taken: nothing comes out")

local stackable = { id = "stack", weight = 1, max = 2 }
local sp = items.pool.new({ stackable })
check(sp:draw(Rng.new(1)) ~= nil, "a stackable comes out")
sp:take("stack")
check(sp:draw(Rng.new(1)) ~= nil, "once taken of two: still comes out")
sp:take("stack")
check(sp:draw(Rng.new(1)) == nil, "taken twice of two: gone")

-- 8. Drops: chance scaled by luck, clamped, then a draw
local drop_ctx = { source = "treasure", floor = 1, build = { tags = {}, luck = 5 } }
check(C.drop(C.new_pools().mutations, Rng.new(123), drop_ctx, 10) ~= nil,
  "drop: chance 10 at luck 5 always drops")
check(C.drop(C.new_pools().mutations, Rng.new(123), drop_ctx, 0) == nil,
  "drop: chance 0 never drops")
check(C.drop(C.new_pools().mutations, Rng.new(123), { source = "treasure" }, 10) ~= nil,
  "drop: no luck in the context is neutral luck 5")
local no_source = C.drop(C.new_pools().mutations, Rng.new(123), { source = "machine" }, 10)
check(no_source == nil, "drop: a source with nothing to give drops nothing")

-- 9. The wrappers pick the right kind and honour sources
local hearts = C.new_pools().hearts
local heart = C.draw_heart(hearts, Rng.new(3), { source = "mob" })
check(heart and heart.kind == "heart", "draw_heart: a heart from a mob")
check(C.draw_heart(C.new_pools().hearts, Rng.new(3), { source = "machine" }) == nil,
  "draw_heart: no heart from a machine")
local virus = C.draw_virus(C.new_pools().virus, Rng.new(3), { source = "machine" })
check(virus and virus.kind == "virus", "draw_virus: a virus from a machine")
check(C.draw_virus(C.new_pools().virus, Rng.new(3), { source = "mob" }) == nil,
  "draw_virus: no virus from a mob")

-- 10. The chances table
check(C.chances.mob == 0.10 and C.chances.obstacle == 0.35 and C.chances.machine == 0.35
  and C.chances.room_clear == 0.20, "the source chances")

print(string.format("OK: %d checks; the rooms content pools work", checks))
