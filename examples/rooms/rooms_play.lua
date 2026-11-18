-- Walking a generated map. Only the current room exists: its grid is built when the slime comes
-- in, the camera stays inside it, and a short fade covers each change of room. A locked door
-- stays shut (drawn gold) until the slime picks up the key in the vault room; a minimap in the
-- corner shows the explored rooms.
local engine = require("engine")
local procgen = require("engine.modules.procgen")
local platformer = require("engine.modules.platformer")
local softbody = require("engine.modules.softbody")
local rooms = require("engine.modules.rooms")
local pixelgrid = require("engine.pixelgrid")
local data = require("rooms_data")
local enemies = require("rooms_enemies")

local W, H = 320, 180
local TS, CW, CH = data.tile_size, data.cell_w, data.cell_h
local MOVE, AIR_MOVE, JUMP, CHARGED_JUMP = 700, 300, 260, 380
-- The slug: a long soft body (softbody width / height, kept long by `shape`), drawn each frame
-- into a SW x SH pixel grid around its centre
local SLUG = { width = 34, height = 13, points = 24, shape = 0.2 }
local SW, SH = 56, 36
local SEED = 1

local play = {}

-- The room's rows with its doors opened: rows 9..11 of the exit's cell, in the first or last
-- column. An exit without a door, or a locked door the slime cannot pass yet, stays a wall.
local function build_rows(self, index)
  local r = self.map.rooms[index]
  local rows = {}
  for i, row in ipairs(r.template.rows) do rows[i] = row end
  self.locked = {}
  for e, exit in ipairs(r.template.exits) do
    local door = r.doors[e]
    local open = door and self.nav:can_pass(door, self.abilities)
    local col = exit.side == "left" and 1 or #rows[1]
    for k = 9, 11 do
      local y = exit.offset * CH + k
      if open then
        rows[y] = rows[y]:sub(1, col - 1) .. "." .. rows[y]:sub(col + 1)
      end
    end
    if door and not open then
      self.locked[#self.locked + 1] = { x = (col - 1) * TS, y = (exit.offset * CH + 8) * TS }
    end
  end
  return rows
end

-- Builds the current room's grid and what is drawn from it; with x, y, puts the slime there
function play.load_room(self, x, y)
  self.grid = platformer.grid.new(build_rows(self, self.nav.index), { tile_size = TS })
  -- solid tiles merged into horizontal runs once per room: a few rectangles a row to draw
  local runs, ones = {}, {}
  for ty = 1, self.grid.height do
    local tx = 1
    while tx <= self.grid.width do
      local kind = self.grid:kind(tx, ty)
      if kind then
        local stop = tx
        while stop < self.grid.width and self.grid:kind(stop + 1, ty) == kind do stop = stop + 1 end
        local list = kind == "solid" and runs or ones
        list[#list + 1] = { (tx - 1) * TS, (ty - 1) * TS, (stop - tx + 1) * TS }
        tx = stop + 1
      else
        tx = tx + 1
      end
    end
  end
  self.runs, self.ones = runs, ones
  -- the room's enemies, and the slime as a fighter with the health it had in the last room
  local spots = {}
  for i, t in ipairs(self.nav.room.template.enemies or {}) do
    spots[i] = { x = (t.tx - 0.5) * TS, y = t.ty * TS }
  end
  local health = self.fight and not self.fight.player.dead and self.fight.player.health or nil
  self.fight = enemies.new(self.slime, self.grid, spots, { boss = self.nav.room.type == "boss",
    seed = SEED * 1000 + self.nav.index, health = health,
    on_slime_death = function() self.dead = true end })
  local item = self.nav.room.grants and not self.abilities[self.nav.room.grants] and self.nav.room.template.item
  self.item = item and { x = (item.tx - 1) * TS + 4, y = (item.ty - 1) * TS + 4, tag = self.nav.room.grants } or nil
  if x then
    self.slime:move_to(x, y)
    self.camera:setBounds(self.nav:bounds())
    self.camera:setPosition(x, y)
  end
end

function play:enter()
  self.map = assert(procgen.generate({ templates = data.templates(), seed = SEED, rooms = 10, abilities = { "key" } }))
  self.nav = rooms.nav.new(self.map, { cell_w = CW * TS, cell_h = CH * TS, tile_size = TS })
  self.fade = rooms.transition.new({ kind = "fade", time = 0.3 })
  self.camera = engine.camera.new({ width = W, height = H, lerp = 10, deadzone_w = 24, deadzone_h = 16 })
  self.abilities = {}
  self.slime = softbody.new(SLUG)
  self.pixels = pixelgrid.new(SW, SH, { palette = {
    { 0.42, 0.86, 0.48 }, { 0.10, 0.30, 0.16 }, { 0.95, 1.00, 0.95 }, { 0.05, 0.08, 0.06 },
  } })
  self.points = {}
  self.facing, self.charging = 1, false
  self.dead, self.deaths = false, 0
  local x, y = self.nav:enter(self.map.start)
  play.load_room(self, x, y)
end

function play:input(input)
  if input:pressed("quit") then love.event.quit() end
end

local function control(self, dt)
  local input, slime = engine.controls, self.slime
  local move = input:axis("move_x")
  if move ~= 0 then self.facing = move > 0 and 1 or -1 end
  slime:push(move * (slime:on_ground() and MOVE or AIR_MOVE), 0)
  local squash = input:down("down")
  slime.inflate = squash and 0.7 or 1
  if squash and slime:on_ground() then self.charging = true end
  if input:pressed("jump") and slime:on_ground() then
    slime:impulse(0, -JUMP)
  elseif self.charging and not squash then
    if slime:on_ground() then slime:impulse(0, -CHARGED_JUMP) end
    self.charging = false
  end
end

function play:update(dt)
  self.fade:update(dt)
  if self.fade:busy() then return end            -- the room is frozen while the screen fades
  if self.dead then                               -- back to the start room, healed, behind a fade
    self.dead, self.deaths = false, self.deaths + 1
    self.fade:start(function()
      self.fight.player.dead = true                -- so the next room starts at full health
      play.load_room(self, self.nav:enter(self.map.start))
    end)
    return
  end
  control(self, dt)
  self.slime:step(dt, self.grid)
  self.fight:step(dt)
  local cx, cy = self.slime:center()
  -- the key: picked up by touching it; the room is rebuilt so its locked doors open
  local it = self.item
  if it and cx > it.x - 6 and cx < it.x + 14 and cy > it.y - 10 and cy < it.y + 14 then
    self.abilities[it.tag] = true
    play.load_room(self)
  end
  local _, door, side = self.nav:leaving(cx, cy)
  if door and self.nav:can_pass(door, self.abilities) then
    self.fade:start(function()
      local x, y = self.nav:go(door)
      play.load_room(self, x, y)
    end, side)
  end
  self.camera:follow(cx, cy)
  self.camera:update(dt)
end

-- The top filled cell of column c of the pixel grid (nil if the column is empty)
local function top_of(px, c)
  for r = 1, SH do if px:get(c, r) ~= 0 then return r end end
  return nil
end

-- An eye stalk: a line of outline cells up from the body's top at column c, and the eye on it
local function stalk(px, c, len, look)
  local top = top_of(px, c)
  if not top then return end
  for r = top - len, top - 1 do px:set(c, r, 2) end
  local ey = top - len - 2
  px:set(c, ey, 3); px:set(c + 1, ey, 3); px:set(c, ey + 1, 3); px:set(c + 1, ey + 1, 3)
  px:set(c + look, ey + 1, 4)
end

local function draw_slime(self, alpha)
  local slime, px = self.slime, self.pixels
  local cx, cy = slime:center()
  local ox, oy = math.floor(cx) - SW / 2, math.floor(cy) - SH / 2
  px:clear()
  px:polygon(slime:outline(self.points, ox, oy, 1, alpha), 1)
  px:outline(2)
  -- two eye stalks near the front end: the front one taller
  local x0, _, x1 = slime:bounds()
  local f = self.facing
  local front = f > 0 and math.floor(x1 - ox) - 6 or math.floor(x0 - ox) + 6
  local look = f > 0 and 1 or 0
  stalk(px, front, 4, look)
  stalk(px, front - 4 * f, 3, look)
  px:draw(ox, oy)
end

local function draw_minimap(self)
  local g, mm = love.graphics, self.nav:minimap()
  local S = 5
  local x0, y0 = W - mm.w * S - 4, 4
  for cy = 1, mm.h do
    for cx = 1, mm.w do
      local c = mm.cells[(cy - 1) * mm.w + cx]
      if c and c.explored then
        if c.room == self.nav.index then g.setColor(0.95, 0.95, 0.6, 1)
        elseif c.type == "boss" then g.setColor(0.8, 0.3, 0.3, 1)
        else g.setColor(0.5, 0.6, 0.8, 1) end
        g.rectangle("fill", x0 + (cx - 1) * S, y0 + (cy - 1) * S, S - 1, S - 1)
      end
    end
  end
end

function play:draw(alpha)
  local g, camera = love.graphics, self.camera
  camera:attach(alpha)
  if self.nav.room.type == "boss" then g.setColor(0.32, 0.16, 0.20, 1) else g.setColor(0.20, 0.22, 0.30, 1) end
  for i = 1, #self.runs do local r = self.runs[i]; g.rectangle("fill", r[1], r[2], r[3], TS) end
  g.setColor(0.45, 0.48, 0.58, 1)
  for i = 1, #self.ones do local r = self.ones[i]; g.rectangle("fill", r[1], r[2], r[3], 3) end
  g.setColor(0.95, 0.75, 0.20, 1)
  for i = 1, #self.locked do local l = self.locked[i]; g.rectangle("fill", l.x + 4, l.y, TS - 8, 3 * TS) end
  if self.item then g.rectangle("fill", self.item.x, self.item.y, 8, 8) end
  self.fight:draw(alpha, self.nav.room.type == "boss")
  g.setColor(1, 1, 1, 1)
  -- the slime blinks while nothing can hurt it
  local p = self.fight.player
  if not (p:invulnerable() and math.floor(p.invuln * 12) % 2 == 1) then draw_slime(self, alpha) end
  camera:detach()
  g.setColor(1, 1, 1, 1)
  engine.text.draw("HP " .. p.health .. "/" .. p.stats:get("max_health"), 4, 4)
  draw_minimap(self)
  local cover = self.fade:cover(alpha)
  if cover > 0 then
    g.setColor(0, 0, 0, cover)
    g.rectangle("fill", 0, 0, W, H)
  end
  g.setColor(1, 1, 1, 1)
end

return play
