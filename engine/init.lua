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
  pixelgrid = require(prefix .. "pixelgrid"),
  layers = require(prefix .. "layers"),
  entity = require(prefix .. "entity"),
  modifiers = require(prefix .. "modifiers"),
  rng = require(prefix .. "rng"),
  save = require(prefix .. "save"),
  level = require(prefix .. "level"),
  ui = require(prefix .. "ui"),
  text = require(prefix .. "text"),
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
  if k == "tune" then         -- engine.tune: loaded on first use (development builds)
    local tune = require(prefix .. "tune")
    rawset(t, "tune", tune)
    return tune
  end
  if k == "debug" then        -- engine.debug: loaded on first use (development builds)
    local dbg = require(prefix .. "debug")
    rawset(t, "debug", dbg)
    return dbg
  end
end })

-- Builds the engine's objects from the config (call it from love.load, or let run() do it):
--   rate, max_steps, max_frame   the fixed timestep (60 Hz, 5 steps a frame, 0.25 s)
--   input                        engine.input's config (actions and axes)
--   pixel                        engine.pixel's config (width, height...)
--   states                       { name = state table }
--   load                         function(engine): create the game's things; runs before `start` is entered
--   start                        the name (or table) of the first state
-- engine.requires("0.2") or ("0.2.1"): stops with a clear error when this base is older than the
-- version a game was written for, or has another major version (docs/VERSIONING.md). Returns
-- the engine. Under 1.0.0 the minor version counts as the major one (0.2 cannot run a 0.3 game).
local function parse_version(v)
  local a, b, c = tostring(v):match("^(%d+)%.?(%d*)%.?(%d*)$")
  if not a then error("engine.requires: a version is \"major.minor.patch\", got " .. tostring(v), 3) end
  return tonumber(a), tonumber(b) or 0, tonumber(c) or 0
end
function engine.requires(wanted)
  local ma, mi, pa = parse_version(engine._VERSION)
  local wa, wi, wp = parse_version(wanted)
  local same_line = ma == wa and (ma > 0 or mi == wi)
  local new_enough = mi > wi or (mi == wi and pa >= wp)
  if not (same_line and new_enough) then
    error(string.format("this game needs 360PC-Engine %s; the base here is %s (docs/VERSIONING.md)",
      tostring(wanted), engine._VERSION), 2)
  end
  return engine
end

function engine.init(config)
  config = config or {}
  engine.config = config
  engine.time = engine.timestep.new({ rate = config.rate, max_steps = config.max_steps,
    max_frame = config.max_frame })
  engine.states = engine.state.new()
  engine.controls = config.input and engine.input.new(config.input) or nil
  engine.screen = config.pixel and engine.pixel.new(config.pixel) or nil
  engine.ui.pixel = engine.screen          -- the menus' size, and their mouse coordinates
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
