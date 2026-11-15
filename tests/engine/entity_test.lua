local T = ...
local Entity = require("engine.entity")
local function ids(q)
  local out = {}
  for _, e in q:each() do out[#out + 1] = e.id end
  return table.concat(out, ",")
end

local w = Entity.new()
local moving = w:query("pos", "vel")
T.check(w:query({ "vel", "pos" }) == moving, "the same question gives the same query")
local a = w:add({ pos = { x = 0 }, vel = { x = 1 } })
local b = w:add({ pos = { x = 5 } }, { "enemy" })
local c = w:add({ pos = { x = 9 }, vel = { x = -1 } }, { "enemy" })
T.check(a.id == 1 and b.id == 2 and c.id == 3 and w:get(2) == b and a.alive, "ids count up and are known at once")
T.check(moving.n == 0, "the lists wait for the flush")
w:flush()
T.check(ids(moving) == "1,3" and w:count() == 3 and w.entities[2] == b, "queries by component set")
local enemies = w:query({ "pos", tags = { "enemy" } })
T.check(ids(enemies) == "2,3", "a query made later finds what is there; tags")
local still = w:query({ "pos", without = { "vel" } })
T.check(ids(still) == "2", "without")

-- changes while walking a list
local seen = {}
for i, e in moving:each() do
  seen[#seen + 1] = e.id
  if i == 1 then
    w:remove(c)                                  -- later in this list
    w:add({ pos = { x = 1 }, vel = { x = 0 } })  -- id 4
    w:set(b, "vel", { x = 2 })
    w:unset(a, "vel")
    T.check(a.vel ~= nil and b.vel.x == 2 and not c.alive and w:get(3) == nil,
      "set and remove show at once, unset waits")
  end
end
T.check(table.concat(seen, ",") == "1" and moving.n == 2, "the list did not move; the dead one was skipped")
w:flush()
T.check(a.vel == nil and ids(moving) == "4,2" and ids(still) == "1" and ids(enemies) == "2" and w:count() == 3,
  "after the flush every list is right, in the order entities joined it")
T.check(not w:remove(c) and not pcall(w.add, w, c), "a removed entity is gone for good")
w:unset(b, "vel"); w:set(b, "vel", { x = 3 }); w:flush()
T.check(b.vel.x == 3 and moving:contains(b), "a set after an unset wins")
w:untag(b, "enemy"); w:tag(a, "enemy"); w:flush()
T.check(ids(enemies) == "1" and moving:first().id == 4, "tag and untag; first")
T.check(w:add({}).id == 5, "ids are never reused")

-- systems
local log = {}
local w2 = Entity.new()
w2:addSystem({ name = "late", order = 10, update = function() log[#log + 1] = "late" end,
  draw = function() log[#log + 1] = "draw late" end, draw_order = -1 })
w2:addSystem({ name = "move", order = 1, query = { "pos", "vel" },
  process = function(_, e, dt, world)
    e.pos.x = e.pos.x + e.vel.x * dt
    log[#log + 1] = "move " .. e.id
    if e.pos.x >= 2 then world:remove(e) end
    if e.spawns then e.spawns = nil; world:add({ pos = { x = 0 }, vel = { x = 1 } }) end
  end,
  added = function(_, e) log[#log + 1] = "+" .. e.id end,
  removed = function(_, e) log[#log + 1] = "-" .. e.id end,
  draw_entity = function(_, e, alpha) log[#log + 1] = "draw " .. e.id .. " " .. alpha end })
w2:addSystem({ name = "early", order = 1, update = function(self, dt, world)
  log[#log + 1] = "early " .. dt .. " " .. world:getSystem("move").entities.n end })
w2:addSystem({ name = "first", order = -5, update = function() log[#log + 1] = "first" end })
local e1 = w2:add({ pos = { x = 0 }, vel = { x = 2 }, spawns = true })
w2:add({ pos = { x = 0 }, vel = { x = 1 } })
w2:update(1)
T.check(table.concat(log, ";") == "+1;+2;first;move 1;move 2;-1;+3;early 1 2;late",
  "systems run in order, equal orders as added, with a flush after each: " .. table.concat(log, ";"))
T.check(not e1.alive and w2.tick == 1, "removed in a system; tick")
log = {}
w2:draw(0.5)
T.check(table.concat(log, ";") == "draw late;draw 2 0.5;draw 3 0.5", "draw order: " .. table.concat(log, ";"))
w2:getSystem("late").enabled = false
T.check(w2:removeSystem(w2:getSystem("first")) and not w2:getSystem("first"), "removeSystem")
log = {}
w2:update(1)
T.check(table.concat(log, ";") == "move 2;move 3;-2;early 1 1", "disabled and removed systems do not run: " .. table.concat(log, ";"))
w2:clear()
T.check(w2:count() == 0 and w2:getSystem("move").entities.n == 0 and w2:add({}).id == 4, "clear keeps the ids going")

-- a step allocates nothing
local w3 = Entity.new()
w3:addSystem({ query = { "pos", "vel" }, process = function(_, e, dt) e.pos.x = e.pos.x + e.vel.x * dt end })
for i = 1, 200 do w3:add({ pos = { x = i }, vel = { x = 1 } }) end
w3:update(0.016)
local q3 = w3:query("pos", "vel")
collectgarbage(); collectgarbage("stop")
local before = collectgarbage("count")
for _ = 1, 100 do w3:update(0.016); w3:draw(0) end
local n = 0
for _, e in q3:each() do n = n + e.id end
local grown = collectgarbage("count") - before
collectgarbage("restart")
T.check(grown == 0, "update, draw and each allocate nothing (" .. grown .. " KB)")
