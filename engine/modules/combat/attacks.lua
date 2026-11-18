-- combat.attacks: attacks described as data, on top of a combat world. Three kinds:
--   melee      one hitbox that sweeps through a list of boxes around the fighter (an arc, a
--              stab, an area around the body) while it is active
--   ranged     projectiles: a fan of shots with speed, gravity, lifetime, piercing and walls
--   explosive  a bomb, placed or thrown (gravity, bounces off walls), that blows after a fuse
--              (or on touching a target) and hurts every fighter in a radius, with falloff and a radial knockback
-- See engine/modules/combat/README.md ("Attacks as data").
--
--   local arsenal = combat.attacks.new(world, { grid = grid })     -- grid: walls for shots and bombs
--   local slash = arsenal:equip(hero, { kind = "melee", cooldown = 0.3, active = 0.12,
--     boxes = { { ox = 4, oy = -8, w = 12, h = 14 } }, knockback = 140 })
--   if input:pressed("attack") then slash:trigger() end
--   arsenal:step(dt)        -- once per fixed step: after the bodies moved, before world:step
--   world:step(dt)
--
-- Positions in a config are offsets from the fighter body's centre when it faces right (+x is
-- in front, y grows downwards); they are mirrored when it faces left. A melee box's ox, oy is
-- its top left corner; a projectile's or a bomb's ox, oy is where its centre starts.
--
-- Shots and bombs live in a pool that only grows (up to max_projectiles): once it is warm a
-- step allocates nothing. No randomness, no clock: the same inputs give the same results on
-- PC and on the console. The module draws nothing; the game reads arsenal.projectiles and
-- arsenal.blasts (see M.position).
local floor, sqrt, sin, cos, atan2, pi = math.floor, math.sqrt, math.sin, math.cos, math.atan2, math.pi
local type, pairs, tostring, error, setmetatable = type, pairs, tostring, error, setmetatable

local M = {}
local Arsenal = {}
Arsenal.__index = Arsenal
local Attack = {}
Attack.__index = Attack

local EPS = 1e-9
local RAD = pi / 180

---------------------------------------------------------------------------
-- Configs
---------------------------------------------------------------------------

-- The fields of a hit, shared by the three kinds (see Fighter:hitbox in world.lua).
local HIT = { damage = "number", power = "number", knockback = "number", kx = "number",
  ky = "number", away = "boolean", hitstop = "number", global_hitstop = "number" }

-- Every field a config may have, by kind, with its type and its default (nil: none).
local COMMON = {
  kind = { "string" }, name = { "string" },
  cooldown = { "number", 0.3 },     -- s from a trigger until the next one is allowed
  windup = { "number", 0 },         -- s from the trigger until it hits, fires or throws
}
local FIELDS = {
  melee = {
    boxes = { "table" },            -- { { ox, oy, w, h }, ... }: one after the other while active
    active = { "number", 0.1 },     -- s the hitbox is out
  },
  ranged = {
    count = { "number", 1 },        -- shots per trigger
    spread = { "number", 0 },       -- degrees between the first and the last shot of a fan
    angle = { "number", 0 },        -- degrees above the facing direction (negative: down)
    speed = { "number", 200 },      -- px/s
    gravity = { "number", 0 },      -- px/s^2, down
    life = { "number", 1 },         -- s before it vanishes
    w = { "number", 4 }, h = { "number", 4 },
    ox = { "number", 0 }, oy = { "number", 0 },
    pierce = { "number", 1 },       -- fighters it can hit before it is gone
    walls = { "string", "stop" },   -- "stop": gone on a solid tile; "pass": through them
  },
  explosive = {
    radius = { "number", 24 },      -- px from the centre to the farthest point it reaches
    falloff = { "number", 0.5 },    -- 0..1: damage and knockback lost at the edge of the radius
    lift = { "number", 0 },         -- extra upward part of the knockback direction
    fuse = { "number", 0.5 },       -- s from the throw (or placing) until it blows
    self = { "boolean", false },    -- true: it can hurt its own fighter too
    blast_time = { "number", 0.2 }, -- s the blast stays in arsenal.blasts (for drawing only)
    ox = { "number", 0 }, oy = { "number", 0 },
    w = { "number", 4 }, h = { "number", 4 },
    throw = { "table" },            -- nil: placed where it is; else how it flies (below)
  },
}
local THROW = {
  speed = { "number", 150 }, angle = { "number", 30 }, gravity = { "number", 500 },
  bounce = { "number", 0.4 },       -- 0..1: speed kept when it hits a wall, floor or ceiling
  friction = { "number", 0.8 },     -- horizontal speed kept on each bounce off a floor
  contact = { "boolean", false },   -- true: blows on touching a fighter it may hit
}

local function check(where, value, spec)
  if value == nil then return spec[2] end
  if type(value) ~= spec[1] then
    error("combat.attacks: " .. where .. " is a " .. spec[1] .. ", not a " .. type(value), 4)
  end
  return value
end

local function fill(out, src, fields, where)
  for k, spec in pairs(fields) do out[k] = check(where .. k, src[k], spec) end
end

-- A checked copy of a config with every default filled in. An unknown kind or field, or a
-- value of the wrong type, is an error that names it. equip calls it; a game may call it when
-- it loads its configs, to fail early.
function M.define(config)
  if type(config) ~= "table" then error("combat.attacks: a config is a table", 2) end
  local kind = config.kind
  local fields = FIELDS[kind]
  if not fields then error("combat.attacks: unknown kind " .. tostring(kind), 2) end
  for k in pairs(config) do
    if COMMON[k] == nil and HIT[k] == nil and fields[k] == nil then
      error("combat.attacks: " .. kind .. " has no field " .. tostring(k), 2)
    end
  end
  local c = {}
  fill(c, config, COMMON, "")
  for k, t in pairs(HIT) do c[k] = check(k, config[k], { t }) end
  fill(c, config, fields, "")
  if kind == "melee" then
    local boxes = c.boxes
    if not boxes or #boxes == 0 then error("combat.attacks: melee needs at least one box", 2) end
    local copy = {}
    for i = 1, #boxes do
      local b = boxes[i]
      copy[i] = { ox = b.ox or 0, oy = b.oy or 0, w = b.w or 0, h = b.h or 0 }
    end
    c.boxes = copy
  elseif kind == "ranged" then
    if c.count < 1 then error("combat.attacks: ranged count is at least 1", 2) end
    if c.walls ~= "stop" and c.walls ~= "pass" then error("combat.attacks: walls is \"stop\" or \"pass\"", 2) end
  elseif kind == "explosive" and c.throw then
    local t = {}
    for k in pairs(c.throw) do
      if THROW[k] == nil then error("combat.attacks: throw has no field " .. tostring(k), 2) end
    end
    fill(t, c.throw, THROW, "throw.")
    c.throw = t
  end
  return c
end

M.kinds = { "melee", "ranged", "explosive" }

---------------------------------------------------------------------------
-- The arsenal: every attack, shot, bomb and blast of one combat world
---------------------------------------------------------------------------

-- combat.attacks.new(world, opts); opts (all optional):
--   grid             walls for shots and bombs: width, height, tile_size and kind(tx, ty) (a
--                    platformer.grid); only "solid" tiles stop them, one-way tiles do not
--   solid            function(x, y) -> true if that pixel is a wall (instead of grid)
--   max_projectiles  shots and bombs in flight at once (default 64); a trigger past it fires
--                    what fits
--   max_blasts       blasts kept for drawing at once (default 16)
--   on_blast         function(blast) when a bomb blows (after its hits)
function M.new(world, opts)
  opts = opts or {}
  local self = setmetatable({
    world = world,
    grid = opts.grid,
    solid = opts.solid,
    max_projectiles = opts.max_projectiles or 64,
    max_blasts = opts.max_blasts or 16,
    on_blast = opts.on_blast,
    attacks = {},             -- in the order they were equipped
    projectiles = {},         -- the pool: read p.alive
    blasts = {},              -- the pool: read b.alive
    blast_count = 0,          -- blasts since the arsenal was made
    _spec = {},               -- the hit of a blast, reused
  }, Arsenal)
  if not self.solid and self.grid then
    local g = self.grid
    local size = g.tile_size
    self.solid = function(x, y)
      return g:kind(floor(x / size) + 1, floor(y / size) + 1) == "solid"
    end
  end
  return self
end

-- Gives a fighter an attack. Returns it; attack:trigger() uses it.
function Arsenal:equip(fighter, config)
  local c = M.define(config)
  local a = setmetatable({
    arsenal = self, fighter = fighter, config = c, kind = c.kind, name = c.name or c.kind,
    phase = "idle",           -- "idle", "windup" or "active" (melee)
    timer = 0,                -- s left in the windup; s spent in "active"
    cool = 0,                 -- s until it can be triggered again
    aim_x = nil, aim_y = nil, -- the direction of this trigger, if it was given one
    uses = 0,                 -- triggers that fired
  }, Attack)
  if c.kind == "melee" then
    local b = c.boxes[1]
    a.hitbox = fighter:hitbox({ w = b.w, h = b.h, power = c.power, damage = c.damage,
      knockback = c.knockback, kx = c.kx, ky = c.ky, away = c.away, hitstop = c.hitstop,
      global_hitstop = c.global_hitstop, tag = a })
  end
  self.attacks[#self.attacks + 1] = a
  return a
end

-- Takes an attack away (its melee hitbox too).
function Arsenal:unequip(attack)
  local list = self.attacks
  for i = 1, #list do
    if list[i] == attack then table.remove(list, i); break end
  end
  if attack.hitbox then attack.hitbox:remove() end
  attack.phase = "removed"
end

-- True if trigger would start it now.
function Attack:ready()
  return self.phase == "idle" and self.cool <= EPS and not self.fighter.dead
end

-- Starts the attack if it is ready. ax, ay (optional): a direction to aim at instead of the
-- facing one (ranged shots and thrown bombs). Returns true if it started.
function Attack:trigger(ax, ay)
  if not self:ready() then return false end
  self.phase, self.timer, self.cool = "windup", self.config.windup, self.config.cooldown
  if ax and ay and (ax ~= 0 or ay ~= 0) then self.aim_x, self.aim_y = ax, ay
  else self.aim_x, self.aim_y = nil, nil end
  return true
end

-- Stops it where it is (a melee hitbox is put away). The cooldown keeps running.
function Attack:cancel()
  if self.hitbox then self.hitbox:deactivate() end
  if self.phase ~= "removed" then self.phase = "idle" end
end

---------------------------------------------------------------------------
-- Melee
---------------------------------------------------------------------------

-- Puts the hitbox on box i of the sweep (offsets from the body's centre, to its top left).
local function melee_place(a, i)
  local b = a.config.boxes[i]
  local body = a.fighter.body
  a.hitbox:set((body.w or 0) * 0.5 + b.ox, (body.h or 0) * 0.5 + b.oy, b.w, b.h)
end

local function melee_update(a, dt)
  local c = a.config
  a.timer = a.timer + dt
  if a.timer >= c.active - EPS then
    a.hitbox:deactivate()
    a.phase = "idle"
    return
  end
  local n = #c.boxes
  local i = floor(a.timer / c.active * n + EPS) + 1
  if i > n then i = n end
  melee_place(a, i)
end

---------------------------------------------------------------------------
-- Shots and bombs
---------------------------------------------------------------------------

local function free_slot(self)
  local list = self.projectiles
  for i = 1, #list do
    if not list[i].alive then return list[i] end
  end
  if #list >= self.max_projectiles then return nil end
  local p = { alive = false, fresh = false, kind = "shot", x = 0, y = 0, px = 0, py = 0, w = 0, h = 0,
    vx = 0, vy = 0, gravity = 0, life = 0, attack = nil, source = nil }
  list[#list + 1] = p
  return p
end

-- The facing of a fighter's body as 1 or -1
local function facing_of(f)
  return (f.body.facing or 1) < 0 and -1 or 1
end

-- The body's centre
local function centre(body)
  return body.x + (body.w or 0) * 0.5, body.y + (body.h or 0) * 0.5
end

-- The angle (radians, up is positive) a shot of this trigger starts at, before its fan offset.
local function base_angle(a, angle_deg)
  if a.aim_x then return atan2(-a.aim_y, a.aim_x) end
  if facing_of(a.fighter) > 0 then return angle_deg * RAD end
  return pi - angle_deg * RAD
end

-- A new projectile at the fighter's offset (ox, oy, mirrored) with that speed and angle.
local function launch(self, a, ox, oy, w, h, speed, angle)
  local p = free_slot(self)
  if not p then return nil end
  local f = a.fighter
  local fx = facing_of(f)
  local cx, cy = centre(f.body)
  p.alive, p.fresh, p.attack, p.source = true, true, a, f
  p.w, p.h = w, h
  p.x, p.y = cx + ox * fx - w * 0.5, cy + oy - h * 0.5
  p.px, p.py = p.x, p.y
  p.vx, p.vy = cos(angle) * speed, -sin(angle) * speed
  return p
end

-- The fighter a shot hits with: one per slot, made the first time the slot is a shot. It has
-- the owner's team, stats and modifiers, so the hit reads like the owner's.
local function shot_fighter(self, p)
  if not p.fighter then
    p.body = { x = 0, y = 0, w = 0, h = 0, facing = 1 }
    p.fighter = self.world:fighter({ body = p.body, params = { max_health = 1 } })
    p.hitbox = p.fighter:hitbox({})
  end
  return p.fighter
end

local function fire_ranged(self, a)
  local c = a.config
  local angle = base_angle(a, c.angle)
  local n = c.count
  for k = 1, n do
    local off = 0
    if n > 1 then off = ((k - 1) / (n - 1) - 0.5) * c.spread * RAD end
    local p = launch(self, a, c.ox, c.oy, c.w, c.h, c.speed, angle + off)
    if not p then return end
    p.kind, p.gravity, p.life, p.walls = "shot", c.gravity, c.life, c.walls
    local f, owner = shot_fighter(self, p), a.fighter
    f.team, f.stats, f.mods, f.owner = owner.team, owner.stats, owner.mods, a
    f.dead, f.hitstop = false, 0
    local body = p.body
    body.x, body.y, body.w, body.h = p.x, p.y, p.w, p.h
    body.facing = p.vx < 0 and -1 or 1
    local hb = p.hitbox
    hb:set(0, 0, p.w, p.h)
    hb.power, hb.damage, hb.knockback = c.power or 1, c.damage, c.knockback or 0
    hb.kx, hb.ky, hb.away = c.kx or 1, c.ky or 0, c.away or false
    hb.hitstop, hb.global_hitstop = c.hitstop, c.global_hitstop or 0
    hb:activate()
  end
end

local function fire_explosive(self, a)
  local c = a.config
  local t = c.throw
  local p
  if t then p = launch(self, a, c.ox, c.oy, c.w, c.h, t.speed, base_angle(a, t.angle))
  else p = launch(self, a, c.ox, c.oy, c.w, c.h, 0, 0) end
  if not p then return end
  p.kind, p.life = "bomb", c.fuse
  p.gravity = t and t.gravity or 0
end

local function retire(p)
  p.alive = false
  if p.hitbox then p.hitbox:deactivate() end
end

-- Overlap of two rectangles
local function overlap(ax, ay, aw, ah, bx, by, bw, bh)
  return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah
end

-- True if the bomb touches a hurtbox its owner may hit.
local function touches_target(self, p)
  local world, src = self.world, p.source
  local list = world.hurtboxes
  for i = 1, #list do
    local box = list[i]
    local t = box.fighter
    if box.enabled and not box.removed and not t.dead and not t.removed and t ~= src
      and world.can_hit(src.team, t.team) then
      local x, y, w, h = box:rect()
      if overlap(p.x, p.y, p.w, p.h, x, y, w, h) then return true end
    end
  end
  return false
end

local function free_blast(self)
  local list = self.blasts
  for i = 1, #list do
    if not list[i].alive then return list[i] end
  end
  if #list >= self.max_blasts then
    local oldest = list[1]                     -- reuse the one that has been shown longest
    for i = 2, #list do if list[i].t > oldest.t then oldest = list[i] end end
    return oldest
  end
  local b = { alive = false, x = 0, y = 0, radius = 0, t = 0, time = 0, hits = 0, attack = nil }
  list[#list + 1] = b
  return b
end

-- Distance from (x, y) to the nearest point of a rectangle
local function rect_distance(x, y, rx, ry, rw, rh)
  local dx, dy = 0, 0
  if x < rx then dx = rx - x elseif x > rx + rw then dx = x - rx - rw end
  if y < ry then dy = ry - y elseif y > ry + rh then dy = y - ry - rh end
  return sqrt(dx * dx + dy * dy)
end

-- A bomb blows at (x, y): every fighter with a hurtbox in the radius is struck once.
local function explode(self, a, src, x, y)
  local c, world = a.config, self.world
  self.blast_count = self.blast_count + 1
  local seq = self.blast_count
  local base = c.damage
  if base == nil then base = src and src.stats:get("attack_damage") * (c.power or 1) or 0 end
  local spec, fx = self._spec, src and facing_of(src) or 1
  spec.power, spec.away = 1, false
  spec.hitstop, spec.global_hitstop = c.hitstop, c.global_hitstop or 0
  local hits = 0
  local list = world.hurtboxes
  for i = 1, #list do
    local box = list[i]
    local t = box.fighter
    if box.enabled and not box.removed and not t.dead and not t.removed and t._attacks_blast ~= seq
      and ((t == src and c.self) or (t ~= src and (not src or world.can_hit(src.team, t.team)))) then
      local rx, ry, rw, rh = box:rect()
      local d = rect_distance(x, y, rx, ry, rw, rh)
      if d <= c.radius then
        t._attacks_blast = seq
        local scale = 1 - c.falloff * (d / c.radius)
        local amount = base * scale
        if base > 0 then                         -- whole numbers, at least 1, like the hit's base
          amount = floor(amount + 0.5)
          if amount < 1 then amount = 1 end
        end
        local nx, ny = rx + rw * 0.5 - x, ry + rh * 0.5 - y
        local len = sqrt(nx * nx + ny * ny)
        if len > EPS then nx, ny = nx / len, ny / len else nx, ny = 0, -1 end
        ny = ny - c.lift
        spec.damage = amount
        spec.knockback = (c.knockback or 0) * scale
        spec.kx, spec.ky = nx * fx, ny                 -- the pipeline multiplies kx by the facing
        if world:strike(src, t, spec) then hits = hits + 1 end
      end
    end
  end
  local b = free_blast(self)
  b.alive, b.x, b.y, b.radius, b.t, b.time, b.hits, b.attack = true, x, y, c.radius, 0, c.blast_time, hits, a
  if self.on_blast then self.on_blast(b) end
end

local function blow(self, p)
  retire(p)
  explode(self, p.attack, p.source, p.x + p.w * 0.5, p.y + p.h * 0.5)
end

-- Moves a projectile one step; walls and bounces. Returns false if it is gone.
local function move(self, p, dt)
  local solid = self.solid
  p.vy = p.vy + p.gravity * dt
  local dx, dy = p.vx * dt, p.vy * dt
  -- small steps, so a fast one never jumps a tile
  local size = self.grid and self.grid.tile_size or 8
  local dist = (dx < 0 and -dx or dx) + (dy < 0 and -dy or dy)
  local n = floor(dist / (size * 0.5)) + 1
  dx, dy = dx / n, dy / n
  local bomb = p.kind == "bomb"
  local t = bomb and p.attack.config.throw
  for _ = 1, n do
    if bomb then
      -- one axis at a time, so it knows which way to bounce
      -- the leading edge's middle point, a hair inside the box
      p.x = p.x + dx
      if solid and dx ~= 0 and solid(dx > 0 and p.x + p.w - 1e-4 or p.x, p.y + p.h * 0.5) then
        p.x = p.x - dx
        p.vx, dx = -p.vx * (t and t.bounce or 0), -dx * (t and t.bounce or 0)
      end
      p.y = p.y + dy
      if solid and dy ~= 0 and solid(p.x + p.w * 0.5, dy > 0 and p.y + p.h - 1e-4 or p.y) then
        p.y = p.y - dy
        local bounce, friction = t and t.bounce or 0, t and t.friction or 0
        if p.vy > 0 then p.vx, dx = p.vx * friction, dx * friction end
        p.vy, dy = -p.vy * bounce, -dy * bounce
      end
    else
      p.x, p.y = p.x + dx, p.y + dy
      if p.walls == "stop" and solid and solid(p.x + p.w * 0.5, p.y + p.h * 0.5) then
        retire(p)
        return false
      end
    end
  end
  -- out of the grid: gone
  local g = self.grid
  if g and (p.x + p.w < 0 or p.y + p.h < 0 or p.x > g.width * g.tile_size or p.y > g.height * g.tile_size) then
    retire(p)
    return false
  end
  return true
end

local function step_projectile(self, p, dt)
  if p.kind == "shot" then
    local hb = p.hitbox
    -- it hit enough fighters in the last world step: gone before it can hit more
    if hb.hit_n >= p.attack.config.pierce then retire(p); return end
    if p.fighter:frozen() then
      p.px, p.py = p.x, p.y
      return
    end
  elseif self.world.hitstop > 0 then
    p.px, p.py = p.x, p.y
    return
  end
  p.px, p.py = p.x, p.y
  -- its lifetime (a bomb's fuse) starts counting on the step after the one it was born in
  if p.fresh then p.fresh = false else p.life = p.life - dt end
  if p.life <= EPS then
    if p.kind == "bomb" then blow(self, p) else retire(p) end
    return
  end
  if not move(self, p, dt) then return end
  if p.kind == "shot" then
    local body = p.body
    body.x, body.y = p.x, p.y
    body.facing = p.vx < 0 and -1 or (p.vx > 0 and 1 or body.facing)
  elseif p.attack.config.throw and p.attack.config.throw.contact and touches_target(self, p) then
    blow(self, p)
  end
end

---------------------------------------------------------------------------
-- The step
---------------------------------------------------------------------------

-- One fixed step: after the bodies moved and the game triggered its attacks, before
-- world:step. Runs windups, cooldowns and melee sweeps (not while their fighter is frozen),
-- fires what is due, moves shots and bombs, blows bombs, and ages the blasts.
function Arsenal:step(dt)
  local attacks = self.attacks
  for i = 1, #attacks do
    local a = attacks[i]
    local f = a.fighter
    if f.dead or f.removed then
      if a.phase ~= "idle" then a:cancel() end
    elseif not f:frozen() then
      if a.cool > 0 then
        a.cool = a.cool - dt
        if a.cool < EPS then a.cool = 0 end
      end
      if a.phase == "windup" then
        if a.timer <= EPS then
          a.uses = a.uses + 1
          local kind = a.kind
          if kind == "melee" then
            a.phase, a.timer = "active", 0
            melee_place(a, 1)
            a.hitbox:activate()
          else
            a.phase = "idle"
            if kind == "ranged" then fire_ranged(self, a) else fire_explosive(self, a) end
          end
        else
          a.timer = a.timer - dt
        end
      elseif a.phase == "active" then
        melee_update(a, dt)
      end
    end
  end
  local list = self.projectiles
  for i = 1, #list do
    local p = list[i]
    if p.alive then step_projectile(self, p, dt) end
  end
  local blasts = self.blasts
  for i = 1, #blasts do
    local b = blasts[i]
    if b.alive then
      b.t = b.t + dt
      if b.t >= b.time - EPS then b.alive = false end
    end
  end
end

-- Puts away every shot, bomb (without blowing it) and blast, and every attack in progress.
function Arsenal:clear()
  local list = self.projectiles
  for i = 1, #list do if list[i].alive then retire(list[i]) end end
  for i = 1, #self.blasts do self.blasts[i].alive = false end
  for i = 1, #self.attacks do self.attacks[i]:cancel() end
end

-- How many shots and bombs are in flight.
function Arsenal:count()
  local n = 0
  local list = self.projectiles
  for i = 1, #list do if list[i].alive then n = n + 1 end end
  return n
end

-- Where to draw a projectile: its top left corner between the last two steps by alpha,
-- rounded to the pixel grid.
function M.position(p, alpha)
  alpha = alpha or 1
  return floor(p.px + (p.x - p.px) * alpha + 0.5), floor(p.py + (p.y - p.py) * alpha + 0.5)
end

return M
