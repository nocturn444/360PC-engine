-- engine.modules.items: weighted item pools for a run. Entries are plain data; a pool picks
-- with an engine.rng stream (for a run: streams:get("loot")), filters by the room type (or any
-- context the game passes), keeps what a run has taken, and grows with permanent unlocks.
-- A genre module: nothing in engine/ requires it and it knows nothing about a game.
-- Reference: engine/modules/items/README.md.
--
--   local items = require("engine.modules.items")
--   local pool = items.pool.new(defs.relics, { unlocked = profile.unlocks })
--   local relic = pool:draw(loot, { room = "treasure" })        -- one entry, or nil
--   local three = pool:draw_many(loot, 3, { room = "shop" })    -- distinct, for a pick 1 of 3
--   pool:take(three[choice])                                    -- the player chose it
--
-- An entry: id (unique string), weight (number >= 0, default 1), rooms (nil: any room; or an
-- array of room types it can appear in), unlock (nil, or a tag: the entry is only in the pool
-- once that tag is unlocked), max (nil: no limit; or how many times a run can take it; 1 for a
-- unique item), requires (nil, or an array of tags the context must have, e.g. an ability).
-- Anything else (name, sprite, the modifiers it gives) is the game's and is left alone.
local type, floor, tostring, sort = type, math.floor, tostring, table.sort

local M = {}
local Pool = {}
Pool.__index = Pool

local function check_entry(e, i)
  if type(e) ~= "table" then error("items: entry " .. i .. " is not a table", 4) end
  if type(e.id) ~= "string" or e.id == "" then error("items: entry " .. i .. " needs a string id", 4) end
  local where = "items: entry " .. e.id .. ": "
  if e.weight == nil then e.weight = 1 end
  if type(e.weight) ~= "number" or not (e.weight >= 0) then error(where .. "weight is a number >= 0", 4) end
  if e.rooms ~= nil and type(e.rooms) ~= "table" then error(where .. "rooms is an array of room types", 4) end
  if e.unlock ~= nil and type(e.unlock) ~= "string" then error(where .. "unlock is a tag (string)", 4) end
  if e.requires ~= nil and type(e.requires) ~= "table" then error(where .. "requires is an array of tags", 4) end
  if e.max ~= nil and (type(e.max) ~= "number" or e.max < 1 or e.max ~= floor(e.max)) then
    error(where .. "max is a whole number >= 1", 4)
  end
end

local function as_set(list)
  local set = {}
  if list == nil then return set end
  if type(list) ~= "table" then error("items: a set of tags is an array (or { tag = true })", 3) end
  for i = 1, #list do set[list[i]] = true end
  -- a { tag = true } table is accepted too; the order never matters for a set
  for k, v in next, list do
    if type(k) == "string" and v then set[k] = true end
  end
  return set
end

-- items.pool.new(entries, opts) -> pool. opts.unlocked: the permanent unlocks (array of tags,
-- or { tag = true }). The entries are checked (defaults filled in place) and kept in their
-- order, which is part of the result of every draw: keep it stable.
function M.new(entries, opts)
  if type(entries) ~= "table" then error("items: pool.new needs an array of entries", 2) end
  local self = setmetatable({ entries = {}, by_id = {}, unlocked = as_set(opts and opts.unlocked),
    taken = {}, scratch = {}, weights = {} }, Pool)
  for i = 1, #entries do self:add(entries[i], i) end
  return self
end

-- pool:add(entry): one more entry at the end (content that a permanent unlock or a mod brings)
function Pool:add(e, i)
  check_entry(e, i or (#self.entries + 1))
  if self.by_id[e.id] then error("items: two entries have the id " .. e.id, 2) end
  self.entries[#self.entries + 1] = e
  self.by_id[e.id] = e
  return e
end

-- pool:unlock(tag) / pool:is_unlocked(tag): permanent unlocks; entries with `unlock = tag`
-- join the pool. The pool does not save them: they belong to the game's permanent progress.
function Pool:unlock(tag) self.unlocked[tag] = true end
function Pool:is_unlocked(tag) return self.unlocked[tag] == true end

local function has_all(tags, set)
  for i = 1, #tags do
    if not set[tags[i]] then return false end
  end
  return true
end

local function room_ok(e, room)
  local rooms = e.rooms
  if rooms == nil then return true end
  if room == nil then return false end
  for i = 1, #rooms do
    if rooms[i] == room then return true end
  end
  return false
end

-- pool:available(entry, ctx) -> true if the entry can come out now. ctx (all optional):
--   room      the room type ("shop", "treasure", ...): entries with `rooms` need one of theirs
--   have      the tags the run has (array or { tag = true }), for `requires`
--   exclude   { [id] = true }: never these
--   filter    function(entry, ctx) -> boolean: the game's own rule
local function avail(self, e, ctx, have)
  if e.weight <= 0 then return false end
  if e.unlock and not self.unlocked[e.unlock] then return false end
  if e.max and (self.taken[e.id] or 0) >= e.max then return false end
  if not room_ok(e, ctx and ctx.room) then return false end
  if e.requires and not has_all(e.requires, have) then return false end
  if ctx then
    if ctx.exclude and ctx.exclude[e.id] then return false end
    if ctx.filter and not ctx.filter(e, ctx) then return false end
  end
  return true
end

function Pool:available(e, ctx)
  return avail(self, e, ctx, as_set(ctx and ctx.have))
end

-- The entries that can come out, and their weights (ctx.weight(entry, weight, ctx) -> number
-- changes a weight: luck, a modifier, a pity rule)
local function candidates(self, ctx)
  local list, weights = self.scratch, self.weights
  local n = 0
  local have = as_set(ctx and ctx.have)
  for i = 1, #self.entries do
    local e = self.entries[i]
    if avail(self, e, ctx, have) then
      local w = e.weight
      if ctx and ctx.weight then
        w = ctx.weight(e, w, ctx)
        if type(w) ~= "number" or not (w >= 0) then error("items: ctx.weight returns a number >= 0", 3) end
      end
      if w > 0 then
        n = n + 1
        list[n], weights[n] = e, w
      end
    end
  end
  for i = #list, n + 1, -1 do list[i] = nil; weights[i] = nil end
  return list, weights, n
end

-- pool:draw(rng, ctx) -> an entry (not taken yet: call pool:take when the player gets it), or
-- nil when nothing can come out. One rng draw when something can (none otherwise).
function Pool:draw(rng, ctx)
  local list, weights, n = candidates(self, ctx)
  if n == 0 then return nil end
  local _, i = rng:weighted(weights)
  return list[i]
end

-- pool:draw_many(rng, count, ctx) -> an array of up to `count` distinct entries (fewer when the
-- pool runs out), for a shop or a "pick 1 of N". Nothing is taken.
function Pool:draw_many(rng, count, ctx)
  ctx = ctx or {}
  local out, exclude, saved = {}, {}, ctx.exclude
  if saved then for k, v in next, saved do exclude[k] = v end end
  ctx.exclude = exclude
  for _ = 1, count do
    local e = self:draw(rng, ctx)
    if not e then break end
    out[#out + 1] = e
    exclude[e.id] = true
  end
  ctx.exclude = saved
  return out
end

-- pool:take(entry or id): the run got it (counts against `max`). pool:taken_count(id).
function Pool:take(e)
  local id = type(e) == "table" and e.id or e
  if not self.by_id[id] then error("items: no entry " .. tostring(id), 2) end
  self.taken[id] = (self.taken[id] or 0) + 1
end
function Pool:taken_count(id) return self.taken[id] or 0 end

-- pool:run_state() -> { [id] = count } (a copy, for engine.save's run in progress);
-- pool:set_run_state(t) puts it back; pool:new_run() forgets it (unlocks stay).
function Pool:run_state()
  local ids = {}
  for id in next, self.taken do ids[#ids + 1] = id end
  sort(ids)
  local out = {}
  for i = 1, #ids do out[ids[i]] = self.taken[ids[i]] end
  return out
end
function Pool:set_run_state(t)
  self.taken = {}
  for id, n in next, t or {} do
    if self.by_id[id] and type(n) == "number" and n > 0 then self.taken[id] = floor(n) end
  end
end
function Pool:new_run() self.taken = {} end

M.pool = { new = M.new }
return M
