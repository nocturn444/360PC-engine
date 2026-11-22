-- engine.text: every glyph of the built-in font, sizes, lower case as upper case, merged runs,
-- scale and rounding, nothing allocated per draw, and the static check of what it calls.
local T = ...
local F = require("fake_love")
F.install()
local globals = {}
for k in pairs(_G) do globals[k] = true end
local text = require("engine.text")

T.check(text.width("") == 0 and text.width("A") == 3 and text.width("AB") == 7 and text.width("AB", 2) == 14,
  "width: 3 per glyph, 1 between")
T.check(text.height() == 5 and text.height(3) == 15, "height")
local count = 0
for code = 33, 95 do
  local rows = text.bits[code]
  local any = false
  for r = 1, 5 do if rows[r] > 0 then any = true end end
  if any then count = count + 1 end
end
T.check(count >= 60, "the font has glyphs for the printable ASCII range (" .. count .. ")")
T.check(text.bits[string.byte("a")] == text.bits[string.byte("A")], "lower case is drawn as upper case")

-- what lands on screen
local function pixels(s, scale)
  F.reset_calls()
  local n = text.draw(s, 10.4, 20.6, scale)
  local set = {}
  for _, c in ipairs(F.find("rectangle")) do
    local x, y, w, h = c[3], c[4], c[5], c[6]
    for i = 0, w - 1 do for j = 0, h - 1 do set[(x + i) .. "," .. (y + j)] = true end end
  end
  return set, n
end
local set, n = pixels("T")
T.check(n == 5 and set["10,21"] and set["12,21"] and set["11,25"] and not set["10,25"], "T: the bar and the stem, rounded to whole pixels")
local _, n_minus = pixels("--")
T.check(n_minus == 2, "two dashes: two runs, the column between glyphs stays empty")
local _, nE = pixels("E")
T.check(nE == 5, "E: one run per row")
local big = pixels("I", 2)
T.check(big["10,21"] and big["15,22"] and not big["16,21"], "scale 2: each font pixel 2 x 2")
F.reset_calls()
T.check(text.draw("~", 0, 0) == 0 and #F.find("rectangle") == 0, "a character the font lacks is blank")
T.check(text.lines({ "A", "B" }, 0, 0) == text.draw("A", 0, 0) + text.draw("B", 0, 6), "lines: one under the other")

-- a Font-like adapter for engine.ui: one object per scale, measuring, wrapping and rectangles
local one, two = text.font(1), text.font(2)
T.check(text.font(1) == one and one ~= two, "font(scale) caches one object per scale")
T.check(one:getWidth("AB") == 7 and two:getWidth("AB") == 14, "the adapter measures through width")
T.check(one:getHeight() == 6 and two:getHeight() == 12, "and its height is the line height")
local widest, lines = one:getWrap("ONE TWO THREE", 30)
T.check(widest == 26 and #lines == 2 and lines[1] == "ONE TWO" and lines[2] == "THREE",
  "getWrap wraps at spaces and returns the widest line")
local empty, elines = one:getWrap("", 30)
T.check(empty == 0 and #elines == 1 and elines[1] == "", "getWrap of an empty string")
F.reset_calls()
one:printf("A", 10, 20, 40, "center")
local first = F.find("rectangle")[1]
T.check(first and first[3] == 28 and first[4] == 20, "printf centres the line in the limit")
F.reset_calls()
one:printf("A", 10, 20, 40, "right")
first = F.find("rectangle")[1]
T.check(first and first[3] == 47, "printf aligns right")
F.reset_calls()
one:printf("ONE TWO", 0, 0, 12, "left")
local ys = {}
for _, c in ipairs(F.find("rectangle")) do ys[c[4]] = true end
T.check(ys[0] and ys[6] and ys[10] and not ys[11], "printf draws wrapped lines one line height apart")

-- nothing allocated per draw
local real = love.graphics.rectangle
love.graphics.rectangle = function() end
collectgarbage(); collectgarbage("stop")
local before = collectgarbage("count")
for _ = 1, 200 do text.draw("SEED 0123 ABC", 1, 1, 2) end
local grown = collectgarbage("count") - before
collectgarbage("restart")
love.graphics.rectangle = real
T.check(grown < 1, "draw allocates nothing (" .. grown .. " KB)")

-- printf allocates nothing once the lines are wrapped and cached
one:printf("CACHED TEXT", 0, 0, 100, "left")
love.graphics.rectangle = function() end
collectgarbage(); collectgarbage("stop")
before = collectgarbage("count")
for _ = 1, 200 do one:printf("CACHED TEXT", 0, 0, 100, "left") end
grown = collectgarbage("count") - before
collectgarbage("restart")
love.graphics.rectangle = real
T.check(grown < 1, "printf allocates nothing after the first wrap (" .. grown .. " KB)")

T.check(require("engine").text == text, "engine.text")
T.no_new_globals(globals)
