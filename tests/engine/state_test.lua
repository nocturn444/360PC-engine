local T = ...
local State = require("engine.state")
local log = {}
local function mk(name, extra)
  local s = extra or {}
  s.name = name
  for _, hook in ipairs({ "enter", "exit", "pause", "resume" }) do
    s[hook] = function(self, other, ...)
      log[#log + 1] = name .. "." .. hook .. "(" .. tostring(other and other.name) .. (... and "," .. tostring(...) or "") .. ")"
    end
  end
  s.update = function(self, dt) log[#log + 1] = name .. ".update" end
  s.draw = function(self, alpha) log[#log + 1] = name .. ".draw" end
  s.input = function(self, input) log[#log + 1] = name .. ".input" end
  return s
end
local function took() local s = table.concat(log, " "); log = {}; return s end

local sm = State.new()
local menu, play, pause = mk("menu"), mk("play"), mk("pause", { transparent = true })
sm:add("menu", menu); sm:add("play", play); sm:add("pause", pause)
T.check(sm:top() == nil and sm:depth() == 0, "empty at first")
sm:update(1); sm:draw(0); sm:input({}); sm:emit("anything")
T.check(took() == "" and sm:pop() == nil, "an empty machine does nothing")

sm:push("menu", "hello")
T.check(took() == "menu.enter(nil,hello)", "push enters with the arguments")
sm:switch("play")
T.check(took() == "menu.exit(play) play.enter(menu)" and sm:depth() == 1, "switch replaces the top")
sm:push(pause)
T.check(took() == "play.pause(pause) pause.enter(play)" and sm:depth() == 2, "push pauses the one below")
sm:input({}); sm:update(1 / 60)
T.check(took() == "pause.input pause.update", "only the top state gets input and update")
sm:draw(0.5)
T.check(took() == "play.draw pause.draw", "a transparent state lets the one below draw first")
pause.transparent = false
sm:draw(0.5)
T.check(took() == "pause.draw", "an opaque state hides the ones below")
T.check(sm:pop("result") == pause and sm:top() == play, "pop returns the old top")
T.check(took() == "pause.exit(play) play.resume(pause,result)", "pop resumes the one below with the arguments")

play.keypressed = function(self, key) return "got " .. key end
T.check(sm:emit("keypressed", "x") == "got x" and sm:emit("nothing") == nil, "emit reaches the top state's hook")

sm:push(pause); took()
sm:reset("menu")
T.check(took() == "pause.exit(nil) play.exit(nil) menu.enter(nil)" and sm:depth() == 1, "reset empties and enters")
T.check(not pcall(sm.push, sm, "nope"), "an unknown state name is an error")

-- a state that pops itself during update and draw
local once = { update = function(self) sm:pop() end, draw = function(self) sm:pop() end, transparent = true }
sm:push(once); sm:update(0)
T.check(sm:top() == menu, "a state can pop itself in update")
sm:push(once); took(); sm:draw(0)
T.check(sm:top() == menu, "a state can pop itself in draw")
