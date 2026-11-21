-- procgen.roomtypes: special room types as modular data. Each type says how many rooms of it a
-- floor gets, from which floor, with what chance and where (far from the start, near it,
-- anywhere); `specials(floor, total, rng, run)` turns the definitions into the `specials` list
-- the generator takes. A new type is one more define: the generator never names a type.
--
--   local types = procgen.roomtypes.new()
--   types:define("shop", { count = 1, max_floor = -2 })
--   types:define("vault", { count = 1, max = 2, replaces = "shop" })
--   types:define("miniboss", { min_floor = 2, chance = function(floor, total, run)
--       return 0.2 + 0.1 * floor + (run and run.kills or 0) * 0.001 end,
--     distance = "far", min_depth = 3 })
--   local specials = types:specials(floor, 10, rng, run)  -- for generate({ specials = specials, ... })
--
-- `run` is optional: any table owned by the game (its counters for the run). It is passed to
-- chance(floor, total, run) and count(floor, total, rng, run), so a chance can depend on what
-- happened earlier in the run. Calls without it work as before.
--
-- A type with `replaces` turns another type off on a floor where it has a room (see define).
-- Replacing types are evaluated first, in definition order, then the others in definition order;
-- the rng is drawn in that order, so the same rng state gives the same specials. The output list
-- stays in definition order. Replacements are applied once, directly to the target type (there
-- is no separate chain rule).
--
-- Templates of a special type (template.type == the name) are only used for that type; every
-- room of a special type is a dead end. "start", "boss" and "normal" are not special types.
local type, floor, tostring = type, math.floor, tostring

local M = {}
local Types = {}
Types.__index = Types

local RESERVED = { start = true, boss = true, normal = true }

function M.new() return setmetatable({ list = {}, by_name = {} }, Types) end

-- types:define(name, def) adds or replaces a type (it keeps its place in the order when
-- replaced; the order is part of a generated map). def fields, all optional:
--   count       a whole number (1), { min, max } (a draw), or function(floor, total, rng, run) -> n
--   chance      0..1 (1), or function(floor, total, run) -> 0..1: whether the floor gets the type
--   max         a whole number >= 0: the most rooms of this type on a floor (after count)
--   replaces    a type name: on a floor where this type has a room, that type gets none
--   min_floor   first floor with this type (1)
--   max_floor   last floor (the last one); a negative number counts from the end: -1 is the last
--               floor, -2 the one before it
--   distance    "any" (default), "far" (the deepest open exits) or "near" (close to the start)
--   min_depth   fewest doors between the start and the room (1)
--   (anything else is the game's: price lists, colours for the minimap...)
-- Returns the Types.
function Types:define(name, def)
  if type(name) ~= "string" or name == "" then error("roomtypes: a type needs a name", 2) end
  if RESERVED[name] then error("roomtypes: " .. name .. " is not a special type", 2) end
  def = def or {}
  local c = def.count
  if c ~= nil and type(c) ~= "function" and type(c) ~= "table" and (type(c) ~= "number" or c < 0 or c ~= floor(c)) then
    error("roomtypes: " .. name .. ".count is a whole number, { min, max } or a function", 2)
  end
  if type(c) == "table" and not (type(c[1]) == "number" and type(c[2]) == "number" and c[1] <= c[2]) then
    error("roomtypes: " .. name .. ".count { min, max } needs min <= max", 2)
  end
  local mx = def.max
  if mx ~= nil and (type(mx) ~= "number" or mx < 0 or mx ~= floor(mx)) then
    error("roomtypes: " .. name .. ".max is a whole number >= 0", 2)
  end
  if def.replaces ~= nil and type(def.replaces) ~= "string" then
    error("roomtypes: " .. name .. ".replaces is a type name", 2)
  end
  if def.distance ~= nil and def.distance ~= "any" and def.distance ~= "far" and def.distance ~= "near" then
    error("roomtypes: " .. name .. ".distance is \"any\", \"far\" or \"near\"", 2)
  end
  local ch = def.chance
  if ch ~= nil and type(ch) ~= "function" and (type(ch) ~= "number" or ch < 0 or ch > 1) then
    error("roomtypes: " .. name .. ".chance is 0..1 or a function", 2)
  end
  if not self.by_name[name] then self.list[#self.list + 1] = name end
  local t = {}
  for k, v in next, def do t[k] = v end      -- a copy: the order does not matter
  t.name = name
  self.by_name[name] = t
  return self
end

function Types:get(name) return self.by_name[name] end

-- The type names, in the order they were first defined.
function Types:names()
  local out = {}
  for i = 1, #self.list do out[i] = self.list[i] end
  return out
end

local function last_floor(v, total)
  if v == nil then return total end
  if v < 0 then return total + 1 + v end
  return v
end

-- How many rooms of a type floor `n` (of `total`) gets: 0 when out of its floors or when its
-- chance says no, then at most `max`. Draws from rng (an engine.rng generator) for chance and
-- ranges, in a fixed order: the same rng state gives the same answer.
function Types:count(name, n, total, rng, run)
  local t = self.by_name[name]
  if not t then error("roomtypes: unknown type " .. tostring(name), 2) end
  if n < (t.min_floor or 1) or n > last_floor(t.max_floor, total) then return 0 end
  local ch = t.chance
  if type(ch) == "function" then ch = ch(n, total, run) end
  if ch ~= nil and ch < 1 then
    if ch <= 0 or rng:float() >= ch then return 0 end
  end
  local c = t.count
  if c == nil then c = 1
  elseif type(c) == "function" then
    c = c(n, total, rng, run)
    if type(c) ~= "number" or c < 0 or c ~= floor(c) then
      error("roomtypes: " .. name .. ".count returned " .. tostring(c) .. " (a whole number >= 0)", 2)
    end
  elseif type(c) == "table" then
    c = rng:int(c[1], c[2])
  end
  if t.max ~= nil and c > t.max then c = t.max end
  return c
end

-- Checks the replaces fields: the target has to be defined, and two types may not replace each
-- other (longer chains are not handled; see the header).
local function check_replaces(self)
  for i = 1, #self.list do
    local name = self.list[i]
    local other = self.by_name[name].replaces
    if other ~= nil then
      local o = self.by_name[other]
      if not o then
        error("roomtypes: " .. name .. " replaces unknown type " .. tostring(other), 3)
      end
      if other == name then error("roomtypes: " .. name .. " replaces itself", 3) end
      if o.replaces == name then
        error("roomtypes: " .. name .. " and " .. other .. " replace each other", 3)
      end
    end
  end
end

-- The generator's `specials` for floor n of total: { { type, count, distance, min_depth }... }
-- in the order of the definitions. A type with no room on that floor stays in the list with
-- count 0, so its templates are still kept out of the ordinary rooms. Types with `replaces` are
-- evaluated before the others (each group in definition order), so their rng draws come first;
-- then an active type sets its target's count to 0. `run` is the game's table for chance/count.
function Types:specials(n, total, rng, run)
  check_replaces(self)
  local counts = {}
  for pass = 1, 2 do
    for i = 1, #self.list do
      local name = self.list[i]
      if (self.by_name[name].replaces ~= nil) == (pass == 1) then
        counts[name] = self:count(name, n, total, rng, run)
      end
    end
  end
  for i = 1, #self.list do
    local name = self.list[i]
    local other = self.by_name[name].replaces
    if other ~= nil and counts[name] > 0 then counts[other] = 0 end
  end
  local out = {}
  for i = 1, #self.list do
    local name = self.list[i]
    local t = self.by_name[name]
    out[i] = { type = name, count = counts[name], distance = t.distance or "any",
      min_depth = t.min_depth or 1 }
  end
  return out
end

-- A set in the spirit of The Binding of Isaac, to start from or to copy:
--   treasure  one per floor, anywhere, at least 2 doors from the start
--   shop      one per floor except the last, anywhere, at least 2 doors from the start
--   miniboss  from floor 2, more likely on later floors (25% on floor 2, up to 85%), far from
--             the start, at least 3 doors away
function M.defaults()
  return M.new()
    :define("treasure", { count = 1, distance = "any", min_depth = 2 })
    :define("shop", { count = 1, max_floor = -2, distance = "any", min_depth = 2 })
    :define("miniboss", { count = 1, min_floor = 2, distance = "far", min_depth = 3,
      chance = function(n, total)
        if total <= 2 then return 0.5 end
        return math.min(0.85, 0.25 + 0.6 * (n - 2) / (total - 2))
      end })
end

return M
