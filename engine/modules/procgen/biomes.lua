-- procgen.biomes: the run's path through biomes. A biome lasts 1 to 3 floors (or any span the
-- game gives); some are fixed (the first one, the last one, or at a given floor) and the rest
-- are chosen when the previous biome ends: at random by weight, only once unlocked, or only
-- when the run so far allows it (what the player did). Data only: what a biome changes (its
-- templates, room types, size, colours, enemies) is read by procgen.floors and by the game.
--
--   local biomes = procgen.biomes.new({
--     { id = "cellar", span = 2, fixed = "first" },
--     { id = "caves", span = { 1, 3 }, weight = 3 },
--     { id = "garden", span = 2, unlock = "found_seed" },               -- after a permanent unlock
--     { id = "ruins", span = 1, when = function(run) return run.flags.spared_guard end },
--     { id = "core", span = 1, fixed = "last" },
--   }, { floors = 10, unlocked = profile.unlocks })
--   local path = biomes:path()                       -- one per run
--   local b = path:enter(n, run_state, run.streams:get("biomes"))   -- floor n's biome
--
-- The choice of the next biome is made when its first floor is entered, so it can depend on
-- the run; with the same rng state, run state and unlocks, it is the same on every platform.
local type, floor, tostring = type, math.floor, tostring

local M = {}
local Set = {}
Set.__index = Set
local Path = {}
Path.__index = Path

local function span_of(b)
  local s = b.span or 1
  if type(s) == "number" then return s, s end
  return s[1], s[2]
end

-- biomes.new(list, opts). Each biome:
--   id          unique string
--   span        floors it lasts: a number (1) or { min, max }
--   fixed       "first", "last", or a floor number where it always starts
--   weight      for the random choice among the variable ones (1); 0 never picked
--   unlock      a tag: only once unlocked (opts.unlocked, set:unlock(tag))
--   when        function(run, path) -> boolean: only when the run allows it (what was done)
--   after       array of biome ids: only right after one of them (alternative paths)
--   min_floor, max_floor   the floors where it may start
--   once        false lets a variable biome come back in the same run (default true: once)
--   anything else is the game's (templates tag, palette, music, enemy set, rooms_add...)
-- opts.floors: floors in a run (10). opts.unlocked: tags unlocked for good ({ tag = true } or array).
function M.new(list, opts)
  opts = opts or {}
  if type(list) ~= "table" or #list == 0 then error("biomes: a non-empty array of biomes", 2) end
  local self = setmetatable({ list = {}, by_id = {}, floors = opts.floors or 10, unlocked = {} }, Set)
  for i = 1, #list do
    local b = list[i]
    if type(b) ~= "table" or type(b.id) ~= "string" then error("biomes: biome " .. i .. " needs an id", 2) end
    if self.by_id[b.id] then error("biomes: two biomes are called " .. b.id, 2) end
    local lo, hi = span_of(b)
    if type(lo) ~= "number" or type(hi) ~= "number" or lo < 1 or hi < lo or lo ~= floor(lo) or hi ~= floor(hi) then
      error("biomes: " .. b.id .. ".span is a whole number >= 1 or { min, max }", 2)
    end
    if b.fixed ~= nil and b.fixed ~= "first" and b.fixed ~= "last" and type(b.fixed) ~= "number" then
      error("biomes: " .. b.id .. ".fixed is \"first\", \"last\" or a floor number", 2)
    end
    self.list[i] = b
    self.by_id[b.id] = b
  end
  local u = opts.unlocked or {}
  for k, v in next, u do
    if type(k) == "number" then self.unlocked[v] = true elseif v then self.unlocked[k] = true end
  end
  return self
end

function Set:unlock(tag) self.unlocked[tag] = true end
function Set:get(id) return self.by_id[id] end

-- A new path for one run.
function Set:path()
  return setmetatable({ set = self, steps = {}, current = nil, used = {} }, Path)
end

local function fixed_at(set, n, total)
  for i = 1, #set.list do
    local b = set.list[i]
    if (b.fixed == "first" and n == 1) or b.fixed == n then return b end
  end
  return nil
end

local function last_biome(set)
  for i = 1, #set.list do if set.list[i].fixed == "last" then return set.list[i] end end
  return nil
end

-- The floor where the next fixed biome (other than "first") starts after floor n, or nil.
local function next_fixed(set, n, total)
  local best
  for i = 1, #set.list do
    local b = set.list[i]
    local at = b.fixed
    if at == "last" then
      local lo = span_of(b)
      at = total - lo + 1
    end
    if type(at) == "number" and at > n and (not best or at < best) then best = at end
  end
  return best
end

-- Draws a span for b that fits in `room` floors; nil when it cannot fit.
local function draw_span(b, room, rng)
  local lo, hi = span_of(b)
  if lo > room then return nil end
  if hi > room then hi = room end
  if lo == hi then return lo end
  return rng:int(lo, hi)
end

-- Can `left` floors be filled with biomes of `pool` (each at most once, any span of theirs)?
local function fillable(pool, left, skip)
  if left == 0 then return true end
  local reach = { [0] = true }
  for i = 1, #pool do
    local b = pool[i]
    if b ~= skip then
      local lo, hi = span_of(b)
      local nxt = {}
      for v = 0, left do
        if reach[v] then
          nxt[v] = true
          for k = lo, hi do if v + k <= left then nxt[v + k] = true end end
        end
      end
      reach = nxt
    end
  end
  return reach[left] == true
end

-- The biomes that could start on floor n now (for a menu of choices or a preview), with how
-- many floors are left before the next fixed biome. run: the game's run state for `when`.
-- reuse: true also lists biomes this run already went through.
function Path:candidates(n, run, reuse)
  local set, total = self.set, self.set.floors
  local stop = next_fixed(set, n - 1, total) or (total + 1)
  local room = stop - n
  local prev = self.current and self.current.biome.id
  local out = {}
  for i = 1, #set.list do
    local b = set.list[i]
    local lo = span_of(b)
    local ok = b.fixed == nil and (b.weight == nil or b.weight > 0) and lo <= room
      and n >= (b.min_floor or 1) and n <= (b.max_floor or total)
      and (b.unlock == nil or set.unlocked[b.unlock])
      and (reuse or b.once == false or not self.used[b.id])
    if ok and b.after then
      ok = false
      for j = 1, #b.after do if b.after[j] == prev then ok = true end end
    end
    if ok and b.when then ok = b.when(run, self) and true or false end
    if ok then out[#out + 1] = b end
  end
  return out, room
end

-- The biome of floor n. Floors are entered in order (1, 2, 3...; entering the same floor again
-- gives the same answer). When the current biome is over, the next one is decided here: the
-- fixed one for this floor if any, otherwise a variable one by weight among the candidates
-- (forced = an id picks that one instead, if it is a candidate: a choice the player made).
-- Returns the biome table; path.current = { biome, first, last } (its floors).
function Path:enter(n, run, rng, forced)
  local set, total = self.set, self.set.floors
  if type(n) ~= "number" or n < 1 or n > total or n ~= floor(n) then
    error("biomes: floor " .. tostring(n) .. " is not 1 to " .. total, 2)
  end
  local cur = self.current
  if cur and n >= cur.first and n <= cur.last then return cur.biome end
  if cur and n ~= cur.last + 1 then error("biomes: floors are entered in order (expected " .. (cur.last + 1) .. ")", 2) end
  if not cur and n ~= 1 then error("biomes: the first floor entered is 1", 2) end
  local b = fixed_at(set, n, total)
  local last = last_biome(set)
  if not b and last then
    local lo = span_of(last)
    if n == total - lo + 1 then b = last end
  end
  local span
  if b then
    local stop = next_fixed(set, n, total) or (total + 1)
    span = draw_span(b, stop - n, rng) or span_of(b)
  else
    -- every (biome, span) that leaves a gap the other free biomes can still fill (those
    -- without `when` or `after`, which may not be possible later); if none, biomes already
    -- used may come back
    local function options_for(reuse, only)
      local list, room = self:candidates(n, run, reuse)
      local plain = {}
      for i = 1, #set.list do
        local x = set.list[i]
        if x.fixed == nil and not x.when and not x.after and (x.weight == nil or x.weight > 0)
          and (x.unlock == nil or set.unlocked[x.unlock]) and (reuse or x.once == false or not self.used[x.id]) then
          plain[#plain + 1] = x
        end
      end
      local out = {}
      for i = 1, #list do
        local x = list[i]
        if not only or x.id == only then
          local lo, hi = span_of(x)
          if hi > room then hi = room end
          local ok = {}
          for k = lo, hi do if fillable(plain, room - k, x) then ok[#ok + 1] = k end end
          for j = 1, #ok do out[#out + 1] = { biome = x, span = ok[j], w = (x.weight or 1) / #ok } end
        end
      end
      return out, room
    end
    -- every (biome, span) that leaves a gap the other free biomes can still fill (those
    -- without `when` or `after`, which may not be possible later); a forced id first; if
    -- nothing fits, biomes already used may come back
    local options, room
    if forced then options, room = options_for(false, forced) end
    if not options or #options == 0 then options, room = options_for(false) end
    if #options == 0 then options, room = options_for(true) end
    if #options == 0 then
      error("biomes: no biome can start on floor " .. n .. " (" .. room .. " floors to fill)", 2)
    end
    local pick = rng:weighted(options, "w")
    b, span = pick.biome, pick.span
  end
  self.current = { biome = b, first = n, last = math.min(total, n + span - 1) }
  self.used[b.id] = true
  self.steps[#self.steps + 1] = { id = b.id, first = n, last = self.current.last }
  return b
end

-- The path so far as plain data for engine.save ({ { id, first, last }... }), and back.
function Path:state()
  local out = {}
  for i = 1, #self.steps do
    local s = self.steps[i]
    out[i] = { id = s.id, first = s.first, last = s.last }
  end
  return out
end

function Path:set_state(steps)
  self.steps, self.used, self.current = {}, {}, nil
  for i = 1, #(steps or {}) do
    local s = steps[i]
    local b = self.set.by_id[s.id]
    if not b then return false, "unknown biome " .. tostring(s.id) end
    self.steps[i] = { id = s.id, first = s.first, last = s.last }
    self.used[s.id] = true
    self.current = { biome = b, first = s.first, last = s.last }
  end
  return true
end

return M
