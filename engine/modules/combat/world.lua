-- combat.world: fighters with hitboxes and hurtboxes, the overlap search, and what a hit does
-- (damage, knockback, invulnerability, hitstop, death). See engine/modules/combat/README.md.
--
--   local world = M.new()
--   local f = world:fighter({ body = body, team = "enemy" })   -- body: x, y, w, h, facing, vx, vy
--   f:hurtbox({ w = 12, h = 12 })
--   local bite = f:hitbox({ ox = 12, w = 8, h = 8, power = 2, knockback = 120 })
--   bite:activate(0.1)
--   world:step(dt)             -- once per fixed step, after the bodies moved
--
-- Overlaps: the hurtboxes are kept sorted by their left edge (an insertion sort: they barely
-- move from one step to the next) and each active hitbox looks at the ones its x range can
-- touch. No hash table decides an order: hits are resolved by hitbox, then by hurtbox, in the
-- order the boxes were created. A step creates no tables.
--
-- Stats are read through fighter.stats:get(name) and events go through fighter.mods:emit(name,
-- hit) if the fighter has one (an engine.modifiers set has both); this file requires neither.
local setmetatable = setmetatable

local M = {}
local World = {}
World.__index = World
local Fighter = {}
Fighter.__index = Fighter
local Box = {}
Box.__index = Box

local EPS = 1e-9          -- a timer this close to zero has run out

local function module(name, ...)
  return require((((...) or "world"):gsub("world$", name)))
end
local stats = module("stats", ...)

local function different(a, b) return a ~= b end

-- opts (all optional):
--   can_hit          function(attacker_team, target_team) -> true if that hit counts.
--                    Default: the teams differ. A fighter never hits itself.
--   default_hitstop  seconds both fighters of a hit freeze when the hitbox says nothing (0)
--   on_hit           function(hit), after every hit that landed
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    fighters = {},            -- in the order they were added
    hitboxes = {},            -- in the order they were created
    hurtboxes = {},
    can_hit = opts.can_hit or different,
    default_hitstop = opts.default_hitstop or 0,
    on_hit = opts.on_hit,
    hitstop = 0,              -- seconds the whole world is frozen for (see frozen)
    hit_count = 0,            -- hits that landed in the last step
    _seq = 0,                 -- ids for the boxes: the order they were created in
    _sorted = {},             -- the hurtboxes by left edge
    _pairs = {}, _pair_n = 0, -- hitbox, hurtbox, hitbox, hurtbox...: the overlaps of the step
    _cand = {},               -- the hurtboxes one hitbox overlaps
    _hits = {}, _depth = 0,   -- hit records, one per nesting level (a handler may strike)
    _dirty = false,           -- something was removed: the lists need packing
  }, World)
end

---------------------------------------------------------------------------
-- Fighters
---------------------------------------------------------------------------

-- opts:
--   body       where the fighter is: a table with x, y (its top left corner) and optionally
--              w, h, facing (1 / -1), vx, vy. A platformer body is one. Default: a new table.
--   team       any value; see can_hit
--   mods       an engine.modifiers set: its stats are read and its events are sent
--   stats      anything with :get(name) answering every name in stats.defaults (default: mods)
--   params     a table from stats.new, when there is neither mods nor stats (default: defaults)
--   health     default: the max_health stat
--   on_hurt    function(fighter, hit) after a hit that landed on it
--   on_death   function(fighter, hit) when its health reaches 0
--   owner      anything of the game's (its entity); the module does not look at it
function World:fighter(opts)
  opts = opts or {}
  local f = setmetatable({
    world = self,
    body = opts.body or { x = 0, y = 0, w = 0, h = 0, facing = 1 },
    team = opts.team,
    mods = opts.mods,
    stats = opts.stats or opts.mods or stats.source(opts.params or stats.new()),
    owner = opts.owner,
    on_hurt = opts.on_hurt, on_death = opts.on_death,
    health = 0,
    dead = false,
    invuln = 0,               -- seconds of invulnerability left
    hitstop = 0,              -- seconds this fighter is frozen for
    hitboxes = {}, hurtboxes = {},
    _was_frozen = false,
    removed = false,
  }, Fighter)
  f.health = opts.health or f.stats:get("max_health")
  self.fighters[#self.fighters + 1] = f
  return f
end

-- Takes a fighter and its boxes out of the world.
function World:remove(fighter)
  if fighter.removed then return end
  fighter.removed = true
  for i = 1, #fighter.hitboxes do fighter.hitboxes[i].removed = true end
  for i = 1, #fighter.hurtboxes do fighter.hurtboxes[i].removed = true end
  self._dirty = true
end

local function new_box(f, kind, opts)
  local world = f.world
  world._seq = world._seq + 1
  return setmetatable({
    id = world._seq, kind = kind, fighter = f,
    ox = opts.ox or 0, oy = opts.oy or 0, w = opts.w or 0, h = opts.h or 0,
    x1 = 0, y1 = 0, x2 = 0, y2 = 0,          -- where it was in the last step
    tag = opts.tag,                          -- anything of the game's
    removed = false,
  }, Box)
end

-- A box of the fighter that can be hit. opts: ox, oy (offset from the body's top left corner
-- when facing right), w, h, tag. Mirrored inside the body's width when the body faces left.
function Fighter:hurtbox(opts)
  local box = new_box(self, "hurt", opts)
  box.enabled = true
  local world = self.world
  self.hurtboxes[#self.hurtboxes + 1] = box
  world.hurtboxes[#world.hurtboxes + 1] = box
  world._sorted[#world._sorted + 1] = box
  return box
end

-- A box of the fighter that hits; inactive until activate. opts: ox, oy, w, h, tag, and
--   power            multiplies the fighter's attack_damage stat (default 1)
--   damage           a fixed amount instead of attack_damage * power
--   knockback        px/s given to the target (default 0), before its knockback_resist
--   kx, ky           the knockback's direction when facing right (default 1, 0); kx is
--                    mirrored when the fighter faces left
--   away             true: kx points away from the fighter's centre instead of along its facing
--   hitstop          seconds both fighters freeze (default: the world's default_hitstop)
--   global_hitstop   seconds the whole world freezes (default 0)
function Fighter:hitbox(opts)
  local box = new_box(self, "hit", opts)
  box.power, box.damage = opts.power or 1, opts.damage
  box.knockback, box.kx, box.ky, box.away = opts.knockback or 0, opts.kx or 1, opts.ky or 0, opts.away or false
  box.hitstop, box.global_hitstop = opts.hitstop, opts.global_hitstop or 0
  box.active = false
  box.time = nil                             -- seconds of activity left; nil: until deactivate
  box.hit_list, box.hit_n = {}, 0            -- the fighters hit in this activation
  local world = self.world
  self.hitboxes[#self.hitboxes + 1] = box
  world.hitboxes[#world.hitboxes + 1] = box
  return box
end

-- Seconds of freeze: at least t for this fighter.
function Fighter:stop(t)
  if t > self.hitstop then self.hitstop = t end
end
-- True while the fighter, or the whole world, is in hitstop: the game skips its update.
function Fighter:frozen()
  return self.hitstop > 0 or self.world.hitstop > 0
end
function Fighter:invulnerable() return self.invuln > 0 end

-- Adds health, up to the max_health stat. Returns the new health. Not for the dead.
function Fighter:heal(amount)
  if self.dead then return 0 end
  local h, max = self.health + amount, self.stats:get("max_health")
  if h > max then h = max end
  self.health = h
  return h
end

-- Back to life with that health (default: max_health), no i-frames and no hitstop.
function Fighter:revive(health)
  self.dead = false
  self.health = health or self.stats:get("max_health")
  self.invuln, self.hitstop = 0, 0
end

---------------------------------------------------------------------------
-- Boxes
---------------------------------------------------------------------------

local function place(box)
  local b = box.fighter.body
  local x
  if (b.facing or 1) < 0 then
    x = b.x + (b.w or 0) - box.ox - box.w
  else
    x = b.x + box.ox
  end
  local y = b.y + box.oy
  box.x1, box.y1, box.x2, box.y2 = x, y, x + box.w, y + box.h
end

-- The box's rectangle now, in world pixels: x, y, w, h (to draw it while debugging).
function Box:rect()
  place(self)
  return self.x1, self.y1, self.w, self.h
end

-- Changes the offset and the size.
function Box:set(ox, oy, w, h)
  self.ox, self.oy, self.w, self.h = ox, oy, w, h
end

-- Hitboxes: starts hitting, with an empty hit list. duration: seconds (it hits in
-- duration / dt steps, the one of this call included when the world steps after it);
-- nil: until deactivate.
function Box:activate(duration)
  local list = self.hit_list
  for i = 1, self.hit_n do list[i] = nil end
  self.hit_n = 0
  self.active = true
  self.time = duration
end

function Box:deactivate()
  self.active = false
  self.time = nil
end

-- True if this activation already hit that fighter.
function Box:hasHit(fighter)
  local list = self.hit_list
  for i = 1, self.hit_n do
    if list[i] == fighter then return true end
  end
  return false
end

-- Takes the box out of the world.
function Box:remove()
  self.removed = true
  self.fighter.world._dirty = true
end

---------------------------------------------------------------------------
-- A hit
---------------------------------------------------------------------------

local function centre_x(b) return b.x + (b.w or 0) * 0.5 end

-- The whole pipeline for one hit. Returns true if it landed.
local function resolve(self, attacker, target, spec, hurtbox)
  if target.dead or target.removed or target.invuln > 0 then return false end
  local list = spec.hit_list
  if list then                               -- a hitbox: once per fighter and activation
    local n = spec.hit_n + 1
    list[n], spec.hit_n = target, n
  end
  local depth = self._depth + 1
  local hit = self._hits[depth]
  if not hit then hit = {}; self._hits[depth] = hit end
  self._depth = depth

  -- 1. the amount: the attacker's stat, then its modifiers, then the target's defense and
  --    its modifiers
  local amount = spec.damage
  if amount == nil then
    amount = attacker and attacker.stats:get("attack_damage") * (spec.power or 1) or 0
  end
  hit.attacker, hit.target, hit.hitbox, hit.hurtbox = attacker, target, spec, hurtbox
  hit.base, hit.amount, hit.knockback = amount, amount, spec.knockback or 0
  hit.cancel, hit.killed, hit.knock_x, hit.knock_y = false, false, 0, 0
  if attacker and attacker.mods then attacker.mods:emit("on_hit", hit) end
  amount = hit.amount - target.stats:get("defense")
  if amount < 0 then amount = 0 end
  hit.amount = amount
  if target.mods then target.mods:emit("on_damaged", hit) end
  if hit.cancel then
    self._depth = depth - 1
    return false
  end
  amount = hit.amount
  if amount < 0 then amount = 0; hit.amount = 0 end

  -- 2. health
  local health = target.health - amount
  if health < 0 then health = 0 end
  target.health = health

  -- 3. knockback, less the target's resistance
  local force = hit.knockback
  if force > 0 then
    local resist = target.stats:get("knockback_resist")
    if resist < 0 then resist = 0 elseif resist > 1 then resist = 1 end
    force = force * (1 - resist)
    local dir = 1
    if attacker then
      local ab = attacker.body
      dir = (ab.facing or 1) < 0 and -1 or 1
      if spec.away then
        local d = centre_x(target.body) - centre_x(ab)
        if d > 0 then dir = 1 elseif d < 0 then dir = -1 end
      end
    end
    local kx, ky = (spec.kx or 1) * dir * force, (spec.ky or 0) * force
    hit.knock_x, hit.knock_y = kx, ky
    local body = target.body
    if force > 0 and body.vx ~= nil then
      body.vx = kx
      if ky ~= 0 and body.vy ~= nil then body.vy = ky end
    end
  end

  -- 4. invulnerability and hitstop
  local inv = target.stats:get("invuln_time")
  if inv > 0 then target.invuln = inv end
  local stop = spec.hitstop or self.default_hitstop
  if stop > 0 then
    if stop > target.hitstop then target.hitstop = stop end
    if attacker and stop > attacker.hitstop then attacker.hitstop = stop end
  end
  local all = spec.global_hitstop
  if all and all > self.hitstop then self.hitstop = all end

  -- 5. callbacks and death
  if target.on_hurt then target.on_hurt(target, hit) end
  if health <= 0 then
    target.dead, hit.killed = true, true
    local boxes = target.hitboxes
    for i = 1, #boxes do boxes[i]:deactivate() end
    if target.mods then target.mods:emit("on_death", hit) end
    if target.on_death then target.on_death(target, hit) end
    if attacker and attacker.mods then attacker.mods:emit("on_kill", hit) end
  end
  if self.on_hit then self.on_hit(hit) end
  self._depth = depth - 1
  return true
end

-- A hit without boxes (a hazard, a poison tick, a reflected hit): the same pipeline, with no
-- overlap, team or hit list check; i-frames still protect. attacker may be nil. spec: the
-- fields of a hitbox (damage or power, knockback, kx, ky, away, hitstop, global_hitstop).
-- Returns true if it landed. May be called from a handler of another hit.
function World:strike(attacker, target, spec)
  return resolve(self, attacker, target, spec, nil)
end

---------------------------------------------------------------------------
-- The step
---------------------------------------------------------------------------

local function pack(list)
  local n, j = #list, 0
  for i = 1, n do
    local v = list[i]
    if not v.removed then
      j = j + 1
      list[j] = v
    end
  end
  for i = j + 1, n do list[i] = nil end
end

local function tick(t, dt)
  t = t - dt
  if t <= EPS then return 0 end
  return t
end

-- Finds this step's overlaps: world._pairs, by hitbox id and then by hurtbox id.
local function detect(self)
  -- the hurtboxes where they are now, sorted by left edge (then by id)
  local sorted = self._sorted
  local count, widest = #sorted, 0
  for i = 1, count do
    local box = sorted[i]
    place(box)
    if box.w > widest then widest = box.w end
  end
  for i = 2, count do
    local box = sorted[i]
    local x, id = box.x1, box.id
    local j = i - 1
    while j >= 1 do
      local o = sorted[j]
      if o.x1 < x or (o.x1 == x and o.id < id) then break end
      sorted[j + 1] = o
      j = j - 1
    end
    sorted[j + 1] = box
  end

  local pairs_, n = self._pairs, 0
  local cand, can_hit = self._cand, self.can_hit
  local hitboxes = self.hitboxes
  for h = 1, #hitboxes do
    local hb = hitboxes[h]
    local f = hb.fighter
    if hb.active and not f.dead then
      place(hb)
      local x1, y1, x2, y2 = hb.x1, hb.y1, hb.x2, hb.y2
      -- the first hurtbox whose left edge is past x1 - widest: none before it reaches x1
      local limit = x1 - widest
      local lo, hi = 1, count + 1
      while lo < hi do
        local mid = (lo + hi - (lo + hi) % 2) / 2
        if sorted[mid].x1 > limit then hi = mid else lo = mid + 1 end
      end
      local c = 0
      local i = lo
      while i <= count do
        local box = sorted[i]
        if box.x1 >= x2 then break end
        local t = box.fighter
        if box.x2 > x1 and box.y1 < y2 and box.y2 > y1 and box.enabled and t ~= f
          and not t.dead and can_hit(f.team, t.team) and not hb:hasHit(t) then
          -- into cand, kept sorted by id
          local id = box.id
          local j = c
          while j >= 1 and cand[j].id > id do
            cand[j + 1] = cand[j]
            j = j - 1
          end
          cand[j + 1] = box
          c = c + 1
        end
        i = i + 1
      end
      for k = 1, c do
        pairs_[n + 1], pairs_[n + 2] = hb, cand[k]
        n = n + 2
        cand[k] = nil
      end
    end
  end
  for i = n + 1, self._pair_n do pairs_[i] = nil end
  self._pair_n = n
  return n
end

-- One fixed step. Call it after the bodies moved (and after the state machines activated
-- their hitboxes): finds the overlaps, resolves the hits in order, then runs the timers
-- (active hitboxes, i-frames, hitstop). Returns how many hits landed.
--
-- Hitstop: while world.hitstop > 0 nothing is searched and only the hitstop counters run. A
-- fighter that was frozen when the step began keeps its i-frames and its hitboxes' active
-- time as they were: the freeze does not eat them.
function World:step(dt)
  if self._dirty then
    pack(self.fighters); pack(self.hitboxes); pack(self.hurtboxes); pack(self._sorted)
    local fighters = self.fighters
    for i = 1, #fighters do
      pack(fighters[i].hitboxes); pack(fighters[i].hurtboxes)
    end
    self._dirty = false
  end
  local fighters = self.fighters
  local frozen = self.hitstop > 0
  for i = 1, #fighters do
    local f = fighters[i]
    f._was_frozen = frozen or f.hitstop > 0
  end

  local landed = 0
  if not frozen then
    local n = detect(self)
    local pairs_ = self._pairs
    for i = 1, n, 2 do
      local hb, box = pairs_[i], pairs_[i + 1]
      local t = box.fighter
      -- an earlier hit of this step may have changed things
      if hb.active and not hb.removed and not box.removed and box.enabled
        and not hb.fighter.dead and not hb:hasHit(t) then
        if resolve(self, hb.fighter, t, hb, box) then landed = landed + 1 end
      end
    end
  end
  self.hit_count = landed

  if frozen then self.hitstop = tick(self.hitstop, dt) end
  for i = 1, #fighters do
    local f = fighters[i]
    if f._was_frozen then
      if f.hitstop > 0 then f.hitstop = tick(f.hitstop, dt) end
    else
      if f.invuln > 0 then f.invuln = tick(f.invuln, dt) end
      local boxes = f.hitboxes
      for j = 1, #boxes do
        local hb = boxes[j]
        if hb.active and hb.time then
          local t = tick(hb.time, dt)
          if t == 0 then hb:deactivate() else hb.time = t end
        end
      end
    end
  end
  return landed
end

-- Seconds of freeze for everything: at least t.
function World:stop(t)
  if t > self.hitstop then self.hitstop = t end
end
-- True while the whole world is in hitstop: the game skips its updates (not world:step).
function World:frozen() return self.hitstop > 0 end

return M
