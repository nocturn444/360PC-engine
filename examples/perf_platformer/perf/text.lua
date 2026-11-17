-- Text without a font: the 3x5 glyphs of tiles.png in a SpriteBatch, one draw call for the
-- whole overlay. The console has no built-in font (docs/GAME_CONFIG.md, default_font) and the
-- test ships no TTF, so love.graphics.print would draw nothing there.
local atlas = require("perf.atlas")
local byte, upper = string.byte, string.upper

local Text = {}
Text.__index = Text

function Text.new(size)
  return setmetatable({ batch = love.graphics.newSpriteBatch(atlas.image, size or 512), width = 0, height = 0 }, Text)
end

-- Replaces what the batch shows: lines is an array of strings (letters are drawn in upper
-- case). background: a dark panel behind the text, in the same batch.
function Text:set(lines, background)
  local batch, glyphs, gw, gh = self.batch, atlas.glyphs, atlas.glyph_w, atlas.glyph_h
  batch:clear()
  local widest = 0
  for row = 1, #lines do
    if #lines[row] > widest then widest = #lines[row] end
  end
  self.width, self.height = widest * gw, #lines * gh
  if background then                       -- the white block of the atlas (6x6), stretched
    batch:setColor(0, 0, 0, 0.6)
    batch:add(atlas.white, -2, -2, 0, (self.width + 3) / 6, (self.height + 3) / 6)
    batch:setColor(1, 1, 1, 1)
  end
  for row = 1, #lines do
    local line = upper(lines[row])
    local y = (row - 1) * gh
    for i = 1, #line do
      local quad = glyphs[byte(line, i)]
      if quad then batch:add(quad, (i - 1) * gw, y) end
    end
  end
  batch:flush()
end

function Text:draw(x, y)
  love.graphics.draw(self.batch, x, y)
end

return Text
