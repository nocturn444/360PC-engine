-- rooms.nav: where the player is on a procgen map, and how the rooms connect in pixels.
--
-- Room pixels: a room's top left corner is 0, 0 and it is w * cell_w by h * cell_h pixels
-- (w, h in map cells). An exit is the stretch of the room's edge in its map cell: the left exit
-- at offset 1 of a room 2 cells high is x = 0, cell_h <= y < 2 * cell_h.
local templates = require((...):gsub("rooms%.nav$", "procgen.templates"))
local procmap = require((...):gsub("rooms%.nav$", "procgen.map"))

local floor, sort = math.floor, table.sort
local exit_cell = templates.exit_cell

local M = {}
local Nav = {}
Nav.__index = Nav

-- nav.new(map, opts): map from procgen.generate; opts.cell_w, opts.cell_h (pixels per map
-- cell, required), opts.tile_size (pixels per tile, for exits and spawns given in tiles),
-- opts.inset (how far inside the edge a body arrives when its exit has no tile, default
-- tile_size * 1.5, or 24), opts.on_enter (function(nav, index, exit) after each enter)
function M.new(map, opts)
  assert(type(map) == "table" and map.rooms and map.doors, "rooms.nav: a map from procgen.generate")
  opts = opts or {}
  local cw, ch = opts.cell_w, opts.cell_h
  assert(type(cw) == "number" and cw > 0 and type(ch) == "number" and ch > 0, "rooms.nav: cell_w and cell_h > 0")
  local self = setmetatable({ map = map, cell_w = cw, cell_h = ch, tile_size = opts.tile_size,
    inset = opts.inset or (opts.tile_size and opts.tile_size * 1.5) or 24, on_enter = opts.on_enter,
    index = nil, room = nil, entered_by = nil, explored = {}, visits = {}, minimap_data = nil,
    exits_by_key = {} }, Nav)
  for i = 1, #map.rooms do self.visits[i] = 0 end
  return self
end

-- The room's size in pixels
function Nav:size(index)
  local r = self.map.rooms[index or self.index]
  return r.w * self.cell_w, r.h * self.cell_h
end

-- Camera bounds of the current room: 0, 0, w, h
function Nav:bounds()
  local w, h = self:size()
  return 0, 0, w, h
end

-- Exit lookup per template: "side offset" -> exit index (made once per template)
local function exit_index(self, tpl, side, offset)
  local by = self.exits_by_key[tpl]
  if not by then
    by = {}
    for e = 1, #tpl.exits do by[tpl.exits[e].side .. tpl.exits[e].offset] = e end
    self.exits_by_key[tpl] = by
  end
  return by[side .. offset]
end

-- Where a body arrives through exit e of room `index` (room pixels): the exit's tile when the
-- template gives one (tx, ty and opts.tile_size), else the middle of the exit's stretch of
-- edge, `inset` pixels inside.
function Nav:arrival(index, e)
  local r = self.map.rooms[index]
  local tpl = r.template
  local exit = tpl.exits[e]
  local ts = self.tile_size
  if ts and exit.tx and exit.ty then return (exit.tx - 0.5) * ts, (exit.ty - 0.5) * ts end
  local cx, cy = exit_cell(tpl, exit)
  local cw, ch, inset = self.cell_w, self.cell_h, self.inset
  local side = exit.side
  if side == "left" then return inset, (cy + 0.5) * ch end
  if side == "right" then return r.w * cw - inset, (cy + 0.5) * ch end
  if side == "up" then return (cx + 0.5) * cw, inset end
  return (cx + 0.5) * cw, r.h * ch - inset
end

-- Where a body starts in a room it did not come into through a door (the start room, a
-- respawn): the template's spawn = { tx, ty } with opts.tile_size, else the room's centre.
function Nav:spawn(index)
  local r = self.map.rooms[index or self.index]
  local sp, ts = r.template.spawn, self.tile_size
  if sp and ts and sp.tx and sp.ty then return (sp.tx - 0.5) * ts, (sp.ty - 0.5) * ts end
  return r.w * self.cell_w / 2, r.h * self.cell_h / 2
end

local function mark(self, index)
  self.explored[index] = true
  local mm = self.minimap_data
  if mm then
    local cells = mm.cells
    for i = 1, #cells do
      local c = cells[i]
      if c and c.room == index then c.explored = true end
    end
  end
end

-- Enters room `index`, through its exit `e` (nil: not through a door). Marks it explored and
-- returns where the body goes, in room pixels.
function Nav:enter(index, e)
  local r = self.map.rooms[index]
  assert(r, "rooms.nav: no room " .. tostring(index))
  self.index, self.room, self.entered_by = index, r, e
  self.visits[index] = self.visits[index] + 1
  mark(self, index)
  local x, y
  if e then x, y = self:arrival(index, e) else x, y = self:spawn(index) end
  if self.on_enter then self.on_enter(self, index, e) end
  return x, y
end

-- Is the point (room pixels, usually a body's centre) past an edge of the current room?
-- Returns the exit index there (or nil when the room has no exit on that stretch of edge),
-- the door index (false when the exit leads nowhere: the game walls it up), and the side.
function Nav:leaving(x, y)
  local r = self.room
  local w, h = r.w * self.cell_w, r.h * self.cell_h
  local side, offset
  if x < 0 then side, offset = "left", floor(y / self.cell_h)
  elseif x >= w then side, offset = "right", floor(y / self.cell_h)
  elseif y < 0 then side, offset = "up", floor(x / self.cell_w)
  elseif y >= h then side, offset = "down", floor(x / self.cell_w)
  else return nil end
  local span = (side == "left" or side == "right") and r.h or r.w
  if offset < 0 then offset = 0 elseif offset > span - 1 then offset = span - 1 end
  local e = exit_index(self, r.template, side, offset)
  if not e then return nil, nil, side end
  return e, r.doors[e], side
end

-- Whether `have` (an array of ability tags, or a set { tag = true }) opens the door. Returns
-- true, or false and the first tag missing.
function Nav:can_pass(door, have)
  local d = self.map.doors[door]
  local req = d.requires
  if #req == 0 then return true end
  have = have or {}
  local set = have
  if #have > 0 then
    for i = 1, #req do
      local found = false
      for j = 1, #have do if have[j] == req[i] then found = true; break end end
      if not found then return false, req[i] end
    end
    return true
  end
  for i = 1, #req do if not set[req[i]] then return false, req[i] end end
  return true
end

-- Where door `door` leads from the current room: room index and the exit it arrives by
function Nav:through(door)
  local d = self.map.doors[door]
  if d.a == self.index then return d.b, d.eb end
  assert(d.b == self.index, "rooms.nav: door " .. door .. " is not in the current room")
  return d.a, d.ea
end

-- Goes through door `door`: enters the room on the other side and returns where the body goes
-- (room pixels of the new room), the new room's index and the exit it came in by.
function Nav:go(door)
  local index, e = self:through(door)
  local x, y = self:enter(index, e)
  return x, y, index, e
end

function Nav:is_explored(index) return self.explored[index] == true end

-- procgen.map.minimap of the map (made on the first call), with `explored` kept up to date
function Nav:minimap()
  if not self.minimap_data then
    self.minimap_data = procmap.minimap(self.map)
    for i in next, self.explored do mark(self, i) end
  end
  return self.minimap_data
end

-- For the run's save (engine.save): { room = index, entered_by = exit, explored = { indices } }
function Nav:state()
  local list = {}
  for i = 1, #self.map.rooms do if self.explored[i] then list[#list + 1] = i end end
  sort(list)
  return { room = self.index, entered_by = self.entered_by, explored = list }
end

-- Back from state(): the explored rooms; then enters the saved room as enter() would (same
-- return values). Indices that the map does not have are ignored.
function Nav:set_state(s)
  self.explored = {}
  local rooms = self.map.rooms
  if self.minimap_data then
    for i = 1, #self.minimap_data.cells do
      local c = self.minimap_data.cells[i]
      if c then c.explored = false end
    end
  end
  for _, i in ipairs(s.explored or {}) do if rooms[i] then mark(self, i) end end
  local index = rooms[s.room] and s.room or self.map.start
  local e = s.entered_by
  if index ~= s.room or not (e and rooms[index].template.exits[e]) then e = nil end
  return self:enter(index, e)
end

return M
