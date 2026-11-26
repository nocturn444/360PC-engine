-- engine.modules.abilities: movement abilities carried as data (air jump, wall jump, dash and
-- grappling hook), for any body through a small adapter. A genre module: nothing in engine/
-- requires it, it needs no other module and it knows nothing about a game. A game grants the
-- abilities its run has and gives the set one intent table per step.
-- Reference: engine/modules/abilities/README.md.
--
--   local abilities = require("engine.modules.abilities")
--   local set = abilities.new(body, { grid = grid })        -- or solid(x, y)
--   set:grant({ kind = "air_jump", id = "double_jump" })
--   set:grant({ kind = "dash", id = "dash", trigger = "double_tap" })
--
--   function play:update(dt)                                -- the fixed step, before body:step
--     intent.move_x, intent.jump, intent.jump_speed = ..., ..., ...
--     set:step(dt, intent)
--     body:step(dt, grid)
--   end
--
-- Units are game pixels and seconds. A step reads numbers and booleans and allocates nothing.
-- No randomness, no clock, nothing from love: the same inputs give the same results on PC and
-- on the console.
local floor, sqrt, cos, sin, atan2, pi = math.floor, math.sqrt, math.cos, math.sin, math.atan2, math.pi
local type, next, tostring, error, setmetatable, table = type, next, tostring, error, setmetatable, table

local M = {}
local Set = {}
Set.__index = Set

local EPS = 1e-9
local RAD = pi / 180

local KINDS = {}

-- A registered kind: handlers.fields (name -> { type, default, values }), handlers.priority
-- (default), and the optional init, restack and reset. handlers.step(ability, set, dt, intent)
-- is required. A game registers its own with abilities.kind, exactly as the built-ins are.
function M.kind(name, handlers)
  if type(name) ~= "string" or name == "" then
    error("abilities.kind: the name is a non-empty string", 2)
  end
  if type(handlers) ~= "table" or type(handlers.step) ~= "function" then
    error("abilities.kind: " .. name .. " needs a step function", 2)
  end
  KINDS[name] = handlers
  return handlers
end

local function field_value(kind, name, spec, value)
  if value == nil then return spec.default end
  if type(value) ~= spec.type then
    error("abilities: " .. kind .. "." .. name .. " is a " .. spec.type .. ", not a " .. type(value), 3)
  end
  if spec.values then
    local found = false
    for i = 1, #spec.values do
      if spec.values[i] == value then found = true; break end
    end
    if not found then
      local text = tostring(spec.values[1])
      for i = 2, #spec.values do text = text .. " or " .. tostring(spec.values[i]) end
      error("abilities: " .. kind .. "." .. name .. " is " .. text, 3)
    end
  end
  return value
end

-- abilities.new(body, opts): body is the adapter (on_ground, wall_side, center, velocity,
-- set_velocity, impulse); opts.solid(x, y) or opts.grid (tile_size + kind(tx, ty)) is what the
-- hook needs.
function M.new(body, opts)
  opts = opts or {}
  return setmetatable({
    body = body,
    solid = opts.solid,
    grid = opts.grid,
    list = {},              -- the live abilities, by priority (lower first)
    by_id = {},             -- id -> the live ability
  }, Set)
end

-- Gives an ability (a checked copy of def). Granting the same id again adds one stack and
-- refills what the stacks give (air uses, dash uses). Returns the live ability.
function Set:grant(def)
  if type(def) ~= "table" then error("abilities: a definition is a table", 2) end
  local kind = def.kind
  local handlers = KINDS[kind]
  if not handlers then error("abilities: unknown kind " .. tostring(kind), 2) end
  local id = def.id
  if type(id) ~= "string" or id == "" then error("abilities: id is a non-empty string", 2) end
  local fields = handlers.fields or {}
  for k in next, def do
    if k ~= "id" and k ~= "kind" and k ~= "priority" and fields[k] == nil then
      error("abilities: " .. kind .. " has no field " .. tostring(k), 2)
    end
  end
  local existing = self.by_id[id]
  if existing then
    existing.stacks = existing.stacks + 1
    if handlers.restack then handlers.restack(existing) end
    return existing
  end
  local priority = def.priority
  if priority == nil then
    priority = handlers.priority or 0
  elseif type(priority) ~= "number" then
    error("abilities: priority is a number", 2)
  end
  local a = { id = id, kind = kind, priority = priority, stacks = 1, handler = handlers }
  local stored = { id = id, kind = kind, priority = priority }
  for name, spec in next, fields do
    local value = field_value(kind, name, spec, def[name])
    a[name], stored[name] = value, value
  end
  a.def = stored
  if handlers.init then handlers.init(a) end
  self.by_id[id] = a
  local list = self.list
  local n = #list + 1
  local i = n
  while i > 1 and list[i - 1].priority > priority do
    list[i] = list[i - 1]
    i = i - 1
  end
  list[i] = a
  return a
end

-- Takes an ability away (all its stacks).
function Set:revoke(id)
  local a = self.by_id[id]
  if not a then return end
  self.by_id[id] = nil
  local list = self.list
  for i = 1, #list do
    if list[i] == a then table.remove(list, i); break end
  end
end

function Set:has(id) return self.by_id[id] ~= nil end
function Set:get(id) return self.by_id[id] end
function Set:stacks(id)
  local a = self.by_id[id]
  return a and a.stacks or 0
end

-- Once per fixed step, before the body steps. intent is the game's own table, refilled every
-- step: move_x, move_y (-1..1), jump (pressed this step), jump_held, dash, hook (pressed this
-- step), jump_speed, facing (the direction to dash when nothing is held) and consumed_jump
-- (written here when an ability used the jump press).
function Set:step(dt, intent)
  local list = self.list
  for i = 1, #list do
    local a = list[i]
    a.handler.step(a, self, dt, intent)
  end
end

-- Drops transient state (a room change): the hook is released, the dash stopped, the air
-- uses refilled. The granted abilities and their stacks stay.
function Set:reset()
  local list = self.list
  for i = 1, #list do
    local a = list[i]
    if a.handler.reset then a.handler.reset(a) end
  end
end

-- The granted abilities and their stacks, as plain data for a run save.
function Set:state()
  local list, out = self.list, {}
  for i = 1, #list do
    local a = list[i]
    out[i] = { id = a.id, kind = a.kind, stacks = a.stacks, def = a.def }
  end
  return out
end

-- Restores what state() returned. Definitions travel with the state, so this needs nothing else.
function Set:set_state(state)
  local list = self.list
  for i = #list, 1, -1 do
    self.by_id[list[i].id] = nil
    list[i] = nil
  end
  for i = 1, #state do
    local entry = state[i]
    local a = self:grant(entry.def)
    if entry.stacks and entry.stacks ~= a.stacks then
      a.stacks = entry.stacks
      if a.handler.restack then a.handler.restack(a) end
    end
  end
end

-- Refills the air jumps of every granted air_jump (a wall jump or a hook release calls it).
function Set:refill_air()
  local list = self.list
  for i = 1, #list do
    local a = list[i]
    if a.kind == "air_jump" then a.uses = a.max_uses end
  end
end

-- The world pixel the hook needs: opts.solid, or opts.grid's solid tiles (and its one-way
-- tiles too when one_way is true: a hook that grabs platforms).
local function solid_at(set, x, y, one_way)
  local solid = set.solid
  if solid then return solid(x, y, one_way) end
  local grid = set.grid
  if not grid then return false end
  local size = grid.tile_size
  local kind = grid:kind(floor(x / size) + 1, floor(y / size) + 1)
  return kind == "solid" or (one_way == true and kind == "one_way")
end

local function intends(move, side)
  return (move < 0 and side < 0) or (move > 0 and side > 0)
end

local function snap_dir(dx, dy, dirs)
  local angle = atan2(dy, dx)
  local step = dirs == 4 and pi * 0.5 or pi * 0.25
  local snapped = floor(angle / step + 0.5) * step
  return cos(snapped), sin(snapped)
end

--------------------------------------------------------------------------------
-- air_jump
--------------------------------------------------------------------------------

M.kind("air_jump", {
  fields = {
    count = { type = "number", default = 1 },   -- uses per stack
    power = { type = "number", default = 1.0 },
  },
  priority = 30,
  init = function(a)
    a.max_uses = a.count * a.stacks
    a.uses = a.max_uses
  end,
  restack = function(a)
    a.max_uses = a.count * a.stacks
    a.uses = a.max_uses
  end,
  reset = function(a) a.uses = a.max_uses end,
  step = function(a, set, dt, intent)
    local body = set.body
    if body:on_ground() then a.uses = a.max_uses end
    if intent.jump and not intent.consumed_jump and not body:on_ground() and a.uses > 0 then
      body:set_velocity(nil, -(intent.jump_speed or 0) * a.power)
      a.uses = a.uses - 1
      intent.consumed_jump = true
    end
  end,
})

--------------------------------------------------------------------------------
-- wall_jump
--------------------------------------------------------------------------------

M.kind("wall_jump", {
  fields = {
    kick_x = { type = "number", default = 180 },
    power = { type = "number", default = 1.0 },
    slide_speed = { type = "number", default = 60 },
    lock = { type = "number", default = 0.15 },
  },
  priority = 10,
  init = function(a) a.lock_timer, a.lock_side = 0, 0 end,
  reset = function(a) a.lock_timer, a.lock_side = 0, 0 end,
  step = function(a, set, dt, intent)
    local body = set.body
    local move_x = intent.move_x or 0
    if a.lock_timer > 0 then
      a.lock_timer = a.lock_timer - dt
      if intends(move_x, a.lock_side) then intent.move_x = 0; move_x = 0 end
    end
    local side = body:wall_side()
    local grounded = body:on_ground()
    if intent.jump and not intent.consumed_jump and not grounded and side ~= 0 then
      body:set_velocity(-side * a.kick_x, -(intent.jump_speed or 0) * a.power)
      a.lock_timer, a.lock_side = a.lock, side
      intent.consumed_jump, intent.move_x = true, 0
      set:refill_air()
    elseif a.slide_speed > 0 and not grounded and side ~= 0 and intends(move_x, side) then
      local _, vy = body:velocity()
      if vy > a.slide_speed then body:set_velocity(nil, a.slide_speed) end
    end
  end,
})

--------------------------------------------------------------------------------
-- dash
--------------------------------------------------------------------------------

local function dash_start(a, set, dir_x, dir_y)
  local body = set.body
  a.active, a.timer, a.cool = true, a.time, a.cooldown
  a.dir_x, a.dir_y = dir_x, dir_y
  if not body:on_ground() then a.air_left = a.air_left - 1 end
  body:set_velocity(dir_x * a.speed, dir_y * a.speed)
end

local function dash_begin(a, set, intent, dir_x, dir_y)
  if dir_x == 0 and dir_y == 0 then
    dir_x = (intent.facing or 1) < 0 and -1 or 1
  else
    dir_x, dir_y = snap_dir(dir_x, dir_y, a.dirs)
  end
  dash_start(a, set, dir_x, dir_y)
end

M.kind("dash", {
  fields = {
    speed = { type = "number", default = 330 },
    time = { type = "number", default = 0.14 },
    cooldown = { type = "number", default = 0.45 },
    air_uses = { type = "number", default = 1 },  -- per stack
    dirs = { type = "number", default = 8, values = { 4, 8 } },
    trigger = { type = "string", default = "button", values = { "button", "double_tap" } },
    tap_window = { type = "number", default = 0.25 },
    tap_threshold = { type = "number", default = 0.5 },
  },
  priority = 20,
  init = function(a)
    a.active, a.timer, a.cool, a.dir_x, a.dir_y = false, 0, 0, 0, 0
    a.max_air = a.air_uses * a.stacks
    a.air_left = a.max_air
    a.prev_above, a.tap_timer, a.tap_sign = false, 0, 0
  end,
  restack = function(a)
    a.max_air = a.air_uses * a.stacks
    a.air_left = a.max_air
  end,
  reset = function(a)
    a.active, a.timer, a.cool, a.dir_x, a.dir_y = false, 0, 0, 0, 0
    a.air_left = a.max_air
    a.prev_above, a.tap_timer, a.tap_sign = false, 0, 0
  end,
  step = function(a, set, dt, intent)
    local body = set.body
    local grounded = body:on_ground()
    if grounded then a.air_left = a.max_air end
    if a.cool > 0 then
      a.cool = a.cool - dt
      if a.cool < 0 then a.cool = 0 end
    end
    if a.active then
      a.timer = a.timer - dt
      local wall = body:wall_side()
      if a.dir_x ~= 0 and wall == (a.dir_x > 0 and 1 or -1) then
        a.active = false
      elseif a.timer <= 0 then
        a.active = false
      else
        body:set_velocity(a.dir_x * a.speed, a.dir_y * a.speed)
      end
    end
    if a.active or a.cool > 0 then return end
    if not grounded and a.air_left <= 0 then return end

    if a.trigger == "double_tap" then
      local move_x = intent.move_x or 0
      local above = move_x > a.tap_threshold or move_x < -a.tap_threshold
      local sign = move_x > 0 and 1 or -1
      local tapped = above and not a.prev_above
      a.prev_above = above
      if a.tap_timer > 0 then a.tap_timer = a.tap_timer - dt end
      if tapped then
        if a.tap_timer > 0 and a.tap_sign == sign then
          a.tap_timer = 0
          dash_start(a, set, sign, 0)
        else
          a.tap_sign, a.tap_timer = sign, a.tap_window
        end
      end
    elseif intent.dash then
      dash_begin(a, set, intent, intent.move_x or 0, intent.move_y or 0)
    end
  end,
})

--------------------------------------------------------------------------------
-- hook
--------------------------------------------------------------------------------

local function hook_release(a) a.phase = "idle" end

M.kind("hook", {
  fields = {
    range = { type = "number", default = 112 },
    speed = { type = "number", default = 420 },   -- flight, px/s
    angle = { type = "number", default = 55 },    -- degrees above horizontal, toward facing
    reel = { type = "number", default = 60 },     -- px/s with up/down
    min_length = { type = "number", default = 16 },
    pump = { type = "number", default = 260 },    -- px/s^2 with left/right while swinging
    release_boost = { type = "number", default = 1.0 },
    one_way = { type = "boolean", default = false },   -- also grabs one-way platforms
  },
  priority = 5,
  init = function(a)
    a.phase, a.hx, a.hy, a.length = "idle", 0, 0, 0
    a.dir_x, a.dir_y, a.travelled = 0, 0, 0
  end,
  reset = function(a) hook_release(a) end,
  step = function(a, set, dt, intent)
    local body = set.body
    local move_x, move_y = intent.move_x or 0, intent.move_y or 0
    if a.phase == "attached" then
      if intent.hook then
        hook_release(a)
      elseif intent.jump and not intent.consumed_jump then
        local vx, vy = body:velocity()
        body:set_velocity(vx * a.release_boost, vy * a.release_boost - (intent.jump_speed or 0) * 0.5)
        intent.consumed_jump = true
        hook_release(a)
        set:refill_air()
      else
        if move_y < 0 then
          a.length = a.length - a.reel * dt
          if a.length < a.min_length then a.length = a.min_length end
        elseif move_y > 0 then
          a.length = a.length + a.reel * dt
        end
        if move_x ~= 0 then body:impulse(move_x * a.pump * dt, 0) end
        local cx, cy = body:center()
        local dx, dy = cx - a.hx, cy - a.hy
        local dist = sqrt(dx * dx + dy * dy)
        if dist > a.length + EPS then
          local ux, uy = dx / dist, dy / dist
          local vx, vy = body:velocity()
          local radial = vx * ux + vy * uy
          local tx, ty = vx - radial * ux, vy - radial * uy
          local inward = -(dist - a.length) / dt
          body:set_velocity(tx + ux * inward, ty + uy * inward)
        end
      end
    elseif a.phase == "flying" then
      local remain = a.speed * dt
      local hit = false
      while remain > EPS do
        local s = remain > 2 and 2 or remain
        local nx, ny = a.hx + a.dir_x * s, a.hy + a.dir_y * s
        a.travelled = a.travelled + s
        remain = remain - s
        if solid_at(set, nx, ny, a.one_way) then hit = true; break end
        a.hx, a.hy = nx, ny
      end
      if hit then
        local cx, cy = body:center()
        local dx, dy = a.hx - cx, a.hy - cy
        a.length = sqrt(dx * dx + dy * dy)
        a.phase = "attached"
      elseif a.travelled >= a.range then
        a.phase = "idle"
      end
    elseif intent.hook then
      local cx, cy = body:center()
      local dir_x, dir_y
      if move_y < 0 then
        dir_x, dir_y = 0, -1
      else
        local facing = (intent.facing or 1) < 0 and -1 or 1
        local rad = a.angle * RAD
        dir_x, dir_y = facing * cos(rad), -sin(rad)
      end
      a.phase, a.hx, a.hy = "flying", cx, cy
      a.dir_x, a.dir_y, a.travelled = dir_x, dir_y, 0
    end
  end,
})

return M
