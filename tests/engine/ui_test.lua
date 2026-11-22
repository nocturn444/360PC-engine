-- engine.ui on the fake love: focus, navigation, key repeat, the widgets, the pick screen,
-- the mouse, and a screen as a state.
local T = ...
local F = require("fake_love")
F.install({ width = 1280, height = 720 })
local Input = require("engine.input")
local Pixel = require("engine.pixel")
local State = require("engine.state")
package.loaded["engine.ui"] = nil
local ui = require("engine.ui")
local globals = {}
for k in pairs(_G) do globals[k] = true end

local input = Input.new({ actions = { confirm = { keys = { "z" } } } })
ui.defineActions(input)
T.check(input.actions.ui_up and input.actions.ui_back, "the default ui actions are defined")
ui.defineActions(input, { ui_accept = { keys = { "z" } } })
T.check(input:getBindings("ui_accept").keys[1] == "z" and #input:getBindings("ui_accept").buttons == 0,
  "and a game can replace their bindings")
ui.defineActions(input, { ui_accept = ui.actions.ui_accept })

local screen
-- one fixed step with these keys held
local function step(keys)
  for k in pairs(F.keys) do F.keys[k] = nil end
  for _, k in ipairs(keys or {}) do F.keys[k] = true end
  input:poll(); input:step()
  screen:input(input)
  screen:update(1 / 60)
end
local function tap(key) step({ key }); step() end

---------------------------------------------------------------------------
-- A 3x3 grid of buttons: spatial navigation, wrap per container
---------------------------------------------------------------------------
local pressed = {}
local cells, rows = {}, {}
for r = 1, 3 do
  local row = {}
  for c = 1, 3 do
    local b = ui.button({ label = r .. "," .. c, id = r .. "," .. c, width = 30,
      on_press = function(self) pressed[#pressed + 1] = self.id end })
    cells[#cells + 1] = b
    row[c] = b
  end
  rows[r] = ui.hstack(row)
end
rows[2].wrap = "horizontal"
local grid = ui.vstack({ rows[1], rows[2], rows[3], id = "grid" })
screen = ui.screen({ root = grid, width = 320, height = 180 })
local function at() return screen.focused.id end

T.check(at() == "1,1", "the first focusable widget has the focus")
local b11, b33 = screen:get("1,1"), screen:get("3,3")
T.check(b11.w == 30 and b11.h == 16, "a button is its text plus the padding: " .. b11.w .. "x" .. b11.h)
T.check(grid.w == 94 and grid.h == 52, "stacks add the spacing: " .. grid.w .. "x" .. grid.h)
T.check(grid.x == 113 and grid.y == 64, "the root is centred in the game's resolution")
T.check(b33.x == grid.x + 64 and b33.y == grid.y + 36, "children are placed in rows and columns")

tap("right"); T.check(at() == "1,2", "right")
tap("down"); T.check(at() == "2,2", "down, to the row under it")
tap("down"); tap("left"); T.check(at() == "3,1", "down and left")
tap("left"); T.check(at() == "3,1", "no wrap: the focus stays at the edge")
tap("down"); T.check(at() == "3,1", "and at the bottom")
tap("up"); tap("left"); T.check(at() == "2,3", "a row with wrap goes round to its other end")
tap("right"); T.check(at() == "2,1", "both ways")
tap("up"); T.check(at() == "1,1", "its wrap is horizontal only")
tap("up"); T.check(at() == "1,1", "so up at the top does nothing")
grid.wrap = true
tap("up"); T.check(at() == "3,1", "the grid wraps as a whole when it is told to")
tap("down"); T.check(at() == "1,1", "and back")
tap("left"); T.check(at() == "1,3", "a row without its own wrap uses the grid's")

-- a disabled widget is skipped
screen:get("1,2").disabled = true
tap("left"); T.check(at() == "1,1", "disabled widgets are skipped")
screen:get("1,2").disabled = nil

-- explicit overrides
b11.right = "3,3"
b33.up = b11
tap("right"); T.check(at() == "3,3", "an explicit neighbour, by id")
tap("up"); T.check(at() == "1,1", "and by widget")
b11.right, b33.up = nil, nil
b11.next, b11.prev = "2,2", "3,3"
tap("down"); T.check(at() == "2,2", "next stands for down and right")
screen:focus(b11); tap("left"); T.check(at() == "3,3", "prev for up and left")
b11.next, b11.prev = nil, nil

-- accept
screen:focus("2,3")
tap("return")
T.check(#pressed == 1 and pressed[1] == "2,3", "accept presses the focused button")
step({ "return" }); step({ "return" }); step({ "return" }); step()
T.check(#pressed == 2, "a held accept presses once")

---------------------------------------------------------------------------
-- Key repeat: 0.4 s, then every 0.1 s, in fixed steps (24 and 6 at 60 Hz)
---------------------------------------------------------------------------
local moves = 0
local items = {}
for i = 1, 20 do items[i] = "item " .. i end
local scrolled = {}
local list = ui.list({ items = items, rows = 4, id = "list",
  on_change = function(self, i) moves = moves + 1 end,
  on_select = function(self, i, item) scrolled[#scrolled + 1] = item end })
screen = ui.screen({ root = ui.vstack({ list, ui.button({ label = "ok", id = "ok" }) }), width = 320, height = 180 })
step({ "down" })
T.check(moves == 1 and list.selected == 2, "the press moves at once")
for _ = 1, 23 do step({ "down" }) end
T.check(moves == 1, "nothing more for 23 steps")
step({ "down" })
T.check(moves == 2, "the first repeat on step 24")
for _ = 1, 5 do step({ "down" }) end
T.check(moves == 2, "then nothing for 5 steps")
step({ "down" })
T.check(moves == 3, "the second repeat 6 steps later")
for _ = 1, 12 do step({ "down" }) end
T.check(moves == 5 and list.selected == 6, "and every 6 steps")
step()
for _ = 1, 30 do step() end
T.check(moves == 5, "released: no more")
step({ "down" }); for _ = 1, 23 do step({ "down" }) end
T.check(moves == 6, "a new press waits the whole delay again")
step()

-- at 30 Hz the same times are 12 and 3 steps
screen:update(1 / 30)
local m0 = moves
for k in pairs(F.keys) do F.keys[k] = nil end
F.keys.down = true
for _ = 1, 16 do input:poll(); input:step(); screen:input(input) end
T.check(moves - m0 == 3, "the delay and the rate follow the step length: " .. (moves - m0))
step()

---------------------------------------------------------------------------
-- List: scrolling, ends, wrap, accept, horizontal
---------------------------------------------------------------------------
list:select(1)
T.check(list.first == 1 and list.selected == 1, "back to the top")
for _ = 1, 3 do tap("down") end
T.check(list.selected == 4 and list.first == 1, "four rows fit")
tap("down")
T.check(list.selected == 5 and list.first == 2, "the list scrolls to keep the selection in view")
list:select(20)
T.check(list.first == 17, "the last rows")
tap("return")
T.check(scrolled[1] == "item 20", "accept reports the selected item")
tap("down")
T.check(screen.focused.id == "ok" and list.selected == 20, "past the end the focus leaves the list")
tap("up")
T.check(screen.focused == list, "and comes back")
list.wrap = true
tap("down")
T.check(list.selected == 1 and list.first == 1 and screen.focused == list, "a list with wrap goes round")
tap("up")
T.check(list.selected == 20 and list.first == 17, "both ways")
F.reset_calls(); screen:draw()
local texts = F.find("printf")
T.check(#texts == 5 and texts[1][2] == "item 17" and texts[4][2] == "item 20", "only the rows in view are drawn")
list:setItems({ { name = "a" }, { label = "b" } })
screen:layout()
T.check(list.selected == 2 and list.first == 1 and list.labels[2] == "b", "items from data, replaced; the selection is kept in range")

local hl = ui.list({ items = { "a", "b", "c", "d" }, orientation = "horizontal", rows = 2, item_width = 20 })
screen = ui.screen({ root = ui.vstack({ ui.button({ label = "top", id = "top" }), hl }), width = 320, height = 180, focus = hl })
T.check(screen.focused == hl, "the first focus can be chosen")
tap("right"); tap("right")
T.check(hl.selected == 3 and hl.first == 2, "a horizontal list moves and scrolls with left and right")
tap("up")
T.check(screen.focused.id == "top", "and up leaves it")

---------------------------------------------------------------------------
-- Toggle and slider
---------------------------------------------------------------------------
local changes = {}
local toggle = ui.toggle({ label = "Music", on_change = function(self, v) changes[#changes + 1] = v end })
local slider = ui.slider({ label = "Volume", min = 0, max = 1, step = 0.1, value = 0.5,
  on_change = function(self, v) changes[#changes + 1] = v end })
screen = ui.screen({ root = ui.vstack({ toggle, slider, align = "stretch", wrap = true }), width = 320, height = 180 })
tap("return")
T.check(toggle.value == true and changes[1] == true, "accept flips a toggle")
tap("return")
T.check(toggle.value == false and changes[2] == false, "and back")
tap("down")
T.check(screen.focused == slider and toggle.w == slider.w, "stretch gives the widgets the same width")
tap("right")
T.near(slider.value, 0.6, "right is one step up")
for _ = 1, 3 do tap("left") end
T.near(slider.value, 0.3, "left is one step down")
for _ = 1, 9 do tap("left") end
T.check(slider.value == 0 and screen.focused == slider, "it stops at the minimum, and keeps the focus")
local n = #changes
tap("left")
T.check(#changes == n, "no change, no callback")
for _ = 1, 12 do tap("right") end
T.check(slider.value == 1, "and at the maximum, exactly: " .. slider.value)
tap("down")
T.check(screen.focused == toggle, "up and down still move the focus (with wrap)")

---------------------------------------------------------------------------
-- Labels wrap; themes are data; anchors
---------------------------------------------------------------------------
local label = ui.label({ text = "one two three four five six", width = 60, align = "center" })
screen = ui.screen({ root = ui.vstack({ label, ui.button({ label = "ok" }), background = true }),
  width = 320, height = 180, anchor = "bottomright", margin = 8, theme = { padding = 6, focus = { 1, 0, 0, 1 } } })
T.check(label.h == 24, "a label with a width wraps (three lines of 8): " .. label.h)
local root = screen.root
T.check(root.w == 60 + 12 and root.x + root.w == 320 - 8 and root.y + root.h == 180 - 8,
  "anchored to the bottom right, inside the margin, with the theme's padding")
F.reset_calls(); screen:draw()
local pf = F.find("printf")[1]
T.check(pf[2] == label.text and pf[5] == 60 and pf[6] == "center", "drawn with printf, wrapped and aligned")
local red = false
for _, c in ipairs(F.find("rectangle")) do
  if c.color[1] == 1 and c.color[2] == 0 and c.color[3] == 0 then red = true end
end
T.check(red, "the focus outline uses the theme's colour")
T.check(ui.theme.padding == 4, "the default theme is not changed")
local r, g, b, a = love.graphics.getColor()
T.check(r == 1 and g == 1 and b == 1 and a == 1, "draw leaves the colour as it was")
label:setText("short")
T.check(screen.dirty, "a new text asks for a new layout")
screen:draw()
T.check(label.h == 8 and not screen.dirty, "done on the next draw")

-- an engine.text font: measured by its adapter, drawn with rectangles, no love.graphics.printf
local tfont = require("engine.text").font(1)
local tl = ui.label({ text = "ONE TWO THREE", width = 30, align = "center" })
screen = ui.screen({ root = ui.vstack({ tl, ui.button({ label = "OK" }), background = true }),
  width = 320, height = 180, theme = { font = tfont } })
T.check(tl.h == 12, "the adapter wraps the label in two lines of 6: " .. tl.h)
F.reset_calls(); screen:draw()
T.check(#F.find("printf") == 0 and #F.find("setFont") == 0,
  "an engine.text font draws without love.graphics.printf or setFont")
T.check(#F.find("rectangle") > 0, "the labels are drawn with rectangles")

---------------------------------------------------------------------------
-- Pick 1 of 3
---------------------------------------------------------------------------
local chosen, cancelled = nil, 0
local choices = {
  { name = "Thorns", description = "Attackers take 2 damage" },
  { name = "Wings", description = "Jump twice", icon = love.graphics.newImage("x.png") },
  { name = "Venom", description = "Hits poison for 3 s", icon = function() end },
}
screen = ui.pick({ title = "Choose a mutation", hint = "A: choose", choices = choices, width = 320, height = 180,
  on_choose = function(i, choice) chosen = { i, choice } end,
  on_cancel = function() cancelled = cancelled + 1 end })
T.check(#screen.cards == 3 and screen.focused == screen.cards[1], "three cards, the first focused")
local c1, c3 = screen.cards[1], screen.cards[3]
T.check(c1.h == c3.h and c1.y == c3.y and c1.x < c3.x, "the cards are a row of the same height")
T.check(screen.root.x >= 0 and screen.root.x + screen.root.w <= 320, "the screen fits the resolution")
tap("right"); tap("right")
T.check(screen.focused == c3, "right moves along the cards")
tap("right")
T.check(screen.focused == c1, "and wraps")
tap("left"); tap("left")
T.check(screen.focused == screen.cards[2], "left too")
tap("return")
T.check(chosen and chosen[1] == 2 and chosen[2] == choices[2], "accept returns the index and the choice")
tap("escape")
T.check(cancelled == 1, "back cancels")
F.reset_calls(); screen:draw()
T.check(#F.find("printf") == 8 and #F.find("draw") == 1, "title, hint, names, descriptions and the image icon are drawn")
choices[1].disabled = true
screen = ui.pick({ choices = choices, width = 320, height = 180, selected = 3, dir = "vertical",
  on_choose = function(i) chosen = i end })
T.check(screen.focused == screen.cards[3], "the first focus can be set")
tap("up")
T.check(screen.focused == screen.cards[2], "a column of cards moves with up and down")
tap("up")
T.check(screen.focused == screen.cards[3], "a disabled choice cannot be focused: the wrap skips it")
screen:choose(1)
T.check(chosen ~= 1, "nor chosen")
tap("escape")
T.check(cancelled == 1, "without on_cancel, back does nothing")

---------------------------------------------------------------------------
-- Mouse: through pixel.toGame (320x180 shown x4)
---------------------------------------------------------------------------
local pixel = Pixel.new({ width = 320, height = 180, mode = "direct" })
pressed = {}
local ba = ui.button({ label = "a", id = "a", width = 40, on_press = function(self) pressed[#pressed + 1] = "a" end })
local bb = ui.button({ label = "b", id = "b", width = 40, on_press = function(self) pressed[#pressed + 1] = "b" end })
local ms = ui.slider({ label = "s", id = "s", track = 40, value = 0 })
local ml = ui.list({ items = { "x", "y", "z" }, id = "l", width = 40 })
screen = ui.screen({ root = ui.vstack({ ba, bb, ms, ml }), pixel = pixel })
T.check(screen.width == 320 and screen.height == 180, "the screen takes the pixel's size")
local function mouse(w, fx, fy, down)
  F.mouse_x, F.mouse_y = pixel:toScreen(w.x + w.w * (fx or 0.5), w.y + w.h * (fy or 0.5))
  F.mouse_buttons[1] = down or nil
  step()
end
mouse(bb)
T.check(screen.focused == ba, "a pointer that has not moved does not take the focus")
mouse(bb, 0.6)
T.check(screen.focused == bb, "hovering a widget focuses it")
tap("up")
T.check(screen.focused == ba, "the controller still moves the focus under a still pointer")
step(); step()
T.check(screen.focused == ba, "and keeps it")
mouse(bb, 0.6, 0.5, true)
T.check(screen.focused == bb and pressed[1] == "b", "a click focuses and presses")
mouse(bb, 0.6, 0.5, true)
T.check(#pressed == 1, "once per click")
mouse(bb, 0.6, 0.5, false)
F.mouse_x, F.mouse_y = 2, 2; step()
T.check(screen.focused == bb, "the pointer over nothing changes nothing")
mouse(ml, 0.5, 0.5)
T.check(screen.focused == ml and ml.selected == 2, "hovering a list selects the item under the pointer")
F.mouse_x, F.mouse_y = pixel:toScreen(ms.x + ms.w - ms.pad - 10, ms.y + 4)
F.mouse_buttons[1] = true; step(); F.mouse_buttons[1] = nil; step()
T.near(ms.value, 0.8, "a click on a slider's track sets its value (to a step)")

---------------------------------------------------------------------------
-- A screen is a state: a transparent pause menu over the game
---------------------------------------------------------------------------
local states = State.new()
local drawn = 0
states:push({ draw = function() drawn = drawn + 1 end })
local resumed = false
local pause = ui.screen({ transparent = true, width = 320, height = 180, mouse = false,
  on_back = function() states:pop() end,
  root = ui.vstack({ background = true, wrap = true,
    ui.label({ text = "PAUSED" }),
    ui.button({ label = "Resume", on_press = function() resumed = true; states:pop() end }),
    ui.button({ label = "Quit", id = "quit" }) }) })
T.check(pause.transparent and pause.dim, "transparent, and it dims the game by default")
states:push(pause)
screen = { input = function(_, i) states:input(i) end, update = function(_, dt) states:update(dt) end }
F.reset_calls(); states:draw(0)
local rects = F.find("rectangle")
T.check(drawn == 1 and rects[1][5] == 320 and rects[1][6] == 180 and rects[1].color[4] == 0.6,
  "the game is drawn under it, dimmed")
tap("down")
T.check(pause.focused.id == "quit", "the state machine feeds it the input")
tap("down"); tap("return")
T.check(resumed and states:depth() == 1, "a button can pop it")
states:push(pause)
tap("escape")
T.check(states:depth() == 1, "and so can back")

-- nothing is allocated per step or per frame
states:push(pause)
for _ = 1, 10 do step({ "down" }); states:draw(0) end
collectgarbage(); collectgarbage("stop")
local before = collectgarbage("count")
local calls = F.calls
for _ = 1, 100 do
  input:poll(); input:step(); states:input(input); states:update(1 / 60)
  pause:navigate("down"); pause:mouse(10, 10, false)
end
local used = collectgarbage("count") - before
collectgarbage("restart")
T.check(used == 0, "a screen allocates nothing per step: " .. used .. " KB")
T.check(calls == F.calls, "sanity")

T.no_new_globals(globals)
