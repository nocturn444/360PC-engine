-- procgen.floors: a run made of floors, each a fresh map (The Binding of Isaac style), larger
-- and fuller the deeper the player goes. A floor plan turns a floor number into the options of
-- procgen.generate: how many rooms, which templates, which special rooms (procgen.roomtypes),
-- the abilities, and the game's own changes.
--
--   local plan = procgen.floors.new({
--     count = 10, templates = lvl.rooms, types = procgen.roomtypes.defaults(),
--     rooms = { first = 7, last = 20 },
--   })
--   local map = plan:generate(n, run.streams:get("floor" .. n))   -- floor n, 1 to count
--
-- Use one rng stream per floor ("floor1", "floor2"...): a floor's map then depends only on the
-- run's seed and its number, never on what happened on the floors before.
local generator = require((...):gsub("floors$", "generator"))

local type, floor, max, tostring = type, math.floor, math.max, tostring

local M = {}
local Plan = {}
Plan.__index = Plan

-- floors.new(def):
--   count       floors in a run (10)
--   templates   the room templates, or function(n, plan) -> templates for floor n. A template
--               with `floors = { min, max }` is only used on those floors (max may be nil;
--               negative numbers count from the end as in roomtypes).
--   types       a procgen.roomtypes set (default: none, only start / normal / boss)
--   rooms       { first = 7, last = 20, jitter = 1 } (rooms on floor 1 and on the last floor,
--               straight in between, plus 0..jitter at random), or function(n, plan, rng) -> n.
--               Special rooms, the start and the boss count in it; it never drops below what
--               the floor's special rooms need.
--   abilities   array, or function(n, plan) -> array: ability locks of floor n (default none)
--   loops       true / false, or function(n, plan) -> boolean (default true)
--   boss_distance  "far" (default) or "any": where the boss room goes
--   attempts    the generator's attempts (default 50)
--   options     function(opts, n, plan, rng): changes the generate options of floor n last
--               (the game's own rules: a check, types, anything)
function M.new(def)
  def = def or {}
  local count = def.count or 10
  if type(count) ~= "number" or count < 1 or count ~= floor(count) then error("floors: count is a whole number >= 1", 2) end
  if def.templates == nil then error("floors: templates are needed", 2) end
  local rooms = def.rooms or {}
  if type(rooms) == "table" then
    rooms = { first = rooms.first or 7, last = rooms.last or 20, jitter = rooms.jitter or 1 }
    if rooms.first < 2 or rooms.last < rooms.first then error("floors: rooms needs 2 <= first <= last", 2) end
  elseif type(rooms) ~= "function" then
    error("floors: rooms is a table or a function", 2)
  end
  return setmetatable({ count = count, templates = def.templates, types = def.types, rooms = rooms,
    abilities = def.abilities, loops = def.loops, boss_distance = def.boss_distance or "far",
    attempts = def.attempts, options_fn = def.options, cache = {} }, Plan)
end

local function bound(v, total, default)
  if v == nil then return default end
  if v < 0 then return total + 1 + v end
  return v
end

-- The templates of floor n (a new array in the order of the full list).
function Plan:templates_for(n)
  local list = self.templates
  if type(list) == "function" then list = list(n, self) end
  if list.is_template_set then list = list.list end
  local out = {}
  for i = 1, #list do
    local t = list[i]
    local f = t.floors
    if f == nil or (n >= bound(f[1], self.count, 1) and n <= bound(f[2], self.count, self.count)) then
      out[#out + 1] = t
    end
  end
  if #out == 0 then error("floors: no template for floor " .. n, 3) end
  return out
end

-- How far through the run floor n is: 0 on the first floor, 1 on the last.
function Plan:progress(n)
  if self.count == 1 then return 1 end
  return (n - 1) / (self.count - 1)
end

-- The number of rooms of floor n before special rooms are added up (draws from rng for jitter).
function Plan:room_count(n, rng)
  local r = self.rooms
  if type(r) == "function" then return r(n, self, rng) end
  local base = floor(r.first + (r.last - r.first) * self:progress(n) + 0.5)
  if r.jitter > 0 then base = base + rng:int(0, r.jitter) end
  return base
end

-- The options of procgen.generate for floor n, drawing from rng (the same rng the map is then
-- generated with: generate(n, rng) does both).
function Plan:options(n, rng)
  if type(n) ~= "number" or n < 1 or n > self.count or n ~= floor(n) then
    error("floors: floor " .. tostring(n) .. " is not 1 to " .. self.count, 2)
  end
  local specials = self.types and self.types:specials(n, self.count, rng) or nil
  local abilities = self.abilities
  if type(abilities) == "function" then abilities = abilities(n, self) end
  local loops = self.loops
  if type(loops) == "function" then loops = loops(n, self) end
  local rooms = self:room_count(n, rng)
  local need = 2 + #(abilities or {})
  for i = 1, #(specials or {}) do need = need + specials[i].count end
  local opts = {
    templates = self:templates_for(n), rng = rng, rooms = max(rooms, need), abilities = abilities,
    loops = loops, specials = specials, boss_distance = self.boss_distance, attempts = self.attempts,
  }
  if self.options_fn then self.options_fn(opts, n, self, rng) end
  return opts
end

local function stamp(self, map, n)
  map.floor, map.floors = n, self.count
  map.progress = self:progress(n)
  return map
end

-- The map of floor n, or nil and the reason. map.floor, map.floors and map.progress (0..1)
-- are set, for the game's difficulty.
function Plan:generate(n, rng)
  local m, err = generator.generate(self:options(n, rng))
  if not m then return nil, err end
  return stamp(self, m, n)
end

-- The same, spread over frames: gen:step(ops) as in procgen.generator; gen.map is stamped too.
function Plan:generator(n, rng)
  local gen = generator.new(self:options(n, rng))
  local plan = self
  local step = gen.step
  function gen:step(ops)
    local done = step(self, ops)
    if done and self.map and not self.map.floor then stamp(plan, self.map, n) end
    return done
  end
  return gen
end

return M
