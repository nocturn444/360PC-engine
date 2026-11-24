-- Walking a run of generated floors (procgen.floors): ten floors, each a fresh map that grows
-- the deeper the slime goes, with a treasure room, a shop and sometimes a miniboss
-- (procgen.roomtypes). Only the current room exists: its grid is built when the slime comes
-- in, the camera stays inside it, and a short fade covers each change of room. A locked door
-- stays shut (drawn gold) until the slime picks up the key in the vault room; once the boss
-- room is cleared, a stairway leads to the next floor. A minimap shows the explored rooms.
-- The floors go through biomes (rooms_biomes.lua, procgen.biomes): each has its difficulty,
-- enemies, colours and music; a treasure room holds an item drawn for the floor's biome
-- (rooms_content.lua) that the slime keeps for the rest of the run. Its stats and look are
-- rooms_stats.lua and rooms_look.lua; hearts, virus, props and a test machine are around it.
local engine = require("engine")
local procgen = require("engine.modules.procgen")
local platformer = require("engine.modules.platformer")
local softbody = require("engine.modules.softbody")
local rooms = require("engine.modules.rooms")
local pixelgrid = require("engine.pixelgrid")
local data = require("rooms_data")
local enemies = require("rooms_enemies")
local enemy_types = require("rooms_enemy_types")
local biomes = require("rooms_biomes")
local rooms_art = require("rooms_art")
local VERSION = "V" .. require("rooms_version") .. " E" .. engine._VERSION
local stats_mod = require("rooms_stats")
local content = require("rooms_content")
local pickups = require("rooms_pickups")
local attack_configs = require("rooms_attacks")
local vines = require("rooms_vines")
local machines = require("rooms_machines")
local looks = require("rooms_look")
local rooms_spawn = require("rooms_spawn")
local minimap = require("rooms_minimap")
local profile = require("rooms_profile")
local tracker = require("rooms_progress")
local endings = require("rooms_endings")
local wallet = require("engine.modules.wallet")
local combat = require("engine.modules.combat")
local props = require("engine.modules.props")
local prop_types = require("rooms_props").types

local W, H = 320, 180
local TS, CW, CH = data.tile_size, data.cell_w, data.cell_h
local MOVE, AIR_MOVE, JUMP, CHARGED_JUMP = 700, 300, 260, 380
local SIZE = 40
local ENEMY_H = 10                            -- the enemy box height (rooms_enemies.lua)
local SEED = 1
local FLOORS = 10

-- How a prop edge without the hangable flag pushes the slime off: px/s outward when its centre
-- is past the edge and a point rests on top (a point this close to the top counts).
local EDGE_SLIDE = { speed = 70, top = 2 }
-- A statue fires the slime's attacks on the enemy team, with its own fixed damage.
local STATUE_STATS = combat.stats.new({ max_health = 1, attack_damage = 1, invuln_time = 0 })
local TURRET_ATTACKS = {}
for i = 1, #attack_configs do
  local c = attack_configs[i]
  if c.name == "ranged" or c.name == "explosive" then TURRET_ATTACKS[c.name] = c end
end

-- The run: 10 floors from 11 rooms to 21, the special rooms of rooms_data.types(), a key per floor
local plan = procgen.floors.new({ count = FLOORS, templates = data.templates(), types = data.types(),
  rooms = { first = 11, last = 21 }, abilities = { "key" } })

local play = { plan = plan, biomes = biomes.new(FLOORS) }

-- A boss or miniboss room with enemies still alive is an arena: its doors stay shut until the
-- fight is won. Trap rooms seal the same way. A cleared room (or one without enemies) opens
-- them again.
local function battle_sealed(self, index)
  local r = self.map.rooms[index]
  if r.type ~= "boss" and r.type ~= "miniboss" and r.type ~= "trap" then return false end
  local state = self.rooms_state[index]
  if state and state.cleared then return false end
  return #(r.template.enemies or {}) > 0
end

-- The room's rows with its doors opened: rows 9..11 of the exit's cell, in the first or last
-- column. An exit without a door, a locked door the slime cannot pass yet, or a sealed arena
-- stays a wall.
local function build_rows(self, index)
  local r = self.map.rooms[index]
  local rows = {}
  for i, row in ipairs(r.template.rows) do rows[i] = row end
  self.locked = {}
  local sealed = self.sealed
  for e, exit in ipairs(r.template.exits) do
    local door = r.doors[e]
    local open = door and self.nav:can_pass(door, self.abilities) and not sealed
    if exit.side == "left" or exit.side == "right" then
      local col = exit.side == "left" and 1 or #rows[1]
      for k = 9, 11 do
        local y = exit.offset * CH + k
        if open then
          rows[y] = rows[y]:sub(1, col - 1) .. "." .. rows[y]:sub(col + 1)
        end
      end
      if door and not open and not sealed then
        self.locked[#self.locked + 1] = { x = (col - 1) * TS + 4, y = (exit.offset * CH + 8) * TS,
          w = TS - 8, h = 3 * TS }
      end
    else
      local row = exit.side == "up" and 1 or #rows
      for k = 9, 11 do
        local x = exit.offset * CW + k
        if open then
          rows[row] = rows[row]:sub(1, x - 1) .. "." .. rows[row]:sub(x + 1)
        end
      end
      if door and not open and not sealed then
        self.locked[#self.locked + 1] = { x = (exit.offset * CW + 8) * TS, y = (row - 1) * TS + 4,
          w = 3 * TS, h = TS - 8 }
      end
    end
  end
  return rows
end

-- The run's tags, for pool entries that require them (abilities and mutation tags).
local function have_tags(self)
  local have = {}
  if self.abilities then for k in pairs(self.abilities) do have[k] = true end end
  local tags = self.stats:tags()
  for k in pairs(tags) do have[k] = true end
  return have
end

-- The context of a content draw: where the drop comes from and what the run has.
local function drop_ctx(self, source, mob)
  local tags = self.stats:tags()
  return {
    source = source, mob = mob, biome = self.biome.id, floor = self.floor,
    room = self.nav.room.type, have = have_tags(self),
    build = { tags = tags, stacks = {}, stats = {}, luck = self.stats:get("luck") },
  }
end

local function spawn_pickup(self, pickup)
  local list = self.room_state.pickups
  list[#list + 1] = pickup
end

-- Applies one mutation: stats, the run's list, the look and, when it has one, the body's rest
-- shape. It never heals or damages the current health (only the new maximum is clamped).
local function acquire_mutation(self, entry)
  if not entry then return false end
  if not self.stats:acquire(entry.id) then return false end
  content.take(self.pools.mutations, entry)
  self.mutations[#self.mutations + 1] = entry
  tracker.mutation(self, entry.id)
  self.look = looks.rebuild(self.mutations)
  looks.palette(self.look, self.pixels)
  local body = looks.physical(self.look)
  if body then self.slime:set_rest_shape(body) end
  local max = self.stats:get("health")
  if self.fight and self.fight.player.health > max then self.fight.player.health = max end
  self.got = entry
  return true
end

-- A killed enemy can drop a heart or some virus. Each enemy has its own stream and rolls once.
local function mob_killed(self, agent)
  if not agent or not agent.body then return end
  profile.kill(agent.mob)
  tracker.kill(self, agent.mob)
  local b = agent.body
  local px, py = b.x + b.w / 2, b.y + b.h / 2
  local ctx = drop_ctx(self, "mob", agent.mob)
  local heart = content.drop(self.pools.hearts, self.streams:get("drop:" .. self.floor .. ":" .. self.nav.index .. ":" .. (agent.index or 0) .. ":heart"), ctx, content.chances.mob)
  if heart then spawn_pickup(self, pickups.heart(px, py, heart.heal or 1)) end
  local virus = content.drop(self.pools.virus, self.streams:get("drop:" .. self.floor .. ":" .. self.nav.index .. ":" .. (agent.index or 0) .. ":virus"), ctx, content.chances.mob)
  if virus then spawn_pickup(self, pickups.virus(px, py, virus.amount or 1)) end
end

local function prop_overlaps(prop, x, y, w, h)
  return x < prop.x + prop.w and x + w > prop.x and y < prop.y + prop.h and y + h > prop.y
end

-- The props' draw lists, rebuilt when the room loads and when a breakable one goes: solid and
-- one-way rectangles, and the spikes and statues that need their own shape.
local function build_prop_draws(self)
  local solid, one, spikes, statues = {}, {}, {}, {}
  for i = 1, self.props:count() do
    local p = self.props:at(i)
    if not p.removed then
      if p.flags.hazard then
        spikes[#spikes + 1] = p
      elseif p.flags.turret then
        statues[#statues + 1] = p
      elseif p.def.collision == "solid" then
        solid[#solid + 1] = { p.x, p.y, p.w, p.h }
      elseif p.def.collision == "one_way" then
        one[#one + 1] = { p.x, p.y, p.w, p.h }
      end
    end
  end
  self.prop_solid, self.prop_ones, self.spikes, self.statue_props = solid, one, spikes, statues
end

-- A breakable prop can drop virus; its own stream means it rolls once even if the room is
-- reloaded (a removed prop is not hit again).
local function break_prop(self, prop)
  if prop.removed or not prop.flags.breakable then return false end
  if not self.props:hit(prop, 1, self) then return false end
  build_prop_draws(self)
  local stream = self.streams:get("obstacle:" .. self.floor .. ":" .. self.nav.index .. ":" .. prop.index)
  local ctx = drop_ctx(self, "obstacle")
  local virus = content.drop(self.pools.virus, stream, ctx, prop.fields.virus_chance)
  if virus then
    spawn_pickup(self, pickups.virus(prop.x + prop.w / 2, prop.y + prop.h / 2, prop.fields.virus))
  end
  return true
end

-- The first time a room has no living enemies: a chance of virus, and the boss/miniboss reward.
local function clear_room(self)
  local state = self.room_state
  state.cleared = true
  local template = self.nav.room.template
  if #(template.enemies or {}) > 0 then
    local stream = self.streams:get("clear:" .. self.floor .. ":" .. self.nav.index)
    local ctx = drop_ctx(self, "room_clear")
    local virus = content.drop(self.pools.virus, stream, ctx, content.chances.room_clear)
    if virus then
      local x, y = self.slime:center()
      spawn_pickup(self, pickups.virus(x, y, virus.amount or 1))
    end
  end
  local kind = self.nav.room.type
  if kind == "boss" or kind == "miniboss" then
    if not state.rewarded then
      state.rewarded = true
      local entry = content.drop(self.pools.mutations,
        self.streams:get("boss:" .. self.floor .. ":" .. self.nav.index), drop_ctx(self, "boss"), 1)
      if entry then acquire_mutation(self, entry) end
    end
    play.load_room(self)
  elseif self.sealed then
    -- any other sealed arena (a trap room): rebuild it so its doors open again
    play.load_room(self)
  end
end

-- Builds the current room's grid and what is drawn from it; with x, y, puts the slime there
function play.load_room(self, x, y)
  local index = self.nav.index
  self.new_discoveries = self.new_discoveries or { enemies = {}, bosses = {}, biomes = {} }
  local state = self.rooms_state[index]
  if not state then state = { enemies = {} }; self.rooms_state[index] = state end
  if not state.enemies then state.enemies = {} end
  if not state.arrivals then state.arrivals = {} end
  self.room_state = state
  self.sealed = battle_sealed(self, index)
  local template = self.nav.room.template
  local base_grid = platformer.grid.new(build_rows(self, index), { tile_size = TS })
  -- solid and one-way room tiles merged into horizontal runs once per room: a few rectangles a
  -- row to draw. Props are drawn apart from them, below.
  local runs, ones = {}, {}
  for ty = 1, base_grid.height do
    local tx = 1
    while tx <= base_grid.width do
      local kind = base_grid:kind(tx, ty)
      if kind then
        local stop = tx
        while stop < base_grid.width and base_grid:kind(stop + 1, ty) == kind do stop = stop + 1 end
        local list = kind == "solid" and runs or ones
        list[#list + 1] = { (tx - 1) * TS, (ty - 1) * TS, (stop - tx + 1) * TS }
        tx = stop + 1
      else
        tx = tx + 1
      end
    end
  end
  self.runs, self.ones = runs, ones
  -- biome art: the solid tiles as one SpriteBatch (the variant picked from the open sides) and
  -- a few fireflies placed by the room's own stream. Without art the flat runs above are drawn.
  self.art = rooms_art.biome(self.biome.id)
  if self.art then
    self.tile_batch = rooms_art.build_tiles(self.art, base_grid)
    if not state.fireflies then
      local stream = self.streams:get("fireflies:" .. self.floor .. ":" .. index)
      local room_w, room_h = base_grid.width * TS, base_grid.height * TS
      local flies = {}
      for i = 1, 8 do
        flies[i] = {
          x = stream:float() * room_w, y = stream:float() * room_h,
          ax = 2 + stream:float() * 6, ay = 2 + stream:float() * 6,
          phase = stream:float() * math.pi * 2, speed = 0.4 + stream:float() * 0.5,
        }
      end
      state.fireflies = flies
    end
    self.fireflies = state.fireflies
  else
    self.tile_batch, self.fireflies = nil, nil
  end
  -- the room's props, with one persistent state each, stamped on the collision grid
  state.props = state.props or {}
  self.props = props.set(prop_types, template.props, { tile_size = TS, state = state.props })
  self.grid = self.props:grid(base_grid)
  build_prop_draws(self)
  -- pickups: the template's first time, then whatever the run dropped and left here
  state.pickups = state.pickups or {}
  if not state.pickups_loaded then
    for _, t in ipairs(template.pickups or {}) do
      local amount = t.amount or 1
      local px, py = (t.tx - 0.5) * TS, (t.ty - 1) * TS + 8
      local p = t.kind == "heart" and pickups.heart(px, py, amount) or pickups.virus(px, py, amount)
      state.pickups[#state.pickups + 1] = p
    end
    state.pickups_loaded = true
  end
  self.pickups = state.pickups
  -- a machine, with its own state (per machine, not per floor)
  state.machines = state.machines or {}
  self.machine, self.machine_near = nil, false
  local mt = template.machine
  if mt then
    local ms = state.machines[1]
    if not ms then ms = {}; state.machines[1] = ms end
    self.machine = machines.new(mt.kind or "healer", (mt.tx - 1) * TS + 2, (mt.ty - 1) * TS + 4, ms)
  end
  -- the room's enemies: its template spots keep their index even when cleared (the saved dead
  -- state removes them on the first step), then the enemies that fell in through a door. A
  -- template spot's type comes from the biome's weighted pool with a stream made from the room
  -- seed and the spot index, so the same room has the same enemies every time it is entered.
  -- Bosses and minibosses stay walkers; an arrival keeps the type it fell with.
  local kind = self.nav.room.type
  local boss = kind == "boss" or kind == "miniboss"
  local b = self.biome
  local m = boss and b.boss or b.mobs
  local room_seed = SEED * 100000 + self.floor * 1000 + self.nav.index
  local spots = {}
  local template_enemies = template.enemies or {}
  for i, t in ipairs(template_enemies) do
    spots[i] = { x = (t.tx - 0.5) * TS, y = t.ty * TS,
      type = boss and "walker" or enemies.pick_type(m.types, room_seed, i) }
  end
  local base = #template_enemies
  for k, a in ipairs(state.arrivals) do
    local id = a.type or "walker"
    local spec = enemy_types.types[id]
    local h = spec and spec.h or ENEMY_H
    spots[base + k] = { x = a.x, y = a.y + h / 2, type = id }   -- the arrival is a centre
  end
  local health = self.fight and not self.fight.player.dead and self.fight.player.health or nil
  -- meeting an enemy (or entering a boss room with its boss) fills the profile's Bestiary.
  if boss then
    if profile.discover("bosses", m.id) then
      self.new_discoveries.bosses[#self.new_discoveries.bosses + 1] = profile.name(m.id)
    end
  elseif #template_enemies > 0 then
    if profile.discover("enemies", m.id) then
      self.new_discoveries.enemies[#self.new_discoveries.enemies + 1] = profile.name(m.id)
    end
  end
  self.fight = enemies.new(self.slime, self.grid, spots, { boss = boss, mob = m.id,
    seed = room_seed, health = health, mode = self.fight and self.fight.mode,
    enemy_stats = combat.stats.new(biomes.enemy_stats(b, boss)), color = m.color,
    slime_source = self.stats:combat_source(), slime_mods = self.stats.mods,
    on_slime_death = function() self.dead = true end,
    on_slime_hurt = function(hit)
      -- the last thing that hurt the slime, for deaths_by; a hazard sets it just before striking
      local owner = hit.attacker and hit.attacker.owner
      if owner and owner.mob then self.last_damage_source = owner.mob
      elseif hit.attacker then self.last_damage_source = m.id end
    end,
    on_killed = function(agent) mob_killed(self, agent) end })
  -- statues: a fighter on the enemy team with the attack its fields pick, no hurtbox (so they
  -- cannot be damaged), and their own timer in the prop state
  local turrets = {}
  for i = 1, #self.statue_props do
    local p = self.statue_props[i]
    local body = { x = p.x, y = p.y, w = p.w, h = p.h,
      facing = p.fields.direction == "left" and -1 or 1 }
    local fighter = self.fight.fight:fighter({ body = body, team = "enemy", params = STATUE_STATS })
    local attack = self.fight.arsenal:equip(fighter, TURRET_ATTACKS[p.fields.attack])
    if p.state.timer == nil then p.state.timer = p.fields.delay end
    turrets[#turrets + 1] = { prop = p, fighter = fighter, attack = attack }
  end
  self.statues = turrets
  -- what the room remembers: the dead stay dead and a hurt enemy keeps its health
  for i = 1, #spots do
    local saved = state.enemies[i]
    if not saved then saved = {}; state.enemies[i] = saved end
    local e = self.fight.enemies[i]
    if saved.dead then
      e.fighter.dead = true
      e.fighter.health = 0
    else
      local hp = saved.health
      if not hp and i > base then hp = state.arrivals[i - base].health end
      if hp and hp < e.fighter.health then e.fighter.health = hp end
    end
  end
  self.kills_before = self.kills
  local item = self.nav.room.grants and not self.abilities[self.nav.room.grants] and template.item
  self.item = item and { x = (item.tx - 1) * TS + 4, y = (item.ty - 1) * TS + 4, tag = self.nav.room.grants } or nil
  -- a treasure room holds one mutation of the floor's biome, drawn the first time the room is
  -- entered (its own stream), on the pedestal until taken
  self.treasure = nil
  if kind == "treasure" and not self.taken[index] then
    local entry = self.loot[index]
    if entry == nil then
      entry = content.draw_mutation(self.pools.mutations,
        self.streams:get("reward:" .. self.floor .. ":" .. index), drop_ctx(self, "treasure")) or false
      self.loot[index] = entry
    end
    if entry then self.treasure = { x = 9.5 * TS - 4, y = 8 * TS, entry = entry } end
  end
  self.stairs = nil
  self.vines = vines.build(self, template, TS)
  if x then
    self.slime:move_to(x, y)
    self.camera:setBounds(self.nav:bounds())
    self.camera:setPosition(x, y)
  end
  self.last_health = self.fight.player.health
end

-- What happened on the floor that just ended, for rooms_spawn.end_floor. A room counts as
-- entered when the slime has visited it at least once.
local function floor_summary(self)
  local summary = { shop_existed = false, shop_entered = false, casino_appeared = false,
    treasure_existed = false, treasure_entered = false, trap_count = 0, obstacle_appeared = false,
    damaged = self.floor_damaged == true }
  for i, r in ipairs(self.map.rooms) do
    local entered = (self.nav.visits[i] or 0) > 0
    if r.type == "shop" then
      summary.shop_existed = true
      if entered then summary.shop_entered = true end
    elseif r.type == "casino" then
      summary.casino_appeared = true
    elseif r.type == "treasure" then
      summary.treasure_existed = true
      if entered then summary.treasure_entered = true end
    elseif r.type == "trap" then
      summary.trap_count = summary.trap_count + 1
    elseif r.type == "obstacle" then
      summary.obstacle_appeared = true
    end
  end
  return summary
end

-- A new run: the seed's streams, a path through the biomes, nothing taken yet
function play.new_run(self)
  self.streams = engine.rng.streams(SEED)
  local unlocked = tracker.unlocked()
  for tag in pairs(unlocked) do play.biomes:unlock(tag) end   -- unlocked biomes join the path
  self.path = play.biomes:path()
  self.pools = content.new_pools({ unlocked = unlocked })
  tracker.new_run(self)
  self.stats = stats_mod.new(content.mutations)
  self.wallet = wallet.new({ virus = 0 })
  self.mutations = {}
  self.look = looks.new()
  if self.pixels then looks.palette(self.look, self.pixels) end
  if self.slime then self.slime:set_rest_shape({ radius = 9, width = 0, height = 0 }) end
  self.kills, self.got = 0, nil
  self.result, self.result_recorded = nil, false
  self.last_damage_source = nil
  self.new_discoveries = { enemies = {}, bosses = {}, biomes = {} }
  self.spawn = rooms_spawn.new_state()
  self.rooms_state = {}
end

-- Floor n: its biome (chosen when the last one ends, from what the run did), a fresh map from
-- its own stream, the key to find again, the slime at the start
function play.new_floor(self, n)
  if n == 1 then play.new_run(self) end
  if n > 1 and self.map and self.spawn then
    rooms_spawn.end_floor(self.spawn, floor_summary(self))
  end
  self.floor = n
  tracker.new_floor(self, n)
  self.biome = self.path:enter(n, { kills = self.kills, floor = n }, self.streams:get("biomes"))
  self.new_discoveries = self.new_discoveries or { enemies = {}, bosses = {}, biomes = {} }
  if profile.discover("biomes", self.biome.id) then
    self.new_discoveries.biomes[#self.new_discoveries.biomes + 1] =
      self.biome.name or profile.name(self.biome.id)
  end
  self.music = self.biome.music      -- a game with tracks: audio:music(self.music, { fade = 1 })
  self.map = assert(plan:generate(n, self.streams:get("floor" .. n), self.biome,
    { spawn = self.spawn, luck = self.stats:get("luck") }))
  self.nav = rooms.nav.new(self.map, { cell_w = CW * TS, cell_h = CH * TS, tile_size = TS })
  self.abilities, self.taken, self.loot = {}, {}, {}
  self.rooms_state, self.room_state = {}, nil
  self.message, self.message_time = nil, nil
  self.floor_damaged = false
end

function play:enter()
  play.new_floor(self, 1)
  self.fade = rooms.transition.new({ kind = "fade", time = 0.3 })
  self.camera = engine.camera.new({ width = W, height = H, lerp = 10, deadzone_w = 24, deadzone_h = 16 })
  self.slime = softbody.new({ radius = 9, points = 18 })
  self.pixels = pixelgrid.new(SIZE, SIZE, { palette = {
    { 0.98, 0.90, 0.52 }, { 0.10, 0.30, 0.16 }, { 0.95, 1.00, 0.95 }, { 0.05, 0.08, 0.06 },
    { 0.75, 0.85, 0.60 },
  } })
  looks.palette(self.look, self.pixels)
  self.points = {}
  self.facing, self.charging = 1, false
  self.dead, self.deaths = false, 0
  self.game_over_pending = false
  self.run_time = 0
  profile.get()
  self.audio = profile.audio
  local x, y = self.nav:enter(self.map.start)
  play.load_room(self, x, y)
end

-- A new run from the first floor, as enter() starts one (the pause menu's Restart run).
function play.restart(self)
  play.enter(self)
end

function play:input(input)
  if input:pressed("pause") then engine.states:push("pause") end
end

local function control(self, dt)
  local input, slime = engine.controls, self.slime
  local move = input:axis("move_x")
  if move ~= 0 then self.facing = move > 0 and 1 or -1 end
  self.fight.box.facing = self.facing            -- the attacks aim where the slime looks
  if input:pressed("switch") then self.fight:switch() end
  if input:pressed("attack") then self.fight:attack() end
  local speed, jump = self.stats:get("speed"), self.stats:get("jump")
  slime:push(move * (slime:on_ground() and MOVE or AIR_MOVE) * speed, 0)
  local squash = input:down("down")
  slime.inflate = squash and 0.7 or 1
  if squash and slime:on_ground() then self.charging = true end
  if input:pressed("jump") and slime:on_ground() then
    slime:impulse(0, -JUMP * jump)
  elseif self.charging and not squash then
    if slime:on_ground() then slime:impulse(0, -CHARGED_JUMP * jump) end
    self.charging = false
  end
end

-- An enemy whose body is past an edge leaves the room. With a door there it moves to the room on
-- the other side, to appear there next time keeping its health; with none, or an exit that leads
-- nowhere, it dies. Neither is a kill (no on_killed, no kill count, no drop).
local function enemies_leaving(self)
  for i = 1, #self.fight.enemies do
    local e = self.fight.enemies[i]
    local f = e.fighter
    if not f.dead and e.move ~= "fly" then        -- flyers never fall through a pit
      local body = e.body
      local x, y = body.x + body.w / 2, body.y + body.h / 2
      local _, door, side = self.nav:leaving(x, y)
      if side then
        local health = f.health
        f.dead, f.health = true, 0
        if door then
          local target, entry = self.nav:through(door)
          local ax, ay = self.nav:arrival(target, entry)
          local ts = self.rooms_state[target]
          if not ts then ts = { enemies = {} }; self.rooms_state[target] = ts end
          ts.arrivals = ts.arrivals or {}
          ts.arrivals[#ts.arrivals + 1] = { x = ax, y = ay, health = health, type = e.type }
        end
      end
    end
  end
end

-- Pushes the slime off the edge of a one-way or solid prop that is not hangable when its centre
-- is past that edge and a point still rests on top, so it slides off and falls.
local function slide_off_edges(self)
  local slime = self.slime
  local x, y, n = slime.x, slime.y, slime.n
  local cx = slime:center()
  for i = 1, self.props:count() do
    local p = self.props:at(i)
    if not p.removed and p.def.collision and not p.flags.hangable then
      local left, right, top = p.x, p.x + p.w, p.y
      if cx < left or cx > right then
        local resting = false
        for k = 1, n do
          local px, py = x[k], y[k]
          if py >= top - EDGE_SLIDE.top and py <= top + EDGE_SLIDE.top
            and px >= left and px <= right then
            resting = true
            break
          end
        end
        if resting then
          slime:set_velocity(cx < left and -EDGE_SLIDE.speed or EDGE_SLIDE.speed, nil)
        end
      end
    end
  end
end

-- Touching a hazard prop costs its damage through the slime's normal damage path (so it gets
-- i-frames) and knocks it away from the prop.
local function hurt_by_spikes(self)
  local player = self.fight.player
  if player.dead or player.invuln > 0 then return end
  local x0, y0, x1, y1 = self.slime:bounds()
  for i = 1, #self.spikes do
    local p = self.spikes[i]
    if not p.removed and x0 < p.x + p.w and x1 > p.x and y0 < p.y + p.h and y1 > p.y then
      local cx = self.slime:center()
      local dir = cx < p.x + p.w / 2 and -1 or 1
      self.last_damage_source = "spikes"
      self.fight.fight:strike(nil, player, { damage = p.fields.damage, knockback = 160,
        kx = dir, ky = -0.5 })
      return
    end
  end
end

-- The statues: every interval seconds (after delay) they fire their attack on the enemy team.
-- Their timers are numbers in the prop state, so this allocates nothing.
function play.update_props(self, dt)
  local statues = self.statues
  for i = 1, #statues do
    local s = statues[i]
    local p = s.prop
    if not p.removed then
      local timer = p.state.timer - dt
      if timer <= 0 then
        s.attack:trigger()
        timer = timer + p.fields.interval
      end
      p.state.timer = timer
    end
  end
end

-- Ends the run in the profile exactly once. A loss also counts who landed the last hit.
local function record_result(self, result)
  if self.result_recorded then return end
  self.result_recorded = true
  if result == "loss" then
    local source = self.last_damage_source
    if not source and self.biome then source = self.biome.mobs.id end
    profile.death_by(source)
  end
  profile.finish_run(result)
end

function play:update(dt)
  self.fade:update(dt)
  if self.fade:busy() then return end            -- the room is frozen while the screen fades
  if self.game_over_pending then                 -- the fade is over: the run ends here
    self.game_over_pending = false
    if self.result == "win" then
      local ending = endings.pick(self)
      local id = ending.id
      -- The cutscene goes over the play state (the menu needs its stats), and its finish
      -- replaces it with the end-of-run menu, so play stays under gameover as after a death.
      engine.states:push("cutscene", ending.script, function(skipped)
        profile.see_ending(id)
        engine.states:pop()
        engine.states:push("gameover")
      end)
    else
      engine.states:push("gameover")
    end
    return
  end
  if self.dead then                               -- dying ends the run, behind a fade
    self.dead, self.deaths = false, self.deaths + 1
    self.floor_damaged = true                       -- a death counts as damage for the floor
    self.result = "loss"
    tracker.run_end(self, "loss")
    record_result(self, "loss")
    self.game_over_pending = true
    self.fade:start(function()
      self.fight.player.dead = true                -- the run's slime stays dead under the menu
    end)
    return
  end
  self.run_time = self.run_time + dt
  control(self, dt)
  vines.update(self, dt, engine.controls, JUMP * self.stats:get("jump"))
  self.slime:step(dt, self.grid)
  slide_off_edges(self)
  hurt_by_spikes(self)
  play.update_props(self, dt)
  self.fight:step(dt)
  if self.last_health and self.fight.player.health < self.last_health then
    self.floor_damaged = true
    tracker.hit(self)
  end
  self.last_health = self.fight.player.health
  enemies_leaving(self)
  self.stats:update(dt)
  self.kills = self.kills_before + self.fight.kills
  -- remember the fight: the dead stay dead and a hurt enemy keeps its health next time
  local state = self.room_state
  for i = 1, #self.fight.enemies do
    local e = self.fight.enemies[i]
    local saved = state.enemies[i]
    if not saved then saved = {}; state.enemies[i] = saved end
    saved.dead = e.fighter.dead
    saved.health = e.fighter.health
  end
  -- a won fight clears the room; a boss or miniboss gives a mutation and opens its doors
  if not state.cleared and self.fight:alive() == 0 then clear_room(self) end
  local cx, cy = self.slime:center()
  -- the key: picked up by touching it; the room is rebuilt so its locked doors open
  local it = self.item
  if it and cx > it.x - 6 and cx < it.x + 14 and cy > it.y - 10 and cy < it.y + 14 then
    self.abilities[it.tag] = true
    play.load_room(self)
  end
  -- treasure: one mutation for the run; the room is rebuilt so its stats count, without healing
  local h = self.treasure
  if h and cx > h.x - 6 and cx < h.x + 14 and cy > h.y - 10 and cy < h.y + 14 then
    if acquire_mutation(self, h.entry) then
      self.taken[self.nav.index], self.treasure = true, nil
      play.load_room(self)
    end
  end
  -- pickups: hearts heal (a full one becomes virus), virus goes to the wallet
  for i = #self.pickups, 1, -1 do
    local p = self.pickups[i]
    if pickups.overlaps(p, cx, cy) then
      if p.kind == "heart" then
        local max = self.stats:get("health")
        local health = self.fight.player.health
        tracker.heart(self)
        if health < max then
          self.fight.player.health = math.min(max, health + (p.amount or 1))
        else
          self.wallet:add("virus", 1)
        end
      elseif p.kind == "virus" then
        self.wallet:add("virus", p.amount or 1)
      end
      table.remove(self.pickups, i)
    end
  end
  -- breakable props: with the attack in front, or by falling on them
  local input = engine.controls
  if input:pressed("attack") then
    local bx = self.facing > 0 and cx + 4 or cx - 24
    for i = 1, self.props:count() do
      local p = self.props:at(i)
      if p.flags.breakable and not p.removed and prop_overlaps(p, bx, cy - 10, 20, 20) then
        break_prop(self, p)
      end
    end
  end
  local _, vy = self.slime:velocity()
  if vy > 120 then
    local x0, y0, x1, y1 = self.slime:bounds()
    for i = 1, self.props:count() do
      local p = self.props:at(i)
      if p.flags.breakable and not p.removed and prop_overlaps(p, x0, y1 - 2, x1 - x0, 6) then
        break_prop(self, p)
      end
    end
  end
  -- the test machine: buy with the interact action when the slime is next to it
  local mc = self.machine
  if mc then
    local near = cx > mc.x - 20 and cx < mc.x + 32 and cy > mc.y - 24 and cy < mc.y + 28
    self.machine_near = near
    if near and input:pressed("interact") then
      local effect, reason = machines.buy(mc, self.wallet)
      if effect == "heal_full" then
        self.fight.player.health = self.stats:get("health")
        self.message, self.message_time = "HEALED", 1.0
      elseif not effect then
        self.message, self.message_time = tostring(reason):upper(), 1.2
      end
    end
  else
    self.machine_near = false
  end
  if self.message_time then
    self.message_time = self.message_time - dt
    if self.message_time <= 0 then self.message, self.message_time = nil, nil end
  end
  -- the boss room, once cleared, opens a stairway down to the next floor; the last floor's boss
  -- ends the run as a victory instead (no stairs, the menu comes after the fade)
  if self.nav.room.type == "boss" and not self.stairs and not self.game_over_pending
      and self.fight:alive() == 0 then
    if self.floor >= FLOORS then
      self.result = "win"
      tracker.floor_end(self)
      tracker.run_end(self, "win")
      record_result(self, "win")
      self.game_over_pending = true
      self.fade:start(nil)
    else
      self.stairs = { x = 9 * TS, y = 10 * TS }
    end
  end
  local st = self.stairs
  if st and cx > st.x - 4 and cx < st.x + 2 * TS + 4 and cy > st.y - 12 then
    tracker.floor_end(self)
    self.fade:start(function()
      local health = self.fight.player.health
      play.new_floor(self, self.floor % FLOORS + 1)
      play.load_room(self, self.nav:enter(self.map.start))
      self.fight.player.health = health
      self.last_health = health
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
  local out = slime:outline(self.points, ox, oy, 1, alpha)
  looks.shape(out, self.look)
  px:polygon(out, 1)
  px:outline(2)
  looks.shade(px)
  looks.draw_limbs(px, self.look, out)
  local x0, y0, x1 = slime:bounds()
  local ex = math.floor((x0 + x1) / 2 - ox) + 1 + self.facing * 2
  local ey = math.floor(y0 - oy) + 5
  local pupil = self.facing > 0 and 1 or 0
  local count = self.look.eye_count or 2
  local start = math.floor(ex - 3 - (count - 2) * 2.5 + 0.5)
  for i = 0, count - 1 do
    local dx = start + i * 5
    px:set(dx, ey, 3); px:set(dx + 1, ey, 3)
    px:set(dx, ey + 1, 3); px:set(dx + 1, ey + 1, 3)
    px:set(dx + pupil, ey + 1, 4)
  end
  px:draw(ox, oy)
end

local MINIMAP_CELL = 7
local MINIMAP_OPTS = { cell = MINIMAP_CELL }
local LABELS = { treasure = "TREASURE", super_treasure = "SUPER TREASURE", shop = "SHOP",
  casino = "CASINO", pact = "PACT", miniboss = "MINIBOSS", boss = "BOSS", trap = "TRAP",
  obstacle = "OBSTACLE" }

local function draw_minimap(self)
  local mm = self.nav:minimap()
  local x0, y0 = W - mm.w * MINIMAP_CELL - 4, 4
  minimap.draw(love.graphics, mm, self.nav.index, x0, y0, MINIMAP_OPTS)
end

-- A few fireflies per room: an additive glow and a bright centre, drifting with sin and cos of
-- time. Their positions and phases were picked when the room loaded, so this allocates nothing.
local function draw_fireflies(self, g)
  local flies, color = self.fireflies, self.biome.glow
  if not flies or not color then return end
  local glow = rooms_art.glow()
  local t = love.timer.getTime()
  g.setBlendMode("add")
  g.setColor(color[1], color[2], color[3], 0.5)
  for i = 1, #flies do
    local f = flies[i]
    local x = f.x + math.sin(t * f.speed + f.phase) * f.ax
    local y = f.y + math.cos(t * f.speed * 0.8 + f.phase) * f.ay
    g.draw(glow, math.floor(x) - 16, math.floor(y) - 16)
  end
  g.setColor(1, 1, 1, 1)
  for i = 1, #flies do
    local f = flies[i]
    local x = math.floor(f.x + math.sin(t * f.speed + f.phase) * f.ax)
    local y = math.floor(f.y + math.cos(t * f.speed * 0.8 + f.phase) * f.ay)
    g.rectangle("fill", x, y, 1, 1)
  end
  g.setBlendMode("alpha")
end

function play:draw(alpha)
  local g, camera = love.graphics, self.camera
  local colors = self.biome.colors
  local art, boss = self.art, self.nav.room.type == "boss"
  if art then
    local cam_x, cam_y = camera:getDrawPosition(alpha)
    rooms_art.draw_background(art, cam_x, cam_y)
  end
  camera:attach(alpha)
  if art then
    if boss then g.setColor(0.8, 0.6, 0.65, 1) else g.setColor(1, 1, 1, 1) end
    g.draw(self.tile_batch, 0, 0)
  else
    if boss then g.setColor(0.32, 0.16, 0.20, 1) else g.setColor(colors.wall[1], colors.wall[2], colors.wall[3], 1) end
    for i = 1, #self.runs do local r = self.runs[i]; g.rectangle("fill", r[1], r[2], r[3], TS) end
  end
  g.setColor(colors.ledge[1], colors.ledge[2], colors.ledge[3], 1)
  for i = 1, #self.ones do local r = self.ones[i]; g.rectangle("fill", r[1], r[2], r[3], 3) end
  if art then draw_fireflies(self, g) end
  -- prop collision, drawn like the room's own walls and ledges
  g.setColor(colors.wall[1], colors.wall[2], colors.wall[3], 1)
  for i = 1, #self.prop_solid do local r = self.prop_solid[i]; g.rectangle("fill", r[1], r[2], r[3], r[4]) end
  g.setColor(colors.ledge[1], colors.ledge[2], colors.ledge[3], 1)
  for i = 1, #self.prop_ones do local r = self.prop_ones[i]; g.rectangle("fill", r[1], r[2], r[3], 3) end
  -- spikes: a row of small teeth along the bottom of the prop
  for i = 1, #self.spikes do
    local p = self.spikes[i]
    local c = p.def.editor.color
    g.setColor(c[1], c[2], c[3], 1)
    g.rectangle("fill", p.x, p.y + p.h - 2, p.w, 2)
    local j = 1
    while j + 1 < p.w do
      g.rectangle("fill", p.x + j, p.y + p.h - 6, 2, 4)
      j = j + 4
    end
  end
  -- statues: a grey block with a darker eye on the side it faces
  for i = 1, #self.statue_props do
    local p = self.statue_props[i]
    local c = p.def.editor.color
    g.setColor(c[1], c[2], c[3], 1)
    g.rectangle("fill", p.x, p.y, p.w, p.h)
    g.setColor(0.20, 0.22, 0.26, 1)
    local right = p.fields.direction ~= "left"
    g.rectangle("fill", right and p.x + p.w - 6 or p.x + 2, p.y + 4, 4, 4)
  end
  g.setColor(0.95, 0.75, 0.20, 1)
  for i = 1, #self.locked do local l = self.locked[i]; g.rectangle("fill", l.x, l.y, l.w, l.h) end
  vines.draw(self, g)
  if self.machine then machines.draw(self.machine, g, false) end
  if self.item then g.rectangle("fill", self.item.x, self.item.y, 8, 8) end
  local tr = self.treasure
  if tr then
    local c = tr.entry.color or { 1, 1, 1 }
    g.setColor(c[1], c[2], c[3], 1); g.rectangle("fill", tr.x, tr.y, 8, 8)
    g.setColor(1, 1, 1, 0.8)
    engine.text.draw(tr.entry.name, tr.x + 4 - engine.text.width(tr.entry.name) / 2, tr.y - 10)
  end
  for i = 1, #self.pickups do
    local p = self.pickups[i]
    local c = pickups.color(p)
    g.setColor(c[1], c[2], c[3], 1)
    g.rectangle("fill", p.x - 4, p.y - 4, 8, 8)
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
  self.fight:draw(alpha, self.nav.room.type == "boss" or self.nav.room.type == "miniboss")
  g.setColor(1, 1, 1, 1)
  -- the slime blinks while nothing can hurt it
  local p = self.fight.player
  if not (p:invulnerable() and math.floor(p.invuln * 12) % 2 == 1) then draw_slime(self, alpha) end
  camera:detach()
  g.setColor(1, 1, 1, 1)
  local maxhp = self.stats:get("health")
  local sh, shmax = self.stats:shield()
  engine.text.draw("HP " .. p.health .. "/" .. maxhp, 4, 4)
  engine.text.draw("VIRUS " .. self.wallet:get("virus"), 4, 12)
  engine.text.draw("SH " .. sh .. "/" .. shmax .. " LUCK " .. self.stats:get("luck"), 4, 20)
  engine.text.draw("FLOOR " .. self.floor .. "/" .. FLOORS .. " " .. self.biome.name, 4, 28)
  if self.got then engine.text.draw("GOT " .. self.got.name, 4, 36) end
  if self.machine and self.machine_near then
    local left = machines.uses_left(self.machine)
    local text = left > 0 and ("B HEAL " .. self.machine.def.price .. " VIRUS") or "HEALER USED"
    engine.text.draw(text, (W - engine.text.width(text)) / 2, H - 12)
  end
  if self.message then
    engine.text.draw(self.message, (W - engine.text.width(self.message)) / 2, H - 22)
  end
  draw_minimap(self)
  -- FPS and build version, bottom left (the FPS text is rebuilt only when the number changes)
  local fps = love.timer.getFPS()
  if fps ~= self.fps_shown then self.fps_shown, self.fps_text = fps, "FPS " .. fps end
  engine.text.draw(self.fps_text, 4, H - 13)
  engine.text.draw(VERSION, 4, H - 7)
  local cover = self.fade:cover(alpha)
  if cover > 0 then
    g.setColor(0, 0, 0, cover)
    g.rectangle("fill", 0, 0, W, H)
  end
  g.setColor(1, 1, 1, 1)
end

return play
