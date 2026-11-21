-- The fight in a room: the slime and the room's enemies as fighters of one combat world. The
-- enemies are platformer controller bodies in a bump world made from the room's grid, run by a
-- patrol / chase / attack state machine (combat.behaviours); the slime is a soft body seen by
-- combat through softbody.box. The slime hurts an enemy by landing on it (a hitbox under the
-- body while it falls) and bounces off; an enemy's bite hurts the slime and knocks it back.
-- The slime also has three attacks (rooms_attacks.lua, combat.attacks configs): melee, ranged
-- and explosive, one at a time; Fight:attack() triggers the current one.
-- Everything here is rebuilt when a room is entered; the play state then restores the room's
-- enemies (the dead stay dead and a hurt one keeps its health).
local platformer = require("engine.modules.platformer")
local combat = require("engine.modules.combat")
local softbody = require("engine.modules.softbody")
local rng = require("engine.rng")
local attack_configs = require("rooms_attacks")

local B = combat.behaviours
local W, H = 12, 10                         -- an enemy's box
local STOMP_SPEED = 120                     -- px/s down: falling at least this fast hurts below
local BOUNCE = -230                         -- px/s: the slime's bounce after a stomp

local SLIME_STATS = combat.stats.new({ max_health = 5, attack_damage = 1, invuln_time = 1.0 })
local ENEMY_STATS = combat.stats.new({ max_health = 2, attack_damage = 1, invuln_time = 0.25 })
local BOSS_STATS = combat.stats.new({ max_health = 6, attack_damage = 2, invuln_time = 0.4, knockback_resist = 0.5 })
local ENEMY_PARAMS = platformer.params.new({ max_speed = 35, ground_accel = 600, air_accel = 400 })

-- An enemy's movement: the shared parameters, except max_speed, which its state asks for
local EnemyStats = {}
EnemyStats.__index = EnemyStats
function EnemyStats:get(name)
  if name == "max_speed" then return self.agent.move_speed or ENEMY_PARAMS.max_speed end
  return ENEMY_PARAMS[name]
end

local function blocked(agent) return agent.body.wall ~= 0 end
local BRAIN = { initial = "patrol", states = {
  patrol = B.patrol({ speed = 22, pause = { 0.3, 0.9 }, blocked = blocked }),
  chase = B.chase({ speed = 45, stop = 8 }),
  attack = B.attack({ hitbox = "bite", windup = 0.3, active = 0.12, recovery = 0.4, next = "chase" }),
} }
BRAIN.states.patrol.transitions = { { to = "chase", when = B.target_within(80, "xy") } }
BRAIN.states.chase.transitions = {
  { to = "attack", when = B.target_within(16, "xy") },
  { to = "patrol", when = B.target_beyond(120, "xy") },
}

local M = { SLIME_STATS = SLIME_STATS }
local Fight = {}
Fight.__index = Fight

-- M.new(slime, grid, spots, opts): spots = { { x, y } ... } (the bottom centre of each enemy, room
-- pixels); opts.boss (stronger enemies), opts.seed (their patrol pauses), opts.health (the
-- slime's health carried over from the last room), opts.mode (the slime's attack, an index of
-- rooms_attacks), opts.on_slime_death; the biome's: opts.enemy_stats, opts.slime_stats
-- (combat.stats tables) and opts.color (the enemies' colour)
function M.new(slime, grid, spots, opts)
  opts = opts or {}
  local self = setmetatable({ slime = slime, enemies = {}, stomps = 0, kills = 0, color = opts.color }, Fight)
  self.world = platformer.collision.newWorld(grid)
  self.fight = combat.world.new()
  self.box = softbody.box(slime)
  local me = self
  self.player = self.fight:fighter({ body = self.box, team = "player", params = opts.slime_stats or SLIME_STATS,
    health = opts.health, on_hurt = function(_, hit) me.box:knock(hit) end,
    on_death = opts.on_slime_death })
  self.hurt = self.player:hurtbox({ w = 1, h = 1 })
  self.stomp = self.player:hitbox({ w = 1, h = 6, damage = 1, knockback = 90, away = true, ky = -0.5 })
  -- the slime's attacks: shots and bombs stop at the room's solid tiles
  self.arsenal = combat.attacks.new(self.fight, { grid = grid, max_projectiles = 24 })
  self.attacks = {}
  for i = 1, #attack_configs do self.attacks[i] = self.arsenal:equip(self.player, attack_configs[i]) end
  self.mode = opts.mode or 1
  self.fight.on_hit = function(hit)
    if hit.killed and hit.target ~= me.player and hit.hitbox ~= me.stomp then me.kills = me.kills + 1 end
    if hit.hitbox == me.stomp then             -- a stomp landed: bounce off
      me.stomps = me.stomps + 1
      me.slime:set_velocity(nil, BOUNCE)
      if hit.killed then me.kills = me.kills + 1 end
    end
  end
  local stream = rng.new(opts.seed or 1)
  for i = 1, #spots do
    local s = spots[i]
    local agent = { target = self.box, rng = stream,
      patrol_points = { { x = s.x - 40 }, { x = s.x + 40 } } }
    agent.body = platformer.controller.new(self.world, { x = s.x - W / 2, y = s.y - H, w = W, h = H,
      stats = setmetatable({ agent = agent }, EnemyStats), actions = { move_x = "move_x" } })
    agent.fighter = self.fight:fighter({ body = agent.body, team = "enemy", owner = agent,
      params = opts.enemy_stats or (opts.boss and BOSS_STATS or ENEMY_STATS) })
    agent.fighter:hurtbox({ w = W, h = H })
    agent.hitboxes = { bite = agent.fighter:hitbox({ ox = W - 2, oy = 2, w = 9, h = 7, knockback = 160, ky = -0.6 }) }
    agent.machine = combat.fsm.new(BRAIN, agent)
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

-- The current attack, and the next one (wraps around)
function Fight:attack() return self.attacks[self.mode]:trigger() end
function Fight:current() return self.attacks[self.mode] end
function Fight:switch()
  self.attacks[self.mode]:cancel()
  self.mode = self.mode % #self.attacks + 1
  return self.attacks[self.mode]
end

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
        body:remove()
      end
    elseif not f:frozen() then
      e.machine:update(dt)
      body:step(e.input, dt)
    else
      body.px, body.py = body.x, body.y
    end
  end
  self.arsenal:step(dt)
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
      g.rectangle("fill", x, y + 2, W, H - 2)
      g.rectangle("fill", x + 2, y, W - 4, 2)
      g.setColor(0.1, 0.05, 0.05, 1)
      g.rectangle("fill", x + ((b.facing or 1) > 0 and W - 4 or 2), y + 3, 2, 2)
      local bite = e.hitboxes.bite
      if bite.active then
        local bx, by, bw, bh = bite:rect()
        g.setColor(1, 1, 1, 0.8)
        g.rectangle("fill", math.floor(bx + 0.5), math.floor(by + 0.5), bw, bh)
      end
    end
  end
  self:draw_attacks(alpha)
  g.setColor(1, 1, 1, 1)
end

-- The slime's attacks, on the pixel grid: the melee box while it is out, the shots, the bombs
-- (blinking faster as the fuse runs out) and each blast as a disc of 2 px rows.
function Fight:draw_attacks(alpha)
  local g = love.graphics
  local melee = self.attacks[1].hitbox
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
