-- engine.init / update / draw / run: the frame loop that ties the modules together.
local T = ...
local F = require("fake_love")
F.install({ width = 1280, height = 720 })
local globals = {}
for k in pairs(_G) do globals[k] = true end
local engine = require("engine")

local log = {}
local st = {
  enter = function() log[#log + 1] = "enter" end,
  input = function(self, input) log[#log + 1] = "input" .. (input:pressed("go") and "!" or "") end,
  update = function(self, dt) log[#log + 1] = "update" end,
  draw = function(self, alpha) log[#log + 1] = "draw"; love.graphics.rectangle("fill", 1, 2, 3, 4) end,
  draw_screen = function(self, alpha) log[#log + 1] = "screen"; love.graphics.rectangle("line", 5, 6, 7, 8) end,
  keypressed = function(self, key) log[#log + 1] = "key " .. key end,
  resize = function(self, w, h) log[#log + 1] = "resize " .. w end,
}
local function took() local s = table.concat(log, " "); log = {}; return s end

local own_update = 0
function love.update(dt) own_update = own_update + 1 end
T.check(engine.run({
  rate = 60, max_steps = 3,
  pixel = { width = 320, height = 180, mode = "direct" },
  input = { actions = { go = { keys = { "space" } } } },
  states = { main = st },
  load = function(e) log[#log + 1] = "load" .. (e == engine and e.screen and e.controls and e.states:depth() == 0 and "" or "?") end,
  start = "main",
}) == engine, "run returns the engine")
T.check(engine.time == nil and took() == "", "nothing is created before love.load")
love.load()
T.check(took() == "load enter" and engine.states:top() == st, "love.load: the game's load, then the first state")
T.check(engine.time.rate == 60 and engine.screen.scale == 4, "the config reached the modules")

F.keys.space = true
love.update(1 / 30)
T.check(took() == "input! update input update" and own_update == 1, "a 30 FPS frame: two steps, pressed in the first; the game's own love.update still runs")
love.update(0.001)
T.check(took() == "", "a frame shorter than a step runs none")
love.update(5)
T.check(took() == "input update input update input update", "a long frame runs max_steps")

F.reset_calls()
love.draw()
local rects = F.find("rectangle")
T.check(took() == "draw screen", "draw, then draw_screen")
T.check(rects[2][2] == "fill" and rects[2].sx == 4 and rects[#rects][2] == "line" and rects[#rects].sx == 1,
  "draw is in game pixels, draw_screen in screen pixels")

love.keypressed("q")
love.resize(640, 360)
T.check(took() == "key q resize 640" and engine.screen.scale == 2, "events reach the top state; resize refits the screen")
local got
engine.controls:capture(function(kind, value) got = kind .. "=" .. value end)
love.keypressed("w")
T.check(got == "keys=w" and took() == "", "a captured key does not reach the state")
local pad = F.add_pad()
love.joystickadded(pad)
T.check(#engine.controls.joysticks == 1, "joystickadded refreshes the gamepads")
T.check(rawget(love, "run") == nil, "love.run is left alone")
T.no_new_globals(globals)

-- without input or pixel: still a loop
engine.init({ states = { a = { update = function() log[#log + 1] = "u" end, draw = function() log[#log + 1] = "d" end } }, start = "a" })
engine.update(1 / 60); engine.draw()
T.check(took() == "u d" and engine.controls == nil and engine.screen == nil, "input and pixel are optional")
