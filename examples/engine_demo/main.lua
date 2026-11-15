-- Engine demo: the smallest game that uses every module of engine/ (docs/ENGINE.md).
-- A menu, a play state and a pause state; a sprite made of layers that moves with actions
-- (keyboard or controller) through two rooms, with a camera that follows it, slides from room
-- to room and shakes; all drawn at 320x180 and scaled to the screen.
-- Needs engine/ and lib/ next to this file (copies or links of the repository's folders).
local engine = require("engine")

local W, H = 320, 180
local ROOMS = {                      -- x, y, w, h and a colour
  { 0, 0, 480, 270, { 0.16, 0.20, 0.30 } },
  { 480, 0, 400, 180, { 0.30, 0.18, 0.16 } },
}
local SPEED = 90                     -- pixels per second

local camera, sprite, anims, tiles
local player = { x = 100, y = 100, px = 100, py = 100, room = 1, facing = 1 }

local function room_at(x)
  return x < ROOMS[2][1] and 1 or 2
end

local menu, play, pause = {}, {}, { transparent = true }

function menu:input(input)
  if input:pressed("confirm") then engine.states:switch("play") end
end

function menu:draw()
  love.graphics.print("ENGINE DEMO", 120, 60)
  love.graphics.print(engine.controls:getDevice() == "gamepad" and "press A" or "press Enter", 124, 90)
end

function play:enter()
  local r = ROOMS[player.room]
  camera:setBounds(r[1], r[2], r[3], r[4])
  camera:setPosition(player.x, player.y)
end

function play:input(input)
  if input:pressed("pause") then engine.states:push("pause") end
  if input:pressed("action") then
    sprite:setVisible("held", not sprite:get("held").visible)
    camera:shake(3, 0.25)
  end
end

function play:update(dt)
  local input = engine.controls
  player.px, player.py = player.x, player.y
  local mx, my = input:axis("move_x"), input:axis("move_y")
  if mx ~= 0 then player.facing = mx < 0 and -1 or 1 end
  local r = ROOMS[player.room]
  player.x = math.max(8, math.min(ROOMS[2][1] + ROOMS[2][3] - 8, player.x + mx * SPEED * dt))
  player.y = math.max(r[2] + 16, math.min(r[2] + r[4], player.y + my * SPEED * dt))
  local now = room_at(player.x)
  if now ~= player.room then
    player.room = now
    r = ROOMS[now]
    player.y = math.max(r[2] + 16, math.min(r[2] + r[4], player.y))
    camera:transition(r[1], r[2], r[3], r[4], { mode = "slide", duration = 0.5 })
  end
  sprite:update(dt)
  camera:follow(player.x, player.y - 8)
  camera:update(dt)
end

function play:draw(alpha)
  local g = love.graphics
  camera:attach(alpha)
  local vx, vy, vw, vh = camera:getViewport(alpha)
  for _, r in ipairs(ROOMS) do
    g.setColor(r[5][1], r[5][2], r[5][3], 1)
    g.rectangle("fill", r[1], r[2], r[3], r[4])
    g.setColor(1, 1, 1, 0.15)
    for x = r[1], r[1] + r[3] - 32, 32 do
      -- only the columns in view
      if x + 16 > vx and x < vx + vw then
        for y = r[2], r[2] + r[4] - 32, 32 do g.rectangle("fill", x, y, 16, 16) end
      end
    end
  end
  g.setColor(1, 1, 1, 1)
  local x = player.px + (player.x - player.px) * alpha
  local y = player.py + (player.y - player.py) * alpha
  sprite:draw(math.floor(x + 0.5), math.floor(y + 0.5), 0, player.facing, 1, 8, 16)
  camera:detach()
  camera:drawFade(0, 0, 0)
  g.print("room " .. player.room, 4, 4)
end

function pause:input(input)
  if input:pressed("pause") or input:pressed("confirm") then engine.states:pop() end
  if input:pressed("back") then love.event.quit() end
end

function pause:draw()
  local g = love.graphics
  g.setColor(0, 0, 0, 0.6)
  g.rectangle("fill", 0, 0, W, H)
  g.setColor(1, 1, 1, 1)
  g.print("PAUSED", 136, 80)
end

engine.run({
  rate = 60,
  pixel = { width = W, height = H },
  input = {
    deadzone = 0.25,
    actions = {
      confirm = { keys = { "return", "space" }, buttons = { "a" } },
      back = { keys = { "escape" }, buttons = { "b" } },
      pause = { keys = { "p" }, buttons = { "start" } },
      action = { keys = { "x" }, mouse = { 1 }, buttons = { "x" }, axes = { "triggerright+" } },
      left = { keys = { "left", "a" }, buttons = { "dpleft" } },
      right = { keys = { "right", "d" }, buttons = { "dpright" } },
      up = { keys = { "up", "w" }, buttons = { "dpup" } },
      down = { keys = { "down", "s" }, buttons = { "dpdown" } },
    },
    axes = {
      move_x = { negative = "left", positive = "right", stick = "leftx" },
      move_y = { negative = "up", positive = "down", stick = "lefty" },
    },
  },
  states = { menu = menu, play = play, pause = pause },
  start = "menu",
  load = function()
    tiles = love.graphics.newImage("tiles.png")          -- two 16x16 tiles
    local grid = engine.anim.grid(tiles, 16, 16)
    anims = engine.anim.set(grid, { blink = { frames = { "1-2", 1 }, duration = 0.4 } })
    camera = engine.camera.new({ width = W, height = H, lerp = 10, deadzone_w = 32, deadzone_h = 16, snap = true })
    sprite = engine.layers.new({ "body", "held", "effect" })
    sprite:set("body", { image = tiles, anim = anims.blink })
    sprite:set("held", { image = tiles, quad = grid(2, 1)[1], ox = 10, oy = 4, tint = { 1, 0.6, 0.2, 1 }, visible = false })
    print("engine_demo: loaded, " .. engine.screen.mode .. " mode, x" .. engine.screen.scale)
  end,
})
