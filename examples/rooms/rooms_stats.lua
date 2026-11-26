-- The slime's run stats (luck, jump, speed, damage, shield, health) and the shield resource.
-- Mutations arrive as engine.modifiers definitions (`stats`, `stacking`, `max_stacks`, `tags`);
-- this file never requires the game's content. See examples/rooms/README.md.
local modifiers = require("engine.modifiers")

local M = {}

-- The schema: base value and hard limits. jump and speed are multipliers.
M.defs = {
  luck = { base = 5, min = 0, max = 10 },
  jump = { base = 1, min = 0.5, max = 3 },
  speed = { base = 1, min = 0.5, max = 2 },
  damage = { base = 1, min = 0, max = 20 },
  shield = { base = 0, min = 0, max = 10 },
  health = { base = 5, min = 1, max = 20 },
}

local SHIELD_MOD = "__rooms_stats_shield"
local SHIELD_RECHARGE = 5      -- seconds without a hit, plus 2.5 per point of shield capacity
local SHIELD_PER_POINT = 2.5
local PERMANENT_PREFIX = "__rooms_stats_permanent:"

local Stats = {}
Stats.__index = Stats

local Source = {}
Source.__index = Source

function Source:get(name)
  local stats = self.stats
  if name == "max_health" then return stats.mods:get("health") end
  if name == "attack_damage" then return stats.mods:get("damage") end
  if name == "defense" then return 0 end
  if name == "knockback_resist" then return 0 end
  if name == "invuln_time" then return 1.0 end
  return stats.mods:get(name)
end

-- mutation_defs: { { id, stacking, max_stacks, stats = { { stat, op, value }, ... }, tags }, ... }
function M.new(mutation_defs)
  local reg = modifiers.new()
  for name, def in pairs(M.defs) do
    reg:stat(name, { base = def.base, min = def.min, max = def.max })
  end
  reg:define({
    id = SHIELD_MOD,
    events = { on_damaged = function(owner, hit) return owner:_shield_absorb(hit) end },
  })
  local defs = {}
  for _, def in ipairs(mutation_defs or {}) do
    reg:define(def)
    defs[def.id] = def
  end
  local self = setmetatable({
    reg = reg,
    defs = defs,
    _stacks = {},
    _permanent = {},
    shield_current = 0,
    shield_timer = 0,
    shield_max = M.defs.shield.base,
    source = setmetatable({ stats = nil }, Source),
  }, Stats)
  self.source.stats = self
  self.mods = reg:attach(self)
  self.mods:add(SHIELD_MOD)
  return self
end

function Stats:get(name)
  return self.mods:get(name)
end

function Stats:stacks(id)
  return self._stacks[id] or 0
end

function Stats:acquire(id)
  local def = self.defs[id]
  if not def then error("rooms_stats: unknown mutation " .. tostring(id), 2) end
  local stacking = def.stacking or "unique"
  local current = self._stacks[id] or 0
  if stacking == "unique" or stacking == "refresh" then
    if current > 0 then
      if stacking ~= "refresh" then return false end
    end
  elseif stacking == "stack" then
    local max = def.max_stacks
    if max and current >= max then return false end
  end
  local changed = self.mods:add(id, 1)
  if not changed then return false end
  self._stacks[id] = self.mods:stacks(id)
  return true
end

-- Takes one stack of a mutation away (the casino's lottery). False when it is not there.
function Stats:lose(id)
  if (self._stacks[id] or 0) <= 0 then return false end
  self.mods:remove(id, 1)
  local n = self.mods:stacks(id)
  self._stacks[id] = n > 0 and n or nil
  return true
end

-- A permanent stat change, for things a pact or a choice takes away for the run. `source`
-- identifies it: applying the same source and stat again does nothing. It is serialized with the
-- run, unlike a timed modifier.
function Stats:add_permanent(name, delta, source)
  if not M.defs[name] then error("rooms_stats: unknown stat " .. tostring(name), 2) end
  if type(delta) ~= "number" then
    error("rooms_stats: the delta of " .. tostring(name) .. " must be a number", 2)
  end
  if source == nil then error("rooms_stats: a permanent change needs a source", 2) end
  local key = tostring(source)
  local id = PERMANENT_PREFIX .. name .. ":" .. key
  if not self.reg.defs[id] then
    self.reg:define({ id = id, stats = { { name, "add", delta } }, tags = { "permanent" } })
  end
  if not self.mods:add(id) then return false end
  self._permanent[#self._permanent + 1] = { name = name, delta = delta, source = key, id = id }
  return true
end

function Stats:tags()
  local set = {}
  for id in pairs(self._stacks) do
    local def = self.defs[id]
    if def and def.tags then
      for _, tag in ipairs(def.tags) do set[tag] = true end
    end
  end
  return set
end

-- The shield's capacity and the resource inside it. Refills the delta of a capacity gained since
-- the last look; a smaller capacity clamps the resource.
function Stats:_sync_shield()
  local max = self.mods:get("shield")
  local last = self.shield_max
  if max > last then
    local current = self.shield_current + (max - last)
    if current > max then current = max end
    self.shield_current = current
  elseif max < last and self.shield_current > max then
    self.shield_current = max
  end
  self.shield_max = max
  return max
end

-- Absorbs damage 1:1 before health; the overflow goes on. Any hit restarts the recharge timer.
function Stats:_shield_absorb(hit)
  self.shield_timer = 0
  local max = self:_sync_shield()
  local amount = hit.amount
  local current = self.shield_current
  if amount > 0 and current > 0 and max > 0 then
    local absorbed = amount
    if absorbed > current then absorbed = current end
    current = current - absorbed
    amount = amount - absorbed
  end
  self.shield_current = current
  hit.amount = amount
  return amount
end

-- current, max
function Stats:shield()
  local max = self:_sync_shield()
  return self.shield_current, max
end

-- One fixed step: the shield refills after (5 + 2.5 * capacity) seconds without a hit.
function Stats:update(dt)
  local max = self:_sync_shield()
  if self.shield_current < max then
    local t = self.shield_timer + dt
    if t >= SHIELD_RECHARGE + SHIELD_PER_POINT * max then
      self.shield_current = max
      self.shield_timer = 0
    else
      self.shield_timer = t
    end
  else
    self.shield_timer = 0
  end
end

-- Created once: combat.world reads it through fighter.stats:get(name).
function Stats:combat_source()
  return self.source
end

function Stats:serialize()
  local mutations = {}
  for id, n in pairs(self._stacks) do mutations[id] = n end
  local permanent = {}
  for i, p in ipairs(self._permanent) do
    permanent[i] = { name = p.name, delta = p.delta, source = p.source }
  end
  return {
    mutations = mutations,
    shield = { current = self.shield_current, timer = self.shield_timer },
    permanent = permanent,
  }
end

function Stats:set_state(state)
  state = state or {}
  for id in pairs(self._stacks) do self.mods:remove(id) end
  self._stacks = {}
  for _, p in ipairs(self._permanent) do self.mods:remove(p.id) end
  self._permanent = {}
  local mutations = state.mutations or {}
  local ids = {}
  for id in pairs(mutations) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local def = self.defs[id]
    local n = mutations[id] or 0
    if def and n > 0 then
      local stacking = def.stacking or "unique"
      if stacking == "unique" or stacking == "refresh" then
        n = 1
      elseif def.max_stacks and n > def.max_stacks then
        n = def.max_stacks
      end
      self.mods:add(id, n)
      self._stacks[id] = self.mods:stacks(id)
    end
  end
  for _, p in ipairs(state.permanent or {}) do
    if M.defs[p.name] then self:add_permanent(p.name, p.delta, p.source) end
  end
  local shield = state.shield or {}
  local max = self.mods:get("shield")
  self.shield_max = max
  local current = shield.current or 0
  if current < 0 then current = 0 elseif current > max then current = max end
  self.shield_current = current
  self.shield_timer = shield.timer or 0
end

return M
