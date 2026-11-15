-- l360.gfx without drawing (runtime/main.c runs it before boot.lua if the GPU did not start; it goes in
-- game:\l360\ with the other .lua files). Same API as runtime/l360_gfx.c, drawing nothing.
-- Counts calls so that boot.lua (and tests/pc/boot_pc.lua) reaches the main loop, and the
-- vertices each call would send, so the test can tell what was asked. Nothing is batched here:
-- draws and submits are the same number (l360_gfx.c joins submits that share texture and shader).
local st = { draws = 0, submits = 0, verts = 0, sends = 0, skipped = 0, dropped = 0, frames = 0,
  missing_images = 0, particles = 0, texture_bytes = 0, image_ms = 0, gpu_wait_ms = 0 }
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
gfx.newQuad = function(x, y, w, h)
  return setmetatable({ is_quad = true, w = tonumber(w), h = tonumber(h) }, { __index = function() return nop end })
end
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
-- ParticleSystem: the settings are kept as given and the particles are only their remaining
-- lifetimes, emitted and expired as l360_particles.c does (the pool's cap, the emission rate, the
-- emitter's lifetime); they have no position. Drawing one sends 6 vertices per live particle.
local ps_pairs = { ParticleLifetime = true, Speed = true, LinearDamping = true, RadialAcceleration = true,
  TangentialAcceleration = true, Rotation = true, Spin = true }
local ps_areas = { none = true, uniform = true, normal = true, ellipse = true, borderellipse = true, borderrectangle = true }
local ps_inserts = { top = true, bottom = true, random = true }
local ps_seed = 0
local function ps_number(v, what) return (assert(tonumber(v), "ParticleSystem:" .. what .. ": number expected")) end
local function ps_offset(p)
  if p.custom_offset then return end
  local q = p.props.Quads[1]
  if q and q.w then p.props.Offset = { q.w / 2, q.h / 2 } else p.props.Offset = { p.tex.w / 2, p.tex.h / 2 } end
end
local function ps_add(p)
  if #p.life >= p.size then return end
  local min, max = p.props.ParticleLifetime[1], p.props.ParticleLifetime[2]
  p.seed = (p.seed * 1103515245 + 12345) % 2147483648
  p.life[#p.life + 1] = min + (max - min) * (p.seed / 2147483648)
end
local PS = {}
PS.emit = function(p, n)
  n = math.floor(ps_number(n, "emit"))
  if not p.active then return end
  for _ = 1, math.min(n, p.size - #p.life) do ps_add(p) end
end
PS.update = function(p, dt)
  dt = ps_number(dt, "update")
  if dt <= 0 then return end
  local live = {}
  for _, l in ipairs(p.life) do if l - dt > 0 then live[#live + 1] = l - dt end end
  p.life = live
  if not p.active then return end
  local rate = p.props.EmissionRate[1]
  if rate > 0 then
    p.emit_counter = p.emit_counter + dt
    while p.emit_counter > 1 / rate do ps_add(p); p.emit_counter = p.emit_counter - 1 / rate end
  end
  p.emitter_life = p.emitter_life - dt
  if p.props.EmitterLifetime[1] ~= -1 and p.emitter_life < 0 then p:stop() end
end
PS.start = function(p) p.active = true end
PS.pause = function(p) p.active = false end
PS.stop = function(p) p.active = false; p.emitter_life = p.props.EmitterLifetime[1]; p.emit_counter = 0 end
PS.reset = function(p) p.life = {}; p.emitter_life = p.props.EmitterLifetime[1]; p.emit_counter = 0 end
PS.isActive = function(p) return p.active end
PS.isPaused = function(p) return not p.active and p.emitter_life < p.props.EmitterLifetime[1] end
PS.isStopped = function(p) return not p.active and p.emitter_life >= p.props.EmitterLifetime[1] end
PS.getCount = function(p) return #p.life end
PS.getBufferSize = function(p) return p.size end
PS.setBufferSize = function(p, size)
  size = math.floor(ps_number(size, "setBufferSize"))
  assert(size >= 1, "Invalid buffer size")
  p.size = size
  p:reset()
end
PS.setTexture = function(p, tex)
  assert(type(tex) == "table" and tex.is_texture, "Image or Canvas expected")
  p.tex = tex
  ps_offset(p)
end
PS.getTexture = function(p) return p.tex end
PS.moveTo = function(p, x, y) p.props.Position = { ps_number(x, "moveTo"), ps_number(y, "moveTo") } end
PS.setEmitterLifetime = function(p, life)
  p.props.EmitterLifetime = { ps_number(life, "setEmitterLifetime") }
  p.emitter_life = p.props.EmitterLifetime[1]
end
PS.setEmissionRate = function(p, rate)
  rate = ps_number(rate, "setEmissionRate")
  assert(rate >= 0, "Invalid emission rate")
  p.props.EmissionRate = { rate }
  if rate > 0 then p.emit_counter = math.min(p.emit_counter, 1 / rate) end
end
PS.setLinearAcceleration = function(p, xmin, ymin, xmax, ymax)
  xmin, ymin = ps_number(xmin, "setLinearAcceleration"), ps_number(ymin, "setLinearAcceleration")
  p.props.LinearAcceleration = { xmin, ymin, tonumber(xmax) or xmin, tonumber(ymax) or ymin }
end
PS.setSizes = function(p, ...)
  local n = select("#", ...)
  assert(n <= 8, "At most eight (8) sizes may be used.")
  local sizes = {}
  for i = 1, math.max(n, 1) do sizes[i] = ps_number((select(i, ...)), "setSizes") end
  p.props.Sizes = sizes
end
PS.setSizeVariation = function(p, v)
  v = ps_number(v, "setSizeVariation")
  assert(v >= 0 and v <= 1, "Size variation has to be between 0 and 1, inclusive.")
  p.props.SizeVariation = { v }
end
PS.setColors = function(p, ...)
  local args, colors = { ... }, {}
  if type(args[1]) == "table" then
    for i, c in ipairs(args) do
      assert(type(c) == "table" and #c >= 3, "expected 4 color components")
      colors[i] = { ps_number(c[1], "setColors"), ps_number(c[2], "setColors"), ps_number(c[3], "setColors"), tonumber(c[4]) or 1 }
    end
  else
    local n = select("#", ...)
    assert(n == 3 or (n > 0 and n % 4 == 0), "Expected red, green, blue, and alpha.")
    for i = 1, n, 4 do
      colors[#colors + 1] = { ps_number(args[i], "setColors"), ps_number(args[i + 1], "setColors"),
        ps_number(args[i + 2], "setColors"), tonumber(args[i + 3]) or 1 }
    end
  end
  assert(#colors <= 8, "At most eight (8) colors may be used.")
  p.props.Colors = colors
end
PS.setQuads = function(p, first, ...)
  local quads = type(first) == "table" and not first.is_quad and first or { first, ... }
  assert(#quads <= 64, "ParticleSystem:setQuads: at most 64 quads")
  for _, q in ipairs(quads) do assert(type(q) == "table" and q.is_quad, "Quad expected") end
  p.props.Quads = { unpack(quads) }
  ps_offset(p)
end
PS.getQuads = function(p) return { unpack(p.props.Quads) } end
PS.setOffset = function(p, x, y)
  p.props.Offset = { ps_number(x, "setOffset"), ps_number(y, "setOffset") }
  p.custom_offset = true
end
PS.setEmissionArea = function(p, dist, dx, dy, angle, relative)
  dist = dist or "none"
  assert(ps_areas[dist], "Invalid particle distribution: " .. tostring(dist))
  if dist == "none" then p.props.EmissionArea = { "none", 0, 0, 0, false } return end
  dx, dy = ps_number(dx, "setEmissionArea"), ps_number(dy, "setEmissionArea")
  assert(dx >= 0 and dy >= 0, "Invalid area spread parameters (must be >= 0)")
  p.props.EmissionArea = { dist, dx, dy, tonumber(angle) or 0, relative and true or false }
end
PS.setInsertMode = function(p, mode)
  assert(ps_inserts[mode], "Invalid insert mode: " .. tostring(mode))
  p.props.InsertMode = { mode }
end
PS.setRelativeRotation = function(p, on) p.props.RelativeRotation = { on and true or false } end
PS.hasRelativeRotation = function(p) return p.props.RelativeRotation[1] end
PS.type = function() return "ParticleSystem" end
PS.typeOf = function(_, n) return n == "ParticleSystem" or n == "Drawable" or n == "Object" end
PS.release = nop
-- The other setters take one number, or min and max (max is min when left out)
for _, name in ipairs({ "ParticleLifetime", "Position", "Direction", "Spread", "Speed", "LinearDamping",
  "RadialAcceleration", "TangentialAcceleration", "Rotation", "Spin", "SpinVariation" }) do
  PS["set" .. name] = function(p, a, b)
    a = ps_number(a, "set" .. name)
    if name == "Position" then b = ps_number(b, "setPosition") elseif ps_pairs[name] then b = tonumber(b) or a else b = nil end
    if name == "ParticleLifetime" then assert(a >= 0 and b >= 0, "Invalid particle lifetime (must be >= 0)") end
    p.props[name] = { a, b }
  end
end
for _, name in ipairs({ "EmissionRate", "EmitterLifetime", "ParticleLifetime", "Position", "Direction", "Spread", "Speed",
  "LinearAcceleration", "LinearDamping", "RadialAcceleration", "TangentialAcceleration", "Sizes", "SizeVariation",
  "Rotation", "Spin", "SpinVariation", "Offset", "EmissionArea", "InsertMode" }) do
  PS["get" .. name] = function(p) return unpack(p.props[name], 1, name == "EmissionArea" and 5 or nil) end
end
PS.getColors = function(p)
  local out = {}
  for i, c in ipairs(p.props.Colors) do out[i] = { c[1], c[2], c[3], c[4] } end
  return unpack(out)
end
local function ps_make(tex, size, props)
  ps_seed = ps_seed + 1
  local p = setmetatable({ is_particles = true, tex = tex, size = size, life = {}, active = true, emit_counter = 0,
    seed = ps_seed, props = props }, { __index = PS })
  p.emitter_life = props.EmitterLifetime[1]
  return p
end
PS.clone = function(p)
  local props = {}
  for k, v in pairs(p.props) do
    props[k] = {}
    for i, x in pairs(v) do props[k][i] = x end
  end
  local c = ps_make(p.tex, p.size, props)
  c.custom_offset = p.custom_offset
  return c
end
gfx.newParticleSystem = function(tex, size)
  assert(type(tex) == "table" and tex.is_texture, "Image or Canvas expected")
  size = math.floor(tonumber(size) or 1000)
  assert(size >= 1, "Invalid ParticleSystem size")
  local p = ps_make(tex, size, { EmissionRate = { 0 }, EmitterLifetime = { -1 }, ParticleLifetime = { 0, 0 },
    Position = { 0, 0 }, Direction = { 0 }, Spread = { 0 }, Speed = { 0, 0 }, LinearAcceleration = { 0, 0, 0, 0 },
    LinearDamping = { 0, 0 }, RadialAcceleration = { 0, 0 }, TangentialAcceleration = { 0, 0 }, Sizes = { 1 },
    SizeVariation = { 0 }, Rotation = { 0, 0 }, Spin = { 0, 0 }, SpinVariation = { 0 }, Colors = { { 1, 1, 1, 1 } },
    Quads = {}, EmissionArea = { "none", 0, 0, 0, false }, InsertMode = { "top" }, RelativeRotation = { false } })
  ps_offset(p)
  return p
end
-- setBlendMode(mode, alphamode): "alpha" or "add"; boot.lua turns LÖVE's other modes into "alpha"
local blend_mode, blend_alpha = "alpha", "alphamultiply"
gfx.setBlendMode = function(mode, alphamode)
  alphamode = alphamode or "alphamultiply"
  assert(mode == "alpha" or mode == "add", "setBlendMode: invalid blend mode " .. tostring(mode))
  assert(alphamode == "alphamultiply" or alphamode == "premultiplied", "setBlendMode: invalid blend alpha mode " .. tostring(alphamode))
  blend_mode, blend_alpha = mode, alphamode
end
gfx.getBlendMode = function() return blend_mode, blend_alpha end
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
  if type(what) == "table" and what.is_particles then
    st.particles = st.particles + #what.life
    if #what.life > 0 then submit(6 * #what.life) end
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
