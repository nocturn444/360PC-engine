-- The fight in a room: the slime and the room's enemies as fighters of one combat world. The
-- enemies are platformer controller bodies in a bump world made from the room's grid, run by a
-- patrol / chase / attack state machine (combat.behaviours); the slime is a soft body seen by
-- combat through softbody.box. The slime hurts an enemy by landing on it (a hitbox under the
-- body while it falls) and bounces off; an enemy's bite hurts the slime and knocks it back.
-- Everything here is rebuilt when a room is entered, so a room's enemies are back when the
-- slime comes back to it.
local platformer = require("engine.modules.platformer")
local combat = require("engine.modules.combat")
local softbody = require("engine.modules.softbody")
local rng = require("engine.rng")

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

local M = {}
local Fight = {}
Fight.__index = Fight

-- M.new(slime, grid, spots, opts): spots = { { x, y } ... } (the bottom centre of each enemy, room
-- pixels); opts.boss (stronger enemies), opts.seed (their patrol pauses), opts.health (the
-- slime's health carried over from the last room), opts.on_slime_death
function M.new(slime, grid, spots, opts)
  opts = opts or {}
  local self = setmetatable({ slime = slime, enemies = {}, stomps = 0, kills = 0 }, Fight)
  self.world = platformer.collision.newWorld(grid)
  self.fight = combat.world.new()
  self.box = softbody.box(slime)
  local me = self
  self.player = self.fight:fighter({ body = self.box, team = "player", params = SLIME_STATS,
    health = opts.health, on_hurt = function(_, hit) me.box:knock(hit) end,
    on_death = opts.on_slime_death })
  self.hurt = self.player:hurtbox({ w = 1, h = 1 })
  self.stomp = self.player:hitbox({ w = 1, h = 6, damage = 1, knockback = 90, away = true, ky = -0.5 })
  self.fight.on_hit = function(hit)
    if hit.attacker == me.player then          -- a stomp landed: bounce off
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
      params = opts.boss and BOSS_STATS or ENEMY_STATS })
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
  g.setColor(1, 1, 1, 1)
end

return M
