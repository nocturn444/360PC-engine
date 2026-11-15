-- l360.gfx without drawing (runtime/main.c runs it before boot.lua if the GPU did not start; it goes in
-- game:\l360\ with the other .lua files). Same API as runtime/l360_gfx.c, drawing nothing.
-- Counts calls so that boot.lua (and tests/pc/boot_pc.lua) reaches the main loop, and the
-- vertices each call would send, so the test can tell what was asked. Nothing is batched here:
-- draws and submits are the same number (l360_gfx.c joins submits that share texture and shader).
local st = { draws = 0, submits = 0, verts = 0, sends = 0, skipped = 0, dropped = 0, frames = 0,
  missing_images = 0, texture_bytes = 0, image_ms = 0, gpu_wait_ms = 0 }
local function nop() end
local function submit(verts)
  st.draws = st.draws + 1; st.submits = st.submits + 1; st.verts = st.verts + verts
end
local function skip() st.skipped = st.skipped + 1 end
local color, line_width = {1, 1, 1, 1}, 1
local Tex = { __index = {
  getWidth = function(s) return s.w end, getHeight = function(s) return s.h end,
  getDimensions = function(s) return s.w, s.h end,
  getPixelWidth = function(s) return s.pw end, getPixelHeight = function(s) return s.ph end,
  getPixelDimensions = function(s) return s.pw, s.ph end,
} }
setmetatable(Tex.__index, { __index = function() return nop end })
local function texture(w, h, dpi)
  dpi = tonumber(dpi) or 1
  return setmetatable({ w = w / dpi, h = h / dpi, pw = w, ph = h, is_texture = true }, Tex)
end
-- Size of a PNG: big-endian width and height in bytes 17 to 24 (IHDR header)
local function png_size(data)
  if type(data) ~= "string" or #data < 24 or data:sub(2, 4) ~= "PNG" then return nil end
  local function u32(o) local a, b, c, d = data:byte(o, o + 3) return ((a * 256 + b) * 256 + c) * 256 + d end
  return u32(17), u32(21)
end
local gfx = {}
gfx.newImage = function(path, data, dpi)
  local t0 = l360.time()
  local w, h = png_size(data)
  if not w then st.missing_images = st.missing_images + 1; w, h = 1, 1 end
  st.texture_bytes = st.texture_bytes + w * h * 4
  st.image_ms = st.image_ms + (l360.time() - t0) * 1000
  return texture(w, h, dpi)
end
gfx.newCanvas = function(w, h) w, h = tonumber(w) or 1280, tonumber(h) or 720 return texture(w, h, 1) end
gfx.newQuad = function() return setmetatable({}, { __index = function() return nop end }) end
-- newShader(name, meta), like l360_gfx.c: meta is the table of shaders/<name>.meta.lua, or nil if
-- the shader was not built. Second result: whether the shader's own program is in use (never
-- without a GPU, but the uniforms are still checked against the metadata).
local missing_uniforms = {}
gfx.newShader = function(name, meta)
  local uniforms = type(meta) == "table" and meta.uniforms or nil
  local sh = {}
  sh.send = function(_, uniform)
    st.sends = st.sends + 1
    local key = tostring(name) .. ": uniform " .. tostring(uniform)
    if uniforms and not uniforms[uniform] and not missing_uniforms[key] then
      missing_uniforms[key] = true
      l360.log("  [missing] shader " .. key)
    end
  end
  sh.sendColor = sh.send
  sh.hasUniform = function(_, uniform) return uniforms ~= nil and uniforms[uniform] ~= nil end
  return setmetatable(sh, { __index = function() return nop end }), false
end
-- Fonts measure 0.44 of their size per byte. Text is a string, a number or a coloured text table.
local function plain(text)
  if type(text) ~= "table" then return tostring(text or "") end
  local out = {}
  for i = 1, #text do if type(text[i]) ~= "table" then out[#out + 1] = tostring(text[i]) end end
  return table.concat(out)
end
-- Lines as l360_gfx.c splits them: at \n, and (with a limit) before the character that would go
-- past it, back at the line's last space if it has one. Returns the widest width and the lines.
local function wrap(text, adv, limit)
  local s = plain(text)
  local lines, width = {}, 0
  local function push(a, b, w)
    lines[#lines + 1] = s:sub(a, b)
    if w > width then width = w end
  end
  local i, n = 1, #s
  while true do
    local start, space, w, w_space = i, nil, 0, 0
    while i <= n and s:byte(i) ~= 10 do
      local c = s:byte(i)
      if limit and w + adv > limit and c ~= 32 and i > start then
        if space then push(start, space - 1, w_space); i = space + 1 else push(start, i - 1, w) end
        start, space, w = i, nil, 0
      else
        if c == 32 then space, w_space = i, w end
        w = w + adv
        i = i + 1
      end
    end
    push(start, i - 1, w)
    if i > n then break end
    i = i + 1
  end
  return width, lines
end
gfx.newFont = function(path, ttf, size)
  size = tonumber(size) or 12
  local line_height = 1
  return setmetatable({ size = size, is_font = true }, { __index = function(_, k)
    if k == "getWidth" then return function(_, s) return (wrap(s, size * 0.44)) end end
    if k == "getWrap" then return function(_, s, limit) return wrap(s, size * 0.44, tonumber(limit)) end end
    if k == "getHeight" then return function() return size end end
    if k == "getAscent" or k == "getBaseline" then return function() return size * 0.75 end end
    if k == "getDescent" then return function() return -size * 0.25 end end
    if k == "getLineHeight" then return function() return line_height end end
    if k == "setLineHeight" then return function(_, h) line_height = tonumber(h) or 1 end end
    if k == "hasGlyphs" then return function() return true end end
    return nop end })
end
-- print(font, text, x, y, ...) and printf(font, text, x, y, limit, align, ...): 6 vertices per
-- character that is not a space; without a font, not drawn
local function glyphs(lines)
  local n = 0
  for _, l in ipairs(lines) do n = n + #l:gsub("%s", "") end
  return n
end
gfx.print = function(font, text)
  if type(font) ~= "table" or not font.is_font then return skip() end
  local _, lines = wrap(text, font.size * 0.44)
  local n = glyphs(lines)
  if n > 0 then submit(6 * n) end
end
gfx.printf = function(font, text, x, y, limit, align)
  if type(font) ~= "table" or not font.is_font then return skip() end
  assert(tonumber(limit), "printf: limit expected")
  align = align or "left"
  assert(align == "left" or align == "center" or align == "right" or align == "justify", "printf: bad align")
  local _, lines = wrap(text, font.size * 0.44, math.max(0, limit))
  local n = glyphs(lines)
  if n > 0 then submit(6 * n) end
end
-- SpriteBatch: only the count; drawing it sends 6 vertices per sprite
local Batch = { __index = {
  add = function(b, ...) b.count = b.count + 1; if b.count > b.size then b.size = b.size * 2 end return b.count end,
  set = function(b, id) assert(type(id) == "number" and id >= 1 and id <= b.count, "SpriteBatch:set: no such sprite") end,
  clear = function(b) b.count = 0 end, flush = nop,
  getCount = function(b) return b.count end, getBufferSize = function(b) return b.size end,
  setColor = function(b, r, g, bl, a)
    if type(r) == "table" then r, g, bl, a = r[1], r[2], r[3], r[4] end
    b.color = { tonumber(r) or 1, tonumber(g) or 1, tonumber(bl) or 1, tonumber(a) or 1 }
  end,
  getColor = function(b) return b.color[1], b.color[2], b.color[3], b.color[4] end,
  setTexture = function(b, tex) assert(type(tex) == "table" and tex.is_texture, "Image or Canvas expected"); b.tex = tex end,
  getTexture = function(b) return b.tex end,
  type = function() return "SpriteBatch" end,
  typeOf = function(_, n) return n == "SpriteBatch" or n == "Drawable" or n == "Object" end,
  release = nop,
} }
gfx.newSpriteBatch = function(tex, size)
  assert(type(tex) == "table" and tex.is_texture, "Image or Canvas expected")
  return setmetatable({ is_batch = true, tex = tex, count = 0, size = math.max(1, math.floor(tonumber(size) or 1000)),
    color = { 1, 1, 1, 1 } }, Batch)
end
gfx.newText = function()
  return setmetatable({}, { __index = function(_, k)
    if k == "getWidth" or k == "getHeight" then return function() return 10 end end
    if k == "getDimensions" then return function() return 10, 10 end end
    return nop end })
end
gfx.setColor = function(r, g, b, a)
  if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
  color[1], color[2], color[3], color[4] = tonumber(r) or 1, tonumber(g) or 1, tonumber(b) or 1, tonumber(a) or 1
end
gfx.getColor = function() return color[1], color[2], color[3], color[4] end
gfx.setLineWidth = function(w) line_width = tonumber(w) or 1 end
gfx.getLineWidth = function() return line_width end
local point_size = 1
gfx.setPointSize = function(s) point_size = tonumber(s) or 1 end
gfx.getPointSize = function() return point_size end
gfx.draw = function(what)
  if type(what) == "table" and what.is_batch then
    if what.count > 0 then submit(6 * what.count) end
    return
  end
  submit(6)
end
-- How many points the arguments from `first` on hold (numbers, or one table of them)
local function count_points(first, ...)
  if type(first) == "table" then return math.floor(#first / 2) end
  return math.floor(select("#", first, ...) / 2)
end
gfx.rectangle = function(mode) submit(mode == "fill" and 6 or 24) end
gfx.polygon = function(mode, ...)
  local np = count_points(...)
  if np >= 3 then submit(mode == "fill" and 3 * (np - 2) or 6 * np) end
end
-- line: 6 vertices per segment; a line that ends where it starts is closed, as in l360_gfx.c
gfx.line = function(...)
  local np = count_points(...)
  if np >= 2 then submit(6 * (np - 1)) end
end
local function ellipse(mode, rx, ry, segs)
  segs = math.floor(tonumber(segs) or 0)
  if segs <= 0 then segs = math.max(8, math.floor(math.sqrt((math.abs(rx) + math.abs(ry)) * 0.5 * 20))) end
  segs = math.min(math.max(segs, 3), 510)
  submit(mode == "fill" and 3 * segs or 6 * segs)
end
gfx.circle = function(mode, x, y, r, segs) ellipse(mode, tonumber(r) or 0, tonumber(r) or 0, segs) end
gfx.ellipse = function(mode, x, y, rx, ry, segs) ellipse(mode, tonumber(rx) or 0, tonumber(ry) or 0, segs) end
gfx.points = function(first, ...)
  local np = type(first) == "table" and type(first[1]) == "table" and #first or count_points(first, ...)
  if np > 0 then submit(6 * np) end
end
for _, k in ipairs({"setShader", "clear", "push", "pop", "origin", "translate", "scale", "rotate", "shear",
  "setCanvas", "setDefaultFilter", "sync"}) do gfx[k] = nop end
gfx.present = function() st.frames = st.frames + 1 end
gfx.getWidth = function() return 1280 end
gfx.getHeight = function() return 720 end
gfx.getDimensions = function() return 1280, 720 end
gfx.getPixelDimensions = function() return 1280, 720 end
gfx.getStats = function() return { drawcalls = st.draws, texturememory = st.texture_bytes } end
l360.gfx = gfx
l360.gfxstats = function()
  local t = {}
  for k, v in pairs(st) do t[k] = v end
  return t
end
