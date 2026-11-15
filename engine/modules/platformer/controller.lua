-- platformer.controller: a character that runs, falls and jumps in a bump.lua world.
-- See engine/modules/platformer/README.md.
--
--   local body = controller.new(world, { x = 8, y = 0, w = 10, h = 14 })
--   body:step(input, dt)        -- once per fixed step (engine.timestep), after input:step()
--
-- Every movement parameter (params.lua) is read through body.stats:get(name) on every step.
-- With opts.params that is the plain table; with opts.stats it is whatever the game gives,
-- such as an engine.modifiers set, so a modifier changes the jump without this file knowing.
local M = {}
local Body = {}
Body.__index = Body

local EPS = 1e-9          -- a timer this close to zero has run out

local function module(name, ...)
  return require((((...) or "controller"):gsub("controller$", name)))
end
local params = module("params", ...)
local filter = module("collision", ...).filter

M.actions = { left = "left", right = "right", jump = "jump", down = "down" }

-- opts:
--   x, y, w, h   the body's rectangle (x, y: its top left corner), in pixels
--   params       a table from params.new (default: the defaults). Not used if stats is given.
--   stats        anything with :get(name) answering every name in params.defaults, such as
--                mods:attach(owner, params.new()) of engine.modifiers
--   actions      action names for engine.input: left, right, jump, down (defaults: the same
--                words), and optionally move_x, an axis used instead of left and right
--   filter       function(body, other) for items without a `kind` (returns a bump response
--                name or nil); default: they are ignored
function M.new(world, opts)
  local self = setmetatable({
    world = world,
    x = opts.x or 0, y = opts.y or 0, w = opts.w, h = opts.h,
    px = opts.x or 0, py = opts.y or 0,      -- the position before the last step (to interpolate)
    vx = 0, vy = 0,                          -- px/s; vy is positive downwards
    facing = 1,                              -- 1 or -1: the last direction held
    on_ground = false,
    ground = nil,                            -- the item stood on
    on_one_way = false,                      -- standing on one-way platforms only
    jumping = false,                         -- rising from a jump that was not cut yet
    jumped = false, landed = false, dropped = false,   -- true for the step it happened in
    wall = 0,                                -- -1 or 1: a wall on that side stopped this step
    ceiling = false,                         -- the head hit something this step
    collisions = nil, collision_count = 0,   -- bump's collisions of the last step
    coyote = 0, buffer = 0,                  -- seconds left
    drop = false,                            -- read by the filter: ignore one-way platforms
    filter = opts.filter,
    stats = opts.stats or params.source(opts.params or params.new()),
    actions = {},
  }, Body)
  for name, action in pairs(M.actions) do self.actions[name] = action end
  for name, action in pairs(opts.actions or {}) do self.actions[name] = action end
  world:add(self, self.x, self.y, self.w, self.h)
  return self
end

local function approach(v, target, step)
  if v < target then
    v = v + step
    if v > target then v = target end
  elseif v > target then
    v = v - step
    if v < target then v = target end
  end
  return v
end

-- One fixed step. input: an engine.input (or anything with down, pressed and axis); nil: no
-- action is held.
function Body:step(input, dt)
  local s, a = self.stats, self.actions
  local dir, jump_down, jump_pressed, down_held = 0, false, false, false
  if input then
    if a.move_x then
      dir = input:axis(a.move_x)
    else
      if input:down(a.right) then dir = dir + 1 end
      if input:down(a.left) then dir = dir - 1 end
    end
    jump_down, jump_pressed = input:down(a.jump), input:pressed(a.jump)
    down_held = input:down(a.down)
  end
  self.px, self.py = self.x, self.y
  self.jumped, self.landed, self.dropped, self.drop = false, false, false, false

  -- timers
  local grounded = self.on_ground
  if grounded then
    self.coyote = s:get("coyote_time")
  elseif self.coyote > 0 then
    self.coyote = self.coyote - dt
  end
  if self.buffer > 0 then self.buffer = self.buffer - dt end
  if jump_pressed then self.buffer = s:get("jump_buffer") end

  -- run
  local rate
  if dir ~= 0 then
    rate = grounded and s:get("ground_accel") or s:get("air_accel")
    self.facing = dir > 0 and 1 or -1
  else
    rate = grounded and s:get("ground_decel") or s:get("air_decel")
  end
  self.vx = approach(self.vx, dir * s:get("max_speed"), rate * dt)

  -- jump, or drop through a one-way platform (down + jump)
  if jump_pressed and down_held and grounded and self.on_one_way then
    self.drop, self.dropped = true, true
    self.coyote, self.buffer = 0, 0
  elseif (jump_pressed or self.buffer > EPS) and (grounded or self.coyote > EPS) then
    self.vy = -s:get("jump_velocity")
    self.jumping, self.jumped = true, true
    self.coyote, self.buffer = 0, 0
  end
  -- jump cut: the button is up while still rising (a buffered tap gives the short jump)
  if self.jumping then
    if self.vy >= 0 then
      self.jumping = false
    elseif not jump_down then
      self.vy = self.vy * s:get("jump_cut")
      self.jumping = false
    end
  end

  -- gravity
  local vy = self.vy + s:get("gravity") * dt
  local max_fall = s:get("max_fall_speed")
  if vy > max_fall then vy = max_fall end
  self.vy = vy

  -- move; the filter reads self.y (the position before the move) for one-way platforms
  local x, y, cols, len = self.world:move(self, self.x + self.vx * dt, self.y + vy * dt, filter)
  self.x, self.y = x, y
  self.collisions, self.collision_count = cols, len
  local on_ground, on_one_way, ground, wall, ceiling = false, true, nil, 0, false
  for i = 1, len do
    local c = cols[i]
    if c.type ~= "cross" then
      local nx, ny = c.normal.x, c.normal.y
      if ny < 0 then
        on_ground, ground = true, c.other
        if c.other.kind ~= "one_way" then on_one_way = false end
      elseif ny > 0 then
        ceiling = true
      end
      if nx ~= 0 then wall = -nx end
    end
  end
  if on_ground then
    if self.vy > 0 then self.vy = 0 end
    self.jumping = false
  end
  if ceiling and self.vy < 0 then self.vy = 0 end
  if wall ~= 0 and self.vx * wall > 0 then self.vx = 0 end
  self.landed = on_ground and not grounded
  self.on_ground, self.ground, self.on_one_way = on_ground, ground, on_ground and on_one_way
  self.wall, self.ceiling = wall, ceiling
end

-- Puts the body somewhere without colliding on the way, and stops it.
function Body:teleport(x, y)
  self.x, self.y, self.px, self.py = x, y, x, y
  self.vx, self.vy = 0, 0
  self.on_ground, self.ground, self.on_one_way, self.jumping = false, nil, false, false
  self.coyote, self.buffer = 0, 0
  self.world:update(self, x, y)
end

-- Takes the body out of its bump world.
function Body:remove()
  if self.world:hasItem(self) then self.world:remove(self) end
end

return M
