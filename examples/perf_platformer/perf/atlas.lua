-- The one image of the test (tiles.png, written by tools/make_tiles.py) and its quads.
local atlas = { glyph_w = 4, glyph_h = 6 }

function atlas.load()
  if atlas.image then return atlas end
  local g = love.graphics
  local image = g.newImage("tiles.png")
  local w, h = image:getDimensions()
  local function cell(i) return g.newQuad(i * 16, 0, 16, 16, w, h) end
  atlas.image = image
  atlas.solid, atlas.one_way, atlas.background = cell(0), cell(1), cell(2)
  atlas.player = { cell(3), cell(4) }
  atlas.enemy = { cell(5), cell(6) }
  atlas.particle = g.newQuad(112, 0, 8, 8, w, h)
  atlas.white = g.newQuad(121, 1, 6, 6, w, h)
  atlas.glyphs = {}                         -- by byte: ASCII 33..95 (32 is the space)
  for code = 33, 95 do
    local i = code - 32
    atlas.glyphs[code] = g.newQuad((i % 32) * 4, 16 + math.floor(i / 32) * 6, 4, 6, w, h)
  end
  return atlas
end

return atlas
