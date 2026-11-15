-- Love360 P4: Balatro dibujado en la Xbox 360.
-- love.graphics viene de C (l360.gfx, sobre Xenos); el resto de LOVE se arma aca.
-- Mando manual por defecto; modo bot seleccionable para medir rendimiento.
-- Sonido en Lua; guardado de partidas en el pendrive de la consola (love360_save.lua).
--
-- Funciones que pone el programa en C (tabla l360):
--   l360.time()        segundos con alta resolucion
--   l360.read(path)    contenido de un archivo del juego, o nil
--   l360.log(s)        imprime una linea (pantalla en la 360)
--   l360.platform      'pc' o 'xbox360'

local l360 = l360
local now = l360.time
local log = l360.log

local W, H = l360.width or 1280, l360.height or 720
local DT = 1 / 30
local gfx = l360.gfx
-- Configuracion: cambiar mode a "bot" para la partida de prueba.
-- El shim puede sobrescribirla sin editar este archivo.
local input_config = l360.input_config or {mode = "manual", deadzone = 0.2}

---------------------------------------------------------------------------
-- Lista de archivos del juego (en la 360 no se puede listar por TFTP)
---------------------------------------------------------------------------
local DIRS = {
  ["resources/shaders"] = {"background.fs","booster.fs","CRT.fs","debuff.fs","dissolve.fs","flame.fs",
    "flash.fs","foil.fs","gold_seal.fs","holo.fs","hologram.fs","negative_shine.fs","negative.fs",
    "played.fs","polychrome.fs","skew.fs","splash.fs","vortex.fs","voucher.fs"},
  ["resources/sounds"] = {"ambientFire1.ogg","ambientFire2.ogg","ambientFire3.ogg","ambientOrgan1.ogg",
    "button.ogg","cancel.ogg","card1.ogg","card3.ogg","cardFan2.ogg","cardSlide1.ogg","cardSlide2.ogg",
    "chips1.ogg","chips2.ogg","coin1.ogg","coin2.ogg","coin3.ogg","coin4.ogg","coin5.ogg","coin6.ogg",
    "coin7.ogg","crumple1.ogg","crumple2.ogg","crumple3.ogg","crumple4.ogg","crumple5.ogg",
    "crumpleLong1.ogg","crumpleLong2.ogg","explosion_buildup1.ogg","explosion_release1.ogg",
    "explosion1.ogg","foil1.ogg","foil2.ogg","generic1.ogg","glass1.ogg","glass2.ogg","glass3.ogg",
    "glass4.ogg","glass5.ogg","glass6.ogg","gold_seal.ogg","gong.ogg","highlight1.ogg","highlight2.ogg",
    "holo1.ogg","introPad1.ogg","magic_crumple.ogg","magic_crumple2.ogg","magic_crumple3.ogg",
    "multhit1.ogg","multhit2.ogg","music1.ogg","music2.ogg","music3.ogg","music4.ogg","music5.ogg",
    "negative.ogg","other1.ogg","paper1.ogg","polychrome1.ogg","slice1.ogg","splash_buildup.ogg",
    "tarot1.ogg","tarot2.ogg","timpani.ogg","voice1.ogg","voice10.ogg","voice11.ogg","voice2.ogg",
    "voice3.ogg","voice4.ogg","voice5.ogg","voice6.ogg","voice7.ogg","voice8.ogg","voice9.ogg",
    "whoosh_long.ogg","whoosh.ogg","whoosh1.ogg","whoosh2.ogg","win.ogg"},
}
-- Archivos que existen aunque no los bajemos (fuentes: solo hace falta saber que estan)
local KNOWN = {}
for _, f in ipairs({"m6x11plus.ttf","GoNotoCJKCore.ttf","GoNotoCurrent-Bold.ttf","NotoSans-Bold.ttf",
  "NotoSansJP-Bold.ttf","NotoSansKR-Bold.ttf","NotoSansSC-Bold.ttf","NotoSansTC-Bold.ttf"}) do
  KNOWN["resources/fonts/" .. f] = true
end
for d, list in pairs(DIRS) do for _, f in ipairs(list) do KNOWN[d .. "/" .. f] = true end end

local file_cache = {}
local function game_file(path)
  path = path:gsub("^%./", "")
  local c = file_cache[path]
  if c == nil then
    c = l360.read(path) or false
    file_cache[path] = c
  end
  return c or nil
end

---------------------------------------------------------------------------
-- Estadisticas
---------------------------------------------------------------------------
local S = { draws = 0, sends = 0, xform = 0, texts = 0 }
local missing = {}
local function note_missing(name)
  if not missing[name] then missing[name] = true; log("  [missing] " .. name) end
end

local function nop() end
local function module(name, t)
  return setmetatable(t, { __index = function(_, k)
    note_missing(name .. "." .. k); return nop end })
end
local function object(kind, t)
  return setmetatable(t, { __index = function(_, k)
    note_missing(kind .. ":" .. k); return nop end })
end

---------------------------------------------------------------------------
-- Fuentes y texto (metricas reales de m6x11plus)
---------------------------------------------------------------------------
local FM = assert(loadstring(assert(l360.read("love360/font_metrics.lua"), "missing font_metrics.lua")))()
local function text_width(s, size)
  local w = 0
  for i = 1, #s do w = w + (FM.adv[s:byte(i)] or 448) end
  return w * size / FM.upm
end
local function flatten(t)
  if type(t) ~= "table" then return tostring(t or "") end
  local out = {}
  for i = 1, #t do if type(t[i]) == "string" then out[#out + 1] = t[i] end end
  return table.concat(out)
end

local function new_font(_, size)
  size = tonumber(size) or 12
  local f
  f = object("Font", {
    getWidth = function(_, s) return text_width(tostring(s or ""), size) end,
    getHeight = function() return size end,
    getLineHeight = function() return 1 end,
    setLineHeight = nop, setFilter = nop, getBaseline = function() return size * 0.75 end,
    getAscent = function() return size * 0.75 end, getDescent = function() return -size * 0.25 end,
    getWrap = function(_, s, limit) return text_width(flatten(s), size), { flatten(s) } end,
    hasGlyphs = function() return true end, setFallbacks = nop, release = nop,
    type = function() return "Font" end, typeOf = function() return false end,
  })
  f._size = size
  return f
end

local function new_text(font, s)
  S.texts = S.texts + 1
  local size = font and font._size or 12
  local str = flatten(s)
  local t
  t = object("Text", {
    getWidth = function() return text_width(str, size) end,
    getHeight = function() return size end,
    getDimensions = function() return text_width(str, size), size end,
    set = function(_, v) str = flatten(v) end,
    setf = function(_, v) str = flatten(v) end,
    add = function() return 1 end, clear = function() str = "" end, release = nop,
    getFont = function() return font end,
  })
  return t
end

---------------------------------------------------------------------------
-- Imagenes: tamano leido del encabezado PNG
---------------------------------------------------------------------------
local function png_size(data)
  if not data or #data < 24 then return 64, 64 end
  local function u32(o) local a, b, c, d = data:byte(o, o + 3); return ((a * 256 + b) * 256 + c) * 256 + d end
  return u32(17), u32(21)
end
local function new_image(path, opts)
  local w, h = png_size(game_file(path))
  local dpi = (opts and opts.dpiscale) or 1
  w, h = w / dpi, h / dpi
  return object("Image", {
    getWidth = function() return w end, getHeight = function() return h end,
    getDimensions = function() return w, h end,
    getPixelWidth = function() return w * dpi end, getPixelHeight = function() return h * dpi end,
    setFilter = nop, setWrap = nop, setMipmapFilter = nop, release = nop,
    getDPIScale = function() return dpi end,
  })
end
local function new_canvas(w, h)
  w, h = w or W, h or H
  return object("Canvas", {
    getWidth = function() return w end, getHeight = function() return h end,
    getDimensions = function() return w, h end, setFilter = nop, release = nop,
    getPixelWidth = function() return w end, getPixelHeight = function() return h end,
    getPixelDimensions = function() return w, h end,
    renderTo = function(_, f) f() end,
  })
end
local function new_shader()
  return object("Shader", {
    send = function() S.sends = S.sends + 1 end,
    hasUniform = function() return true end, release = nop,
  })
end
local function new_quad(x, y, w, h)
  return object("Quad", { getViewport = function() return x, y, w, h end, setViewport = function(_, a, b, c, d) x, y, w, h = a, b, c, d end, release = nop })
end

local function count_draw() S.draws = S.draws + 1 end
local function count_xform() S.xform = S.xform + 1 end

---------------------------------------------------------------------------
-- Canales e hilos: los de sonido y guardado corren como corrutina en el hilo principal
---------------------------------------------------------------------------
local channels = {}
local threads = {}
local function get_channel(name)
  local c = channels[name]
  if c then return c end
  local q = {}
  c = object("Channel", {
    push = function(_, v) if #q < 256 then q[#q + 1] = v end return #q end,
    supply = function(_, v) if #q < 256 then q[#q + 1] = v end return true end,
    pop = function() return table.remove(q, 1) end,
    demand = function()
      local v = table.remove(q, 1)
      if v ~= nil then return v end
      if coroutine.running() then coroutine.yield() end
      return nil
    end,
    peek = function() return q[1] end,
    getCount = function() return #q end,
    clear = function() q = {} end,
  })
  channels[name] = c
  return c
end

-- El hilo de sonido de Balatro es un archivo con un while true. Se carga como
-- corrutina: cuando no hay pedidos, demand() hace yield y el bucle principal
-- lo despierta una vez por frame. Lo mismo con save_manager.lua (guardado). Los demas hilos siguen siendo falsos.
local function new_thread(path)
  if type(path) ~= "string" or not (path:match("sound_manager%.lua$") or path:match("save_manager%.lua$")) then
    return object("Thread", { start = nop, wait = nop,
      isRunning = function() return false end, getError = nop })
  end
  local src = game_file(path)
  local fn, err = src and loadstring(src, "@" .. path)
  if not fn then
    log("  [thread] could not load " .. path .. ": " .. tostring(err))
    return object("Thread", { start = nop, wait = nop,
      isRunning = function() return false end, getError = function() return err end })
  end
  -- En LOVE cada hilo tiene sus propios globales. Sin esto, SOURCES y las
  -- funciones PLAY_SOUND/MODULATE del hilo pisarian las del hilo principal.
  if setfenv then setfenv(fn, setmetatable({}, { __index = _G })) end
  local co = coroutine.create(fn)
  local t
  t = object("Thread", {
    start = function(_, ...)
      if t._co and coroutine.status(t._co) == "suspended" then
        local ok, e = coroutine.resume(t._co, ...)
        if not ok then t._error = e; t._co = nil
          log("  [thread] ERROR in " .. path .. ": " .. tostring(e)) end
      end
      return true
    end,
    wait = nop,
    isRunning = function() return t._co ~= nil and coroutine.status(t._co) == "suspended" end,
    getError = function() return t._error end,
  })
  t._co = co
  t._saver = path:match("save_manager%.lua$") ~= nil
  threads[#threads + 1] = t
  return t
end

local function threads_step()
  for i = 1, #threads do
    local t = threads[i]
    local co = t._co
    if co and coroutine.status(co) == "suspended" then
      local t0 = l360.time()
      local ok, err = coroutine.resume(co)
      -- tarea 12: cuanto tarda el hilo de guardado de Balatro (save_run: armar el texto y escribirlo)
      local ms = (l360.time() - t0) * 1000
      if t._saver and ms > 20 then log(string.format("  [save] save_manager: %.0f ms this frame", ms)) end
      if not ok then
        t._error = err
        t._co = nil
        log("  [thread] ERROR: " .. tostring(err))
      end
    end
  end
end

---------------------------------------------------------------------------
-- Guardados: los .jkr de Balatro van al pendrive (love360_save.lua); el resto, en memoria
---------------------------------------------------------------------------
local save = {}     -- ruta -> contenido
local save_dirs = {}
local Save = assert(loadstring(assert(l360.read("love360/love360_save.lua"),
  "missing love360/love360_save.lua"), "@love360_save.lua"))()
local save_backend, save_where = Save.backend(l360, l360.read("love360/guardado.txt"))
local saves = Save.new(save_backend, log, l360.time)
log("  [save] at " .. save_where)
local function persistent(path) return path:match("%.jkr$") ~= nil end

local function fs_info(path)
  path = path:gsub("^%./", "")
  if persistent(path) then
    local d = saves.read(path)
    return d and { type = "file", size = #d, modtime = 0 } or nil
  end
  if save[path] then return { type = "file", size = #save[path], modtime = 0 } end
  if save_dirs[path] or saves.isdir(path) then return { type = "directory", size = 0, modtime = 0 } end
  if DIRS[path] then return { type = "directory", size = 0, modtime = 0 } end
  if KNOWN[path] then return { type = "file", size = 1, modtime = 0 } end
  if path:match("%.lua$") or path:match("%.png$") then
    local d = game_file(path)
    if d then return { type = "file", size = #d, modtime = 0 } end
  end
  return nil
end

---------------------------------------------------------------------------
-- Audio: love.sound y love.audio sobre l360.audio
---------------------------------------------------------------------------
local audio_driver = l360.audio
local sound_cache, sound_missing = {}, {}
local active_sources = setmetatable({}, {__mode = "k"})

local function u16(s, p)
  local a, b = s:byte(p, p + 1)
  if not b then return nil end
  return a + b * 256
end
local function u32(s, p)
  local a, b, c, d = s:byte(p, p + 3)
  if not d then return nil end
  return a + b * 256 + c * 65536 + d * 16777216
end

-- Devuelve desde (bytes, base 0 como newbuffer), bytes, canales, frecuencia y
-- frames de un WAV PCM 16 bits o IMA ADPCM mono; en ADPCM, ademas block_align.
local function parse_wav(data)
  if type(data) ~= "string" or #data < 12 or data:sub(1, 4) ~= "RIFF"
      or data:sub(9, 12) ~= "WAVE" then
    return nil, "no es un WAV"
  end
  local fmt, fact, data_pos, data_size
  local pos = 13
  while pos + 8 <= #data do
    local id = data:sub(pos, pos + 3)
    local size = u32(data, pos + 4)
    if not size then break end
    local body = pos + 8
    if id == "fmt " then
      if body + 15 <= #data then
        fmt = { format = u16(data, body), channels = u16(data, body + 2),
          rate = u32(data, body + 4), block_align = u16(data, body + 12), bits = u16(data, body + 14) }
      end
    elseif id == "fact" then
      fact = u32(data, body)
    elseif id == "data" then
      local from = body - 1
      local available = #data - from
      if available < 0 then available = 0 end
      data_pos = from
      data_size = math.min(size, available)
    end
    pos = body + size + (size % 2)
  end
  if not fmt then return nil, "no fmt chunk" end
  if not data_pos or not data_size or data_size < 2 then return nil, "no data chunk" end
  if fmt.format == 0x11 then
    -- IMA ADPCM: bloques de block_align bytes con 1 + 2 * (block_align - 4) frames (mono)
    if fmt.channels ~= 1 then return nil, "ADPCM must be mono" end
    if fmt.bits ~= 4 then return nil, "ADPCM must be 4-bit" end
    local ba = fmt.block_align or 0
    if ba < 8 or ba > 8192 then return nil, "block_align out of range" end
    if not fmt.rate or fmt.rate < 4000 or fmt.rate > 96000 then return nil, "sample rate out of range" end
    local spb = 1 + 2 * (ba - 4)
    local whole, rest = math.floor(data_size / ba), data_size % ba
    local frames = whole * spb + (rest >= 4 and 1 + 2 * (rest - 4) or 0)
    if fact and fact > 0 and fact < frames then frames = fact end
    if frames <= 0 then return nil, "no samples" end
    data_size = math.min(data_size, math.ceil(frames / spb) * ba)
    return data_pos, data_size, 1, fmt.rate, frames, ba
  end
  if fmt.format ~= 1 then return nil, "no es PCM" end
  if fmt.channels ~= 1 and fmt.channels ~= 2 then return nil, "channels must be 1 or 2" end
  if fmt.bits ~= 16 then return nil, "must be 16-bit" end
  if not fmt.rate or fmt.rate < 4000 or fmt.rate > 96000 then return nil, "sample rate out of range" end
  local frame_bytes = 2 * fmt.channels
  data_size = data_size - (data_size % frame_bytes)
  if data_size <= 0 then return nil, "no samples" end
  return data_pos, data_size, fmt.channels, fmt.rate, math.floor(data_size / frame_bytes)
end

local SoundMethods = {}
local SoundMT = { __index = function(_, k)
  local f = SoundMethods[k]
  if f then return f end
  if k:sub(1, 1) ~= "_" then note_missing("SoundData:" .. k) end
  return nil
end }
function SoundMethods:getDuration() return self._duration or 0 end
function SoundMethods:getSampleRate() return self._rate or 0 end
function SoundMethods:getChannelCount() return self._channels or 0 end
function SoundMethods:getSampleCount() return self._frames or 0 end
function SoundMethods:getBitDepth() return 16 end
function SoundMethods:release() end

-- Buffer ADPCM entero (efectos largos): newstream con su tamano final y un solo append
local function new_adpcm_buffer(data, rate, ba, frames, from, bytes)
  local b = audio_driver.newstream(1, rate, ba, frames)
  b:append(data, from, bytes)
  return b
end

local function make_sound_data(data, path)
  local from, bytes, channels, rate, frames, ba = parse_wav(data)
  if not from then
    log("  [sound] " .. (path or "data") .. ": " .. tostring(bytes))
    return nil
  end
  local buffer
  if audio_driver and audio_driver.newbuffer then
    local ok, b
    if ba then
      ok, b = pcall(new_adpcm_buffer, data, rate, ba, frames, from, bytes)
    else
      ok, b = pcall(audio_driver.newbuffer, data, channels, rate, from, bytes)
    end
    if ok then
      buffer = b
    else
      log("  [audio] could not create the buffer for " .. (path or "data") .. ": " .. tostring(b))
    end
  else
    log("  [audio] missing l360.audio")
  end
  return setmetatable({ _buffer = buffer, _frames = frames, _channels = channels,
    _rate = rate, _duration = frames / rate, _path = path }, SoundMT)
end

local function norm_path(path)
  local p = tostring(path):gsub("^%./", "")
  return p
end

-- El juego sigue pidiendo .ogg porque asi esta en su lista. La herramienta de
-- PC deja .wav con el mismo nombre base; probamos primero el .wav para no pedir
-- por TFTP un .ogg que no existe. Asi no hace falta tocar el codigo de Balatro.
local function read_sound(path)
  if path:match("%.ogg$") then
    local wav = l360.read((path:gsub("%.ogg$", ".wav")))
    if wav and wav:sub(1, 4) ~= "OggS" then return wav end
    local ogg = l360.read(path)
    if ogg and ogg:sub(1, 4) ~= "OggS" then return ogg end
    if ogg or wav then return nil, "OGG not converted" end
    return nil, "no existe"
  end
  local data = l360.read(path)
  if data and data:sub(1, 4) ~= "OggS" then return data end
  if data then return nil, "OGG not converted" end
  return nil, "no existe"
end

local function load_sound_data(path)
  path = norm_path(path)
  local cached = sound_cache[path]
  if cached ~= nil then return cached or nil end
  local data, why = read_sound(path)
  if not data then
    sound_cache[path] = false
    if not sound_missing[path] then
      sound_missing[path] = true
      log("  [missing sound] " .. path .. " (" .. tostring(why) .. ")")
    end
    return nil
  end
  local sd = make_sound_data(data, path)
  sound_cache[path] = sd or false
  return sd
end

local function new_sound_data(source)
  if type(source) == "table" and getmetatable(source) == SoundMT then return source end
  if type(source) ~= "string" then return nil end
  if source:sub(1, 4) == "RIFF" then return make_sound_data(source, "datos") end
  return load_sound_data(source)
end

---------------------------------------------------------------------------
-- Musica en segundo plano: IMA ADPCM partido en trozos (herramientas/pc/14_convertir_sonidos.bat)
-- musicN.idx dice el tamano total; los trozos musicN.p000.wav, p001... se bajan con
-- l360.fetch_* en el tiempo libre de cada frame, en orden "trozo 0 de todas las pistas,
-- trozo 1 de todas...", y se agregan al buffer con append. Si Balatro pide tocar una pista
-- antes de que esten los trozos 0 de todas, el pedido espera y arrancan todas juntas.
---------------------------------------------------------------------------
local streams = {}            -- pistas en el orden en que se crearon
local stream_cache = {}       -- ruta -> SoundData de la pista
local pending_plays = {}      -- Sources que esperan los trozos 0
local streams_started = false
local fetch_id, fetch_track, fetch_part, fetch_tries = nil, nil, nil, 0
local start_voice

local function read_idx(path)
  local base = path:gsub("%.[^./]*$", "")
  local txt = l360.read(base .. ".idx")
  if not txt then return nil end
  local idx = {}
  for k, v in txt:gmatch("([%w_]+)%s*=%s*(%d+)") do idx[k] = tonumber(v) end
  if not (idx.rate and idx.channels and idx.block_align and idx.frames and idx.parts) then
    log("  [music] " .. base .. ".idx incomplete")
    return nil
  end
  idx.base = base
  return idx
end

local function new_stream_data(path)
  local cached = stream_cache[path]
  if cached ~= nil then return cached or nil end
  stream_cache[path] = false
  if not (audio_driver and audio_driver.newstream) then return nil end
  local idx = read_idx(path)
  if not idx then return nil end
  local ok, b = pcall(audio_driver.newstream, idx.channels, idx.rate, idx.block_align, idx.frames)
  if not ok then
    log("  [music] could not create the buffer for " .. path .. ": " .. tostring(b))
    return nil
  end
  local track = { path = path, base = idx.base, buf = b, parts = idx.parts, next = 0,
    bytes = 0, t0 = now(), failed = false }
  streams[#streams + 1] = track
  local sd = setmetatable({ _buffer = b, _frames = idx.frames, _channels = idx.channels,
    _rate = idx.rate, _duration = idx.frames / idx.rate, _path = path, _stream = track }, SoundMT)
  stream_cache[path] = sd
  return sd
end

-- Listas para arrancar: todas las pistas creadas tienen su trozo 0 (o fallaron)
local function streams_ready()
  for i = 1, #streams do
    local t = streams[i]
    if not t.failed and t.next == 0 then return false end
  end
  return true
end

local function release_pending()
  if #pending_plays == 0 or not streams_ready() then return end
  streams_started = true
  local list = pending_plays
  pending_plays = {}
  for i = 1, #list do
    local src = list[i]
    local want = src._pending
    src._pending = nil
    if want == "play" or want == "pause" then
      if start_voice(src) and want == "pause" then audio_driver.pause(src._voice, true) end
    end
  end
end

local function stream_part_name(t, i)
  return string.format("%s.p%03d.wav", t.base, i)
end

local function stream_add_part(t, data)
  local from, bytes, _, _, _, ba = parse_wav(data)
  if not from or not ba then error("invalid chunk: " .. tostring(bytes)) end
  t.buf:append(data, from, bytes)
end

local function stream_fail(t, why)
  t.failed = true
  log("  [music] " .. t.base .. ": stopped loading at chunk " .. t.next .. " (" .. tostring(why) .. ")")
end

-- Baja trozos hasta el instante `deadline` (segundos de l360.time). Una vez por frame,
-- antes de l360.wait_frame: usa el tiempo que sobra del frame y no se pasa.
local function streams_step(deadline)
  if #streams == 0 or not l360.fetch_start then return end
  while true do
    if not fetch_id then
      local best
      for i = 1, #streams do
        local t = streams[i]
        if not t.failed and t.next < t.parts and (not best or t.next < best.next) then best = t end
      end
      if not best then return end
      local id, err = l360.fetch_start(stream_part_name(best, best.next))
      if not id then stream_fail(best, err); return end
      fetch_id, fetch_track, fetch_part = id, best, best.next
    end
    local ms = (deadline - now()) * 1000 - 1
    if ms <= 0 then return end
    local r, err = l360.fetch_step(fetch_id, ms)
    if r == "pendiente" then return end
    local t = fetch_track
    fetch_id = nil
    if r then
      fetch_tries = 0
      local ok, e = pcall(stream_add_part, t, r)
      if not ok then
        stream_fail(t, e)
      else
        t.bytes = t.bytes + #r
        t.next = fetch_part + 1
        if t.next == t.parts then
          log(string.format("  [music] %s complete: %d chunks, %.1f MB in %.1f s",
            t.base, t.parts, t.bytes / 1048576, now() - t.t0))
        end
      end
      release_pending()
    else
      fetch_tries = fetch_tries + 1
      if fetch_tries >= 3 then fetch_tries = 0; stream_fail(t, err); release_pending() end
    end
  end
end

local SourceMethods = {}
local SourceMT = { __index = function(_, k)
  local f = SourceMethods[k]
  if f then return f end
  if k:sub(1, 1) ~= "_" then note_missing("Source:" .. k) end
  return nil
end }
local new_source

local function voice_state(self)
  if not self._voice then return nil end
  local st = audio_driver and audio_driver.state(self._voice) or "stopped"
  if st == "stopped" then
    self._voice = nil
    self._start_frame = 0
    active_sources[self] = nil
    return nil
  end
  return st
end

start_voice = function(self)
  if not self._data or not self._data._buffer or not audio_driver then return false end
  local id = audio_driver.play(self._data._buffer, self._volume, self._pitch,
    self._loop, self._start_frame or 0)
  if not id then
    if not self._play_failed then
      self._play_failed = true
      log("  [audio] no free voices for " .. (self._path or "a sound"))
    end
    return false
  end
  self._play_failed = false
  self._voice = id
  self._start_frame = 0
  active_sources[self] = true
  return true
end

function SourceMethods:play()
  if self._released then return false end
  if self._pending == "play" then return true end
  local st = voice_state(self)
  if st == "playing" then return true end
  if st == "paused" then
    if audio_driver then audio_driver.pause(self._voice, false) end
    active_sources[self] = true
    return true
  end
  local d = self._data
  if d and d._stream and not streams_started and not streams_ready() then
    -- musica: esperar los trozos 0 de todas las pistas y arrancar todas juntas
    if self._pending == nil then pending_plays[#pending_plays + 1] = self end
    self._pending = "play"
    active_sources[self] = true
    return true
  end
  return start_voice(self)
end

function SourceMethods:stop()
  if self._pending then self._pending = "stop" end   -- release_pending lo saltea
  if self._voice and audio_driver then audio_driver.stop(self._voice) end
  self._voice = nil
  self._start_frame = 0
  active_sources[self] = nil
  return true
end

function SourceMethods:pause()
  if self._pending == "play" then self._pending = "pause"; return true end
  if voice_state(self) == "playing" and audio_driver then
    audio_driver.pause(self._voice, true)
    return true
  end
  return false
end

function SourceMethods:resume()
  if self._pending == "pause" then self._pending = "play"; return true end
  if voice_state(self) == "paused" and audio_driver then
    audio_driver.pause(self._voice, false)
    active_sources[self] = true
    return true
  end
  return false
end

function SourceMethods:isPlaying()
  if self._pending == "play" then return true end
  return voice_state(self) == "playing"
end

function SourceMethods:setVolume(v)
  self._volume = math.max(0, math.min(1, tonumber(v) or 0))
  if self._voice and audio_driver then audio_driver.set(self._voice, self._volume, nil, nil) end
end

function SourceMethods:getVolume() return self._volume end

function SourceMethods:setPitch(v)
  local p = tonumber(v) or 1
  if p <= 0 then p = 1 end -- l360.audio cuenta 0 o negativo como 1
  self._pitch = math.min(16, p)
  if self._voice and audio_driver then audio_driver.set(self._voice, nil, self._pitch, nil) end
end

function SourceMethods:getPitch() return self._pitch end

function SourceMethods:setLooping(v)
  self._loop = v and true or false
  if self._voice and audio_driver then audio_driver.set(self._voice, nil, nil, self._loop) end
end

function SourceMethods:isLooping() return self._loop end

function SourceMethods:tell()
  local st = voice_state(self)
  local rate = self._data and self._data._rate or 48000
  if st and audio_driver then
    local frame = audio_driver.tell(self._voice)
    if frame then return frame / rate end
    return 0
  end
  return (self._start_frame or 0) / rate
end

function SourceMethods:seek(offset)
  local rate = self._data and self._data._rate or 48000
  local frames = self._data and self._data._frames or 0
  local frame = math.floor((tonumber(offset) or 0) * rate + 0.5)
  if frame < 0 or frame >= frames then frame = 0 end
  if voice_state(self) and audio_driver then
    audio_driver.seek(self._voice, frame)
  else
    self._start_frame = frame
  end
  return true
end

function SourceMethods:getDuration()
  return self._data and self._data:getDuration() or 0
end

function SourceMethods:getChannelCount()
  return self._data and self._data:getChannelCount() or 0
end

function SourceMethods:getType() return self._type end

function SourceMethods:clone()
  local s = new_source(self._data, self._path, self._type)
  s._volume, s._pitch, s._loop = self._volume, self._pitch, self._loop
  return s
end

function SourceMethods:release()
  self:stop()
  self._released = true
  self._data = nil
  self._path = nil
  active_sources[self] = nil
  return true
end

new_source = function(source, path, kind)
  local data
  if type(source) == "table" and getmetatable(source) == SoundMT then
    data = source
  elseif type(source) == "string" then
    data = new_sound_data(source)
  end
  local s = setmetatable({
    _is_source = true, _data = data, _path = path or (data and data._path),
    _type = kind == "stream" and "stream" or "static",
    _volume = 1, _pitch = 1, _loop = false, _voice = nil,
    _start_frame = 0, _released = false, _play_failed = false,
  }, SourceMT)
  return s
end

local Audio = {}
Audio.newSource = function(source, kind)
  local path
  if type(source) == "string" and source:sub(1, 4) ~= "RIFF" then path = norm_path(source) end
  if path and kind == "stream" then
    local sd = new_stream_data(path)        -- con .idx: musica en trozos, sin bloquear
    if sd then return new_source(sd, path, kind) end
  end
  return new_source(source, path, kind)
end

local function source_action(s, method)
  if s == nil then return end
  if type(s) == "table" and not s._is_source then
    for i = 1, #s do
      local src = s[i]
      if src and src[method] then src[method](src) end
    end
  elseif s[method] then
    s[method](s)
  end
end

Audio.play = function(s)
  if s == nil then
    for src in pairs(active_sources) do src:resume() end
    return true
  end
  source_action(s, "play")
  return true
end

Audio.stop = function(s)
  if s == nil then
    for src in pairs(active_sources) do src:stop() end
    return true
  end
  source_action(s, "stop")
  return true
end

Audio.pause = function(s)
  if s == nil then
    for src in pairs(active_sources) do src:pause() end
    return true
  end
  source_action(s, "pause")
  return true
end

Audio.setVolume = function(v)
  if audio_driver then return audio_driver.master(v) end
  return 0
end
Audio.getVolume = function()
  if audio_driver then return audio_driver.master() end
  return 0
end
Audio.getActiveSourceCount = function()
  local n = 0
  for src in pairs(active_sources) do
    if src:isPlaying() then
      n = n + 1
    elseif not src._voice and not src._pending then
      active_sources[src] = nil
    end
  end
  return n
end

---------------------------------------------------------------------------
-- La tabla love
---------------------------------------------------------------------------
love = module("love", {})
-- love.graphics: lo que dibuja viene de C; lo que falta (texto, fuentes) en Lua
local G_ = {}
for k, v in pairs(gfx) do G_[k] = v end
local c_newImage, c_newShader = gfx.newImage, gfx.newShader
-- Cache de imagenes: Balatro vuelve a cargar todas las texturas cada vez que se cambia
-- "Pixel art smoothing" (y otras opciones). Las texturas de la 360 no se liberan, asi que
-- sin cache cada cambio sumaba ~87 MB y tardaba 5-10 s en bajarlas otra vez.
local image_cache = {}
G_.newImage = function(path, opts)
  local dpi = (opts and opts.dpiscale) or 1
  local key = tostring(path) .. "@" .. dpi
  local img = image_cache[key]
  if img then return img end
  local data = l360.read(path)
  if not data then log("  [missing image] " .. tostring(path)) end
  img = c_newImage(path, data or "", dpi)
  image_cache[key] = img
  return img
end
G_.newShader = function(path)
  local name = tostring(path):match("([^/]+)%.fs$") or tostring(path)
  local sh, translated = c_newShader(name)
  if not translated then log("  [untranslated shader, drawn with the default one] " .. name) end
  return sh
end
-- Fuentes: todas usan m6x11plus (la del juego en ingles); las CJK pesan 18 MB y no hacen falta
local FONT_PATH = "resources/fonts/m6x11plus.ttf"
local font_ttf
local c_newFont, c_newText = gfx.newFont, gfx.newText
local function real_font(_, size)
  font_ttf = font_ttf or l360.read(FONT_PATH)
  if not font_ttf then log("  [missing font] " .. FONT_PATH); return new_font(nil, size) end
  return c_newFont(FONT_PATH, font_ttf, tonumber(size) or 12)
end
local default_font
G_.newFont = real_font
G_.setNewFont = real_font
G_.getFont = function() default_font = default_font or real_font(nil, 12); return default_font end
G_.newText = function(font, s)
  if type(font) == "userdata" then return c_newText(font, s) end
  return new_text(font, s)
end
G_.newVideo = function() return object("Video", {}) end
G_.getDPIScale = function() return 1 end
G_.isActive = function() return true end
G_.isCreated = function() return true end
G_.setLineStyle = nop
G_.setBlendMode = nop
G_.getBlendMode = function() return "alpha", "alphamultiply" end
G_.setScissor = nop
G_.setFont = nop
G_.reset = nop
G_.setStencilTest = nop
G_.setColorMask = nop
love.graphics = module("love.graphics", G_)
love.filesystem = module("love.filesystem", {
  read = function(path)
    path = path:gsub("^%./", "")
    if persistent(path) then
      local d = saves.read(path)
      if d then return d, #d end
      return nil, "no existe"
    end
    if save[path] then return save[path], #save[path] end
    local d = game_file(path)
    if d then return d, #d end
    return nil, "no existe"
  end,
  write = function(path, data)
    path = path:gsub("^%./", "")
    if persistent(path) then return saves.write(path, data) end
    save[path] = tostring(data); return true
  end,
  append = function(path, data)
    path = path:gsub("^%./", "")
    if persistent(path) then return saves.append(path, data) end
    save[path] = (save[path] or "") .. tostring(data); return true
  end,
  getInfo = function(path) return fs_info(path) end,
  createDirectory = function(path) save_dirs[path:gsub("^%./", "")] = true; return true end,
  remove = function(path)
    path = path:gsub("^%./", "")
    if persistent(path) then return saves.remove(path) end
    local had = save[path] ~= nil or save_dirs[path] ~= nil
    save[path] = nil; save_dirs[path] = nil
    return had
  end,
  getDirectoryItems = function(path) local l = DIRS[path:gsub("/$", "")]; local o = {}
    if l then for i = 1, #l do o[i] = l[i] end end; return o end,
  getSaveDirectory = function() return "save" end,
  getSourceBaseDirectory = function() return "." end,
  getIdentity = function() return "Balatro" end, setIdentity = nop,
  load = function(path) local d = game_file(path); return d and loadstring(d, "@" .. path) end,
})
love.data = module("love.data", {
  compress = function(_, _, s) return s end,
  decompress = function(_, _, s) return s end,
})
love.thread = module("love.thread", {
  newThread = new_thread,
  getChannel = get_channel, newChannel = function() return get_channel({}) end,
})
love.timer = module("love.timer", {
  getTime = now, step = function() return DT end, sleep = nop,
  getFPS = function() return 60 end, getDelta = function() return DT end,
})
love.event = module("love.event", { pump = nop, poll = function() return nop end, quit = nop, push = nop })
love.mouse = module("love.mouse", {
  getPosition = function() return W / 2, H / 2 end, getX = function() return W / 2 end,
  getY = function() return H / 2 end, setVisible = nop, isVisible = function() return false end,
  setGrabbed = nop, setRelativeMode = nop, isDown = function() return false end,
  setPosition = nop, getSystemCursor = nop, setCursor = nop,
})
love.keyboard = module("love.keyboard", { isDown = function() return false end, setKeyRepeat = nop })
local Input = assert(loadstring(assert(l360.read("love360/love360_input.lua"),
  "missing love360/love360_input.lua"), "@love360_input.lua"))()
local input = Input.new(love, l360, input_config)
love.touch = module("love.touch", { getTouches = function() return {} end })
love.window = module("love.window", {
  setMode = function() return true end, updateMode = function() return true end,
  getMode = function() return W, H, { fullscreen = false, fullscreentype = "desktop", vsync = 1,
    display = 1, resizable = true, borderless = false, highdpi = false, msaa = 0 } end,
  getDesktopDimensions = function() return W, H end,
  getFullscreenModes = function() return { { width = W, height = H } } end,
  getDisplayCount = function() return 1 end, isOpen = function() return true end,
  toPixels = function(x) return x end, fromPixels = function(x) return x end,
  setTitle = nop, getTitle = function() return "Balatro" end, showMessageBox = function() return 1 end,
  setIcon = nop, getDPIScale = function() return 1 end, setVSync = nop, getVSync = function() return 1 end,
  isMinimized = function() return false end, hasFocus = function() return true end,
  getDisplayName = function() return "Love360" end, setFullscreen = nop,
  getFullscreen = function() return false end,
})
love.system = module("love.system", {
  getOS = function() return "Windows" end, openURL = nop,
  getClipboardText = function() return "" end, setClipboardText = nop,
  getProcessorCount = function() return 6 end,
})
love.sound = module("love.sound", { newSoundData = new_sound_data })
love.audio = module("love.audio", Audio)
love.math = module("love.math", { random = math.random })
love.arg = module("love.arg", { parseGameArguments = function(a) return a end })
love.handlers = {}
arg = arg or {}

package.preload["luasteam"] = function()
  return object("luasteam", { init = function() return true end, shutdown = nop, runCallbacks = nop,
    userStats = object("userStats", {}), friends = object("friends", {}), utils = object("utils", {}) })
end
for _, m in ipairs({"love.filesystem","love.timer","love.thread","love.audio","love.sound","love.system","love.data"}) do
  package.preload[m] = function() return love end
end

-- require de los modulos del juego desde l360.read (en la 360, por TFTP)
table.insert(package.loaders, 2, function(name)
  local path = name:gsub("%.", "/") .. ".lua"
  local d = game_file(path)
  if not d then return "\n\tnot found: " .. path end
  local f, err = loadstring(d, "@" .. path)
  if not f then error(err) end
  return f
end)

---------------------------------------------------------------------------
-- Arranque del juego
---------------------------------------------------------------------------
local t_boot = now()
LOAD_TIMES = {}
local ok, err = pcall(require, "main")
if not ok then log("ERROR loading main.lua: " .. tostring(err)); return end
log(string.format("main.lua and modules: %.0f ms", (now() - t_boot) * 1000))
LOAD_TIMES[#LOAD_TIMES + 1] = string.format("main.lua and modules: %.1f s", now() - t_boot)

local t_load = now()
G.F_SKIP_TUTORIAL = true
ok, err = xpcall(love.load, debug.traceback)
if not ok then log("ERROR in love.load: " .. tostring(err)); return end
love.resize(W, H)
log(string.format("love.load (G:start_up): %.0f ms", (now() - t_load) * 1000))
LOAD_TIMES[#LOAD_TIMES + 1] = string.format("love.load (G:start_up): %.1f s", now() - t_load)
LOAD_TIMES[#LOAD_TIMES + 1] = string.format("since program start: %.1f s", now())

---------------------------------------------------------------------------
-- El bot: juega una partida corta con acciones del propio juego
---------------------------------------------------------------------------
local game_time = 0
local wait_until = 0
local function wait(s) wait_until = game_time + s end
local function idle()
  if game_time < wait_until then return false end
  for _, e in ipairs(G.E_MANAGER.queues.base) do
    if e.blocking then return false end       -- quedan animaciones que frenan la partida
  end
  return not (G.CONTROLLER and G.CONTROLLER.locked)
end

local played_rounds, max_rounds = 0, tonumber(l360.rounds) or 2
local shop_rerolled = false
local phase = "menu"
local done = false
local hand_actions = 0
local showcase_done = false

-- Para ver los efectos: comodines con cada edicion y algunas cartas con edicion y sello
local function showcase()
  local jokers = {
    {"j_joker", {foil = true}}, {"j_greedy_joker", {holo = true}},
    {"j_lusty_joker", {polychrome = true}}, {"j_wrathful_joker", {negative = true}},
  }
  for _, j in ipairs(jokers) do
    local ok, err = pcall(function()
      local c = create_card("Joker", G.jokers, nil, nil, nil, nil, j[1])
      c:set_edition(j[2], true, true)
      c:add_to_deck()
      G.jokers:emplace(c)
    end)
    if not ok then log("  [bot] could not create " .. j[1] .. ": " .. tostring(err)) end
  end
  local eds = {{foil = true}, {holo = true}, {polychrome = true}}
  for i = 1, math.min(#G.playing_cards, 12) do
    local c = G.playing_cards[i]
    pcall(function()
      if i <= 6 then c:set_edition(eds[(i - 1) % 3 + 1], true, true) end
      if i > 6 then c:set_seal(i % 2 == 0 and "Gold" or "Red", true, true) end
    end)
  end
end

local function state_name()
  for k, v in pairs(G.STATES) do if v == G.STATE then return k end end
  return tostring(G.STATE)
end

local function bot()
  local st = G.STATE
  if phase == "menu" then
    if st == G.STATES.MENU and G.MAIN_MENU_UI and game_time > 6 then
      G.FUNCS.start_run(nil, { stake = 1, seed = "LOVE360" })
      phase = "run"; wait(2)
    end
    return
  end
  if not idle() then return end
  if st == G.STATES.BLIND_SELECT and G.blind_select and G.STATE_COMPLETE then
    if not showcase_done then showcase_done = true; showcase(); wait(2); return end
    if played_rounds >= max_rounds then done = true; return end
    local key = G.GAME.round_resets.blind_choices[G.GAME.blind_on_deck]
    G.FUNCS.select_blind({ config = { ref_table = G.P_BLINDS[key] }, UIBox = G.blind_select })
    hand_actions = 0
    wait(1.5)
  elseif st == G.STATES.SELECTING_HAND and #G.hand.cards > 0 then
    hand_actions = hand_actions + 1
    if hand_actions == 1 and G.GAME.current_round.discards_left > 0 then
      for i = 1, math.min(3, #G.hand.cards) do G.hand:add_to_highlighted(G.hand.cards[i], true) end
      G.FUNCS.discard_cards_from_highlighted(nil, true)
    else
      -- jugar las 5 primeras; la segunda mano gana la ronda para que la partida avance
      if hand_actions >= 3 then G.GAME.blind.chips = 1 end
      for i = 1, math.min(5, #G.hand.cards) do G.hand:add_to_highlighted(G.hand.cards[i], true) end
      G.FUNCS.play_cards_from_highlighted(nil)
    end
    wait(1)
  elseif st == G.STATES.ROUND_EVAL and G.round_eval and G.STATE_COMPLETE then
    G.FUNCS.cash_out({ config = {} })
    played_rounds = played_rounds + 1
    shop_rerolled = false
    wait(2)
  elseif st == G.STATES.SHOP and G.shop and G.STATE_COMPLETE then
    if not shop_rerolled then
      shop_rerolled = true
      G.GAME.dollars = math.max(G.GAME.dollars, 20)
      G.FUNCS.reroll_shop()
      wait(2.5)
    else
      G.FUNCS.toggle_shop()
      wait(2)
    end
  elseif st == G.STATES.GAME_OVER then
    done = true
  end
end

---------------------------------------------------------------------------
-- Bucle principal: 30 FPS, con medicion
---------------------------------------------------------------------------
local per, order = {}, {}
local function bucket(name)
  local b = per[name]
  if not b then
    b = { n = 0, up = 0, dr = 0, gpu = 0, tot = 0, upmax = 0, drmax = 0, totmax = 0, draws = 0, over = 0 }
    per[name] = b; order[#order + 1] = name
  end
  return b
end

local function report(title)
  local R = {}
  local function out(s) R[#R + 1] = s end
  local st = l360.gfxstats()
  out("Love360 P4 (" .. l360.platform .. "): " .. title)
  for _, l in ipairs(LOAD_TIMES) do out("Load: " .. l) end
  local rs = l360.readstats()
  out(string.format("Files loaded from the PC: %d (%.1f MB) in %.1f s", rs.files, rs.bytes / 1048576, rs.ms / 1000))
  out(string.format("Images: %.0f MB of textures, decoded in %.1f s; missing: %d",
    st.texture_bytes / 1048576, st.image_ms / 1000, st.missing_images))
  out(string.format("Draws dropped because the VB was full: %d. Calls not drawn (text, video): %d", st.dropped, st.skipped))
  out("State             frames  update avg/max    draw avg/max    GPU wait    frame avg/max    >33ms  draws")
  for _, name in ipairs(order) do
    local b = per[name]
    out(string.format("%-16s %7d  %6.2f / %6.1f  %6.2f / %6.1f  %7.2f  %7.2f / %6.1f  %5d  %6.0f",
      name, b.n, b.up / b.n, b.upmax, b.dr / b.n, b.drmax, b.gpu / b.n, b.tot / b.n, b.totmax, b.over, b.draws / b.n))
  end
  local miss = {}
  for k in pairs(missing) do miss[#miss + 1] = k end
  table.sort(miss)
  out("Missing LOVE functions (in Lua): " .. (#miss > 0 and table.concat(miss, ", ") or "none"))
  local txt = table.concat(R, "\n") .. "\n"
  for _, s in ipairs(R) do log(s) end
  l360.upload("p4_resultados.txt", txt)
  l360.upload_log()
end

l360.start_render()
local frame = 0
local dt_smooth = 1 / 60
local last = now()
local reported = false
local last_ctx_name
local t_begin = now()
while true do
  local t0 = now()
  local dt = math.min(t0 - last, 0.1)
  last = t0
  dt_smooth = math.min(0.8 * dt_smooth + 0.2 * dt, 0.1)
  frame = frame + 1
  game_time = game_time + dt
  local name = input:isBot() and (phase == "menu") and (G.STATE == G.STATES.SPLASH and "SPLASH" or "MENU") or state_name()
  if done then name = "FIN_DEL_BOT" end
  if name ~= last_ctx_name then
    last_ctx_name = name
    l360.set_context(name)
    log(string.format("  [state] %s (frame %d, %.0f s, Lua %.0f KB)", name, frame, now(), collectgarbage("count")))
  end
  if frame % 300 == 0 then
    local used, arena = 0, 0
    if l360.heap then used, arena = l360.heap() end
    log(string.format("  [memory] frame %d, %.0f s, Lua %.0f KB, malloc %.0f / %.0f MB, %s",
      frame, now(), collectgarbage("count"), used / 1024, arena / 1024, name))
    if l360.audio then
      local a = l360.audio.stats()
      log(string.format("  [audio] voices %d, chunks %d, underruns %d, starved %d, mix max %d us, thread %s",
        a.voices, a.chunks, a.underruns, a.starved or 0, a.mix_us_max, a.running and "yes" or "NO"))
    end
  end
  local st0 = l360.gfxstats().draws

  ok, err = xpcall(function()
    l360.poll_input() -- USB, Start (recarga) y red, una vez por frame; l360.pad lee el snapshot.
    input:update() -- callbacks antes del update, incluso durante pausa
    if input:isBot() then
      if not done then bot() end
    else
      done = false -- nunca terminar una partida manual por el limite del bot
    end
    love.update(dt_smooth)
    threads_step()
  end, debug.traceback)
  local t1 = now()
  if not ok then log("ERROR in update (frame " .. frame .. "): " .. tostring(err)); break end
  local tg = now()
  gfx.sync()                       -- la GPU termino el frame anterior mientras corria update
  local wait_gpu = (now() - tg) * 1000
  ok, err = xpcall(love.draw, debug.traceback)
  local t2 = now()
  if not ok then log("ERROR in draw (frame " .. frame .. "): " .. tostring(err)); break end
  local gst = l360.gfxstats()
  love.graphics.present()
  local t3 = now()

  local b = bucket(name)
  local up, dr, gp, tot = (t1 - t0) * 1000, (t2 - t1) * 1000 - wait_gpu, wait_gpu, (t3 - t0) * 1000
  b.n = b.n + 1; b.up = b.up + up; b.dr = b.dr + dr; b.gpu = b.gpu + gp; b.tot = b.tot + tot
  if up > b.upmax then b.upmax = up end
  if dr > b.drmax then b.drmax = dr end
  if tot > b.totmax then b.totmax = tot end
  if tot > 33.4 then b.over = b.over + 1 end
  b.draws = b.draws + (gst.draws - st0)

  if done and not reported then
    reported = true
    report(string.format("bot run finished in %.0f s, %d frames", now() - t_begin, frame))
  end

  -- 30 FPS: la musica se baja en lo que sobra del frame; despues, esperar el resto
  -- atendiendo la red (sin polling de USB).
  streams_step(t0 + 1 / 30)
  l360.wait_frame(t0 + 1 / 30)
end
report("stopped by an error")
