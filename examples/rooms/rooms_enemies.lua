-- The fight in a room: the slime and the room's enemies as fighters of one combat world. An
-- enemy type (rooms_enemy_types.lua) says how its body moves: "walk" bodies are platformer
-- controllers with gravity, "fly" bodies are plain tables moved with combat.behaviours.fly_move
-- in the same bump world. Every type's brain and stats are built once per room from the type's
-- data and shared by its enemies; one enemy arsenal steps every type's attacks. The slime is a
-- soft body seen by combat through softbody.box. The slime hurts an enemy by landing on it (a
-- hitbox under the body while it falls) and bounces off; an enemy's bite or contact hurts the
-- slime and knocks it back. The slime also has three attacks (rooms_attacks.lua,
-- combat.attacks configs): melee, ranged and explosive (the bomb), each on its own button:
-- Fight:melee(), Fight:shoot(ax, ay) and Fight:bomb(); opts.attacks replaces the configs (the
-- run's ranged attack changes with its shot mutations).
-- Everything here is rebuilt when a room is entered; the play state then
-- restores the room's enemies (the dead stay dead and a hurt one keeps its health).
local platformer = require("engine.modules.platformer")
local combat = require("engine.modules.combat")
local softbody = require("engine.modules.softbody")
local rng = require("engine.rng")
local attack_configs = require("rooms_attacks")
local enemy_types = require("rooms_enemy_types")
local rooms_art = require("rooms_art")

local B = combat.behaviours
local STOMP_SPEED = 120                     -- px/s down: falling at least this fast hurts below
local BOUNCE = -230                         -- px/s: the slime's bounce after a stomp
local CONTACT_KNOCKBACK = 120               -- px/s: a contact hitbox pushes the slime away

local SLIME_STATS = combat.stats.new({ max_health = 5, attack_damage = 1, invuln_time = 1.0 })
local ENEMY_STATS = combat.stats.new({ max_health = 2, attack_damage = 1, invuln_time = 0.25 })
local BOSS_STATS = combat.stats.new({ max_health = 6, attack_damage = 2, invuln_time = 0.4, knockback_resist = 0.5 })
local ENEMY_PARAMS = platformer.params.new({ max_speed = 35, ground_accel = 600, air_accel = 400 })

-- An enemy's movement: the shared parameters, except max_speed (which its state asks for) and
-- jump_velocity (which a hop writes to agent.jump_velocity).
local EnemyStats = {}
EnemyStats.__index = EnemyStats
function EnemyStats:get(name)
  if name == "max_speed" then
    return self.agent.move_speed or self.agent.type_speed or ENEMY_PARAMS.max_speed
  end
  if name == "jump_velocity" then
    return self.agent.jump_velocity or ENEMY_PARAMS.jump_velocity
  end
  return ENEMY_PARAMS[name]
end

local function blocked(agent) return agent.body.wall ~= 0 end

-- A value of a combat.stats table or of anything with :get(name) (the type's multipliers apply
-- over it).
local function stat_value(stats, name)
  if type(stats.get) == "function" then return stats:get(name) end
  return stats[name]
end

-- The type's stats: the biome's, with its health and damage multipliers. Built once per type
-- per room, never per enemy.
local function type_stats(base, spec)
  local health = stat_value(base, "max_health") * (spec.health or 1)
  if health < 1 then health = 1 end
  local damage = stat_value(base, "attack_damage") * (spec.damage or 1)
  if damage < 0 then damage = 0 end
  return combat.stats.new({
    max_health = health, attack_damage = damage,
    invuln_time = stat_value(base, "invuln_time"),
    knockback_resist = stat_value(base, "knockback_resist"),
  })
end

local M = { SLIME_STATS = SLIME_STATS }
local Fight = {}
Fight.__index = Fight

-- The type a room's weighted pool gives spot `index`. The stream is made from the room seed and
-- the spot index, so re-entering a room gives the same enemies and a seed is enough to know them.
-- The registry order (not pairs) drives the draw, so PC and the console agree.
function M.pick_type(pool, seed, index)
  if not pool then return "walker" end
  local total = 0
  for i = 1, #enemy_types.order do
    local id = enemy_types.order[i]
    local w = pool[id]
    if w and w > 0 then total = total + w end
  end
  if total <= 0 then return "walker" end
  local r = rng.new(seed * 100 + index):float() * total
  for i = 1, #enemy_types.order do
    local id = enemy_types.order[i]
    local w = pool[id]
    if w and w > 0 then
      r = r - w
      if r < 0 then return id end
    end
  end
  return "walker"
end

-- M.new(slime, grid, spots, opts): spots = { { x, y } ... } (the bottom centre of each enemy, room
-- pixels); opts.boss (stronger enemies), opts.seed (their patrol pauses), opts.health (the
-- slime's health carried over from the last room), opts.attacks (the slime's attack configs,
-- default rooms_attacks), opts.on_slime_death, opts.on_killed; the biome's: opts.enemy_stats,
-- opts.slime_stats (a combat.stats table or a stat source), opts.slime_source/opts.slime_mods
-- (the run's stats), opts.mob (the mob id of this room) and opts.color (the enemies' colour)
function M.new(slime, grid, spots, opts)
  opts = opts or {}
  local self = setmetatable({ slime = slime, enemies = {}, stomps = 0, kills = 0, color = opts.color }, Fight)
  self.world = platformer.collision.newWorld(grid)
  self.room_w, self.room_h = grid.width * grid.tile_size, grid.height * grid.tile_size
  self.fight = combat.world.new()
  self.box = softbody.box(slime)
  local me = self
  local slime_stats = opts.slime_stats
  local slime_source = opts.slime_source
  if not slime_source and type(slime_stats) == "table" and type(slime_stats.get) == "function" then
    slime_source = slime_stats
  end
  local slime_params = (not slime_source) and (slime_stats or SLIME_STATS) or nil
  self.player = self.fight:fighter({ body = self.box, team = "player", stats = slime_source,
    mods = opts.slime_mods, params = slime_params, health = opts.health,
    on_hurt = function(_, hit) me.box:knock(hit) end,
    on_death = opts.on_slime_death })
  self.hurt = self.player:hurtbox({ w = 1, h = 1 })
  self.stomp = self.player:hitbox({ w = 1, h = 6, power = 1, knockback = 90, away = true, ky = -0.5 })
  -- the slime's attacks: shots and bombs stop at the room's solid tiles
  self.arsenal = combat.attacks.new(self.fight, { grid = grid, max_projectiles = 24 })
  self.enemy_arsenal = combat.attacks.new(self.fight, { grid = grid, max_projectiles = 32 })
  self.attacks = {}
  local configs = opts.attacks or attack_configs
  for i = 1, #configs do
    local c = configs[i]
    self.attacks[i] = self.arsenal:equip(self.player, c)
    self.attacks[c.name] = self.attacks[i]
  end
  self.on_killed = opts.on_killed
  self.fight.on_hit = function(hit)
    if hit.killed and hit.target ~= me.player and hit.hitbox ~= me.stomp then
      me.kills = me.kills + 1
    end
    if hit.hitbox == me.stomp then             -- a stomp landed: bounce off
      me.stomps = me.stomps + 1
      me.slime:set_velocity(nil, BOUNCE)
      if hit.killed then me.kills = me.kills + 1 end
    end
    if hit.killed and hit.target ~= me.player and me.on_killed then
      me.on_killed(hit.target.owner, hit)
    end
  end
  local base_stats = opts.enemy_stats or (opts.boss and BOSS_STATS or ENEMY_STATS)
  local built_stats, built_brains = {}, {}
  local stream = rng.new(opts.seed or 1)
  for i = 1, #spots do
    local s = spots[i]
    local id = s.type or "walker"
    local spec = enemy_types.types[id]
    if not spec then
      error("rooms_enemies: unknown enemy type " .. tostring(id) .. " at spot " .. i, 2)
    end
    local brain, stats = built_brains[id], built_stats[id]
    if not brain then
      brain = combat.brains.build(spec.brain, { grid = grid, blocked = blocked })
      stats = type_stats(base_stats, spec)
      built_brains[id], built_stats[id] = brain, stats
    end
    local w, h = spec.w, spec.h
    local agent = { target = self.box, rng = stream, index = i, mob = opts.mob,
      type = id, move = spec.move, shape = spec.look and spec.look.shape or id,
      type_speed = spec.speed, patrol_points = { { x = s.x - 40 }, { x = s.x + 40 } } }
    if spec.move == "fly" then
      agent.body = { x = s.x - w / 2, y = s.y - h, w = w, h = h,
        px = s.x - w / 2, py = s.y - h, facing = 1, world = self.world }
      self.world:add(agent.body, agent.body.x, agent.body.y, w, h)
    else
      agent.body = platformer.controller.new(self.world, { x = s.x - w / 2, y = s.y - h, w = w, h = h,
        stats = setmetatable({ agent = agent }, EnemyStats), actions = { move_x = "move_x" } })
    end
    agent.fighter = self.fight:fighter({ body = agent.body, team = "enemy", owner = agent,
      params = stats })
    agent.fighter:hurtbox({ w = w, h = h })
    agent.hitboxes = {}
    if spec.hitboxes then
      for name, hb in pairs(spec.hitboxes) do
        agent.hitboxes[name] = agent.fighter:hitbox({ ox = hb.ox, oy = hb.oy, w = hb.w, h = hb.h,
          power = hb.power, damage = hb.damage, knockback = hb.knockback, kx = hb.kx, ky = hb.ky,
          away = hb.away })
      end
    end
    if spec.contact then
      agent.contact = agent.fighter:hitbox({ ox = 0, oy = 0, w = w, h = h,
        knockback = CONTACT_KNOCKBACK, ky = -0.4 })
      agent.contact:activate()
    end
    if spec.attacks then
      agent.attacks = {}
      for name, config in pairs(spec.attacks) do
        agent.attacks[name] = self.enemy_arsenal:equip(agent.fighter, config)
      end
    end
    agent.machine = combat.fsm.new(brain, agent)
    agent.input = B.input(agent)
    self.enemies[i] = agent
  end
  self:sync()
  return self
end

-- The slime's boxes follow its soft body: the hurtbox is its box shrunk a little, the stomp box
-- is a strip under it, active only while it falls fast
function Fight:sync()
  local box, slime = self.box, self.slime
  box:sync()
  self.hurt:set(2, 2, box.w - 4, box.h - 4)
  self.stomp:set(1, box.h - 3, box.w - 2, 6)
  local _, vy = slime:velocity()
  if vy > STOMP_SPEED and not self.stomp.active then
    self.stomp:activate()
  elseif vy <= STOMP_SPEED and self.stomp.active then
    self.stomp:deactivate()
  end
end

-- The slime's three attacks, each on its own button. Each returns true if it started.
-- shoot(ax, ay): toward that direction, or the facing when nil or (0, 0).
function Fight:melee() return self.attacks.melee:trigger() end
function Fight:shoot(ax, ay) return self.attacks.ranged:trigger(ax, ay) end
function Fight:bomb() return self.attacks.explosive:trigger() end
function Fight:can_bomb() return self.attacks.explosive:ready() end

-- One fixed step, after the slime stepped. Returns the hits that landed.
function Fight:step(dt)
  self:sync()
  for i = 1, #self.enemies do
    local e = self.enemies[i]
    local f, body = e.fighter, e.body
    if f.dead then
      if not e.removed then
        e.removed = true
        self.fight:remove(f)
        if e.move == "fly" then
          if self.world:hasItem(body) then self.world:remove(body) end
        else
          body:remove()
        end
      end
    elseif not f:frozen() then
      e.machine:update(dt)
      if e.move == "fly" then
        B.fly_move(e, self.world, platformer.collision.filter, dt)
        -- a flyer stays inside the room: the door gaps would let it out, and a room is only
        -- cleared when every enemy is dead
        local nx, ny = body.x, body.y
        if nx < 0 then nx = 0 elseif nx > self.room_w - body.w then nx = self.room_w - body.w end
        if ny < 0 then ny = 0 elseif ny > self.room_h - body.h then ny = self.room_h - body.h end
        if nx ~= body.x or ny ~= body.y then
          body.x, body.y = nx, ny
          self.world:update(body, nx, ny)
        end
      else
        body:step(e.input, dt)
      end
      -- touching hurts, except while the slime stomps: landing on an enemy is its attack
      if e.contact then
        if self.stomp.active then e.contact:deactivate() else e.contact:activate() end
      end
    else
      body.px, body.py = body.x, body.y
    end
  end
  self.arsenal:step(dt)
  self.enemy_arsenal:step(dt)
  return self.fight:step(dt)
end

function Fight:alive()
  local n = 0
  for i = 1, #self.enemies do if not self.enemies[i].fighter.dead then n = n + 1 end end
  return n
end

-- Draws the living enemies (room pixels): a body, an eye on the facing side, and the bite's
-- box while it is out. Red while hurt.
function Fight:draw(alpha, boss)
  local g = love.graphics
  for i = 1, #self.enemies do
    local e = self.enemies[i]
    if not e.fighter.dead then
      local b = e.body
      local x = math.floor(b.px + (b.x - b.px) * alpha + 0.5)
      local y = math.floor(b.py + (b.y - b.py) * alpha + 0.5)
      if e.fighter:invulnerable() then g.setColor(1, 0.35, 0.35, 1)
      elseif self.color then g.setColor(self.color[1], self.color[2], self.color[3], 1)
      elseif boss then g.setColor(0.85, 0.30, 0.55, 1)
      else g.setColor(0.85, 0.55, 0.25, 1) end
      if e.machine and e.machine.phase == "windup" then g.setColor(1, 0.95, 0.65, 1) end
      rooms_art.draw_enemy(x, y, b.w, b.h, b.facing, boss, e.shape)
      local bite = e.hitboxes and e.hitboxes.bite
      if bite and bite.active then
        local bx, by, bw, bh = bite:rect()
        g.setColor(1, 1, 1, 0.8)
        g.rectangle("fill", math.floor(bx + 0.5), math.floor(by + 0.5), bw, bh)
      end
    end
  end
  self:draw_enemy_attacks(alpha)
  self:draw_attacks(alpha)
  g.setColor(1, 1, 1, 1)
end

-- The enemies' shots, on the pixel grid like the slime's, in a colour of their own.
function Fight:draw_enemy_attacks(alpha)
  local g = love.graphics
  local list = self.enemy_arsenal.projectiles
  g.setColor(0.95, 0.35, 0.45, 1)
  for i = 1, #list do
    local p = list[i]
    if p.alive then
      local x, y = combat.attacks.position(p, alpha)
      g.rectangle("fill", x, y, p.w, p.h)
    end
  end
end

-- The slime's attacks, on the pixel grid: the melee box while it is out, the shots, the bombs
-- (blinking faster as the fuse runs out) and each blast as a disc of 2 px rows.
function Fight:draw_attacks(alpha)
  local g = love.graphics
  local melee = self.attacks.melee.hitbox
  if melee and melee.active then
    local bx, by, bw, bh = melee:rect()
    g.setColor(0.95, 1.00, 0.95, 0.7)
    g.rectangle("fill", math.floor(bx + 0.5), math.floor(by + 0.5), bw, bh)
  end
  local list = self.arsenal.projectiles
  for i = 1, #list do
    local p = list[i]
    if p.alive then
      local x, y = combat.attacks.position(p, alpha)
      if p.kind == "bomb" then
        if math.floor(p.life * (p.life < 0.3 and 20 or 8)) % 2 == 0 then g.setColor(0.95, 0.35, 0.20, 1)
        else g.setColor(0.25, 0.20, 0.20, 1) end
      else
        g.setColor(0.98, 0.90, 0.52, 1)
      end
      g.rectangle("fill", x, y, p.w, p.h)
    end
  end
  local blasts = self.arsenal.blasts
  for i = 1, #blasts do
    local b = blasts[i]
    if b.alive then
      local r = math.floor(b.radius * (0.5 + 0.5 * b.t / b.time) + 0.5)
      local cx, cy = math.floor(b.x + 0.5), math.floor(b.y + 0.5)
      g.setColor(1.00, 0.80, 0.30, 0.85 - 0.6 * b.t / b.time)
      for dy = -r, r - 1, 2 do
        local m = dy + 1
        local half = math.floor(math.sqrt(r * r - m * m) + 0.5)
        g.rectangle("fill", cx - half, cy + dy, 2 * half, 2)
      end
    end
  end
end

return M
