-- engine.entity: entities made of components, queries, tags and systems. See docs/ENGINE.md.
--
-- An entity is a plain table. Its components are its fields: e.pos = { x = 1, y = 2 }. The
-- world owns three more fields: e.id (a number, never reused in this world), e.alive and
-- e.tags (a set: e.tags.enemy == true).
--
-- Data changes at once; the query lists change at the next world:flush(), which world:update
-- runs before the first system and after each one. So a system can add and remove entities,
-- components and tags while it walks a list: the list does not move under it.
--   world:add      the entity exists at once (id, world:get), and joins the lists at the flush
--   world:remove   e.alive is false at once; it leaves the lists at the flush
--   world:set      the component is there at once; the lists follow at the flush
--   world:unset    the component stays until the flush, so no list holds an entity without it
--   world:tag / world:untag   e.tags changes at once; the lists follow at the flush
-- Lists keep the order in which entities joined them, which for entities that never change
-- is the order they were added in.
local sort, concat = table.sort, table.concat

local M = {}
local World = {}
World.__index = World
local Query = {}
Query.__index = Query

local function matches(q, e)
  local need = q.need
  for i = 1, #need do
    if e[need[i]] == nil then return false end
  end
  local tags = e.tags
  local want = q.tags
  for i = 1, #want do
    if not tags[want[i]] then return false end
  end
  local without = q.without
  for i = 1, #without do
    local k = without[i]
    if e[k] ~= nil or tags[k] then return false end
  end
  return true
end

-- for i, e in query:each() do ... end: the live entities, in order. Nothing is allocated.
local function next_alive(q, i)
  local list, n = q.list, q.n
  repeat
    i = i + 1
    if i > n then return nil end
  until list[i].alive
  return i, list[i]
end
function Query:each() return next_alive, self, 0 end
function Query:count() return self.n end
function Query:first()
  local _, e = next_alive(self, 0)
  return e
end
function Query:contains(e) return self.has[e] == true end

function M.new()
  local w = setmetatable({
    next_id = 1,       -- the id of the next entity
    tick = 0,          -- updates run so far
    by_id = {},
    queries = {}, query_list = {},
    systems = {}, draw_systems = {}, system_seq = 0,
    dirty = {}, spare = {}, dirty_n = 0, queued = {},
    unset_e = {}, unset_k = {}, unset_n = 0,
    flushing = false,
  }, World)
  w.all = w:query()
  w.entities = w.all.list     -- every entity; w.all.n of them
  return w
end

local function mark(w, e)
  if not w.queued[e] then
    w.queued[e] = true
    local n = w.dirty_n + 1
    w.dirty_n = n
    w.dirty[n] = e
  end
end

-- Adds a table as an entity. tags: an optional list of names. Returns the entity.
function World:add(e, tags)
  e = e or {}
  if e.id ~= nil then error("this table is, or was, an entity already (id " .. tostring(e.id) .. ")", 2) end
  local id = self.next_id
  self.next_id = id + 1
  e.id, e.alive = id, true
  local set = {}
  if tags then
    for i = 1, #tags do set[tags[i]] = true end
  end
  e.tags = set
  self.by_id[id] = e
  mark(self, e)
  return e
end

-- Removes an entity (or the entity with that id). False if it was not alive.
function World:remove(e)
  if type(e) == "number" then e = self.by_id[e] end
  if not e or not e.alive then return false end
  e.alive = false
  self.by_id[e.id] = nil
  mark(self, e)
  return true
end

function World:get(id) return self.by_id[id] end
function World:count() return self.all.n end

-- Gives the entity a component (any value but nil; true by default) or replaces it.
function World:set(e, name, data)
  if data == nil then data = true end
  -- an unset still waiting for the flush would take the new component away
  local ue, uk = self.unset_e, self.unset_k
  for i = 1, self.unset_n do
    if ue[i] == e and uk[i] == name then ue[i] = false end
  end
  e[name] = data
  mark(self, e)
  return data
end

function World:unset(e, name)
  if e[name] == nil then return end
  local n = self.unset_n + 1
  self.unset_n = n
  self.unset_e[n], self.unset_k[n] = e, name
  mark(self, e)
end

function World:tag(e, name)
  if not e.tags[name] then
    e.tags[name] = true
    mark(self, e)
  end
end

function World:untag(e, name)
  if e.tags[name] then
    e.tags[name] = nil
    mark(self, e)
  end
end

local function notify(q, hook, e, world)
  local listeners = q.listeners
  for i = 1, #listeners do
    local s = listeners[i]
    local f = s[hook]
    if f then f(s, e, world) end
  end
end

-- Brings the query lists up to date. Do not call it while walking a list.
function World:flush()
  if self.flushing then return end
  self.flushing = true
  local queries = self.query_list
  while self.dirty_n > 0 or self.unset_n > 0 do
    local ue, uk = self.unset_e, self.unset_k
    for i = 1, self.unset_n do
      local e = ue[i]
      if e then e[uk[i]] = nil end
      ue[i], uk[i] = nil, nil
    end
    self.unset_n = 0
    -- the hooks below may queue more: they go to the other table, for the next round
    local batch, n = self.dirty, self.dirty_n
    self.dirty, self.spare, self.dirty_n = self.spare, batch, 0
    local queued = self.queued
    for i = 1, n do queued[batch[i]] = nil end
    for i = 1, n do
      local e = batch[i]
      batch[i] = nil
      local alive = e.alive
      for j = 1, #queries do
        local q = queries[j]
        local has = q.has
        if alive and matches(q, e) then
          if not has[e] then
            has[e] = true
            local k = q.n + 1
            q.n = k
            q.list[k] = e
            if q.listeners[1] then notify(q, "added", e, self) end
          end
        elseif has[e] then
          has[e] = nil
          q.stale = true
          if q.listeners[1] then notify(q, "removed", e, self) end
        end
      end
    end
    for j = 1, #queries do
      local q = queries[j]
      if q.stale then
        local list, has, k = q.list, q.has, 0
        for i = 1, q.n do
          local e = list[i]
          if has[e] then
            k = k + 1
            list[k] = e
          end
        end
        for i = k + 1, q.n do list[i] = nil end
        q.n, q.stale = k, false
      end
    end
  end
  self.flushing = false
end

local function sorted_copy(list)
  local out = {}
  for i = 1, #(list or {}) do out[i] = list[i] end
  sort(out)
  return out
end

-- world:query("pos", "vel") or world:query({ "pos", "vel", tags = { "enemy" }, without = { "frozen" } }):
-- the entities that have every component and every tag named, and no component or tag named
-- in `without`. The same question always gives the same Query object, so ask once and keep it:
-- query.list[1..query.n] is kept up to date by the world (dead entities stay in it, with
-- alive == false, until the flush; query:each() skips them).
function World:query(...)
  local spec = ...
  if type(spec) ~= "table" then spec = { ... } end
  local need, tags, without = sorted_copy(spec), sorted_copy(spec.tags), sorted_copy(spec.without)
  local key = concat(need, ",") .. "|" .. concat(tags, ",") .. "|" .. concat(without, ",")
  local q = self.queries[key]
  if q then return q end
  q = setmetatable({ key = key, need = need, tags = tags, without = without,
    list = {}, has = {}, n = 0, stale = false, listeners = {} }, Query)
  local all = self.all
  if all then
    for i = 1, all.n do
      local e = all.list[i]
      if e.alive and matches(q, e) then
        q.n = q.n + 1
        q.list[q.n] = e
        q.has[e] = true
      end
    end
  end
  self.queries[key] = q
  self.query_list[#self.query_list + 1] = q
  return q
end

local function by_order(a, b)
  if a.order ~= b.order then return a.order < b.order end
  return a._seq < b._seq
end
local function by_draw_order(a, b)
  local ao, bo = a.draw_order or a.order, b.draw_order or b.order
  if ao ~= bo then return ao < bo end
  return a._seq < b._seq
end

-- A system is a table; every field is optional:
--   name
--   order            a number: systems update lowest first; equal orders run as they were added
--   draw_order       the same for drawing (default: order)
--   query            what world:query takes; the Query is then in system.entities
--   update(self, dt, world)             once per fixed step
--   process(self, e, dt, world)         once per fixed step for each live entity of the query
--   draw(self, alpha, world)            once per frame
--   draw_entity(self, e, alpha, world)  once per frame for each live entity of the query
--   added(self, e, world), removed(self, e, world)   an entity joined or left the query (at a flush)
--   enabled          false to skip it
function World:addSystem(sys)
  if sys._seq then error("this system is already in a world", 2) end
  self.system_seq = self.system_seq + 1
  sys._seq = self.system_seq
  sys.order = sys.order or 0
  if sys.enabled == nil then sys.enabled = true end
  if sys.query then
    self:flush()
    local q = self:query(sys.query)
    sys.entities = q
    if sys.added or sys.removed then
      q.listeners[#q.listeners + 1] = sys
      if sys.added then
        for i = 1, q.n do sys:added(q.list[i], self) end
      end
    end
  end
  local systems, draws = self.systems, self.draw_systems
  systems[#systems + 1] = sys
  draws[#draws + 1] = sys
  sort(systems, by_order)
  sort(draws, by_draw_order)
  return sys
end

local function take_out(list, item)
  for i = 1, #list do
    if list[i] == item then return table.remove(list, i) end
  end
end

function World:removeSystem(sys)
  if not take_out(self.systems, sys) then return false end
  take_out(self.draw_systems, sys)
  if sys.entities then take_out(sys.entities.listeners, sys) end
  sys._seq = nil
  return true
end

function World:getSystem(name)
  local systems = self.systems
  for i = 1, #systems do
    if systems[i].name == name then return systems[i] end
  end
end

-- One fixed step: every enabled system in order, with a flush before the first and after each.
function World:update(dt)
  self:flush()
  local systems = self.systems
  for i = 1, #systems do
    local s = systems[i]
    if s.enabled then
      local f = s.update
      if f then f(s, dt, self) end
      f = s.process
      if f then
        local q = s.entities
        local list = q.list
        for j = 1, q.n do
          local e = list[j]
          if e.alive then f(s, e, dt, self) end
        end
      end
      if self.dirty_n > 0 or self.unset_n > 0 then self:flush() end
    end
  end
  self.tick = self.tick + 1
end

-- One frame: every enabled system's draw and draw_entity, in draw order. Nothing is flushed.
function World:draw(alpha)
  local systems = self.draw_systems
  for i = 1, #systems do
    local s = systems[i]
    if s.enabled then
      local f = s.draw
      if f then f(s, alpha, self) end
      f = s.draw_entity
      if f then
        local q = s.entities
        local list = q.list
        for j = 1, q.n do
          local e = list[j]
          if e.alive then f(s, e, alpha, self) end
        end
      end
    end
  end
end

-- Removes every entity. Systems and queries stay; ids go on from where they were.
function World:clear()
  local all = self.all
  for i = 1, all.n do self:remove(all.list[i]) end
  for _, e in pairs(self.by_id) do self:remove(e) end   -- added, not flushed yet
  self:flush()
end

return M
