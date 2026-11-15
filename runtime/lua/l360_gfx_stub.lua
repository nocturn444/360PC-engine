-- l360.gfx sin dibujar (runtime/main.c lo corre antes de boot.lua si la GPU no arranco; va en
-- game:\l360\ con los otros .lua). La misma API que runtime/l360_gfx.c, sin dibujar nada.
-- Cuenta llamadas para que boot.lua (y tests/pc/boot_pc.lua)
-- llegue al bucle principal.
local st = { draws = 0, sends = 0, skipped = 0, dropped = 0, frames = 0, missing_images = 0,
  texture_bytes = 0, image_ms = 0, gpu_wait_ms = 0 }
local function nop() end
local function draw() st.draws = st.draws + 1 end
local function skip() st.skipped = st.skipped + 1 end
local function send() st.sends = st.sends + 1 end
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
  return setmetatable({ w = w / dpi, h = h / dpi, pw = w, ph = h }, Tex)
end
-- Tamano de un PNG: ancho y alto big-endian en los bytes 17 a 24 (cabecera IHDR)
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
-- Segundo resultado: si el shader esta traducido. Sin GPU no hay ninguno.
gfx.newShader = function() return setmetatable({ send = send }, { __index = function() return nop end }), false end
gfx.newFont = function(path, ttf, size)
  size = tonumber(size) or 12
  return setmetatable({ size = size }, { __index = function(_, k)
    if k == "getWidth" then return function(_, s) return #tostring(s or "") * size * 0.44 end end
    if k == "getHeight" then return function() return size end end
    return nop end })
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
gfx.draw, gfx.rectangle, gfx.polygon = draw, draw, draw
for _, k in ipairs({"print", "printf", "line", "circle", "ellipse", "points"}) do gfx[k] = skip end
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
