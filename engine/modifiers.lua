-- engine.modifiers: modifiers defined as data, the stats they change and the events they hear.
-- See docs/ENGINE.md. Nothing here knows what a stat or an event means: the game names them.
--
--   local mods = modifiers.new()                       -- the registry: definitions, events, stats
--   mods:define({ id = "swift", stats = { { "speed", "mul_base", 0.25 } } })
--   local set = mods:attach(entity, { speed = 90 })    -- one entity's modifiers and base stats
--   set:add("swift"); set:get("speed")                 --> 112.5
--
-- Stat evaluation, always in this order (see compute below):
--   1. base       set:setBase, else the stat's declared base, else 0
--   2. add        base + sum(value * stacks)
--   3. mul_base   * (1 + sum(value * stacks))
--   4. mul        * product(value ^ stacks)
--   5. set        replaces the result of 1-4: the highest priority wins, then the largest value
--   6. min, max   raised to the largest "min", then lowered to the smallest "max"
--   7. the stat's declared min and max
--
-- A modifier never rewrites another: a handler gets (entity, ctx, modifier) where modifier is a
-- read-only view of its own instance (id, name, stacks, time, duration, and state, a table of
-- its own to keep counters in). No call gives it another modifier's instance.
local sort, remove = table.sort, table.remove

local M = {}
local Registry = {}
Registry.__index = Registry
local Set = {}
Set.__index = Set

local OPS = { add = true, mul_base = true, mul = true, set = true, min = true, max = true }
local STACKING = { unique = true, stack = true, refresh = true }
local COMBINE = { none = true, chain = true, sum = true, any = true, all = true }
local NO_EVENTS = {}
local EPS = 1e-9       -- a timer this close to zero has run out (30 steps of 1/60 are 0.5 s)

function M.new()
  local r = setmetatable({ defs = {}, events = {}, stats = {} }, Registry)
  r:event("on_jump")
  r:event("on_attack")
  r:event("on_hit", { combine = "chain", field = "amount", min = 0 })
  r:event("on_damaged", { combine = "chain", field = "amount", min = 0 })
  r:event("on_kill")
  r:event("on_update")
  return r
end

-- Declares how an event combines what its handlers return (events not declared are "none"):
--   "none"    returns are ignored
--   "chain"   ctx[field] goes through the handlers: a return that is not nil replaces it;
--             emit returns the last value (not below `min` or above `max`, if given)
--   "sum"     emit returns the sum of the numbers returned
--   "any"     emit returns true if a handler returned a true value
--   "all"     emit returns false if a handler returned false
function Registry:event(name, opts)
  opts = opts or {}
  local combine = opts.combine or "none"
  if not COMBINE[combine] then error("unknown event combination " .. tostring(combine), 2) end
  if combine == "chain" and not opts.field then error("a chain event needs a field", 2) end
  self.events[name] = { combine = combine, field = opts.field, min = opts.min, max = opts.max }
end

-- Optional: a stat's default base and its hard limits. opts: base, min, max.
function Registry:stat(name, opts)
  opts = opts or {}
  self.stats[name] = { base = opts.base, min = opts.min, max = opts.max }
end

-- def (only id is required):
--   id, name, tags = { "curse", ... }
--   stats = { { stat, op, value }, ... }   op: add, mul_base, mul, set, min, max
--   events = { on_jump = function(entity, ctx, modifier) ... end, ... }
--            also on_add and on_remove, which only this modifier hears
--   priority    a number, default 0: higher hears events first
--   stacking    "unique" (default: adding it again does nothing), "stack" (adds stacks, up to
--               max_stacks) or "refresh" (one stack; adding it again restarts its timer)
--   max_stacks  for "stack"; default: no limit
--   duration    seconds; default: it stays. Adding a "stack" or "refresh" modifier again
--               restarts the timer; the whole modifier goes when it runs out.
function Registry:define(def)
  local id = def.id
  if id == nil then error("a modifier needs an id", 2) end
  if self.defs[id] then error("modifier " .. tostring(id) .. " is already defined", 2) end
  local stacking = def.stacking or "unique"
  if not STACKING[stacking] then error("unknown stacking rule " .. tostring(stacking), 2) end
  local c = { def = def, id = id, name = def.name or id, priority = def.priority or 0,
    stacking = stacking, max_stacks = stacking == "stack" and def.max_stacks or nil,
    duration = def.duration, events = def.events or NO_EVENTS, tags = {}, by_stat = {} }
  for _, tag in ipairs(def.tags or {}) do c.tags[tag] = true end
  for _, entry in ipairs(def.stats or {}) do
    local stat, op, value = entry[1] or entry.stat, entry[2] or entry.op, entry[3] or entry.value
    if not OPS[op] then error("modifier " .. tostring(id) .. ": unknown stat operation " .. tostring(op), 2) end
    if type(value) ~= "number" then error("modifier " .. tostring(id) .. ": the value of " .. tostring(stat) .. " must be a number", 2) end
    local ops = c.by_stat[stat]
    if not ops then ops = {}; c.by_stat[stat] = ops end
    ops[#ops + 1] = op
    ops[#ops + 1] = value
  end
  self.defs[id] = c
  return def
end

function Registry:defineAll(list)
  for _, def in ipairs(list) do self:define(def) end
end

-- The definition table given to define, or nil.
function Registry:get(id)
  local c = self.defs[id]
  return c and c.def
end

-- A modifier set for one owner (an entity, or anything: handlers get it as their first
-- argument). base: optional { stat = value }.
function Registry:attach(owner, base)
  local set = setmetatable({
    reg = self, owner = owner,
    version = 0,       -- goes up whenever a stat may have changed
    evals = 0,         -- stats computed so far (the rest came from the cache)
    _base = {}, _cache = {}, _list = {}, _by_id = {}, _seq = 0, _depth = 0,
    _queue = {}, _queue_n = 0, _flushing = false,
    _life = {}, _update = {},
  }, Set)
  for stat, v in pairs(base or {}) do set._base[stat] = v end
  return set
end

local function read_only()
  error("a modifier's view is read-only: keep its data in modifier.state", 2)
end

local function invalidate(self)
  local cache = self._cache
  for k in pairs(cache) do cache[k] = nil end
  self.version = self.version + 1
end

local function new_instance(c, seq, stacks, time, state)
  local data = { id = c.id, name = c.name, stacks = stacks, time = time, duration = time, state = state or {} }
  return { c = c, seq = seq, data = data,
    view = setmetatable({}, { __index = data, __newindex = read_only, __metatable = "read-only" }) }
end

local function by_priority(a, b)
  if a.c.priority ~= b.c.priority then return a.c.priority > b.c.priority end
  return a.seq < b.seq
end

local flush_queue

-- on_add / on_remove: heard by that modifier only. What it adds or removes meanwhile waits.
local function lifecycle(self, inst, name, reason)
  local h = inst.c.events[name]
  if not h then return end
  local ctx = self._life
  ctx.reason, ctx.stacks = reason, inst.data.stacks
  self._depth = self._depth + 1
  h(self.owner, ctx, inst.view)
  self._depth = self._depth - 1
  if self._depth == 0 and self._queue_n > 0 then flush_queue(self) end
end

local function drop(self, inst, reason)
  local list = self._list
  for i = 1, #list do
    if list[i] == inst then remove(list, i); break end
  end
  self._by_id[inst.c.id] = nil
  invalidate(self)
  lifecycle(self, inst, "on_remove", reason)
end

local function queue(self, op, id, a, b)
  local q, n = self._queue, self._queue_n
  q[n + 1], q[n + 2], q[n + 3], q[n + 4] = op, id, a or false, b or false
  self._queue_n = n + 4
end

flush_queue = function(self)
  if self._flushing then return end
  self._flushing = true
  local q, i = self._queue, 1
  while i <= self._queue_n do
    local op, id, a, b = q[i], q[i + 1], q[i + 2] or nil, q[i + 3] or nil
    i = i + 4
    if op == "add" then self:add(id, a, b)
    elseif op == "remove" then self:remove(id, a)
    else self:removeTagged(id) end
  end
  for j = 1, self._queue_n do q[j] = nil end
  self._queue_n = 0
  self._flushing = false
end

-- Gives the owner a modifier. stacks (default 1) and duration (default: the definition's) are
-- optional. Returns true if something changed, false if a "unique" one was already there, and
-- nil if it was called from a handler: then it is done when the event is over.
function Set:add(id, stacks, duration)
  local c = self.reg.defs[id]
  if not c then error("no modifier with the id " .. tostring(id), 2) end
  if self._depth > 0 then queue(self, "add", id, stacks, duration); return nil end
  stacks = stacks or 1
  local time = duration or c.duration
  local inst = self._by_id[id]
  if inst then
    if c.stacking == "unique" then return false end
    local d = inst.data
    local reason = "refresh"
    if c.stacking == "stack" then
      local s = d.stacks + stacks
      if c.max_stacks and s > c.max_stacks then s = c.max_stacks end
      if s ~= d.stacks then
        d.stacks = s
        reason = "stack"
        invalidate(self)
      end
    end
    if time then d.time, d.duration = time, time end
    lifecycle(self, inst, "on_add", reason)
    return true
  end
  if c.stacking ~= "stack" then stacks = 1
  elseif c.max_stacks and stacks > c.max_stacks then stacks = c.max_stacks end
  self._seq = self._seq + 1
  inst = new_instance(c, self._seq, stacks, time)
  -- after the last one of the same or a higher priority
  local list = self._list
  local at = #list + 1
  while at > 1 and list[at - 1].c.priority < c.priority do at = at - 1 end
  table.insert(list, at, inst)
  self._by_id[id] = inst
  invalidate(self)
  lifecycle(self, inst, "on_add", "new")
  return true
end

-- Takes `stacks` stacks away, or the whole modifier (no stacks given, or none left).
function Set:remove(id, stacks)
  if self._depth > 0 then queue(self, "remove", id, stacks); return nil end
  local inst = self._by_id[id]
  if not inst then return false end
  local d = inst.data
  if stacks and stacks < d.stacks then
    d.stacks = d.stacks - stacks
    invalidate(self)
    return true
  end
  drop(self, inst, "remove")
  return true
end

-- Removes every modifier with that tag. Returns how many.
function Set:removeTagged(tag)
  if self._depth > 0 then queue(self, "tagged", tag); return nil end
  local list, n, i = self._list, 0, 1
  while i <= #list do
    local inst = list[i]
    if inst.c.tags[tag] then
      drop(self, inst, "remove")
      n = n + 1
      i = 1      -- on_remove may have changed the list
    else
      i = i + 1
    end
  end
  return n
end

function Set:has(id) return self._by_id[id] ~= nil end
function Set:stacks(id)
  local inst = self._by_id[id]
  return inst and inst.data.stacks or 0
end
-- Seconds left, or nil (it is not there, or it has no timer).
function Set:timeLeft(id)
  local inst = self._by_id[id]
  return inst and inst.data.time or nil
end
function Set:count() return #self._list end
function Set:hasTag(tag)
  local list = self._list
  for i = 1, #list do
    if list[i].c.tags[tag] then return true end
  end
  return false
end
-- The ids, in the order events reach them (a new table: not for every step).
function Set:ids()
  local out = {}
  for i, inst in ipairs(self._list) do out[i] = inst.c.id end
  return out
end

function Set:setBase(stat, value)
  if self._base[stat] ~= value then
    self._base[stat] = value
    invalidate(self)
  end
end
function Set:getBase(stat)
  local v = self._base[stat]
  if v == nil then
    local decl = self.reg.stats[stat]
    v = decl and decl.base or 0
  end
  return v
end

local function compute(self, stat)
  local decl = self.reg.stats[stat]
  local base = self._base[stat]
  if base == nil then base = decl and decl.base or 0 end
  local add, pct, mul = 0, 0, 1
  local set_v, set_p, lo, hi
  local list = self._list
  for i = 1, #list do
    local inst = list[i]
    local ops = inst.c.by_stat[stat]
    if ops then
      local stacks = inst.data.stacks
      for j = 1, #ops, 2 do
        local op, v = ops[j], ops[j + 1]
        if op == "add" then add = add + v * stacks
        elseif op == "mul_base" then pct = pct + v * stacks
        elseif op == "mul" then
          for _ = 1, stacks do mul = mul * v end
        elseif op == "set" then
          local p = inst.c.priority
          if set_v == nil or p > set_p or (p == set_p and v > set_v) then set_v, set_p = v, p end
        elseif op == "min" then
          if lo == nil or v > lo then lo = v end
        else
          if hi == nil or v < hi then hi = v end
        end
      end
    end
  end
  local v = (base + add) * (1 + pct) * mul
  if set_v ~= nil then v = set_v end
  if lo and v < lo then v = lo end
  if hi and v > hi then v = hi end
  if decl then
    if decl.min and v < decl.min then v = decl.min end
    if decl.max and v > decl.max then v = decl.max end
  end
  return v
end

-- The stat's value with every modifier applied. Computed once, then kept until a modifier,
-- a stack count or a base changes.
function Set:get(stat)
  local v = self._cache[stat]
  if v == nil then
    v = compute(self, stat)
    self._cache[stat] = v
    self.evals = self.evals + 1
  end
  return v
end

-- Sends an event to every modifier that has a handler for it: higher priority first, then in
-- the order they were acquired. Handlers are called as handler(owner, ctx, modifier), once
-- whatever the stacks (modifier.stacks tells). Returns what the event's combination says.
function Set:emit(name, ctx)
  local ev = self.reg.events[name]
  local mode = ev and ev.combine or "none"
  local field = ev and ev.field
  local list, owner = self._list, self.owner
  local acc
  if mode == "sum" then acc = 0 elseif mode == "any" then acc = false elseif mode == "all" then acc = true end
  self._depth = self._depth + 1
  for i = 1, #list do
    local inst = list[i]
    local h = inst.c.events[name]
    if h then
      local r = h(owner, ctx, inst.view)
      if mode == "chain" then
        if r ~= nil then ctx[field] = r end
      elseif mode == "sum" then
        if r then acc = acc + r end
      elseif mode == "any" then
        if r then acc = true end
      elseif mode == "all" then
        if r == false then acc = false end
      end
    end
  end
  self._depth = self._depth - 1
  if self._depth == 0 and self._queue_n > 0 then flush_queue(self) end
  if mode == "chain" then
    local v = ctx[field]
    if v ~= nil then
      if ev.min and v < ev.min then v = ev.min; ctx[field] = v end
      if ev.max and v > ev.max then v = ev.max; ctx[field] = v end
    end
    return v
  end
  return acc
end

-- One fixed step: runs the timers (a modifier whose time is up goes, with on_remove and
-- ctx.reason == "expire"), then sends on_update with ctx.dt.
function Set:update(dt)
  local list = self._list
  self._depth = self._depth + 1
  local i = 1
  while i <= #list do
    local inst = list[i]
    local d = inst.data
    local t = d.time
    if t then
      t = t - dt
      if t <= EPS then
        d.time = 0
        remove(list, i)
        self._by_id[inst.c.id] = nil
        invalidate(self)
        lifecycle(self, inst, "on_remove", "expire")
      else
        d.time = t
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  self._depth = self._depth - 1
  if self._depth == 0 and self._queue_n > 0 then flush_queue(self) end
  local ctx = self._update
  ctx.dt = dt
  self:emit("on_update", ctx)
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

-- A plain table (numbers, strings, booleans and tables of them) for a save: the bases and, for
-- each modifier, its id, stacks, time left and state. Keep only plain data in modifier.state.
function Set:serialize()
  local out = { seq = self._seq, base = copy(self._base), mods = {} }
  for i, inst in ipairs(self._list) do
    local d = inst.data
    out.mods[i] = { id = d.id, stacks = d.stacks, time = d.time, duration = d.duration, seq = inst.seq,
      state = next(d.state) ~= nil and copy(d.state) or nil }
  end
  return out
end

-- Puts back what serialize gave, replacing what the set holds. No on_add is sent: nothing is
-- acquired. Returns nil, or the list of ids that are not defined any more (they are skipped).
function Set:restore(data)
  local list, by_id = {}, {}
  local missing
  for _, m in ipairs(data.mods or {}) do
    local c = self.reg.defs[m.id]
    if c then
      local inst = new_instance(c, m.seq, m.stacks or 1, m.time, copy(m.state))
      inst.data.duration = m.duration or m.time
      list[#list + 1] = inst
      by_id[m.id] = inst
    else
      missing = missing or {}
      missing[#missing + 1] = m.id
    end
  end
  sort(list, by_priority)
  self._list, self._by_id = list, by_id
  self._base = copy(data.base or {})
  self._seq = data.seq or #list
  invalidate(self)
  return missing
end

-- A system for engine.entity that updates the modifier set every entity keeps in the
-- component `component` (default "mods"): world:addSystem(modifiers.system()).
function M.system(component, order)
  component = component or "mods"
  return { name = "modifiers", order = order or 0, query = { component },
    process = function(_, e, dt) e[component]:update(dt) end }
end

return M
