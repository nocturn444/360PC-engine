-- Example state: a square moved with the keyboard or the controller. Logic runs in fixed
-- steps (update); draw interpolates between the last two steps with alpha.
local engine = require("engine")

local W, H, SIZE, SPEED = 320, 180, 16, 90
local play = { x = 152, y = 82, px = 152, py = 82, bright = false }

function play:enter()
  self.x, self.y = (W - SIZE) / 2, (H - SIZE) / 2
  self.px, self.py = self.x, self.y
end

function play:input(input)
  if input:pressed("action") then self.bright = not self.bright end
  if input:pressed("quit") then love.event.quit() end
end

function play:update(dt)
  local input = engine.controls
  self.px, self.py = self.x, self.y
  self.x = math.max(0, math.min(W - SIZE, self.x + input:axis("move_x") * SPEED * dt))
  self.y = math.max(0, math.min(H - SIZE, self.y + input:axis("move_y") * SPEED * dt))
end

function play:draw(alpha)
  local g = love.graphics
  g.setColor(0.10, 0.12, 0.18, 1)
  g.rectangle("fill", 0, 0, W, H)
  if self.bright then g.setColor(1, 0.8, 0.2, 1) else g.setColor(0.4, 0.7, 1, 1) end
  local x = self.px + (self.x - self.px) * alpha
  local y = self.py + (self.y - self.py) * alpha
  g.rectangle("fill", math.floor(x + 0.5), math.floor(y + 0.5), SIZE, SIZE)
  g.setColor(1, 1, 1, 1)
  g.print("New Game", 4, 4)       -- on the console text needs default_font in game.lua
end

return play
