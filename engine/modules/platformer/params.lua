-- platformer.params: the controller's movement parameters as plain data, and what a jump can
-- reach with them (for level generation). See engine/modules/platformer/README.md.
-- Units: pixels and seconds. Nothing here is random or reads a clock.
local pairs, tostring = pairs, tostring

local M = {}

M.defaults = {
  gravity = 900,          -- px/s^2, downwards
  max_fall_speed = 360,   -- px/s
  max_speed = 90,         -- px/s, running
  ground_accel = 900,     -- px/s^2 towards max_speed while a direction is held, on the ground
  ground_decel = 1200,    -- px/s^2 towards 0 with no direction held, on the ground
  air_accel = 600,        -- the same two, in the air
  air_decel = 300,
  jump_velocity = 310,    -- px/s upwards at the start of a jump (a positive number)
  jump_cut = 0.4,         -- releasing jump while rising multiplies the upward speed by this
  coyote_time = 0.1,      -- s after walking off a ledge during which a jump still starts
  jump_buffer = 0.1,      -- s a jump press is remembered before landing
}

-- The parameter names, sorted.
M.names = {}
for name in pairs(M.defaults) do M.names[#M.names + 1] = name end
table.sort(M.names)

-- A new table with the defaults and the given values over them. It is also the `base` table
-- engine.modifiers wants: mods:attach(owner, params.new({ jump_velocity = 320 })).
function M.new(overrides)
  local p = {}
  for name, v in pairs(M.defaults) do p[name] = v end
  for name, v in pairs(overrides or {}) do
    if M.defaults[name] == nil then error("platformer: unknown parameter " .. tostring(name), 2) end
    p[name] = v
  end
  return p
end

-- A stat source over a plain table: source:get(name) reads params[name] (live: the table can
-- change). The controller reads every parameter through such a get.
local Source = {}
Source.__index = Source
function Source:get(name) return self.params[name] end
function M.source(params) return setmetatable({ params = params }, Source) end

-- The parameters as a plain table, read now from a stat source (anything with :get(name),
-- such as an engine.modifiers set): what M.reach needs to know a modified character's jump.
function M.resolve(stats)
  local p = {}
  for i = 1, #M.names do p[M.names[i]] = stats:get(M.names[i]) end
  return p
end

local MAX_STEPS = 36000   -- ten minutes at 60 Hz: a jump that long never lands

-- One full jump (jump held), stepped exactly as the controller steps it. `level` is the
-- height of the landing surface above the take-off surface (pixels, negative: below).
-- Returns the peak height and, if the jump lands there, the horizontal distance and the time.
local function simulate(p, dt, level)
  local g, max_fall, speed = p.gravity, p.max_fall_speed, p.max_speed
  local vy, h, x, peak = p.jump_velocity, 0, 0, 0     -- up is positive here
  for step = 1, MAX_STEPS do
    vy = vy - g * dt
    if vy < -max_fall then vy = -max_fall end
    h = h + vy * dt
    x = x + speed * dt
    if h > peak then peak = h end
    if vy <= 0 then
      if peak < level then return peak end            -- it never got that high
      if h < level then return peak, x, step * dt end
    end
  end
  return peak
end

-- The horizontal distance (pixels) a full jump at max_speed covers before landing on a surface
-- `rise` pixels above the take-off surface (0: level ground; negative: lower), or nil if the
-- jump does not get that high (or never lands). Then the time in the air.
-- opts: dt (the fixed step, default 1/60)
function M.jump_distance(params, rise, opts)
  local _, x, t = simulate(params, opts and opts.dt or 1 / 60, rise or 0)
  return x, t
end

-- What a jump reaches with these parameters (a plain table; M.resolve gives one for a
-- character with modifiers). opts: tile_size (default 16), dt (the fixed step, default 1/60).
-- Returns a new table:
--   jump_height, jump_height_tiles       how far the feet rise in a full jump
--   jump_distance, jump_distance_tiles   how far a full jump at max_speed travels before
--                                        landing at the height it left from
--   air_time                             seconds that jump lasts
--   coyote_distance                      extra run past a ledge before the jump (max_speed * coyote_time)
--   tile_size, dt                        what the numbers were computed with
-- The tile counts are not rounded. Distances are travel of the body's position: a body of
-- width w can stand with only its edge on a ledge, so the widest gap it crosses is
-- jump_distance + w (plus coyote_distance).
function M.reach(params, opts)
  opts = opts or {}
  local size = opts.tile_size or 16
  local dt = opts.dt or 1 / 60
  local peak, x, t = simulate(params, dt, 0)
  return {
    jump_height = peak, jump_height_tiles = peak / size,
    jump_distance = x or 0, jump_distance_tiles = (x or 0) / size,
    air_time = t or 0,
    coyote_distance = params.max_speed * params.coyote_time,
    tile_size = size, dt = dt,
  }
end

return M
