-- engine.cutscene: validation, wait / fade / move / pan timing, concurrent steps with
-- wait = false, typing and the two-press advance, hold-to-skip, call with always, on_finish,
-- sound and music, the draw calls, and nothing allocated in update or draw.
local T = ...
local F = require("fake_love")
F.install({ width = 1280, height = 720 })
local globals = {}
for k in pairs(_G) do globals[k] = true end
local engine = require("engine")
local cutscene = require("engine.cutscene")
local DT = 1 / 60

T.check(engine.cutscene == cutscene, "engine.cutscene loads on first use")

local function fake_input()
  local inp = { p = {}, d = {} }
  function inp:pressed(a) return self.p[a] == true end
  function inp:down(a) return self.d[a] == true end
  return inp
end
local function step(cs, inp)
  if inp then cs:input(inp) end
  cs:update(DT)
end
local function steps(cs, n, inp)
  for _ = 1, n do step(cs, inp) end
end
local function tap(cs, inp, action)
  inp.p[action or "ui_accept"] = true
  step(cs, inp)
  inp.p[action or "ui_accept"] = false
end
local function fails(script, ...)
  local ok, err = pcall(cutscene.new, script)
  T.check(not ok, "an invalid script is rejected")
  local msg = tostring(err)
  for _, part in ipairs({ ... }) do
    T.check(msg:find(part, 1, true), "the error names " .. part .. ": " .. msg)
  end
end

---------------------------------------------------------------------------
-- Validation names the step and the field
---------------------------------------------------------------------------
fails({ id = "bad", steps = { { "wait" } } }, "step 1", "\"time\"")
fails({ id = "bad", steps = { { "wait", time = 0 }, { "bogus" } } }, "step 2", "bogus")
fails({ steps = { { "show", id = "a", image = "a.png" }, { "move", id = "a" } } }, "step 2", "\"time\"")
fails({ steps = { { "show", id = "a" } } }, "step 1", "\"image\"")
fails({ steps = { { "show", id = "a", image = "a.png", rect = { 1, 1 } } } }, "step 1", "\"image\"")
fails({ steps = { { "fade", to = 2, time = 1 } } }, "step 1", "\"to\"")
fails({ steps = { { "text", text = "x", y = 0 } } }, "step 1", "\"x\"")
fails({ steps = { { "call" } } }, "step 1", "\"fn\"")
fails({ steps = { { "pan", x = 1, y = 2, time = 1, ease = "bogus" } } }, "step 1", "\"ease\"")

---------------------------------------------------------------------------
-- wait, fade, move, pan: timing
---------------------------------------------------------------------------
local finished, skipped = 0, nil
local cs = cutscene.new({ steps = { { "wait", time = 1 } } },
  { on_finish = function(c, s) finished, skipped = finished + 1, s end })
T.check(cs.step_index == 1 and not cs.done, "a wait starts")
steps(cs, 58)
T.check(not cs.done, "58 steps is less than a second")
steps(cs, 5)
T.check(cs.done and finished == 1 and skipped == false, "a wait ends once, on_finish says not skipped")

cs = cutscene.new({ steps = { { "fade", to = 1, time = 1 } } })
T.check(cs.fade == 0, "the overlay starts clear")
steps(cs, 30)
T.near(cs.fade, 0.5, "fade reaches half in half the time", 0.02)
steps(cs, 30)
T.check(cs.fade == 1 and cs.done, "and covers at the end")

cs = cutscene.new({ steps = {
  { "show", id = "a", rect = { 4, 4 }, x = 0, y = 0 },
  { "move", id = "a", x = 100, y = 50, time = 1 },
} })
local el = cs.elements[1]
steps(cs, 30)
T.near(el.x, 50, "move tweens x", 0.05)
T.near(el.y, 25, "move tweens y", 0.05)
steps(cs, 30)
T.check(el.x == 100 and el.y == 50 and cs.done, "move ends at the target")

cs = cutscene.new({ steps = { { "pan", x = 40, y = 20, time = 1 } } })
steps(cs, 30)
T.near(cs.view_x, 20, "pan tweens the view's x", 0.05)
T.near(cs.view_y, 10, "pan tweens the view's y", 0.05)
steps(cs, 30)
T.check(cs.view_x == 40 and cs.view_y == 20 and cs.done, "pan ends at the target")

---------------------------------------------------------------------------
-- wait = false starts the next step at once
---------------------------------------------------------------------------
local marks = {}
cs = cutscene.new({ steps = {
  { "wait", time = 2, wait = false },
  { "wait", time = 1 },
  { "call", fn = function() marks[#marks + 1] = "next" end },
} })
T.check(cs.step_index == 2, "the second step starts with the first")
steps(cs, 65)
T.check(not cs.done and #marks == 1, "the faster one finishes while the first still runs")
steps(cs, 60)
T.check(cs.done, "done only when every running step finished")

---------------------------------------------------------------------------
-- Typing: speed, and two presses with wait = "button"
---------------------------------------------------------------------------
cs = cutscene.new({ steps = { { "text", text = "ABCDEFGHIJ", x = 0, y = 0, w = 200, speed = 10 } } })
local block = cs.texts[1]
T.check(block.total == 10 and block.shown == 0, "the text is wrapped once when the step starts")
steps(cs, 30)
T.check(block.shown > 4 and block.shown < 6 and not cs.done, "typing at 10 characters a second")
local inp = fake_input()
tap(cs, inp)
T.check(block.shown == 10 and not cs.done, "the first press finishes the typing")
tap(cs, inp)
T.check(cs.done, "the second press continues")

cs = cutscene.new({ steps = { { "text", text = "HI", x = 0, y = 0, w = 100, speed = 0, wait = 0.5 } } })
block = cs.texts[1]
T.check(block.shown == 2, "speed 0: all of it at once")
steps(cs, 29)
T.check(not cs.done, "a number wait counts after the typing")
steps(cs, 2)
T.check(cs.done, "and then continues")

---------------------------------------------------------------------------
-- Hold to skip: a short press does nothing; 1 s skips; not when skippable = false
---------------------------------------------------------------------------
local finishes, was_skipped = 0, nil
cs = cutscene.new({ steps = { { "wait", time = 10 } } },
  { on_finish = function(c, s) finishes, was_skipped = finishes + 1, s end })
inp = fake_input()
inp.d.ui_back = true
steps(cs, 30, inp)
T.check(not cs.done and cs.skip_hold > 0.4, "half a second held does not skip")
inp.d.ui_back = false
step(cs, inp)
T.check(cs.skip_hold == 0, "releasing the button resets the hold")
inp.d.ui_back = true
steps(cs, 65, inp)
T.check(cs.done and was_skipped == true and finishes == 1, "a second held skips, on_finish says skipped")

cs = cutscene.new({ skippable = false, steps = { { "wait", time = 10 } } })
inp.d.ui_back = true
steps(cs, 120, inp)
T.check(not cs.done, "a script that is not skippable ignores the hold")

local once = 0
cs = cutscene.new({ steps = { { "wait", time = 10 } } },
  { on_finish = function() once = once + 1 end })
cs:skip()
cs:skip()
T.check(cs.done and once == 1, "on_finish runs once, even after a second skip")

---------------------------------------------------------------------------
-- call with always on skip
---------------------------------------------------------------------------
marks = {}
cs = cutscene.new({ steps = {
  { "call", fn = function() marks[#marks + 1] = "start" end },
  { "wait", time = 10 },
  { "call", fn = function() marks[#marks + 1] = "always" end, always = true },
  { "call", fn = function() marks[#marks + 1] = "never" end },
} })
T.check(marks[1] == "start", "a call runs when it starts")
cs:skip()
T.check(cs.done and #marks == 2 and marks[2] == "always", "skip runs only the always calls not reached")
T.check(cs.step_index == 4, "skip moves the index to the last step")

---------------------------------------------------------------------------
-- Sound and music go to the audio; without it they do nothing
---------------------------------------------------------------------------
local audio_calls = {}
local audio = {
  play = function(_, name, volume, pitch) audio_calls[#audio_calls + 1] = { name, volume, pitch } end,
  music = function(_, name, opts) audio_calls[#audio_calls + 1] = { name, opts and opts.fade } end,
}
cutscene.new({ steps = {
  { "sound", name = "beep", volume = 0.5, pitch = 1.2 },
  { "music", name = "theme", fade = 2 },
  { "music" },
} }, { audio = audio })
T.check(#audio_calls == 3 and audio_calls[1][1] == "beep" and audio_calls[1][2] == 0.5
  and audio_calls[1][3] == 1.2, "sound is play(name, volume, pitch)")
T.check(audio_calls[2][1] == "theme" and audio_calls[2][2] == 2, "music is music(name, { fade })")
T.check(audio_calls[3][1] == nil, "music without a name stops it")
T.check(pcall(cutscene.new, { steps = { { "sound", name = "x" }, { "music", name = "y" } } }),
  "sound and music without audio do nothing")

---------------------------------------------------------------------------
-- Elements: show replaces by id, hide removes, images are cached
---------------------------------------------------------------------------
local loaded = 0
cs = cutscene.new({ steps = {
  { "show", id = "a", rect = { 4, 4 } },
  { "show", id = "a", rect = { 5, 5 } },
  { "show", id = "i", image = "pic.png" },
  { "show", id = "j", image = "pic.png" },
} }, { image = function(file) loaded = loaded + 1; return love.graphics.newImage(file) end })
T.check(#cs.elements == 3 and cs.elements[1].rect_w == 5, "show replaces an element with the same id")
T.check(loaded == 1 and cs.elements[2].image == cs.elements[3].image, "an image is loaded once")

cs = cutscene.new({ steps = { { "show", id = "a", rect = { 4, 4 } }, { "hide", id = "a" } } })
T.check(#cs.elements == 0, "hide removes the element")

T.check(type(engine.text.wrap) == "function", "engine.text.wrap is exposed")
local lines = engine.text.wrap("HELLO WORLD", 30, 1)
T.check(#lines >= 2 and lines.w > 0, "it wraps like the font's getWrap")

---------------------------------------------------------------------------
-- Drawing: engine.text only, no printf / print / setFont, no scissor
---------------------------------------------------------------------------
cs = cutscene.new({ background = { 0.1, 0.2, 0.3 }, steps = {
  { "show", id = "box", rect = { 20, 10 }, color = { 1, 0, 0 }, x = 5, y = 6 },
  { "text", text = "HELLO WORLD WRAPPED", x = 4, y = 100, w = 40, speed = 0, wait = false },
  { "say", text = "A LINE OF DIALOGUE", speaker = "BLOB", speed = 0, wait = false },
  { "fade", to = 0.5, time = 0 },
} })
F.reset_calls()
cs:draw()
T.check(#F.find("printf") == 0 and #F.find("print") == 0 and #F.find("setFont") == 0,
  "text goes through engine.text, not a font")
T.check(#F.find("setScissor") == 0, "no scissor")
local rects = F.find("rectangle")
T.check(rects[1].color[1] == 0.1 and rects[1].color[2] == 0.2 and rects[1].color[4] == 1,
  "the background is drawn first")
T.check(#rects > 4, "the element, the dialogue box, the text and the fade are all rectangles")

---------------------------------------------------------------------------
-- update and draw allocate nothing when no step starts
---------------------------------------------------------------------------
cs = cutscene.new({ steps = {
  { "show", id = "a", rect = { 8, 8 }, x = 0, y = 0 },
  { "text", text = "ALLOCATION FREE TYPING AND DRAWING", x = 0, y = 100, w = 200, speed = 100,
    wait = false },
  { "wait", time = 100 },
} })
inp = fake_input()
for _ = 1, 120 do cs:input(inp); cs:update(DT) end
local real_rect = love.graphics.rectangle
love.graphics.rectangle = function() end
collectgarbage(); collectgarbage("stop")
local before = collectgarbage("count")
for _ = 1, 200 do cs:input(inp); cs:update(DT); cs:draw() end
local grown = collectgarbage("count") - before
collectgarbage("restart")
love.graphics.rectangle = real_rect
T.check(grown < 1, "update and draw allocate nothing once the steps are running (" .. grown .. " KB)")

T.no_new_globals(globals)
