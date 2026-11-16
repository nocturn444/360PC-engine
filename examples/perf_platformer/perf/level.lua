-- The level: a procgen map of the rooms in rooms.lua, turned into one tile grid, a bump world
-- with its collisions (platformer module), one SpriteBatch per room, and the places where an
-- enemy can stand. The same seed gives the same level on PC and on the console.
local engine = require("engine")
local platformer = require("engine.modules.platformer")
local procgen = require("engine.modules.procgen")
local rooms = require("perf.rooms")

local RW, RH, TS = rooms.width, rooms.height, rooms.tile_size
local Level = {}
Level.__index = Level

-- settings: seed (a number or a seed code), rooms, min_width (in rooms)
function Level.new(settings)
  local seed = settings.seed
  if type(seed) == "string" then seed = assert(engine.rng.code_to_seed(seed)) end
  local self = setmetatable({}, Level)
  self.streams = engine.rng.streams(seed)
  self.seed = self.streams.seed
  self.code = engine.rng.seed_to_code(self.seed)

  local min_width = settings.min_width or 4
  local map, err = procgen.generate({
    templates = rooms.templates(),
    rng = self.streams:get("level"),
    rooms = settings.rooms or 12,
    check = function(m)                  -- the game's own rule: wide enough to scroll
      local lo, hi = math.huge, -math.huge
      for i = 1, #m.rooms do
        local r = m.rooms[i]
        if r.x < lo then lo = r.x end
        if r.x + r.w - 1 > hi then hi = r.x + r.w - 1 end
      end
      if hi - lo + 1 < min_width then return false, "narrower than " .. min_width .. " rooms" end
      return true
    end,
  })
  if not map then error("perf_platformer: no level for seed " .. self.code .. ": " .. tostring(err)) end
  self.map = map
  self.hash = procgen.hash(map)

  -- The map's cells, from 0
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for i = 1, #map.rooms do
    local r = map.rooms[i]
    x0, y0 = math.min(x0, r.x), math.min(y0, r.y)
    x1, y1 = math.max(x1, r.x + r.w - 1), math.max(y1, r.y + r.h - 1)
  end
  self.cells_w, self.cells_h = x1 - x0 + 1, y1 - y0 + 1
  self.tiles_w, self.tiles_h = self.cells_w * RW, self.cells_h * RH
  self.width, self.height = self.tiles_w * TS, self.tiles_h * TS

  -- One grid of characters for the whole level; " " where there is no room
  local tiles = {}
  for ty = 1, self.tiles_h do
    local row = {}
    for tx = 1, self.tiles_w do row[tx] = " " end
    tiles[ty] = row
  end
  self.tiles = tiles
  self.rooms = {}
  for i = 1, #map.rooms do
    local r = map.rooms[i]
    local ox, oy = (r.x - x0) * RW, (r.y - y0) * RH
    local rows = r.template.rows
    for ty = 1, RH do
      for tx = 1, RW do tiles[oy + ty][ox + tx] = rows[ty]:sub(tx, tx) end
    end
    -- Open the border where the map put a door; an exit without one stays a wall
    for e = 1, #r.template.exits do
      if r.doors[e] then
        local side = r.template.exits[e].side
        if side == "left" or side == "right" then
          local tx = ox + (side == "left" and 1 or RW)
          for ty = 9, 11 do tiles[oy + ty][tx] = "." end
        else
          local ty = oy + (side == "up" and 1 or RH)
          for tx = 9, 12 do tiles[ty][ox + tx] = side == "up" and "." or "=" end
        end
      end
    end
    self.rooms[i] = { index = i, id = r.id, x = ox * TS, y = oy * TS, w = RW * TS, h = RH * TS,
      tx = ox, ty = oy, start = i == map.start, batch = nil }
  end

  self.grid = platformer.grid.new(tiles, { tile_size = TS })
  self.world, self.rects = platformer.collision.newWorld(self.grid)

  -- Where a body can stand: an empty tile over a solid or one-way one, room by room, row by
  -- row (a fixed order: the enemies' places depend on it)
  self.spots = {}
  for i = 1, #self.rooms do
    local room = self.rooms[i]
    for ty = 2, RH - 1 do
      for tx = 2, RW - 1 do
        local gx, gy = room.tx + tx, room.ty + ty
        local under = tiles[gy + 1][gx]
        if tiles[gy][gx] == "." and (under == "#" or under == "=") then
          self.spots[#self.spots + 1] = { x = (gx - 1) * TS, y = (gy - 1) * TS, room = i }
        end
      end
    end
  end
  -- The player starts on the floor of the start room, in the middle
  local start = self.rooms[map.start]
  self.start_x, self.start_y = start.x + start.w / 2, start.y + (RH - 1) * TS
  return self
end

-- One SpriteBatch per room: its background and its tiles, in the room's own coordinates.
-- Returns how many sprites were added in all.
function Level:build(atlas)
  local g = love.graphics
  local count = 0
  for i = 1, #self.rooms do
    local room = self.rooms[i]
    local batch = g.newSpriteBatch(atlas.image, RW * RH * 2, "static")
    for ty = 1, RH do
      for tx = 1, RW do
        local c = self.tiles[room.ty + ty][room.tx + tx]
        local x, y = (tx - 1) * TS, (ty - 1) * TS
        if c == "#" then
          batch:add(atlas.solid, x, y); count = count + 1
        else
          batch:add(atlas.background, x, y); count = count + 1
          if c == "=" then batch:add(atlas.one_way, x, y); count = count + 1 end
        end
      end
    end
    batch:flush()
    room.batch = batch
  end
  self.sprites = count
  return count
end

-- Draws the rooms that touch the view (a world rectangle); returns how many
function Level:draw(vx, vy, vw, vh)
  local g, n = love.graphics, 0
  local list = self.rooms
  for i = 1, #list do
    local r = list[i]
    if r.x < vx + vw and r.x + r.w > vx and r.y < vy + vh and r.y + r.h > vy then
      g.draw(r.batch, r.x, r.y)
      n = n + 1
    end
  end
  return n
end

return Level
