-- engine.tune: fields, steps, limits and rounding, the overlay's input (choose, change, hold to
-- repeat, open and close), save and load through a fake filesystem, the overlay's drawing on
-- the fake love, and the lazy load through engine.tune.
local T = ...
local F = require("fake_love")
F.install()
local globals = {}
for k in pairs(_G) do globals[k] = true end
local tune = require("engine.tune")

-- A stand-in for engine.input: the test sets what is pressed this step and what is held
local function fake_input()
  local inp = { p = {}, d = {} }
  function inp:pressed(a) return self.p[a] == true end
  function inp:down(a) return self.d[a] == true end
  return inp
end
local logs = {}
local function log(text) logs[#logs + 1] = text end

-- Fields
local body = { stiffness = 0.9, gravity = 600, name = "slime" }
local params = { jump = 260 }
local t = tune.new({ log = log })
t:add(body, "stiffness", { min = 0.1, max = 1, step = 0.05 })
 :add(body, "gravity", { min = 100, step = 25 })
 :add(params, "jump", { label = "jump speed", step = 10 })
T.check(#t.fields == 3 and t:get("jump speed") == 260 and t:get("gravity") == 600, "three fields, by label")
T.check(not pcall(t.add, t, body, "name"), "a field must be a number")
T.check(not pcall(t.add, t, params, "jump", { label = "jump speed" }), "two fields with one label")
T.check(not pcall(t.add, t, body, "gravity", { label = "g", step = 0 }), "step > 0")

-- Nudges: steps, limits, rounding
T.check(t:nudge(1) == 0.95 and body.stiffness == 0.95, "one step up")
T.check(t:nudge(1) == 1 and t:nudge(1) == 1, "up to max, and no further")
for _ = 1, 7 do t:nudge(-1) end
T.check(body.stiffness == 0.65, "seven steps down, no float drift (" .. body.stiffness .. ")")
for _ = 1, 40 do t:nudge(-1) end
T.check(body.stiffness == 0.1, "down to min")
T.check(t:set("gravity", 50) == 100 and body.gravity == 100, "set clamps")
T.check(t:set("nothing", 1) == nil and t:set("gravity", "x") == nil, "set ignores unknown labels and non-numbers")
local seen
local t2 = tune.new({ log = log }):add(params, "jump", { on_change = function(v, tgt, key) seen = { v, tgt, key } end })
t2:nudge(1)
T.check(seen and seen[1] == 261 and seen[2] == params and seen[3] == "jump", "on_change gets the value, table and key")
params.jump = 260
t:reset()
T.check(body.stiffness == 0.9 and body.gravity == 600 and params.jump == 260, "reset: the values at add time")

-- Input
local inp = fake_input()
T.check(not t:input(inp) and not t.open, "closed until the toggle")
inp.p.tune = true
T.check(t:input(inp) and t.open, "the toggle opens it")
inp.p = { tune_next = true }; t:input(inp)
T.check(t.selected == 2, "next")
inp.p = { tune_prev = true }; t:input(inp); t:input({ pressed = function() return false end, down = function() return false end })
inp.p = { tune_prev = true }; t:input(inp)
T.check(t.selected == 3, "prev wraps around to the last field")
inp.p = {}; inp.d = { tune_inc = true }
t:input(inp)
T.check(params.jump == 270, "a press of inc: one step at once")
for _ = 1, 17 do t:input(inp) end                 -- 0.3 s held: still one step
T.check(params.jump == 270, "no repeat for 0.3 s")
for _ = 1, 12 do t:input(inp) end                 -- 0.2 s more: two repeats
T.check(params.jump == 290, "then ten steps a second (" .. params.jump .. ")")
inp.d = { tune_dec = true }; t:input(inp)
T.check(params.jump == 280, "dec: one step down at once")
inp.d = {}; inp.p = { tune = true }; t:input(inp)
inp.p = {}; inp.d = { tune_inc = true }; t:input(inp)
T.check(not t.open and params.jump == 280, "closed: no changes")
local custom = tune.new({ actions = { toggle = "debug_tune" }, log = log })
T.check(custom.actions.toggle == "debug_tune" and custom.actions.inc == "tune_inc", "actions can be renamed")

-- Save and load
local files = {}
local fs = {
  write = function(name, text) files[name] = text; return true end,
  read = function(name) return files[name] end,
}
local a = tune.new({ file = "tune_slime.txt", fs = fs, log = log })
local A = { stiffness = 0.75, jump = 300 }
a:add(A, "stiffness", { step = 0.05 }):add(A, "jump", { label = "jump speed" })
T.check(a:save() == true and files["tune_slime.txt"], "save writes the file")
T.check(logs[#logs] == "tune: saved tune_slime.txt" and a.message == "saved tune_slime.txt", "and says so")
local B = { stiffness = 0.9, jump = 260, extra = 1 }
local b = tune.new({ file = "tune_slime.txt", fs = fs, log = log })
b:add(B, "stiffness", { step = 0.05 }):add(B, "jump", { label = "jump speed" }):add(B, "extra")
T.check(b:load() == 2 and B.stiffness == 0.75 and B.jump == 300 and B.extra == 1, "load sets the fields it names, the others stay")
files["tune_slime.txt"] = 'return os.exit()'
T.check(b:load() == false, "a file that is not data: refused")
files["tune_slime.txt"] = require("engine.save").serialize({ ["jump speed"] = 9000, ghost = 1 })
local c = tune.new({ file = "tune_slime.txt", fs = fs, log = log })
local C = { jump = 260 }
c:add(C, "jump", { label = "jump speed", max = 500 })
T.check(c:load() == 1 and C.jump == 500, "loaded values are clamped; unknown names ignored")
local none = tune.new({ file = "missing.txt", fs = fs, log = log })
local okn, why = none:load()
T.check(okn == false and why == "no file", "no file: false, no error")
local broken = tune.new({ fs = { write = function() error("disk full") end }, log = log })
broken:add({ v = 1 }, "v")
local oks, err = broken:save()
T.check(oks == false and tostring(err):find("disk full", 1, true), "a write that fails: false and the reason, nothing raised")
local pressed_save = tune.new({ fs = fs, open = true, log = log }):add({ v = 2 }, "v")
inp.d = {}; inp.p = { tune_save = true }; pressed_save:input(inp)
T.check(files["tune.txt"] ~= nil, "the save action writes the default file")

-- Drawing
local d = tune.new({ open = true, log = log })
d:add({ speed = 90 }, "speed", { step = 5 }):add({ k = 0.5 }, "k", { step = 0.05 })
local lines = d:lines()
T.check(lines[1] == "> speed  90" and lines[2] == "  k  0.50", "lines: marked selection and step decimals")
F.reset_calls(); d:draw(4, 4)
T.check(#F.find("print") == 0 and #F.find("rectangle") > 20, "the overlay: a backing and the lines in engine.text")
local printed = {}
local own = tune.new({ open = true, log = log, print = function(s, x, y) printed[#printed + 1] = s end, line_height = 12 })
own:add({ speed = 90 }, "speed"); own:draw()
T.check(printed[1] == "> speed  90", "or with the game's own print")
d.open = false; d.message = nil
F.reset_calls(); d:draw()
T.check(#F.find("rectangle") == 0, "closed and no message: nothing drawn")
d.message = "saved"; F.reset_calls(); d:draw()
T.check(#F.find("rectangle") > 5, "closed with a message: just the message")

-- Through engine
local engine = require("engine")
T.check(engine.tune == tune, "engine.tune loads it on first use")
T.no_new_globals(globals)
