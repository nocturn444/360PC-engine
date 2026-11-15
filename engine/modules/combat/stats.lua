-- combat.stats: a fighter's combat stats as plain data. See engine/modules/combat/README.md.
-- The world reads each of them through fighter.stats:get(name) when it resolves a hit, so an
-- engine.modifiers set changes them without the module knowing.
local pairs, tostring = pairs, tostring

local M = {}

M.defaults = {
  max_health = 10,        -- health a fighter starts with; heal() stops there
  attack_damage = 1,      -- damage of a hit whose hitbox has power 1 and no damage of its own
  defense = 0,            -- taken away from every hit received (the hit never goes below 0)
  knockback_resist = 0,   -- 0..1: the part of a knockback that is ignored (1: never pushed)
  invuln_time = 0.5,      -- s after being hurt during which nothing hits (0: no i-frames)
}

-- The stat names, sorted.
M.names = {}
for name in pairs(M.defaults) do M.names[#M.names + 1] = name end
table.sort(M.names)

-- A new table with the defaults and the given values over them. It is also the `base` table
-- engine.modifiers wants: mods:attach(owner, stats.new({ max_health = 3 })).
function M.new(overrides)
  local p = {}
  for name, v in pairs(M.defaults) do p[name] = v end
  for name, v in pairs(overrides or {}) do
    if M.defaults[name] == nil then error("combat: unknown stat " .. tostring(name), 2) end
    p[name] = v
  end
  return p
end

-- A stat source over a plain table: source:get(name) reads params[name] (live).
local Source = {}
Source.__index = Source
function Source:get(name) return self.params[name] end
function M.source(params) return setmetatable({ params = params }, Source) end

-- The stats as a plain table, read now from a stat source (anything with :get(name)).
function M.resolve(stats)
  local p = {}
  for i = 1, #M.names do p[M.names[i]] = stats:get(M.names[i]) end
  return p
end

return M
