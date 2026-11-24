-- engine.modules.progress.counters: what a run (or a floor) did, as named numbers and named
-- sets of ids. The game picks the names ("kills", "kills:shooter", "items", "rooms"...); a
-- missing number reads as 0 and a missing set is empty. add / set / mark / has / get allocate
-- nothing once their tables exist, so they are safe on a kill or a pickup.
-- Reference: engine/modules/progress/README.md.
--
--   local run = progress.counters.new()
--   run:add("kills", 1)
--   run:mark("items", "spring_heel")
--   if run:has("items", "spring_heel") then ... end
local type = type
local next = next

local M = {}
local Counters = {}
Counters.__index = Counters

local function check_key(key)
  if type(key) ~= "string" or key == "" then
    error("progress.counters: a counter key is a non-empty string", 4)
  end
end

local function check_number(n)
  if type(n) ~= "number" then error("progress.counters: a counter value is a number", 4) end
end

local function check_set(name)
  if type(name) ~= "string" or name == "" then
    error("progress.counters: a set name is a non-empty string", 4)
  end
end

-- counters.new() -> a new, empty counters object.
function M.new()
  return setmetatable({ numbers = {}, sets = {} }, Counters)
end

-- counters:add(key, n) -> the new value. A missing counter starts at 0.
function Counters:add(key, n)
  check_key(key)
  check_number(n)
  local value = (self.numbers[key] or 0) + n
  self.numbers[key] = value
  return value
end

-- counters:set(key, n) -> n. Replaces a counter, for values the game knows ("floor", "depth").
function Counters:set(key, n)
  check_key(key)
  check_number(n)
  self.numbers[key] = n
  return n
end

-- counters:get(key) -> the value, or 0 when the counter was never set.
function Counters:get(key)
  return self.numbers[key] or 0
end

-- counters:mark(set, id): adds an id to a named set (items held, rooms visited...). The set is
-- created the first time; after that marking an id that is already there allocates nothing.
function Counters:mark(set, id)
  check_set(set)
  local ids = self.sets[set]
  if ids == nil then
    ids = {}
    self.sets[set] = ids
  end
  ids[id] = true
end

-- counters:has(set, id) -> true when the named set holds the id.
function Counters:has(set, id)
  local ids = self.sets[set]
  return ids ~= nil and ids[id] == true
end

-- counters:count(set) -> how many ids the named set holds (0 when it does not exist).
function Counters:count(set)
  local ids = self.sets[set]
  if ids == nil then return 0 end
  local n = 0
  for _ in next, ids do n = n + 1 end
  return n
end

-- counters:reset(): a new run (or floor): clears the same tables instead of making new ones.
function Counters:reset()
  for key in next, self.numbers do self.numbers[key] = nil end
  for set in next, self.sets do self.sets[set] = nil end
  return self
end

-- counters:state() -> a plain table (numbers and sets) for a run save.
function Counters:state()
  local numbers = {}
  for key, value in next, self.numbers do numbers[key] = value end
  local sets = {}
  for set, ids in next, self.sets do
    local copy = {}
    for id, value in next, ids do copy[id] = value end
    sets[set] = copy
  end
  return { numbers = numbers, sets = sets }
end

-- counters:set_state(t) puts a saved state back. A malformed entry is ignored, so a save from
-- another version still loads; the rest of the state is replaced, not merged.
function Counters:set_state(t)
  if type(t) ~= "table" then error("progress.counters: set_state needs a table", 2) end
  self:reset()
  local numbers = t.numbers
  if type(numbers) == "table" then
    for key, value in next, numbers do
      if type(key) == "string" and type(value) == "number" then self.numbers[key] = value end
    end
  end
  local sets = t.sets
  if type(sets) == "table" then
    for set, ids in next, sets do
      if type(set) == "string" and type(ids) == "table" then
        local copy = {}
        for id, value in next, ids do
          if value then copy[id] = true end
        end
        self.sets[set] = copy
      end
    end
  end
  return self
end

return M
