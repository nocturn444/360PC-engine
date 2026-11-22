-- engine.autopause: the optional pause state pushed when the controller in use is removed or the
-- window loses the focus. Every case gets a fresh engine (and so fresh love callbacks).
local T = ...
local F = require("fake_love")

local function fresh(config)
  local stale = {}
  for name in pairs(package.loaded) do
    if name == "engine" or name:match("^engine%.") then stale[#stale + 1] = name end
  end
  for i = 1, #stale do package.loaded[stale[i]] = nil end
  F.install({ width = 1280, height = 720 })
  local engine = require("engine")
  engine.run(config)
  love.load()
  return engine
end

local function remove(pad)
  for i = #F.pads, 1, -1 do
    if F.pads[i] == pad then table.remove(F.pads, i) end
  end
  love.joystickremoved(pad)
end

local INPUT = { actions = { jump = { buttons = { "a" } } } }

-- Without autopause: removing the pad in use changes nothing.
do
  local enters = 0
  local play = {}
  local pause = { enter = function() enters = enters + 1 end }
  local engine = fresh({ input = INPUT, states = { play = play, pause = pause }, start = "play" })
  local pad = F.add_pad()
  love.joystickadded(pad)
  love.gamepadpressed(pad, "a")
  T.check(engine.controls.joystick == pad, "the pad in use is remembered")
  remove(pad)
  T.check(engine.states:top() == play and enters == 0, "without autopause nothing is pushed")
end

-- The pad in use leaves: the pause state is pushed with reason "controller" and the joystick,
-- and gets controllerlost after the push. A second removal does not push it again.
do
  local got = {}
  local play = {}
  local pause = {
    enter = function(self, previous, reason, joystick)
      got.previous, got.reason, got.joystick = previous, reason, joystick
    end,
    controllerlost = function(self, joystick) got.lost = joystick end,
  }
  local engine = fresh({ input = INPUT, states = { play = play, pause = pause }, start = "play",
    autopause = { state = "pause" } })
  local pad = F.add_pad()
  love.joystickadded(pad)
  love.gamepadpressed(pad, "a")
  remove(pad)
  T.check(engine.states:top() == pause, "removing the pad in use pushes the pause state")
  T.check(got.previous == play and got.reason == "controller" and got.joystick == pad,
    "enter gets the play state, the reason and the joystick")
  T.check(got.lost == pad, "controllerlost reaches the pause state")
  local depth = engine.states:depth()
  love.joystickremoved(pad)
  T.check(engine.states:depth() == depth, "it does not push twice")
end

-- Another pad leaving while the one in use stays changes nothing; when the one in use leaves, it does.
do
  local enters = 0
  local play = {}
  local pause = { enter = function() enters = enters + 1 end }
  local engine = fresh({ input = INPUT, states = { play = play, pause = pause }, start = "play",
    autopause = { state = "pause" } })
  local pad, other = F.add_pad(), F.add_pad()
  love.joystickadded(pad); love.joystickadded(other)
  love.gamepadpressed(pad, "a")
  remove(other)
  T.check(engine.states:top() == play and enters == 0, "another pad leaving is ignored")
  remove(pad)
  T.check(engine.states:top() == pause and enters == 1, "the pad in use leaving pauses")
end

-- A state can opt out with autopause = false.
do
  local enters = 0
  local play = { autopause = false }
  local pause = { enter = function() enters = enters + 1 end }
  local engine = fresh({ input = INPUT, states = { play = play, pause = pause }, start = "play",
    autopause = { state = "pause" } })
  local pad = F.add_pad()
  love.joystickadded(pad)
  love.gamepadpressed(pad, "a")
  remove(pad)
  T.check(engine.states:top() == play and enters == 0, "autopause = false opts out")
end

-- Losing the focus pushes it with reason "focus"; focus = false turns that off.
do
  local got
  local play = {}
  local pause = { enter = function(self, previous, reason) got = reason end }
  local engine = fresh({ input = INPUT, states = { play = play, pause = pause }, start = "play",
    autopause = { state = "pause" } })
  love.focus(false)
  T.check(engine.states:top() == pause and got == "focus", "losing the focus pauses the game")
end

do
  local enters = 0
  local play = {}
  local pause = { enter = function() enters = enters + 1 end }
  local engine = fresh({ input = INPUT, states = { play = play, pause = pause }, start = "play",
    autopause = { state = "pause", focus = false } })
  love.focus(false)
  T.check(engine.states:top() == play and enters == 0, "focus = false opts out")
end

-- controller = false turns off the controller half only.
do
  local enters = 0
  local play = {}
  local pause = { enter = function() enters = enters + 1 end }
  local engine = fresh({ input = INPUT, states = { play = play, pause = pause }, start = "play",
    autopause = { state = "pause", controller = false } })
  local pad = F.add_pad()
  love.joystickadded(pad)
  love.gamepadpressed(pad, "a")
  remove(pad)
  T.check(engine.states:top() == play and enters == 0, "controller = false opts out")
end

-- engine.autopause can be called by the game, and returns whether it pushed.
do
  local play = {}
  local pause = {}
  local engine = fresh({ input = INPUT, states = { play = play, pause = pause }, start = "play",
    autopause = { state = "pause" } })
  T.check(engine.autopause("script") == true and engine.states:top() == pause,
    "engine.autopause pushes the configured state")
  T.check(engine.autopause("script") == false, "and refuses when it is already on top")
end
