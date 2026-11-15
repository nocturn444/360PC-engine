local T = ...
local F = require("fake_love")
F.install()
local Input = require("engine.input")
local pad = F.add_pad()

local input = Input.new({
  deadzone = 0.25, threshold = 0.5,
  actions = {
    jump = { keys = { "space", "z" }, buttons = { "a" } },
    fire = { mouse = { 1 }, axes = { "triggerright+" } },
    left = { keys = { "left" }, buttons = { "dpleft" } },
    right = { keys = { "right" }, buttons = { "dpright" } },
    up = { axes = { { axis = "lefty", dir = -1, threshold = 0.8 } } },
  },
  axes = { move_x = { negative = "left", positive = "right", stick = "leftx" } },
})
local function frame(steps)
  input:poll()
  for _ = 1, steps or 1 do input:step() end
end

frame()
T.check(not input:down("jump") and not input:pressed("jump") and input:axis("move_x") == 0, "nothing held")

-- edges: pressed for exactly one step, also when a frame runs several steps
F.keys.space = true
input:poll(); input:step()
T.check(input:pressed("jump") and input:down("jump") and not input:released("jump"), "pressed on the first step")
input:step()
T.check(not input:pressed("jump") and input:down("jump"), "not pressed on the second step of the same frame")
frame(2)
T.check(input:down("jump") and not input:pressed("jump"), "held")
F.keys.space = nil
frame()
T.check(input:released("jump") and not input:down("jump"), "released")
frame()
T.check(not input:released("jump"), "released lasts one step")

-- a tap between two steps is not lost: frames with no step in between
F.keys.z = true; input:poll()
F.keys.z = nil; input:poll()
input:step()
T.check(input:pressed("jump") and input:down("jump"), "a tap shorter than a step is seen")
input:step()
T.check(input:released("jump") and not input:down("jump"), "and released on the next step")

-- gamepad button and device tracking
T.check(input:getDevice() == "keyboard", "the keyboard was used last")
pad.buttons.a = true; frame()
local device, joy = input:getDevice()
T.check(input:pressed("jump") and device == "gamepad" and joy == pad, "gamepad button; the device follows")
pad.buttons.a = nil; frame()
F.mouse_buttons[1] = true; frame()
T.check(input:pressed("fire") and input:getDevice() == "keyboard", "mouse button; the device is the keyboard again")
F.mouse_buttons[1] = nil; frame()

-- axes as buttons, with thresholds
pad.axes.triggerright = 0.49; frame()
T.check(not input:down("fire"), "under the threshold")
pad.axes.triggerright = 0.5; frame()
T.check(input:pressed("fire"), "at the threshold")
pad.axes.triggerright = 0; frame()
pad.axes.lefty = -0.7; frame()
T.check(not input:down("up"), "a binding's own threshold")
pad.axes.lefty = -0.9; frame()
T.check(input:down("up"), "a binding's own threshold, passed")
pad.axes.lefty = 0.9; frame()
T.check(not input:down("up"), "the other direction does not count")
pad.axes.lefty = 0; frame()

-- axis actions: deadzone, rescaling, digital keys
pad.axes.leftx = 0.2; frame()
T.check(input:axis("move_x") == 0, "inside the deadzone")
pad.axes.leftx = -0.25; frame()
T.check(input:axis("move_x") == 0, "at the edge of the deadzone")
pad.axes.leftx = 0.625; frame()
T.near(input:axis("move_x"), 0.5, "rescaled from the edge of the deadzone")
pad.axes.leftx = -1; frame()
T.near(input:axis("move_x"), -1, "full tilt")
F.keys.right = true; frame()
T.check(input:axis("move_x") == 1, "a digital direction wins over the stick")
F.keys.left = true; frame()
T.near(input:axis("move_x"), -1, "both directions cancel out: the stick is used")
pad.axes.leftx = 0; F.keys.left = nil; F.keys.right = nil; frame()
pad.buttons.dpleft = true; frame()
T.check(input:axis("move_x") == -1 and input:axis("left") == 1 and input:axis("right") == 0, "d-pad; a plain action as an axis")
pad.buttons.dpleft = nil; frame()

-- rebinding
input:bind("jump", "keys", "up")
input:unbind("jump", "keys", "space")
F.keys.space = true; frame()
T.check(not input:down("jump"), "unbound key")
F.keys.space = nil; F.keys.up = true; frame()
T.check(input:pressed("jump"), "newly bound key")
F.keys.up = nil; frame()
local b = input:getBindings("jump")
T.check(#b.keys == 2 and b.keys[1] == "z" and b.keys[2] == "up" and b.buttons[1] == "a", "getBindings")
input:bind("jump", "axes", "triggerleft+")
input:bind("jump", "axes", "triggerleft+")
T.check(#input:getBindings("jump").axes == 1, "binding twice does not duplicate")
local saved = input:export()
T.check(saved.actions.fire.axes[1] == "triggerright+" and saved.actions.up.axes[1].threshold == 0.8, "export")
input:unbind("jump", "keys")
T.check(#input:getBindings("jump").keys == 0, "unbind every key")
input:load(saved)
T.check(#input:getBindings("jump").keys == 2, "load restores exported bindings")
T.check(not pcall(input.down, input, "nope") and not pcall(input.bind, input, "jump", "wheels", 1), "unknown action or kind is an error")

-- capture: the next event goes to the function, once
local got
input:capture(function(kind, value) got = kind .. "=" .. tostring(value) end)
T.check(input:gamepadaxis(pad, "leftx", 0.1) == false and got == nil, "a small axis move is not captured")
T.check(input:gamepadaxis(pad, "leftx", -0.9) == true and got == "axes=leftx-", "captured an axis")
T.check(input:keypressed("q") == false, "capture is one shot")
input:capture(function(kind, value) got = kind .. "=" .. tostring(value) end)
T.check(input:keypressed("q") and got == "keys=q", "captured a key")

-- controllers coming and going, and one gamepad per input
local pad2 = F.add_pad()
input:refreshJoysticks()
pad2.buttons.a = true; frame()
T.check(input:pressed("jump") and select(2, input:getDevice()) == pad2, "a second gamepad is read too")
pad2.buttons.a = nil; frame()
local only2 = Input.new({ joystick = 2, actions = { jump = { buttons = { "a" } } } })
pad.buttons.a = true; only2:poll(); only2:step()
T.check(not only2:down("jump"), "joystick = 2 ignores the first gamepad")
pad2.buttons.a = true; only2:poll(); only2:step()
T.check(only2:down("jump"), "joystick = 2 reads the second")
pad.buttons.a = nil; pad2.buttons.a = nil
table.remove(F.pads, 2)
input:refreshJoysticks()
T.check(select(2, input:getDevice()) == nil and #input.joysticks == 1, "a removed gamepad is forgotten")

-- flush: what is held does not count as pressed again
F.keys.z = true; input:poll(); input:flush(); input:step()
T.check(input:down("jump") and not input:pressed("jump"), "flush")
F.keys.z = nil

-- poll and step allocate nothing
frame()
collectgarbage(); collectgarbage("stop")
local before = collectgarbage("count")
for _ = 1, 200 do input:poll(); input:step(); input:step() end
local grown = collectgarbage("count") - before
collectgarbage("restart")
T.check(grown == 0, "poll and step allocate nothing (" .. grown .. " KB)")
