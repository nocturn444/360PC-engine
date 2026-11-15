-- examples/engine_demo on the fake love: menu -> play -> pause, moving through the rooms.
-- (tests/pc/boot_pc.lua examples/engine_demo runs the same game on the console's boot.)
local T = ...
local F = require("fake_love")
F.install({ width = 1280, height = 720, image_w = 32, image_h = 16 })
for _, m in ipairs({ "engine", "engine.init", "engine.anim" }) do package.loaded[m] = nil end
local printed = {}
local real_print = print
print = function(s) printed[#printed + 1] = tostring(s) end
local ok, err = pcall(function()
  assert(loadfile("examples/engine_demo/main.lua"))()
  love.load()
end)
print = real_print
T.check(ok, "the demo loads: " .. tostring(err))
T.check(printed[1] == "engine_demo: loaded, canvas mode, x4", "it reports its screen: " .. tostring(printed[1]))
local engine = require("engine")
local states = engine.states
local function frames(n) for _ = 1, n do love.update(1 / 60); love.draw() end end
local function tap(key) F.keys[key] = true; frames(1); F.keys[key] = nil; frames(1) end

frames(2)
T.check(states:top() == states:get("menu"), "starts in the menu")
tap("return")
T.check(states:top() == states:get("play"), "confirm starts the game")
tap("p")
T.check(states:depth() == 2 and states:top() == states:get("pause"), "pause is pushed over play")
F.reset_calls(); love.draw()
T.check(#F.find("draw") >= 2, "the paused game is still drawn under the pause screen")
local tick = engine.time.tick
F.keys.right = true; frames(10); F.keys.right = nil
T.check(engine.time.tick == tick + 10, "the steps go on while paused")
tap("p")
T.check(states:depth() == 1, "and popped")

-- walk right with the stick into the second room
local pad = F.add_pad()
love.joystickadded(pad)
pad.axes.leftx = 1
frames(60 * 5)
F.reset_calls(); love.draw()
local texts = F.find("print")
T.check(texts[#texts][2] == "room 2", "the stick walked the sprite into the second room: " .. tostring(texts[#texts][2]))
T.check(engine.controls:getDevice() == "gamepad", "the controller is the device in use")
pad.axes.leftx = 0
pad.buttons.x = true; frames(1); pad.buttons.x = nil; frames(1)
F.reset_calls(); love.draw()
T.check(#F.find("draw") == 3, "the action shows the second layer (two sprite layers and the canvas)")
texts = F.find("print")
T.check(texts[#texts - 1][2] == "speed 187.5", "an entity with two modifiers: (90 + 60) * 1.25: " .. tostring(texts[#texts - 1][2]))
frames(121)
F.reset_calls(); love.draw()
texts = F.find("print")
T.check(texts[#texts - 1][2] == "speed 112.5", "and one again when the dash runs out: " .. tostring(texts[#texts - 1][2]))

-- pick 1 of 3 (engine.ui): C opens it over the game, right and accept take the second card
tap("c")
T.check(states:depth() == 2 and states:top().cards and #states:top().cards == 3, "the pick screen is pushed over play")
tap("right"); tap("return")
T.check(states:depth() == 1, "choosing closes it")
F.reset_calls(); love.draw()
texts = F.find("print")
T.check(texts[#texts - 1][2] == "speed 75", "and adds the chosen modifier: (90 - 30) * 1.25: " .. tostring(texts[#texts - 1][2]))
tap("c"); tap("escape")
T.check(states:depth() == 1, "back cancels it")
