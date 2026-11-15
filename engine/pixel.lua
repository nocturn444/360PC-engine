-- engine.pixel: draw the game at a low, fixed resolution (for example 320x180) and show it
-- scaled by a whole number, centred, with bars around it. See docs/ENGINE.md.
--
-- Two ways of getting there, same coordinates for the game:
--   "canvas": the game is drawn on a canvas of the game's size and the canvas is drawn scaled
--             with nearest filtering. Real low-resolution pixels. PC only: on the console a
--             Canvas always has the screen's size (docs/API_SUBSET.md).
--   "direct": the game is drawn straight to the screen under a translate + scale. Every game
--             pixel is still scale x scale screen pixels as long as things are drawn at whole
--             coordinates (camera snap); rotated or scaled sprites show screen-sized pixels.
-- mode "auto" (the default) is "direct" on the console and "canvas" elsewhere.
local floor, min = math.floor, math.min

local M = {}
local Pixel = {}
Pixel.__index = Pixel

-- The scale and the top-left corner that fit a gw x gh game in a sw x sh screen. With `integer`
-- the scale is a whole number (at least 1) whenever the screen is at least the game's size.
function M.fit(gw, gh, sw, sh, integer)
  local scale = min(sw / gw, sh / gh)
  if integer ~= false and scale >= 1 then scale = floor(scale) end
  return scale, floor((sw - gw * scale) / 2), floor((sh - gh * scale) / 2)
end

-- opts: width, height (required), mode ("auto", "canvas", "direct"), integer (true),
-- background = { r, g, b } (the game area, black), bars = { r, g, b } (around it, black),
-- default_filter (true: love.graphics.setDefaultFilter("nearest", "nearest"))
function M.new(opts)
  assert(opts and opts.width and opts.height, "pixel needs width and height")
  local g = love.graphics
  local self = setmetatable({}, Pixel)
  self.width, self.height = opts.width, opts.height
  self.integer = opts.integer ~= false
  local bg, bars = opts.background or {}, opts.bars or {}
  self.bg_r, self.bg_g, self.bg_b = bg[1] or 0, bg[2] or 0, bg[3] or 0
  self.bar_r, self.bar_g, self.bar_b = bars[1] or 0, bars[2] or 0, bars[3] or 0
  local mode = opts.mode or "auto"
  if mode == "auto" then
    local console = love.system and love.system.getOS() == "Xbox 360"
    mode = console and "direct" or "canvas"
  end
  assert(mode == "canvas" or mode == "direct", "pixel mode must be auto, canvas or direct")
  self.mode = mode
  if opts.default_filter ~= false then g.setDefaultFilter("nearest", "nearest") end
  if mode == "canvas" then
    self.canvas = g.newCanvas(self.width, self.height)
    self.canvas:setFilter("nearest", "nearest")
  end
  self.scale, self.ox, self.oy = 1, 0, 0
  self.screen_w, self.screen_h = 0, 0
  self.cr, self.cg, self.cb, self.ca = 1, 1, 1, 1
  self:resize()
  return self
end

-- Call when the window changes size (love.resize). No arguments: asks love.graphics.
function Pixel:resize(sw, sh)
  if not sw then sw, sh = love.graphics.getDimensions() end
  self.screen_w, self.screen_h = sw, sh
  self.scale, self.ox, self.oy = M.fit(self.width, self.height, sw, sh, self.integer)
end

-- Between start and finish, drawing is in game pixels: 0,0 to width,height.
function Pixel:start()
  local g = love.graphics
  self.cr, self.cg, self.cb, self.ca = g.getColor()
  if self.canvas then
    g.setCanvas(self.canvas)
    g.clear(self.bg_r, self.bg_g, self.bg_b, 1)
    g.push()
    g.origin()
  else
    g.push()
    g.origin()
    g.translate(self.ox, self.oy)
    g.scale(self.scale, self.scale)
    g.setColor(self.bg_r, self.bg_g, self.bg_b, 1)
    g.rectangle("fill", 0, 0, self.width, self.height)
    g.setColor(self.cr, self.cg, self.cb, self.ca)
  end
end

function Pixel:finish()
  local g = love.graphics
  local ox, oy, sw, sh = self.ox, self.oy, self.screen_w, self.screen_h
  local w, h = self.width * self.scale, self.height * self.scale
  g.pop()
  if self.canvas then g.setCanvas() end
  g.push()
  g.origin()
  -- the bars, drawn last: in direct mode they also hide what was drawn outside the game area
  g.setColor(self.bar_r, self.bar_g, self.bar_b, 1)
  if oy > 0 then g.rectangle("fill", 0, 0, sw, oy) end
  if sh - oy - h > 0 then g.rectangle("fill", 0, oy + h, sw, sh - oy - h) end
  if ox > 0 then g.rectangle("fill", 0, oy, ox, h) end
  if sw - ox - w > 0 then g.rectangle("fill", ox + w, oy, sw - ox - w, h) end
  if self.canvas then
    -- a canvas holds premultiplied colours: over black, with the premultiplied blend
    g.setColor(0, 0, 0, 1)
    g.rectangle("fill", ox, oy, w, h)
    g.setColor(1, 1, 1, 1)
    g.setBlendMode("alpha", "premultiplied")
    g.draw(self.canvas, ox, oy, 0, self.scale, self.scale)
    g.setBlendMode("alpha", "alphamultiply")
  end
  g.pop()
  g.setColor(self.cr, self.cg, self.cb, self.ca)
end

-- Screen (window) pixels to game pixels; the third result says whether the point is in the game area.
function Pixel:toGame(sx, sy)
  local gx, gy = (sx - self.ox) / self.scale, (sy - self.oy) / self.scale
  return gx, gy, gx >= 0 and gy >= 0 and gx < self.width and gy < self.height
end

function Pixel:toScreen(gx, gy)
  return gx * self.scale + self.ox, gy * self.scale + self.oy
end

-- The mouse in game pixels (on the console: the centre, there is no mouse).
function Pixel:getMouse()
  if not love.mouse then return self.width / 2, self.height / 2, true end
  return self:toGame(love.mouse.getPosition())
end

return M
