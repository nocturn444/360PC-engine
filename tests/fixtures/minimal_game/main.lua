-- Minimal game for the runtime checks: a moving rectangle, a log line now and then, a counter
-- kept in the save folder, a shader (shaders/tint.glsl, declared in game.lua), a tile map in a
-- SpriteBatch (tiles.png: two 16x16 tiles), text, lines and circles, and the pad's A button.
-- Runs the same on LÖVE 11.x.
local x, frames, runs = 0, 0, 0
local tint, map
local MAP_W, MAP_H = 40, 4

function love.load()
  runs = (tonumber((love.filesystem.read("runs.txt"))) or 0) + 1
  love.filesystem.write("runs.txt", tostring(runs))
  tint = love.graphics.newShader("shaders/tint.glsl")
  tint:send("tint", { 0.4, 0.7, 1.0, 1.0 })
  local tiles = love.graphics.newImage("tiles.png")
  tiles:setFilter("nearest", "nearest")
  local quads = { love.graphics.newQuad(0, 0, 16, 16, tiles), love.graphics.newQuad(16, 0, 16, 16, tiles) }
  map = love.graphics.newSpriteBatch(tiles, MAP_W * MAP_H)
  for ty = 0, MAP_H - 1 do
    for tx = 0, MAP_W - 1 do
      map:add(quads[(tx + ty) % 2 + 1], tx * 16, ty * 16)
    end
  end
  map:setColor(1, 1, 0.5, 1)
  map:set(1, quads[2], 0, 0)
  print(string.format("minimal_game: love.load, run %d, window %dx%d", runs, love.graphics.getDimensions()))
end

function love.update(dt)
  frames = frames + 1
  x = (x + 200 * dt) % 1280
  if frames % 30 == 0 then print(string.format("minimal_game: frame %d, x = %.0f", frames, x)) end
end

function love.draw()
  love.graphics.setColor(0.9, 0.3, 0.2, 1)
  love.graphics.rectangle("fill", x, 300, 120, 120)
  tint:send("amount", 0.5 + 0.5 * math.sin(frames / 30))
  love.graphics.setShader(tint)
  love.graphics.rectangle("fill", x, 440, 120, 120)
  love.graphics.setShader()

  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(map, 0, 592, 0, 2, 2)
  love.graphics.print("Minimal Game, run " .. runs, 40, 40)
  love.graphics.printf(string.format("frame %d\n%d FPS", frames, love.timer.getFPS()), 0, 80, 1280, "center")
  love.graphics.setLineWidth(3)
  love.graphics.line(40, 200, 240, 200, 240, 260, 40, 260)
  love.graphics.circle("line", x + 60, 240, 30)
  love.graphics.setColor(0.2, 0.6, 0.9, 1)
  love.graphics.circle("fill", x + 60, 240, 20, 16)
  love.graphics.setLineWidth(1)
end

function love.gamepadpressed(joystick, button)
  print("minimal_game: gamepadpressed " .. button)
  if button == "start" then love.event.quit() end
end
