-- engine.text: a tiny built-in pixel font (3 x 5 glyphs, ASCII 32 to 95; lower case is drawn
-- as upper case) drawn with rectangles, so debug overlays show text on the console without a
-- TTF (the console has no built-in font and love.graphics.print needs one, see
-- docs/GAME_CONFIG.md, default_font). Each pixel row of a line is drawn as merged runs: a few
-- rectangles per glyph row, nothing allocated. For a game's own text, ship a TTF or a font
-- sprite sheet; this is for development overlays.
--
--   local text = require("engine.text")
--   text.draw("SEED 1234", 4, 4)                  -- the current colour, scale 1
--   text.draw("PAUSED", 100, 80, 2)               -- each font pixel 2 x 2
--   local w, h = text.width("PAUSED", 2), text.height(2)
--
-- text.font(scale) returns a Font-like object (one per scale, cached) for code that expects a
-- LÖVE font, such as engine.ui: getWidth(s), getHeight() (the line height), getWrap(s, limit)
-- (word wrap: the widest line and its lines) and printf(s, x, y, limit, align) (draws the
-- wrapped lines with text.draw, aligned left, center or right). getWrap allocates because it
-- runs on layout; printf keeps the wrapped lines per string and limit, so drawing allocates
-- nothing. Give it to a screen as theme = { font = text.font(1) } and the menus draw with
-- rectangles on the console, with no TTF.
local byte, floor = string.byte, math.floor

local M = {}

M.glyph_w, M.glyph_h, M.advance, M.line_height = 3, 5, 4, 6

-- "rows" of 3 pixels, top to bottom; "#" is on
local SOURCE = {
  ["0"] = ".#. #.# #.# #.# .#.", ["1"] = ".#. ##. .#. .#. ###", ["2"] = "### ..# ### #.. ###",
  ["3"] = "### ..# ### ..# ###", ["4"] = "#.# #.# ### ..# ..#", ["5"] = "### #.. ### ..# ###",
  ["6"] = "### #.. ### #.# ###", ["7"] = "### ..# ..# ..# ..#", ["8"] = "### #.# ### #.# ###",
  ["9"] = "### #.# ### ..# ###",
  A = "### #.# ### #.# #.#", B = "##. #.# ##. #.# ##.", C = "### #.. #.. #.. ###",
  D = "##. #.# #.# #.# ##.", E = "### #.. ### #.. ###", F = "### #.. ### #.. #..",
  G = "### #.. #.# #.# ###", H = "#.# #.# ### #.# #.#", I = "### .#. .#. .#. ###",
  J = "..# ..# ..# #.# ###", K = "#.# #.# ##. #.# #.#", L = "#.. #.. #.. #.. ###",
  M = "#.# ### ### #.# #.#", N = "##. #.# #.# #.# #.#", O = "### #.# #.# #.# ###",
  P = "### #.# ### #.. #..", Q = "### #.# #.# ### ..#", R = "##. #.# ##. #.# #.#",
  S = ".## #.. .#. ..# ##.", T = "### .#. .#. .#. .#.", U = "#.# #.# #.# #.# ###",
  V = "#.# #.# #.# #.# .#.", W = "#.# #.# ### ### #.#", X = "#.# #.# .#. #.# #.#",
  Y = "#.# #.# .#. .#. .#.", Z = "### ..# .#. #.. ###",
  ["."] = "... ... ... ... .#.", [","] = "... ... ... .#. #..", [":"] = "... .#. ... .#. ...",
  ["-"] = "... ... ### ... ...", ["+"] = "... .#. ### .#. ...", ["/"] = "..# ..# .#. #.. #..",
  ["%"] = "#.# ..# .#. #.. #.#", ["("] = ".#. #.. #.. #.. .#.", [")"] = ".#. ..# ..# ..# .#.",
  ["="] = "... ### ... ### ...", ["*"] = "... #.# .#. #.# ...", ["#"] = "#.# ### #.# ### #.#",
  ["!"] = ".#. .#. .#. ... .#.", ["?"] = "### ..# .#. ... .#.", ["_"] = "... ... ... ... ###",
  ["<"] = "..# .#. #.. .#. ..#", [">"] = "#.. .#. ..# .#. #..", ["["] = "##. #.. #.. #.. ##.",
  ["]"] = ".## ..# ..# ..# .##", ["'"] = ".#. .#. ... ... ...", ['"'] = "#.# #.# ... ... ...",
  [";"] = "... .#. ... .#. #..", ["$"] = ".## ##. .#. .## ##.", ["&"] = ".#. #.# .#. #.# .##",
  ["@"] = "### #.# #.# #.. ###", ["^"] = ".#. #.# ... ... ...", ["\\"] = "#.. #.. .#. ..# ..#",
}

-- BITS[code][row] = the row's pixels as a number: 4 for the left one, 2, 1 for the right one
local BITS = {}
for code = 32, 127 do BITS[code] = { 0, 0, 0, 0, 0 } end
for ch, src in next, SOURCE do
  local rows, r = BITS[byte(ch)], 0
  for row in src:gmatch("%S+") do
    r = r + 1
    local v = 0
    for i = 1, 3 do if row:sub(i, i) == "#" then v = v + 2 ^ (3 - i) end end
    rows[r] = v
  end
end
for code = 97, 122 do BITS[code] = BITS[code - 32] end     -- a..z drawn as A..Z
M.bits = BITS

local MASK = { 4, 2, 1 }

-- Whether the font has a pixel at column c (from 0) of line row r (1..5) of string s
local function on(s, c, r)
  local k = floor(c / 4)
  local i = c - k * 4
  if i == 3 then return false end
  local rows = BITS[byte(s, k + 1)]
  if not rows then return false end
  return floor(rows[r] / MASK[i + 1]) % 2 == 1
end

-- text.width(s, scale) and text.height(scale): the size of a one-line string, in pixels
function M.width(s, scale)
  local n = #s
  if n == 0 then return 0 end
  return (n * 4 - 1) * (scale or 1)
end
function M.height(scale) return 5 * (scale or 1) end

-- text.draw(s, x, y, scale): one line in the current colour, top left at x, y (rounded to whole
-- pixels). Characters the font lacks are blank. Returns the number of rectangles drawn.
function M.draw(s, x, y, scale)
  local g = love.graphics
  scale = scale or 1
  x, y = floor(x + 0.5), floor(y + 0.5)
  local cols, n = #s * 4 - 1, 0
  for r = 1, 5 do
    local c = 0
    local yy = y + (r - 1) * scale
    while c < cols do
      if on(s, c, r) then
        local stop = c
        while stop + 1 < cols and on(s, stop + 1, r) do stop = stop + 1 end
        g.rectangle("fill", x + c * scale, yy, (stop - c + 1) * scale, scale)
        n = n + 1
        c = stop + 1
      else
        c = c + 1
      end
    end
  end
  return n
end

-- text.lines(list, x, y, scale): draw(list[i]) one line_height apart. Returns rectangles drawn.
function M.lines(list, x, y, scale)
  scale = scale or 1
  local n = 0
  for i = 1, #list do n = n + M.draw(list[i], x, y + (i - 1) * 6 * scale, scale) end
  return n
end

-- Word wrap like love.graphics Font:getWrap: lines and their widest width, split at spaces and
-- newlines (a word longer than the limit stays on its own line). Allocates: it is for layout.
local function wrap(s, limit, scale)
  local lines, widest = {}, 0
  for para in (tostring(s) .. "\n"):gmatch("(.-)\n") do
    local line, lw = "", 0
    for word in para:gmatch("%S+") do
      local ww = M.width(word, scale)
      local sep = line == "" and 0 or 4 * scale
      if line ~= "" and lw + sep + ww > limit then
        lines[#lines + 1] = line
        if lw > widest then widest = lw end
        line, lw = word, ww
      elseif sep > 0 then
        line, lw = line .. " " .. word, lw + sep + ww
      else
        line, lw = word, ww
      end
    end
    lines[#lines + 1] = line
    if lw > widest then widest = lw end
  end
  lines.w = widest
  return lines
end

local FONTS = {}

-- text.font(scale): a Font-like object (cached per scale) for engine.ui and anything else that
-- takes a LÖVE font. getWrap is for layout; printf reuses the wrapped lines, so drawing does
-- not allocate.
function M.font(scale)
  scale = scale or 1
  local f = FONTS[scale]
  if f then return f end
  f = { scale = scale, cache = {} }
  function f:getWidth(s) return M.width(tostring(s), scale) end
  function f:getHeight() return M.line_height * scale end
  function f:getWrap(s, limit)
    limit = limit or 1e6
    local by = self.cache[s]
    if not by then by = {}; self.cache[s] = by end
    local lines = by[limit]
    if not lines then lines = wrap(s, limit, scale); by[limit] = lines end
    return lines.w, lines
  end
  function f:printf(s, x, y, limit, align)
    limit = limit or 1e6
    local by = self.cache[s]
    if not by then by = {}; self.cache[s] = by end
    local lines = by[limit]
    if not lines then lines = wrap(s, limit, scale); by[limit] = lines end
    local lh = M.line_height * scale
    for i = 1, #lines do
      local line = lines[i]
      local dx = 0
      if align == "center" or align == "right" then
        local lw = M.width(line, scale)
        if align == "center" then dx = floor((limit - lw) / 2)
        else dx = limit - lw end
      end
      M.draw(line, x + dx, y + (i - 1) * lh, scale)
    end
  end
  FONTS[scale] = f
  return f
end

return M
