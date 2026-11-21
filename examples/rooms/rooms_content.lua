-- The mutation and consumable content pools of the rooms example, built on engine.modules.items.
-- The modules stay generic: this file is where the game's sources, mobs, floors, synergy and
-- luck rules live.
--
--   local content = require("rooms_content")
--   local pools = content.new_pools()
--   local ctx = { source = "treasure", floor = 1, biome = "cellar",
--     build = { tags = { jump = true }, stacks = {}, stats = {}, luck = 5 } }
--   local entry = content.drop(pools.mutations, rng, ctx, content.chances.mob)
--   if entry then content.take(pools.mutations, entry) end
--
-- `items.pool` already filters rooms, biomes and requires; `M.filter` adds the game's own rules
-- (sources, mobs, floors) and `M.weigh` adds synergy/anti. The draw wrappers wire both into a
-- draw context, so callers only pass the plain context described above.
local items = require("engine.modules.items")
local mutation_defs = require("rooms_mutations")
local consumable_defs = require("rooms_consumables")

local M = {}

-- The roll of each source, before luck (see M.drop)
M.chances = { mob = 0.10, obstacle = 0.35, machine = 0.35, room_clear = 0.20 }

-- The chance a drop of a source happens: baseline, and the effect of one point of luck.
local function normalize_mutation(e)
  if e.max == nil then
    if e.unique then e.max = 1
    elseif e.max_stacks then e.max = e.max_stacks end
  end
  return e
end

-- Mutations with `max` filled in: unique = 1, stackable = max_stacks
M.mutations = {}
for i = 1, #mutation_defs.entries do
  M.mutations[i] = normalize_mutation(mutation_defs.entries[i])
end

-- All consumables, and the two pools split by kind
M.consumables, M.hearts, M.virus = {}, {}, {}
for i = 1, #consumable_defs.entries do
  local e = consumable_defs.entries[i]
  M.consumables[i] = e
  if e.kind == "heart" then M.hearts[#M.hearts + 1] = e
  elseif e.kind == "virus" then M.virus[#M.virus + 1] = e end
end

local function in_list(list, value)
  if list == nil or value == nil then return false end
  for i = 1, #list do
    if list[i] == value then return true end
  end
  return false
end

-- Tags can be a set { tag = true } (the documented form) or a plain array.
local function in_tags(tags, tag)
  if tags == nil then return false end
  if tags[tag] then return true end
  for i = 1, #tags do
    if tags[i] == tag then return true end
  end
  return false
end

-- M.filter(entry, ctx): the game's own rule, for items' ctx.filter. rooms/biomes/requires are
-- items' job; here only sources, mobs and floors. ctx fields: source, mob, biome, floor, room,
-- build, have.
function M.filter(entry, ctx)
  ctx = ctx or {}
  if entry.sources ~= nil and not in_list(entry.sources, ctx.source) then return false end
  if entry.mobs ~= nil and not in_list(entry.mobs, ctx.mob) then return false end
  local floors = entry.floors
  if floors ~= nil then
    local f = ctx.floor
    if f == nil then return false end
    if floors.min ~= nil and f < floors.min then return false end
    if floors.max ~= nil and f > floors.max then return false end
  end
  return true
end

-- M.weigh(entry, base, ctx): items' ctx.weight. Each synergy tag the build has multiplies by
-- 1.5 (total synergy at most x3); each anti tag multiplies by 0.5 (total anti at least x0.1).
-- No luck here: luck is applied to the drop chance in M.drop.
function M.weigh(entry, base, ctx)
  local tags = ctx and ctx.build and ctx.build.tags
  local w = base
  local syn = entry.synergy
  if syn ~= nil and tags ~= nil then
    local mult = 1
    for i = 1, #syn do
      if in_tags(tags, syn[i]) then mult = mult * 1.5 end
    end
    if mult > 3 then mult = 3 end
    w = w * mult
  end
  local anti = entry.anti
  if anti ~= nil and tags ~= nil then
    local mult = 1
    for i = 1, #anti do
      if in_tags(tags, anti[i]) then mult = mult * 0.5 end
    end
    if mult < 0.1 then mult = 0.1 end
    w = w * mult
  end
  return w
end

-- Luck 5 is neutral; below it drops are rarer, above it more common.
function M.luck_multiplier(luck)
  if luck == nil then luck = 5 end
  return 0.5 + luck * 0.1
end

local function clamp01(x)
  if x < 0 then return 0 end
  if x > 1 then return 1 end
  return x
end

-- Module-level hooks: a draw never allocates a closure (the context copy is one table).
local function content_filter(entry, ctx) return M.filter(entry, ctx) end
local function content_weight(entry, weight, ctx) return M.weigh(entry, weight, ctx) end

local function with_hooks(ctx)
  local c = {}
  if ctx ~= nil then
    for k, v in next, ctx do c[k] = v end
  end
  c.filter = content_filter
  c.weight = content_weight
  return c
end

-- M.drop(pool, rng, ctx, chance): roll the source's chance with luck, then draw. ctx.build.luck
-- defaults to 5.
function M.drop(pool, rng, ctx, chance)
  ctx = ctx or {}
  local luck = ctx.build and ctx.build.luck
  local p = clamp01((chance or 0) * M.luck_multiplier(luck))
  if not rng:chance(p) then return nil end
  return pool:draw(rng, with_hooks(ctx))
end

-- Draw wrappers: pool:draw with the content filter and weight rule
function M.draw_mutation(pool, rng, ctx) return pool:draw(rng, with_hooks(ctx)) end
function M.draw_heart(pool, rng, ctx) return pool:draw(rng, with_hooks(ctx)) end
function M.draw_virus(pool, rng, ctx) return pool:draw(rng, with_hooks(ctx)) end

-- M.take(pool, entry): the slime got it (counts against max for uniques)
function M.take(pool, entry) return pool:take(entry) end

-- The pools of a run: mutations, and consumables split by kind
function M.new_pools()
  return {
    mutations = items.pool.new(M.mutations),
    hearts = items.pool.new(M.hearts),
    virus = items.pool.new(M.virus),
  }
end

return M
