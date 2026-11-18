-- Walking a run of generated floors (procgen.floors): ten floors, each a fresh map that grows
-- the deeper the slime goes, with a treasure room, a shop and sometimes a miniboss
-- (procgen.roomtypes). Only the current room exists: its grid is built when the slime comes
-- in, the camera stays inside it, and a short fade covers each change of room. A locked door
-- stays shut (drawn gold) until the slime picks up the key in the vault room; once the boss
-- room is cleared, a stairway leads to the next floor. A minimap shows the explored rooms.
-- The floors go through biomes (rooms_biomes.lua, procgen.biomes): each has its difficulty,
-- enemies, colours and music; a treasure room holds an item drawn for the floor's biome
-- (rooms_items.lua, engine.modules.items) that the slime keeps for the rest of the run.
local engine = require("engine")
local procgen = require("engine.modules.procgen")
local platformer = require("engine.modules.platformer")
local softbody = require("engine.modules.softbody")
local rooms = require("engine.modules.rooms")
local pixelgrid = require("engine.pixelgrid")
local data = require("rooms_data")
local enemies = require("rooms_enemies")
local biomes = require("rooms_biomes")
local loot = require("rooms_items")
local combat = require("engine.modules.combat")

local W, H = 320, 180
local TS, CW, CH = data.tile_size, data.cell_w, data.cell_h
local MOVE, AIR_MOVE, JUMP, CHARGED_JUMP = 700, 300, 260, 380
local SIZE = 40
local SEED = 1
local FLOORS = 10

-- The run: 10 floors from 6 rooms to 18, the special rooms of rooms_data.types(), a key per floor
local plan = procgen.floors.new({ count = FLOORS, templates = data.templates(), types = data.types(),
  rooms = { first = 6, last = 18 }, abilities = { "key" } })

local play = { plan = plan, biomes = biomes.new(FLOORS) }

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
  local kind = self.nav.room.type
  local boss = kind == "boss" or kind == "miniboss"
  local b, bonus = self.biome, self.bonus
  local m = boss and b.boss or b.mobs
  self.fight = enemies.new(self.slime, self.grid, spots, { boss = boss,
    seed = SEED * 100000 + self.floor * 1000 + self.nav.index, health = health, mode = self.fight and self.fight.mode,
    enemy_stats = combat.stats.new(biomes.enemy_stats(b, boss)), color = m.color,
    slime_stats = combat.stats.new({ max_health = 5 + bonus.max_health, attack_damage = 1 + bonus.damage,
      invuln_time = 1.0 + bonus.invuln }),
    on_slime_death = function() self.dead = true end })
  self.kills_before = self.kills
  local item = self.nav.room.grants and not self.abilities[self.nav.room.grants] and self.nav.room.template.item
  self.item = item and { x = (item.tx - 1) * TS + 4, y = (item.ty - 1) * TS + 4, tag = self.nav.room.grants } or nil
  -- a treasure room holds an item of the floor's biome, drawn the first time the room is
  -- entered (the run's "loot" stream), on its pedestal until taken
  self.treasure = nil
  if kind == "treasure" and not self.taken[self.nav.index] then
    local entry = self.loot[self.nav.index]
    if entry == nil then
      entry = self.pool:draw(self.streams:get("loot"), { room = "treasure", biome = b.id }) or false
      self.loot[self.nav.index] = entry
    end
    if entry then self.treasure = { x = 9.5 * TS - 4, y = 8 * TS, entry = entry } end
  end
  self.stairs = nil
  if x then
    self.slime:move_to(x, y)
    self.camera:setBounds(self.nav:bounds())
    self.camera:setPosition(x, y)
  end
end

-- A new run: the seed's streams, a path through the biomes, nothing taken yet
function play.new_run(self)
  self.streams = engine.rng.streams(SEED)
  self.path = play.biomes:path()
  self.pool = self.pool or loot.pool()
  self.pool:new_run()
  self.bonus = loot.no_bonus()
  self.kills, self.got = 0, nil
end

-- Floor n: its biome (chosen when the last one ends, from what the run did), a fresh map from
-- its own stream, the key to find again, the slime at the start
function play.new_floor(self, n)
  if n == 1 then play.new_run(self) end
  self.floor = n
  self.biome = self.path:enter(n, { kills = self.kills, floor = n }, self.streams:get("biomes"))
  self.music = self.biome.music      -- a game with tracks: audio:music(self.music, { fade = 1 })
  self.map = assert(plan:generate(n, self.streams:get("floor" .. n), self.biome))
  self.nav = rooms.nav.new(self.map, { cell_w = CW * TS, cell_h = CH * TS, tile_size = TS })
  self.abilities, self.taken, self.loot = {}, {}, {}
end

function play:enter()
  play.new_floor(self, 1)
  self.fade = rooms.transition.new({ kind = "fade", time = 0.3 })
  self.camera = engine.camera.new({ width = W, height = H, lerp = 10, deadzone_w = 24, deadzone_h = 16 })
  self.slime = softbody.new({ radius = 9, points = 18 })
  self.pixels = pixelgrid.new(SIZE, SIZE, { palette = {
    { 0.98, 0.90, 0.52 }, { 0.10, 0.30, 0.16 }, { 0.95, 1.00, 0.95 }, { 0.05, 0.08, 0.06 },
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
  self.fight.box.facing = self.facing            -- the attacks aim where the slime looks
  if input:pressed("switch") then self.fight:switch() end
  if input:pressed("attack") then self.fight:attack() end
  local bonus = self.bonus
  slime:push(move * (slime:on_ground() and MOVE or AIR_MOVE) * bonus.move, 0)
  local squash = input:down("down")
  slime.inflate = squash and 0.7 or 1
  if squash and slime:on_ground() then self.charging = true end
  if input:pressed("jump") and slime:on_ground() then
    slime:impulse(0, -JUMP * bonus.jump)
  elseif self.charging and not squash then
    if slime:on_ground() then slime:impulse(0, -CHARGED_JUMP * bonus.jump) end
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
  self.kills = self.kills_before + self.fight.kills
  local cx, cy = self.slime:center()
  -- the key: picked up by touching it; the room is rebuilt so its locked doors open
  local it = self.item
  if it and cx > it.x - 6 and cx < it.x + 14 and cy > it.y - 10 and cy < it.y + 14 then
    self.abilities[it.tag] = true
    play.load_room(self)
  end
  -- treasure: the item is the slime's for the rest of the run; the room is rebuilt so its
  -- stats count, and the slime is healed
  local h = self.treasure
  if h and cx > h.x - 6 and cx < h.x + 14 and cy > h.y - 10 and cy < h.y + 14 then
    self.pool:take(h.entry)
    loot.apply(self.bonus, h.entry)
    self.taken[self.nav.index], self.treasure = true, nil
    self.got = h.entry
    self.fight.player.dead = true                  -- the next fight starts at full health
    play.load_room(self)
  end
  -- the boss room, once cleared, opens a stairway down to the next floor (after the last: floor 1)
  if self.nav.room.type == "boss" and not self.stairs and self.fight:alive() == 0 then
    self.stairs = { x = 9 * TS, y = 10 * TS }
  end
  local st = self.stairs
  if st and cx > st.x - 4 and cx < st.x + 2 * TS + 4 and cy > st.y - 12 then
    self.fade:start(function()
      local health = self.fight.player.health
      play.new_floor(self, self.floor % FLOORS + 1)
      play.load_room(self, self.nav:enter(self.map.start))
      self.fight.player.health = health
    end)
    return
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

local function draw_slime(self, alpha)
  local slime, px = self.slime, self.pixels
  local cx, cy = slime:center()
  local ox, oy = math.floor(cx) - SIZE / 2, math.floor(cy) - SIZE / 2
  px:clear()
  px:polygon(slime:outline(self.points, ox, oy, 1, alpha), 1)
  px:outline(2)
  local x0, y0, x1 = slime:bounds()
  local ex = math.floor((x0 + x1) / 2 - ox) + 1 + self.facing * 2
  local ey = math.floor(y0 - oy) + 5
  local look = self.facing > 0 and 1 or 0
  for dx = -3, 2, 5 do
    px:set(ex + dx, ey, 3); px:set(ex + dx + 1, ey, 3)
    px:set(ex + dx, ey + 1, 3); px:set(ex + dx + 1, ey + 1, 3)
    px:set(ex + dx + look, ey + 1, 4)
  end
  px:draw(ox, oy)
end

local TYPE_COLORS = {
  normal = { 0.5, 0.6, 0.8 }, start = { 0.5, 0.6, 0.8 }, boss = { 0.8, 0.3, 0.3 },
  treasure = { 0.95, 0.75, 0.2 }, shop = { 0.35, 0.8, 0.45 }, miniboss = { 0.9, 0.5, 0.25 },
}
local LABELS = { treasure = "TREASURE", shop = "SHOP", miniboss = "MINIBOSS", boss = "BOSS" }

local function draw_minimap(self)
  local g, mm = love.graphics, self.nav:minimap()
  local S = 5
  local x0, y0 = W - mm.w * S - 4, 4
  for cy = 1, mm.h do
    for cx = 1, mm.w do
      local c = mm.cells[(cy - 1) * mm.w + cx]
      if c and c.explored then
        if c.room == self.nav.index then g.setColor(0.95, 0.95, 0.6, 1)
        else
          local col = TYPE_COLORS[c.type] or TYPE_COLORS.normal
          g.setColor(col[1], col[2], col[3], 1)
        end
        g.rectangle("fill", x0 + (cx - 1) * S, y0 + (cy - 1) * S, S - 1, S - 1)
      end
    end
  end
end

function play:draw(alpha)
  local g, camera = love.graphics, self.camera
  local colors = self.biome.colors
  camera:attach(alpha)
  if self.nav.room.type == "boss" then g.setColor(0.32, 0.16, 0.20, 1) else g.setColor(colors.wall[1], colors.wall[2], colors.wall[3], 1) end
  for i = 1, #self.runs do local r = self.runs[i]; g.rectangle("fill", r[1], r[2], r[3], TS) end
  g.setColor(colors.ledge[1], colors.ledge[2], colors.ledge[3], 1)
  for i = 1, #self.ones do local r = self.ones[i]; g.rectangle("fill", r[1], r[2], r[3], 3) end
  g.setColor(0.95, 0.75, 0.20, 1)
  for i = 1, #self.locked do local l = self.locked[i]; g.rectangle("fill", l.x + 4, l.y, TS - 8, 3 * TS) end
  if self.item then g.rectangle("fill", self.item.x, self.item.y, 8, 8) end
  local tr = self.treasure
  if tr then
    local c = tr.entry.color or { 1, 1, 1 }
    g.setColor(c[1], c[2], c[3], 1); g.rectangle("fill", tr.x, tr.y, 8, 8)
    g.setColor(1, 1, 1, 0.8)
    engine.text.draw(tr.entry.name, tr.x + 4 - engine.text.width(tr.entry.name) / 2, tr.y - 10)
  end
  if self.stairs then
    g.setColor(0.1, 0.1, 0.12, 1)
    g.rectangle("fill", self.stairs.x, self.stairs.y, 2 * TS, TS)
    g.setColor(0.6, 0.85, 1, 1)
    g.rectangle("line", self.stairs.x, self.stairs.y, 2 * TS, TS)
  end
  local label = LABELS[self.nav.room.type]
  if label then
    g.setColor(1, 1, 1, 0.6)
    engine.text.draw(label, (CW * TS - engine.text.width(label, 2)) / 2, 2 * TS, 2)
  end
  self.fight:draw(alpha, self.nav.room.type == "boss")
  g.setColor(1, 1, 1, 1)
  -- the slime blinks while nothing can hurt it
  local p = self.fight.player
  if not (p:invulnerable() and math.floor(p.invuln * 12) % 2 == 1) then draw_slime(self, alpha) end
  camera:detach()
  g.setColor(1, 1, 1, 1)
  engine.text.draw("HP " .. p.health .. "/" .. p.stats:get("max_health"), 4, 4)
  engine.text.draw("ATK " .. self.fight:current().name, 4, 12)
  engine.text.draw("FLOOR " .. self.floor .. "/" .. FLOORS .. " " .. self.biome.name, 4, 20)
  if self.got then engine.text.draw("GOT " .. self.got.name, 4, 28) end
  draw_minimap(self)
  local cover = self.fade:cover(alpha)
  if cover > 0 then
    g.setColor(0, 0, 0, cover)
    g.rectangle("fill", 0, 0, W, H)
  end
  g.setColor(1, 1, 1, 1)
end

return play
