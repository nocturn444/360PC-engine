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

T.check(require("engine").text == text, "engine.text")
T.no_new_globals(globals)
