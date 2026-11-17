-- The slime's room. Logic in fixed steps (update); draw rasterizes the body's outline, between
-- the last two steps, into a small pixel grid and draws it on the game's pixel grid.
local engine = require("engine")
local softbody = require("engine.modules.softbody")
local platformer = require("engine.modules.platformer")
local pixelgrid = require("engine.pixelgrid")

local TS = 16
local ROOM = {
  "####################",
  "#..................#",
  "#..................#",
  "#..........====....#",
  "#..................#",
  "#....====.........##",
  "#................###",
  "#..............#####",
  "#.....##.......#####",
  "#.....##.......#####",
  "####################",
}
-- the controls' numbers, tuned live with the overlay (engine.tune) like the body's own
local params = { move = 700, air_move = 300, jump = 260, charged_jump = 380, squash = 0.7 }
local SIZE = 40                              -- the pixel grid around the slime, in pixels

local play = {}

function play:enter()
  self.grid = platformer.grid.new(ROOM, { tile_size = TS })
  self.slime = softbody.new({ x = 60, y = 60, radius = 9, points = 18 })
  self.pixels = pixelgrid.new(SIZE, SIZE, { palette = {
    { 0.42, 0.86, 0.48 },                    -- 1 body
    { 0.10, 0.30, 0.16 },                    -- 2 outline
    { 0.95, 1.00, 0.95 },                    -- 3 eye white
    { 0.05, 0.08, 0.06 },                    -- 4 pupil
    { 0.70, 0.98, 0.72 },                    -- 5 shine
  } })
  self.points = {}
  self.facing = 1
  self.charging = false
  local slime = self.slime
  self.tuner = engine.tune.new({ file = "tune_slime.txt" })
  self.tuner:add(slime, "stiffness", { min = 0.05, max = 1, step = 0.05 })
    :add(slime, "pressure", { min = 0.05, max = 1, step = 0.05 })
    :add(slime, "damping", { min = 0.9, max = 1, step = 0.001 })
    :add(slime, "friction", { min = 0, max = 1, step = 0.05 })
    :add(slime, "gravity", { min = 100, max = 2000, step = 25 })
    :add(slime, "iterations", { min = 1, max = 12, step = 1 })
    :add(params, "move", { min = 0, max = 3000, step = 50 })
    :add(params, "air_move", { label = "air move", min = 0, max = 3000, step = 50 })
    :add(params, "jump", { min = 0, max = 800, step = 10 })
    :add(params, "charged_jump", { label = "charged jump", min = 0, max = 1000, step = 10 })
    :add(params, "squash", { min = 0.3, max = 1, step = 0.05 })
  self.tuner:load()                          -- what was saved with F5 / RB last time, if anything
end

function play:input(input)
  self.tuner:input(input)
  if input:pressed("quit") then love.event.quit() end
end

function play:update(dt)
  local input, slime = engine.controls, self.slime
  local move = input:axis("move_x")
  if move ~= 0 then self.facing = move > 0 and 1 or -1 end
  slime:push(move * (slime:on_ground() and params.move or params.air_move), 0)
  -- hold down to squash; let go on the ground for a bigger jump
  local squash = input:down("down")
  slime.inflate = squash and params.squash or 1
  if squash and slime:on_ground() then self.charging = true end
  if input:pressed("jump") and slime:on_ground() then
    slime:impulse(0, -params.jump)
  elseif self.charging and not squash then
    if slime:on_ground() then slime:impulse(0, -params.charged_jump) end
    self.charging = false
  end
  slime:step(dt, self.grid)
end

function play:draw(alpha)
  local g = love.graphics
  g.setColor(0.20, 0.22, 0.30, 1)
  for ty = 1, self.grid.height do
    for tx = 1, self.grid.width do
      local kind = self.grid:kind(tx, ty)
      if kind == "solid" then
        g.rectangle("fill", (tx - 1) * TS, (ty - 1) * TS, TS, TS)
      elseif kind == "one_way" then
        g.rectangle("fill", (tx - 1) * TS, (ty - 1) * TS, TS, 3)
      end
    end
  end
  g.setColor(1, 1, 1, 1)

  -- the slime: its outline between the last two steps, in the grid's own coordinates
  local slime, px = self.slime, self.pixels
  local cx, cy = slime:center()
  local ox, oy = math.floor(cx) - SIZE / 2, math.floor(cy) - SIZE / 2
  px:clear()
  px:polygon(slime:outline(self.points, ox, oy, 1, alpha), 1)
  px:outline(2)
  -- a face that looks where it moves: at the top of the body, offset towards the facing side
  local x0, y0, x1 = slime:bounds()
  local ex = math.floor((x0 + x1) / 2 - ox) + 1 + self.facing * 2
  local ey = math.floor(y0 - oy) + 5
  local look = self.facing > 0 and 1 or 0
  for dx = -3, 2, 5 do                       -- two eyes, 2 x 2 each, the pupil low on the facing side
    px:set(ex + dx, ey, 3); px:set(ex + dx + 1, ey, 3)
    px:set(ex + dx, ey + 1, 3); px:set(ex + dx + 1, ey + 1, 3)
    px:set(ex + dx + look, ey + 1, 4)
  end
  px:set(math.floor(x0 - ox) + 4, ey + 3, 5)               -- a shine on the far side
  px:draw(ox, oy)
  self.tuner:draw(4, 4)
end

return play
