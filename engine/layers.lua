-- engine.layers: a sprite made of named layers drawn one over another (a body, what it wears,
-- what it holds, an effect...). Knows nothing about entities: it is a thing you update and draw
-- at a position. See docs/ENGINE.md.
--
-- Draw order, back to front:
--   1. the layers named in the order list given to new(), in that list's order;
--   2. then any other layer, in the order they were first added.
-- Replacing a layer keeps its place.
local M = {}
local Set = {}
Set.__index = Set

-- order: optional list of layer names, back to front, e.g. { "body", "outfit", "held", "effect" }
function M.new(order)
  local self = setmetatable({ layers = {}, list = {}, rank = {}, extra = 0 }, Set)
  for i, name in ipairs(order or {}) do self.rank[name] = i end
  self.base = #(order or {})
  return self
end

local function by_rank(a, b) return a.rank < b.rank end

-- Adds a layer, or replaces the one with that name. def (all optional except what to draw):
--   image          an Image (or anything love.graphics.draw takes)
--   quad           the part of the image to draw
--   anim           an animation with update(dt) and draw(image, x, y, r, sx, sy, ox, oy), such as anim8's
--   draw           function(layer, x, y, r, sx, sy, ox, oy) instead of the above
--   ox, oy         offset from the set's origin, in the sprite's own pixels (it follows flips and rotation)
--   tint           { r, g, b, a }, multiplied with the colour current when the set is drawn
--   visible        default true
function Set:set(name, def)
  local l = self.layers[name]
  if not l then
    local rank = self.rank[name]
    if not rank then
      self.extra = self.extra + 1
      rank = self.base + self.extra
      self.rank[name] = rank
    end
    l = { name = name, rank = rank }
    self.layers[name] = l
    self.list[#self.list + 1] = l
    table.sort(self.list, by_rank)
  end
  local tint = def.tint
  l.image, l.quad, l.anim, l.draw = def.image, def.quad, def.anim, def.draw
  l.ox, l.oy = def.ox or 0, def.oy or 0
  l.r, l.g, l.b, l.a = 1, 1, 1, 1
  if tint then l.r, l.g, l.b, l.a = tint[1] or 1, tint[2] or 1, tint[3] or 1, tint[4] or 1 end
  l.visible = def.visible ~= false
  return l
end

function Set:remove(name)
  local l = self.layers[name]
  if not l then return false end
  self.layers[name] = nil
  for i = 1, #self.list do
    if self.list[i] == l then table.remove(self.list, i); break end
  end
  return true
end

-- The layer's table (fields: image, quad, anim, draw, ox, oy, r, g, b, a, visible), or nil.
function Set:get(name) return self.layers[name] end
function Set:has(name) return self.layers[name] ~= nil end
function Set:count() return #self.list end

local function layer_of(self, name)
  local l = self.layers[name]
  if not l then error("no layer named " .. tostring(name), 3) end
  return l
end

function Set:setVisible(name, visible) layer_of(self, name).visible = visible and true or false end
function Set:setOffset(name, ox, oy) local l = layer_of(self, name); l.ox, l.oy = ox, oy end
function Set:setAnim(name, anim) layer_of(self, name).anim = anim end
function Set:setQuad(name, quad) layer_of(self, name).quad = quad end
function Set:setTint(name, r, g, b, a)
  local l = layer_of(self, name)
  l.r, l.g, l.b, l.a = r or 1, g or 1, b or 1, a or 1
end

-- The layer names in draw order (a new table: not for every frame).
function Set:getOrder()
  local out = {}
  for i, l in ipairs(self.list) do out[i] = l.name end
  return out
end

-- Advances every layer's animation, visible or not, so they stay in step.
function Set:update(dt)
  local list = self.list
  for i = 1, #list do
    local anim = list[i].anim
    if anim then anim:update(dt) end
  end
end

-- Draws the visible layers in order. Same arguments as love.graphics.draw after the drawable.
function Set:draw(x, y, r, sx, sy, ox, oy)
  local g = love.graphics
  r, sx, ox, oy = r or 0, sx or 1, ox or 0, oy or 0
  sy = sy or sx
  local cr, cg, cb, ca = g.getColor()
  local list = self.list
  for i = 1, #list do
    local l = list[i]
    if l.visible then
      g.setColor(cr * l.r, cg * l.g, cb * l.b, ca * l.a)
      local lx, ly = ox - l.ox, oy - l.oy
      if l.draw then
        l.draw(l, x, y, r, sx, sy, lx, ly)
      elseif l.anim then
        l.anim:draw(l.image, x, y, r, sx, sy, lx, ly)
      elseif l.quad then
        g.draw(l.image, l.quad, x, y, r, sx, sy, lx, ly)
      elseif l.image then
        g.draw(l.image, x, y, r, sx, sy, lx, ly)
      end
    end
  end
  g.setColor(cr, cg, cb, ca)
end

return M
