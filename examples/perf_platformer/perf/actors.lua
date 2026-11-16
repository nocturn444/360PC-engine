-- The player and the enemies: platformer controller bodies in the level's bump world, fighters
-- in a combat world, and for each enemy a patrol / chase / attack state machine
-- (combat.behaviours). Everything is drawn with one SpriteBatch.
local platformer = require("engine.modules.platformer")
local combat = require("engine.modules.combat")
local floor = math.floor

local B = combat.behaviours
local BODY_W, BODY_H = 10, 12
local RESPAWN = 1.5                    -- seconds a dead enemy stays away

local PLAYER_PARAMS = platformer.params.new()
local ENEMY_PARAMS = platformer.params.new({ max_speed = 35, ground_accel = 600, air_accel = 400 })
local PLAYER_STATS = combat.stats.new({ max_health = 20, attack_damage = 1, invuln_time = 0.5 })
local ENEMY_STATS = combat.stats.new({ max_health = 3, attack_damage = 1, invuln_time = 0.2 })

-- An enemy's movement parameters: the shared table, except that max_speed is the speed its
-- state asks for (patrol is slower than chase)
local EnemyStats = {}
EnemyStats.__index = EnemyStats
function EnemyStats:get(name)
  if name == "max_speed" then return self.agent.move_speed or ENEMY_PARAMS.max_speed end
  return ENEMY_PARAMS[name]
end

local function blocked(agent) return agent.body.wall ~= 0 end
local BRAIN = { initial = "patrol", states = {
  patrol = B.patrol({ speed = 25, pause = { 0.2, 0.8 }, blocked = blocked }),
  chase = B.chase({ speed = 50, stop = 10 }),
  attack = B.attack({ hitbox = "bite", windup = 0.25, active = 0.1, recovery = 0.35, next = "chase" }),
} }
BRAIN.states.patrol.transitions = { { to = "chase", when = B.target_within(72, "xy") } }
BRAIN.states.chase.transitions = {
  { to = "attack", when = B.target_within(14, "xy") },
  { to = "patrol", when = B.target_beyond(110, "xy") },
}

local Actors = {}
Actors.__index = Actors

-- level: perf.level; atlas: perf.atlas (loaded)
function Actors.new(level, atlas)
  local self = setmetatable({ level = level, atlas = atlas, world = level.world }, Actors)
  self.fight = combat.world.new()
  self.rng = level.streams:get("enemies")
  self.tick, self.hits, self.kills, self.deaths, self.drawn = 0, 0, 0, 0, 0
  -- The enemies' places: the level's standing spots in an order drawn once from the seed, so
  -- enemy i is always in the same place whatever the count
  self.spots = {}
  for i = 1, #level.spots do self.spots[i] = level.spots[i] end
  level.streams:get("spawn"):shuffle(self.spots)

  local body = platformer.controller.new(self.world, { x = level.start_x - BODY_W / 2,
    y = level.start_y - BODY_H, w = BODY_W, h = BODY_H, params = PLAYER_PARAMS,
    actions = { move_x = "move_x" } })
  local fighter = self.fight:fighter({ body = body, team = "player", params = PLAYER_STATS })
  fighter:hurtbox({ w = BODY_W, h = BODY_H })
  self.player = { body = body, fighter = fighter,
    slash = fighter:hitbox({ ox = BODY_W, oy = 1, w = 14, h = 10, knockback = 160, hitstop = 2 / 60 }) }

  self.enemies, self.count = {}, 0
  self.batch = love.graphics.newSpriteBatch(atlas.image, 256, "stream")
  return self
end

local function add_enemy(self, i)
  local spot = self.spots[(i - 1) % #self.spots + 1]
  local sx, sy = spot.x + 3, spot.y + 16 - BODY_H
  local agent = { index = i, spawn_x = sx, spawn_y = sy, respawn = 0, target = self.player.body,
    patrol_points = { { x = spot.x - 32 }, { x = spot.x + 48 } }, rng = self.rng }
  agent.body = platformer.controller.new(self.world, { x = sx, y = sy, w = BODY_W, h = BODY_H,
    stats = setmetatable({ agent = agent }, EnemyStats), actions = { move_x = "move_x" } })
  agent.fighter = self.fight:fighter({ body = agent.body, team = "enemy", params = ENEMY_STATS, owner = agent })
  agent.fighter:hurtbox({ w = BODY_W, h = BODY_H })
  agent.hitboxes = { bite = agent.fighter:hitbox({ ox = BODY_W - 2, oy = 2, w = 8, h = 8, knockback = 120 }) }
  agent.machine = combat.fsm.new(BRAIN, agent)
  agent.input = B.input(agent)
  return agent
end

-- Adds or removes enemies until there are n: the first n are always the same ones
function Actors:setCount(n)
  if #self.spots == 0 then n = 0 end
  while self.count < n do
    self.count = self.count + 1
    self.enemies[self.count] = add_enemy(self, self.count)
  end
  while self.count > n do
    local e = self.enemies[self.count]
    self.fight:remove(e.fighter)
    e.body:remove()
    self.enemies[self.count] = nil
    self.count = self.count - 1
  end
end

-- One fixed step. input: the game's controls, or the autopilot
function Actors:step(input, dt)
  self.tick = self.tick + 1
  local p = self.player
  if p.fighter.dead then
    p.fighter:revive()
    self.deaths = self.deaths + 1
  end
  if not p.fighter:frozen() then
    p.body:step(input, dt)
    if input:pressed("attack") then p.slash:activate(6 / 60) end
  end
  local enemies = self.enemies
  for i = 1, self.count do
    local e = enemies[i]
    local f, body = e.fighter, e.body
    if f.dead then
      if e.respawn <= 0 then            -- it just died
        e.respawn = RESPAWN
        self.kills = self.kills + 1
      end
      e.respawn = e.respawn - dt
      body.px, body.py = body.x, body.y
      if e.respawn <= 0 then
        body:teleport(e.spawn_x, e.spawn_y)
        f:revive()
        e.machine:set("patrol")
      end
    elseif not f:frozen() then
      e.machine:update(dt)
      -- hop over what is in the way while chasing
      e.jump = e.machine.state == "chase" and body.wall ~= 0 and body.on_ground
      body:step(e.input, dt)
    else
      body.px, body.py = body.x, body.y
    end
  end
  self.hits = self.hits + self.fight:step(dt)
end

local function add_sprite(batch, quads, body, alpha, frame)
  local x = body.px + (body.x - body.px) * alpha
  local y = body.py + (body.y - body.py) * alpha
  local quad = quads[(body.vx ~= 0 and frame or 0) % 2 + 1]
  -- the sprite is 16x16 with the 10x12 body at (3, 4): mirrored around the body's centre
  batch:add(quad, floor(x + 0.5) + BODY_W / 2, floor(y + 0.5) - 4, 0, body.facing, 1, 8, 0)
end

-- Fills the batch with the actors inside the view (a world rectangle) and draws it: one draw
-- call. Returns how many enemies were drawn.
function Actors:draw(alpha, vx, vy, vw, vh)
  local batch, atlas = self.batch, self.atlas
  batch:clear()
  local frame = floor(self.tick / 8)
  local x0, y0, x1, y1 = vx - 16, vy - 16, vx + vw + 16, vy + vh + 16
  local drawn = 0
  local enemies = self.enemies
  for i = 1, self.count do
    local e = enemies[i]
    local b = e.body
    if not e.fighter.dead and b.x > x0 and b.x < x1 and b.y > y0 and b.y < y1 then
      add_sprite(batch, atlas.enemy, b, alpha, frame + i)
      drawn = drawn + 1
    end
  end
  local p = self.player
  if p.fighter.invuln <= 0 or frame % 2 == 0 then        -- blinks while invulnerable
    add_sprite(batch, atlas.player, p.body, alpha, frame)
  end
  batch:flush()
  love.graphics.draw(batch, 0, 0)
  self.drawn = drawn
  return drawn
end

-- The autopilot: an input for the player's body that walks, turns at walls, jumps and attacks
-- on a fixed schedule, so every benchmark run does the same thing.
local Pilot = {}
Pilot.__index = Pilot
function Actors.pilot()
  return setmetatable({ t = 0, dir = 1, stuck = 0 }, Pilot)
end
-- Once per fixed step, before the player's body steps
function Pilot:step(body)
  self.t = self.t + 1
  if body.wall == self.dir then self.stuck = self.stuck + 1 else self.stuck = 0 end
  if self.stuck > 45 then
    self.dir, self.stuck = -self.dir, 0
  end
end
function Pilot:axis() return self.dir end
function Pilot:down(name)
  if name == "jump" then return self.t % 50 < 14 end
  if name == "right" then return self.dir > 0 end
  if name == "left" then return self.dir < 0 end
  return false
end
function Pilot:pressed(name)
  if name == "jump" then return self.t % 50 == 0 end
  if name == "attack" then return self.t % 20 == 0 end
  return false
end

return Actors
