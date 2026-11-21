-- procgen.generator: builds a map from room templates, one room at a time, so the work can be
-- spread over frames. generator.generate(opts) runs it to the end in one call; both give the
-- same map for the same rng state, because the budget only decides where the work pauses.
--
-- opts:
--   templates  array of templates (procgen.templates) or a set from templates.new
--   rng        an engine.rng generator (for a run: streams:get("level")); or seed = number/string
--   rooms      rooms in the map, start and boss included (default 12)
--   abilities  array of ability tags, in the order the player finds them (default none).
--              The map is cut into #abilities + 1 zones; the door into zone k needs abilities[k],
--              and the item of abilities[k] is in a zone before it.
--   types      optional { type = weight }: how often each room type is picked for the filler
--              rooms (then a template of that type by its weight). Default: every template that
--              is not "start", "boss" or an item room, by its weight.
--   loops      true (default): neighbour rooms of the same zone whose exits face each other are
--              joined, which makes loops; false keeps the map a tree.
--   branching  0 to 1 (default 0.5): how much the filler rooms avoid the gaps between rooms
--              that are already on the map. 0 is the old uniform pick among the open exits;
--              higher values make open exits that grow outward win over the ones that would
--              fill a gap, so the map spreads into separate branches instead of a compact
--              block. 1 never fills a gap while another open exit is free.
--   attempts   tries before giving up (default 50); each try goes on drawing from the same rng.
--   check      optional function(map) -> true or false, message: the game's own rule; a map it
--              refuses is thrown away and tried again.
--   specials   optional array of { type, count = 1, distance = "any" | "far" | "near",
--              min_depth = 1 }: special rooms (a shop, a treasure room, a miniboss...) placed
--              after the other rooms, before the boss, each one a dead end that loops never
--              join. Templates of those types are never used as filler rooms. distance picks
--              the open exits by how many doors they are from the start (far: the deepest ones;
--              near: the closest ones), falling back to any exit; min_depth is the fewest doors
--              between the start and the special room. Specials count in `rooms`.
--              A count of 0 places none but still keeps the type's templates out of the
--              filler. procgen.roomtypes builds this list from modular room type definitions.
--   boss_distance  optional "far": the boss goes behind one of the deepest open exits
--              (default: any open exit of the last zone).
--
-- generator.new(opts) -> gen. gen:step(ops) does at most `ops` operations (one operation is one
-- room placed or tried) and returns true when finished. Then gen.map is the map, or nil and
-- gen.error says why. gen.ops counts the operations done.
local templates = require((...):gsub("generator$", "templates"))
local graph = require((...):gsub("generator$", "graph"))
local map_mod = require((...):gsub("generator$", "map"))
local Rng = require("engine.rng")

local type, floor, sort = type, math.floor, table.sort
local co_create, co_resume, co_yield, co_status = coroutine.create, coroutine.resume, coroutine.yield, coroutine.status

local M = {}

local OFF, SPAN = 4096, 8192
local function key(x, y) return (x + OFF) * SPAN + (y + OFF) end

local NEAR = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- The tags a door needs: those of both exits and the zone lock, sorted, without repeats
local function door_tags(e1, e2, lock)
  local list, seen = {}, {}
  local function add(t)
    if not seen[t] then seen[t] = true; list[#list + 1] = t end
  end
  for i = 1, #e1.requires do add(e1.requires[i]) end
  if e2 then for i = 1, #e2.requires do add(e2.requires[i]) end end
  if lock then add(lock) end
  sort(list)
  return list
end

local function pools(set, opts)
  local start, boss, item, filler, by_type, special = {}, {}, {}, {}, {}, {}
  local special_type = {}
  for i = 1, #(opts.specials or {}) do special_type[opts.specials[i].type] = true end
  for i = 1, #set.list do
    local t = set.list[i]
    if t.weight > 0 then
      if t.type == "start" then start[#start + 1] = t
      elseif t.type == "boss" then boss[#boss + 1] = t
      elseif special_type[t.type] then
        local list = special[t.type]
        if not list then list = {}; special[t.type] = list end
        list[#list + 1] = t
      elseif t.item then item[#item + 1] = t
      else
        filler[#filler + 1] = t
        local bt = by_type[t.type]
        if not bt then bt = {}; by_type[t.type] = bt end
        bt[#bt + 1] = t
      end
    end
  end
  local types
  if opts.types then
    types = {}
    for i = 1, #set.types do                 -- in the order of the templates, never pairs()
      local name = set.types[i]
      local w = opts.types[name]
      if w and w > 0 and by_type[name] then types[#types + 1] = { name = name, weight = w } end
    end
    if #types == 0 then error("procgen: no template has a type of opts.types", 3) end
  end
  for i = 1, #(opts.specials or {}) do
    local sp = opts.specials[i]
    if (sp.count or 1) > 0 and not special[sp.type] then
      error("procgen: no template has the special type \"" .. tostring(sp.type) .. "\"", 3)
    end
  end
  return { start = start, boss = boss, item = item, filler = filler, by_type = by_type, types = types,
    special = special }
end

-- One try. Returns the map, or nil and why.
local function attempt(g)
  local opts, set, P, rng = g.opts, g.set, g.pools, g.rng
  local branching = opts.branching or 0
  local abilities = g.abilities
  local zones = #abilities + 1
  local rooms, doors, cells, frontier = {}, {}, {}, {}
  local m = map_mod.new(rooms, doors, abilities)

  local function tick()
    g.ops = g.ops + 1
    g.budget = g.budget - 1
    if g.budget <= 0 then co_yield() end
  end

  local function fits(tpl, x, y)
    for cx = x, x + tpl.w - 1 do
      for cy = y, y + tpl.h - 1 do
        if cells[key(cx, cy)] then return false end
      end
    end
    return true
  end

  local function add_room(tpl, x, y, zone, depth)
    local room = { index = #rooms + 1, id = tpl.id, template = tpl, x = x, y = y, w = tpl.w, h = tpl.h,
      type = tpl.type, zone = zone, depth = depth or 0, doors = {}, closed = {} }
    rooms[room.index] = room
    for e = 1, #tpl.exits do room.doors[e] = false end
    for cx = x, x + tpl.w - 1 do
      for cy = y, y + tpl.h - 1 do cells[key(cx, cy)] = room.index end
    end
    for e = 1, #tpl.exits do
      frontier[#frontier + 1] = { room = room.index, exit = e, zone = zone, open = true }
    end
    return room
  end

  -- The cell an exit leads to
  local function target(room, e)
    local ex = room.template.exits[e]
    local ox, oy = templates.exit_cell(room.template, ex)
    return room.x + ox + templates.dx[ex.side], room.y + oy + templates.dy[ex.side], ex
  end

  -- How many other rooms touch the cell an open exit leads to: filling such a cell makes the
  -- map more compact instead of growing a branch.
  local function gap_of(f)
    local tx, ty = target(rooms[f.room], f.exit)
    local n = 0
    for d = 1, 4 do
      local j = cells[key(tx + NEAR[d][1], ty + NEAR[d][2])]
      if j and j ~= f.room then n = n + 1 end
    end
    return n
  end

  -- The ways a template of the pool can be put behind a frontier entry
  local function candidates(pool, f)
    local room = rooms[f.room]
    local tx, ty, ex = target(room, f.exit)
    if cells[key(tx, ty)] then f.open = false; return nil end
    local want = templates.opposite[ex.side]
    local list = {}
    for i = 1, #pool do
      local tpl = pool[i]
      for e = 1, #tpl.exits do
        local e2 = tpl.exits[e]
        if e2.side == want then
          local ox, oy = templates.exit_cell(tpl, e2)
          local x, y = tx - ox, ty - oy
          if fits(tpl, x, y) then list[#list + 1] = { tpl = tpl, exit = e, x = x, y = y, weight = tpl.weight } end
        end
      end
    end
    return list
  end

  -- Places one room of the pool behind an open exit of a room whose zone passes zone_ok.
  -- pool: an array of templates, or "filler" (a type by opts.types first, then a template).
  -- zone nil: the new room takes the zone of the exit it hangs from. entry_ok(f), optional:
  -- a further filter on the open exits (specials: distance, never behind a special room).
  local function place(pool, zone_ok, zone, lock, entry_ok)
    local open = {}
    for i = 1, #frontier do
      local f = frontier[i]
      if f.open and zone_ok(f.zone) and (not entry_ok or entry_ok(f)) then open[#open + 1] = f end
    end
    while #open > 0 do
      tick()
      local f, fi
      if branching > 0 then
        local total, pen = 0, floor(branching * 100 + 0.5)
        for i = 1, #open do
          local gap, w = gap_of(open[i]), nil
          if gap == 0 then w = 100 else w = 100 - pen * gap end
          if w < 0 then w = 0 end
          open[i].bweight, total = w, total + w
        end
        if total == 0 then
          for i = 1, #open do open[i].bweight = 1 end
        end
        f, fi = rng:weighted(open, "bweight")
      else
        f, fi = rng:pick(open)
      end
      local p = pool
      if p == "filler" then
        p = P.types and P.by_type[rng:weighted(P.types).name] or P.filler
      end
      local list = candidates(p, f)
      if list and #list > 0 then
        local c = rng:weighted(list)
        local from = rooms[f.room]
        local room = add_room(c.tpl, c.x, c.y, zone or f.zone, from.depth + 1)
        local e1, e2 = from.template.exits[f.exit], c.tpl.exits[c.exit]
        local door = { index = #doors + 1, a = from.index, b = room.index, ea = f.exit, eb = c.exit,
          requires = door_tags(e1, e2, lock), lock = lock }
        doors[door.index] = door
        from.doors[f.exit] = door.index
        room.doors[c.exit] = door.index
        f.open = false
        for i = #frontier, 1, -1 do    -- the new room's own exit back to `from` is taken
          local g2 = frontier[i]
          if g2.room == room.index and g2.exit == c.exit then g2.open = false end
        end
        return room
      end
      if not list then
        -- the exit is blocked for good
      elseif pool ~= "filler" then
        -- nothing of this pool fits here; the exit stays open for others
      else
        f.open = false
      end
      open[fi] = open[#open]
      open[#open] = nil
    end
    return nil
  end

  tick()
  if #P.start == 0 then return nil, "no template has type \"start\"" end
  local start = rng:weighted(P.start)
  add_room(start, 0, 0, 0)
  m.start = 1

  -- How many filler rooms each zone gets
  local specials = 0
  for i = 1, #(opts.specials or {}) do specials = specials + (opts.specials[i].count or 1) end
  local fill = opts.rooms - 1 - (#P.boss > 0 and 1 or 0) - (#P.item > 0 and #abilities or 0) - specials
  if fill < zones - 1 then return nil, "too few rooms for the abilities", true end
  local base, extra = floor(fill / zones), fill % zones

  for z = 0, zones - 1 do
    local count = base + (z < extra and 1 or 0)
    if z > 0 then
      local lock = abilities[z]
      local entry = place("filler", function(fz) return fz < z end, z, lock)
      if not entry then return nil, "no room for the door into zone " .. z end
      count = count - 1
    end
    for _ = 1, count do
      if not place("filler", function(fz) return fz == z end, z) then
        return nil, "zone " .. z .. " ran out of exits"
      end
    end
    if z < zones - 1 then
      local tag = abilities[z + 1]
      if #P.item > 0 then
        local r = place(P.item, function(fz) return fz == z end, z)
        if not r then return nil, "no room for the item of " .. tag end
        r.grants = tag
      else
        local holder                         -- the newest room of the zone without an item
        for i = #rooms, 1, -1 do
          if rooms[i].zone == z and not rooms[i].grants then holder = rooms[i]; break end
        end
        holder.grants = tag
      end
    end
  end
  -- Special rooms: dead ends hung from ordinary rooms, by distance from the start
  local function deepest(zone_ok)
    local d = -1
    for i = 1, #frontier do
      local f = frontier[i]
      if f.open and zone_ok(f.zone) and not rooms[f.room].special then d = math.max(d, rooms[f.room].depth) end
    end
    return d
  end
  local any_zone = function() return true end
  local function place_far(pool, zone_ok, zone, distance, min_depth)
    local not_special = function(f) return not rooms[f.room].special and rooms[f.room].depth + 1 >= min_depth end
    local r
    if distance == "far" or distance == "near" then
      local band
      if distance == "far" then
        local d = deepest(zone_ok)
        band = function(f) return not_special(f) and rooms[f.room].depth >= d - 1 end
      else
        band = function(f) return not_special(f) and rooms[f.room].depth <= min_depth end
      end
      r = place(pool, zone_ok, zone, nil, band)
    end
    return r or place(pool, zone_ok, zone, nil, not_special)
  end
  local function seal(room)                    -- nothing hangs off a special room: a dead end
    room.special = true
    for i = 1, #frontier do
      if frontier[i].room == room.index then frontier[i].open = false end
    end
  end
  for i = 1, #(opts.specials or {}) do
    local sp = opts.specials[i]
    for _ = 1, sp.count or 1 do
      local r = place_far(P.special[sp.type], any_zone, nil, sp.distance, sp.min_depth or 1)
      if not r then return nil, "no room for a special room of type " .. sp.type end
      r.min_depth = sp.min_depth or 1
      seal(r)
    end
  end
  if #P.boss > 0 then
    local last = function(fz) return fz == zones - 1 end
    local r
    if opts.boss_distance == "far" then
      r = place_far(P.boss, last, zones - 1, "far", 1)
    else
      r = place(P.boss, last, zones - 1)
    end
    if not r then return nil, "no room for the boss" end
    m.boss = r.index
    if opts.specials then r.special = true end
  end

  -- Loops: facing exits of neighbour rooms of the same zone (never the boss room)
  if opts.loops ~= false then
    for i = 1, #rooms do
      local room = rooms[i]
      for e = 1, #room.template.exits do
        if not room.doors[e] then
          local tx, ty, ex = target(room, e)
          local j = cells[key(tx, ty)]
          local other = j and rooms[j]
          if other and other.zone == room.zone and i ~= m.boss and j ~= m.boss
            and not room.special and not other.special then
            local back = templates.opposite[ex.side]
            local ox, oy = templates.exit_cell(room.template, ex)
            for e2 = 1, #other.template.exits do
              local x2 = other.template.exits[e2]
              if x2.side == back and not other.doors[e2] then
                local bx, by = target(other, e2)
                if bx == room.x + ox and by == room.y + oy then
                  local door = { index = #doors + 1, a = i, b = j, ea = e, eb = e2,
                    requires = door_tags(ex, x2), loop = true }
                  doors[door.index] = door
                  room.doors[e] = door.index
                  other.doors[e2] = door.index
                  break
                end
              end
            end
          end
        end
      end
    end
  end
  for i = 1, #rooms do
    local room = rooms[i]
    for e = 1, #room.doors do
      if not room.doors[e] then room.closed[#room.closed + 1] = e end
    end
  end

  -- depth: the fewest doors from the start, now that loops may have made shortcuts
  if opts.specials or opts.boss_distance == "far" then
    for i = 1, #rooms do rooms[i].depth = nil end
    rooms[1].depth = 0
    local queue, qi = { 1 }, 1
    while queue[qi] do
      local r = rooms[queue[qi]]
      qi = qi + 1
      for e = 1, #r.doors do
        local d = r.doors[e] and doors[r.doors[e]]
        if d then
          local o = rooms[d.a == r.index and d.b or d.a]
          if not o.depth then o.depth = r.depth + 1; queue[#queue + 1] = o.index end
        end
      end
    end
    for i = 1, #rooms do
      local r = rooms[i]
      if r.min_depth and (r.depth or 0) < r.min_depth then
        return nil, "a " .. r.type .. " room ended up " .. tostring(r.depth) .. " doors from the start"
      end
    end
    if opts.boss_distance == "far" and m.boss then
      local deepest_room = 0
      for i = 1, #rooms do
        if not rooms[i].special then deepest_room = math.max(deepest_room, rooms[i].depth or 0) end
      end
      if (rooms[m.boss].depth or 0) < deepest_room - 1 then
        return nil, "loops brought the boss closer to the start than the far rooms"
      end
    end
  end

  tick()
  local ok, why = graph.validate(m)
  if not ok then return nil, why end
  if opts.check then
    ok, why = opts.check(m)
    if not ok then return nil, "check: " .. tostring(why) end
  end
  return m
end

local function run(g)
  local why, final
  for n = 1, g.opts.attempts do
    local m
    m, why, final = attempt(g)
    if m then
      m.attempts = n
      g.map = m
      return
    end
    if final then break end
  end
  g.error = "procgen: no map after " .. g.opts.attempts .. " attempts (last: " .. tostring(why) .. ")"
end

local Gen = {}
Gen.__index = Gen

function M.new(opts)
  if type(opts) ~= "table" then error("procgen: generator.new needs an options table", 2) end
  local set = templates.new(opts.templates)
  local rng = opts.rng
  if rng == nil then
    if opts.seed == nil then error("procgen: give rng (an engine.rng generator) or seed", 2) end
    rng = Rng.new(opts.seed)
  end
  local branching = opts.branching
  if branching == nil then branching = 0.5 end
  if type(branching) ~= "number" or branching < 0 or branching > 1 then
    error("procgen: branching is a number from 0 to 1", 2)
  end
  local o = { rooms = opts.rooms or 12, attempts = opts.attempts or 50, types = opts.types,
    loops = opts.loops, check = opts.check, specials = opts.specials, boss_distance = opts.boss_distance,
    branching = branching }
  for i = 1, #(o.specials or {}) do
    local sp = o.specials[i]
    if type(sp) ~= "table" or type(sp.type) ~= "string" then error("procgen: specials[" .. i .. "] needs a type", 2) end
    if sp.type == "start" or sp.type == "boss" or sp.type == "normal" then
      error("procgen: " .. sp.type .. " cannot be a special room type", 2)
    end
    local c = sp.count or 1
    if type(c) ~= "number" or c < 0 or c ~= floor(c) then error("procgen: specials[" .. i .. "].count is a whole number >= 0", 2) end
    if sp.distance ~= nil and sp.distance ~= "any" and sp.distance ~= "far" and sp.distance ~= "near" then
      error("procgen: specials[" .. i .. "].distance is \"any\", \"far\" or \"near\"", 2)
    end
  end
  if type(o.rooms) ~= "number" or o.rooms < 1 or o.rooms ~= floor(o.rooms) then
    error("procgen: rooms is a whole number >= 1", 2)
  end
  local abilities = {}
  local seen = {}
  for i = 1, #(opts.abilities or {}) do
    local t = opts.abilities[i]
    if type(t) ~= "string" or seen[t] then error("procgen: abilities is an array of distinct strings", 2) end
    seen[t] = true
    abilities[i] = t
  end
  local g = setmetatable({ opts = o, set = set, rng = rng, abilities = abilities, ops = 0, budget = 0,
    done = false }, Gen)
  g.pools = pools(set, o)
  g.co = co_create(function() run(g) end)
  return g
end

function Gen:step(ops)
  if self.done then return true end
  self.budget = ops or 1
  local ok, err = co_resume(self.co)
  if not ok then
    self.done = true
    error(err, 0)
  end
  if co_status(self.co) == "dead" then self.done = true end
  return self.done
end

-- generator.generate(opts) -> map, or nil and the reason
function M.generate(opts)
  local g = M.new(opts)
  g:step(math.huge)
  return g.map, g.error
end

return M
