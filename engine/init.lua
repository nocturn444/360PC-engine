-- 360PC-Engine: the generic engine layer. A game does
--     local engine = require("engine")
--     engine.run({ ... })
-- in main.lua. Reference: docs/ENGINE.md. Nothing here knows about a game or a genre.
local prefix = (...):gsub("%.init$", "") .. "."

local engine = {
  _VERSION = "0.1.0",
  state = require(prefix .. "state"),
  timestep = require(prefix .. "timestep"),
  input = require(prefix .. "input"),
  camera = require(prefix .. "camera"),
  pixel = require(prefix .. "pixel"),
  layers = require(prefix .. "layers"),
  -- set by init():
  config = nil,
  time = nil,      -- the Timestep
  states = nil,    -- the state Machine
  controls = nil,  -- the Input, if config.input was given
  screen = nil,    -- the Pixel, if config.pixel was given
}

-- engine.anim needs lib/anim8: loaded on first use, so a game without animations can leave it out
setmetatable(engine, { __index = function(t, k)
  if k == "anim" then
    local anim = require(prefix .. "anim")
    rawset(t, "anim", anim)
    return anim
  end
end })

-- Builds the engine's objects from the config (call it from love.load, or let run() do it):
--   rate, max_steps, max_frame   the fixed timestep (60 Hz, 5 steps a frame, 0.25 s)
--   input                        engine.input's config (actions and axes)
--   pixel                        engine.pixel's config (width, height...)
--   states                       { name = state table }
--   load                         function(engine): create the game's things; runs before `start` is entered
--   start                        the name (or table) of the first state
function engine.init(config)
  config = config or {}
  engine.config = config
  engine.time = engine.timestep.new({ rate = config.rate, max_steps = config.max_steps,
    max_frame = config.max_frame })
  engine.states = engine.state.new()
  engine.controls = config.input and engine.input.new(config.input) or nil
  engine.screen = config.pixel and engine.pixel.new(config.pixel) or nil
  for name, st in pairs(config.states or {}) do engine.states:add(name, st) end
  if config.load then config.load(engine) end
  if config.start then engine.states:push(config.start) end
  return engine
end

-- One frame of logic: reads the input, then runs the fixed steps the frame time asks for.
function engine.update(frame_dt)
  local time, states, controls = engine.time, engine.states, engine.controls
  if controls then controls:poll() end
  local steps = time:advance(frame_dt)
  local dt = time.dt
  for _ = 1, steps do
    if controls then
      controls:step()
      states:input(controls)
    end
    states:update(dt)
  end
  return steps
end

-- One frame of drawing: the states' draw(alpha) in game pixels, then their draw_screen(alpha)
-- in screen pixels (for what should not be scaled: debug text, a high-resolution overlay).
function engine.draw()
  local states, screen, alpha = engine.states, engine.screen, engine.time.alpha
  if screen then screen:start() end
  states:draw(alpha)
  if screen then screen:finish() end
  states:draw(alpha, "draw_screen")
end

-- Sets the love callbacks: load, update, draw, resize, and the input events. Callbacks the
-- game already defined are kept and run first. The other events also reach the top state as
-- hooks of the same name (keypressed, gamepadpressed...). love.run is left alone.
function engine.run(config)
  local function chain(name, fn)
    local old = rawget(love, name)
    love[name] = old and function(...) old(...); return fn(...) end or fn
  end
  chain("load", function() engine.init(config) end)
  chain("update", engine.update)
  chain("draw", engine.draw)
  chain("resize", function(w, h)
    if engine.screen then engine.screen:resize(w, h) end
    engine.states:emit("resize", w, h)
  end)
  for _, name in ipairs({ "joystickadded", "joystickremoved" }) do
    chain(name, function(joystick)
      if engine.controls then engine.controls:refreshJoysticks() end
      engine.states:emit(name, joystick)
    end)
  end
  for _, name in ipairs({ "keypressed", "mousepressed", "gamepadpressed", "gamepadaxis" }) do
    chain(name, function(a, b, c, d)
      local controls = engine.controls
      if controls then
        local taken
        if name == "mousepressed" then taken = controls:mousepressed(c)
        else taken = controls[name](controls, a, b, c) end
        if taken then return end   -- it went to input:capture
      end
      engine.states:emit(name, a, b, c, d)
    end)
  end
  for _, name in ipairs({ "keyreleased", "mousereleased", "gamepadreleased", "textinput", "focus", "quit" }) do
    chain(name, function(...) return engine.states:emit(name, ...) end)
  end
  return engine
end

return engine
