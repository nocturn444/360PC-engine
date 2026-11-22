-- Vines (lianas) of the rooms example: the slime grabs a `vine` prop (rooms_props.lua), climbs
-- it with up / down and swings on it with left / right; jump lets go with the pendulum's speed.
-- The prop fields `speed` and `swing` control it. The play state only builds the room's list,
-- updates it before the slime steps and draws it, so the rest of the prop wiring can change
-- without touching this file. No love at load: only draw() touches love.graphics.
local sqrt, atan2, sin, cos, pi = math.sqrt, math.atan2, math.sin, math.cos, math.pi
local type = type
local prop_types = require("rooms_props").types

local M = {}

-- Tuning, in game pixels and seconds. `speed` and `swing` are the prop type's defaults.
M.tuning = {
  speed = 60,          -- climbing speed, pixels / s (the prop field overrides it)
  swing = true,        -- can swing (the prop field overrides it)
  pump = 10,           -- angular speed added while left / right is held, rad / s^2
  damping = 0.6,       -- fraction of the angular speed lost per second
  gravity = 900,       -- the pendulum's gravity, pixels / s^2
  max_angle = pi / 3,  -- radians from the vertical (60 degrees)
  min_length = 6,      -- pixels from the top: never grab closer than this
  width = 3,           -- line width, pixels
  color = { 0.25, 0.65, 0.30 },
}
local D = M.tuning

local function default_of(def, key)
  for i = 1, #(def.fields or {}) do
    local f = def.fields[i]
    if f.key == key then return f.default end
  end
end

-- A vine instance: x, y, w, h (pixels), its top and bottom points, speed and swing.
local function new_vine(x, y, w, h, speed, swing)
  local top_x = x + w / 2
  return {
    x = x, y = y, w = w, h = h,
    top_x = top_x, top_y = y, bottom_x = top_x, bottom_y = y + h,
    speed = speed or D.speed, swing = swing == nil and D.swing or swing,
  }
end

-- The placements of the template, with the vine type's defaults for size, speed and swing.
local function from_template(template, tile_size)
  local list = {}
  local def = prop_types:get("vine")
  local dw = def and def.size.w or 1
  local dh = def and def.size.h or 4
  local dspeed = (def and default_of(def, "speed")) or D.speed
  local dswing = def and default_of(def, "swing")
  if dswing == nil then dswing = D.swing end
  local props = template.props
  for i = 1, #(props or {}) do
    local p = props[i]
    if p.type == "vine" then
      local fields = p.fields or {}
      local speed, swing = fields.speed, fields.swing
      if speed == nil then speed = dspeed end
      if swing == nil then swing = dswing end
      list[#list + 1] = new_vine((p.tx - 1) * tile_size, (p.ty - 1) * tile_size,
        (p.w or dw) * tile_size, (p.h or dh) * tile_size, speed, swing)
    end
  end
  return list
end

-- The live props of the room (engine.modules.props), when the play state already has a set.
local function from_set(set)
  local list = {}
  for i = 1, set:count() do
    local p = set:at(i)
    if p.type == "vine" and not p.removed then
      local fields = p.fields
      list[#list + 1] = new_vine(p.x, p.y, p.w, p.h,
        fields and fields.speed, fields and fields.swing)
    end
  end
  return list
end

local function is_set(v)
  return type(v) == "table" and type(v.count) == "function" and type(v.at) == "function"
end

-- M.build(self, template, tile_size): the room's vines, from self.props if it exists, else from
-- the template's placements. Also lets go of a vine left from the previous room.
function M.build(self, template, tile_size)
  if self.vine and self.slime then
    self.slime.gravity = self.vine_gravity or self.slime.gravity
  end
  self.vine, self.vine_gravity = nil, nil
  self.vine_len, self.vine_angle, self.vine_angvel = 0, 0, 0
  self.vines = is_set(self.props) and from_set(self.props)
    or from_template(template or {}, tile_size or 16)
  return self.vines
end

local function find(list, cx, cy)
  for i = 1, #list do
    local v = list[i]
    if cx >= v.x and cx <= v.x + v.w and cy >= v.y and cy <= v.y + v.h then return v end
  end
end

local function grab(self, vine, cx, cy)
  local dx, dy = cx - vine.top_x, cy - vine.top_y
  local len = sqrt(dx * dx + dy * dy)
  if len < D.min_length then len = D.min_length elseif len > vine.h then len = vine.h end
  local angle = atan2(dx, dy)
  if angle > D.max_angle then angle = D.max_angle
  elseif angle < -D.max_angle then angle = -D.max_angle end
  self.vine = vine
  self.vine_len, self.vine_angle, self.vine_angvel = len, angle, 0
  self.vine_gravity = self.slime.gravity
  self.slime.gravity = 0
end

-- Lets go: the pendulum's tangential speed, plus the normal jump when it is a jump.
local function release(self, jump)
  local slime = self.slime
  local len, angle, angvel = self.vine_len, self.vine_angle, self.vine_angvel
  local vx = cos(angle) * len * angvel
  local vy = -sin(angle) * len * angvel
  slime.gravity = self.vine_gravity or slime.gravity
  if jump and jump > 0 then vy = vy - jump end
  slime:impulse(vx, vy)
  self.vine, self.vine_gravity = nil, nil
  self.vine_len, self.vine_angle, self.vine_angvel = 0, 0, 0
end

-- M.update(self, dt, input, jump): grab, climb, swing or let go; call it before the slime's
-- step. `jump` is the normal jump's speed, in pixels / s.
function M.update(self, dt, input, jump)
  local vine = self.vine
  local grabbed = false
  if not vine then
    if not (input:pressed("up") or input:pressed("down")) then return end
    local cx, cy = self.slime:center()
    vine = find(self.vines, cx, cy)
    if not vine then return end
    grab(self, vine, cx, cy)
    grabbed = true
  end
  local slime = self.slime
  -- the normal controls also read up / down (jump shares their keys): drop what they asked for
  slime.ax, slime.ay, slime.ivx, slime.ivy = 0, 0, 0, 0
  local up, down = input:down("up"), input:down("down")
  local len = self.vine_len
  if up then len = len - vine.speed * dt end
  if down then len = len + vine.speed * dt end
  if len < D.min_length then len = D.min_length elseif len > vine.h then len = vine.h end
  self.vine_len = len
  if not grabbed then
    if input:pressed("jump") and not up then release(self, jump); return end
    if input:pressed("down") and len >= vine.h - 0.01 then release(self, 0); return end
  end
  if vine.swing then
    local move = input:axis("move_x")
    local angle, angvel = self.vine_angle, self.vine_angvel
    angvel = angvel + (-(D.gravity / len) * sin(angle) + move * D.pump) * dt
    angvel = angvel * (1 - D.damping * dt)
    angle = angle + angvel * dt
    if angle > D.max_angle then angle, angvel = D.max_angle, 0
    elseif angle < -D.max_angle then angle, angvel = -D.max_angle, 0 end
    self.vine_angle, self.vine_angvel = angle, angvel
  else
    self.vine_angle, self.vine_angvel = 0, 0
  end
  local angle = self.vine_angle
  local sx = vine.top_x + sin(angle) * len
  local sy = vine.top_y + cos(angle) * len
  slime.gravity = 0
  slime:move_to(sx, sy)
  slime:set_velocity(0, 0)
end

-- M.draw(self, g): a green line from each vine's top to its bottom, bent to the slime on the
-- one it holds. g is love.graphics (the only love here).
function M.draw(self, g)
  local list = self.vines
  if not list or #list == 0 then return end
  local c = D.color
  g.setColor(c[1], c[2], c[3], 1)
  g.setLineWidth(D.width)
  local held = self.vine
  for i = 1, #list do
    local v = list[i]
    if v == held then
      local cx, cy = self.slime:center()
      g.line(v.top_x, v.top_y, cx, cy, v.bottom_x, v.bottom_y)
    else
      g.line(v.top_x, v.top_y, v.bottom_x, v.bottom_y)
    end
  end
  g.setLineWidth(1)
end

return M
