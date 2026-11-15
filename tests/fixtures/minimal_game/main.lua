-- Minimal game for the runtime checks: a moving rectangle, a log line now and then, a counter
-- kept in the save folder, a shader (shaders/tint.glsl, declared in game.lua), and the pad's A
-- button. Runs the same on LÖVE 11.x.
local x, frames, runs = 0, 0, 0
local tint

function love.load()
  runs = (tonumber((love.filesystem.read("runs.txt"))) or 0) + 1
  love.filesystem.write("runs.txt", tostring(runs))
  tint = love.graphics.newShader("shaders/tint.glsl")
  tint:send("tint", { 0.4, 0.7, 1.0, 1.0 })
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
end

function love.gamepadpressed(joystick, button)
  print("minimal_game: gamepadpressed " .. button)
  if button == "start" then love.event.quit() end
end
