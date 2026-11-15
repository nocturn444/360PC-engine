-- 360PC-Engine console boot: runs a LÖVE game on the console runtime.
-- love.graphics comes from C (l360.gfx); the rest of the LÖVE API is built here in Lua.
-- Order, like LÖVE: game.lua (engine config, docs/GAME_CONFIG.md), conf.lua (love.conf),
-- main.lua, love.load, and then the frame loop at 30 FPS (love.update, love.draw).
-- Lua 5.1 / LuaJIT without JIT.
--
-- What the C program provides (the l360 table): see runtime/main.c and runtime/l360_sys.c.
--   l360.time()        seconds, high resolution
--   l360.read(path)    contents of a file of the game folder, or nil
--   l360.log(s)        one line to the log (and to the text screen)
--   l360.runtime_dir   folder of this Lua layer inside the game folder ("l360/")

local l360 = l360
local now = l360.time
local log = l360.log

local W, H = l360.width or 1280, l360.height or 720
local DT = 1 / 30
local gfx = l360.gfx
local RT = l360.runtime_dir or "l360/"

local function runtime_module(name)
  local src = assert(l360.read(RT .. name), "missing " .. RT .. name)
  return assert(loadstring(src, "@" .. name))()
end

---------------------------------------------------------------------------
-- game.lua: the per-game config (name, identity, save folder...)
---------------------------------------------------------------------------
local Config = runtime_module("config.lua")
local game
do
  local src = l360.read("game.lua")
  if src then
    local cfg, err = Config.load(src)
    if not cfg then log("[ERROR] " .. tostring(err)); return end
    game = cfg
  else
    game = Config.defaults()
    log("  [missing] game.lua: using defaults (name \"" .. game.name .. "\", save folder \"" .. game.save_dir .. "\")")
  end
end
l360.game = game
log(string.format("game.lua: %s (identity %s, save folder %s)", game.name, game.identity, game.save_dir))
if l360.save_set_dir and not l360.save_set_dir(game.save_dir) then return end

local function clean_path(path)
  path = tostring(path):gsub("\\", "/"):gsub("^%./", ""):gsub("/+$", "")
  return path
end
local function game_file(path)
  return l360.read(clean_path(path))
end

---------------------------------------------------------------------------
-- Missing LÖVE functions: logged once each, and they do nothing
---------------------------------------------------------------------------
local missing = {}
local function note_missing(name)
  if not missing[name] then missing[name] = true; log("  [missing] " .. name) end
end

local function nop() end
local function module(name, t)
  return setmetatable(t, { __index = function(_, k)
    note_missing(name .. "." .. tostring(k)); return nop end })
end
local function object(kind, t)
  return setmetatable(t, { __index = function(_, k)
    note_missing(kind .. ":" .. tostring(k)); return nop end })
end

---------------------------------------------------------------------------
-- Fonts and text without a TTF: approximate metrics, nothing drawn
---------------------------------------------------------------------------
local function text_width(s, size) return #s * size * 0.5 end
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
-- Channels and threads. There are no real threads: a love.thread runs as a coroutine on the main
-- thread, resumed once per frame. It gives the turn back when Channel:demand finds nothing or
-- when it calls love.timer.sleep; a thread that never does either stops the game.
---------------------------------------------------------------------------
local channels = {}
local threads = {}
local current_thread            -- the thread whose coroutine is running now
local function new_channel()
  local q = {}
  return object("Channel", {
    push = function(_, v) if #q < 256 then q[#q + 1] = v end return #q end,
    supply = function(_, v) if #q < 256 then q[#q + 1] = v end return true end,
    pop = function() return table.remove(q, 1) end,
    demand = function()
      local v = table.remove(q, 1)
      if v ~= nil then return v end
      if current_thread then coroutine.yield() end
      return table.remove(q, 1)
    end,
    peek = function() return q[1] end,
    getCount = function() return #q end,
    clear = function() q = {} end,
  })
end
local function get_channel(name)
  local c = channels[name]
  if not c then c = new_channel(); channels[name] = c end
  return c
end

-- st: the state of a thread ({ name, co, error, started, thread }), kept apart from the Thread
-- object, whose unknown fields are "missing" functions.
local function thread_resume(st, ...)
  local co = st.co
  if not co or coroutine.status(co) ~= "suspended" then return end
  local before = current_thread
  current_thread = st
  local ok, err = coroutine.resume(co, ...)
  current_thread = before
  if not ok then
    st.error = tostring(err)
    st.co = nil
    log("  [thread] ERROR in " .. st.name .. ": " .. st.error)
    local f = rawget(love, "threaderror")
    if f then f(st.thread, st.error) end
  elseif coroutine.status(co) == "dead" then
    st.co = nil
  end
end

-- newThread(file name or code): like LÖVE, a string with a line break (or a long one) is code.
local function new_thread(source)
  local name, src = "thread code", source
  if type(source) == "string" and #source < 1024 and not source:find("\n", 1, true) then
    name, src = source, game_file(source)
  end
  local fn, err
  if type(src) == "string" then fn, err = loadstring(src, "@" .. name) else err = "not found" end
  if not fn then
    log("  [thread] could not load " .. tostring(name) .. ": " .. tostring(err))
    return object("Thread", { start = nop, wait = nop,
      isRunning = function() return false end, getError = function() return err end })
  end
  -- In LÖVE every thread has its own globals.
  setfenv(fn, setmetatable({}, { __index = _G }))
  local st = { name = name, co = coroutine.create(fn) }
  st.thread = object("Thread", {
    start = function(_, ...)
      if not st.started then
        st.started = true
        threads[#threads + 1] = st
        thread_resume(st, ...)
      end
      return true
    end,
    wait = nop,
    isRunning = function() return st.started == true and st.co ~= nil end,
    getError = function() return st.error end,
    release = nop,
  })
  return st.thread
end

local function threads_step()
  for i = #threads, 1, -1 do
    local st = threads[i]
    if st.co then thread_resume(st) else table.remove(threads, i) end
  end
end

---------------------------------------------------------------------------
-- Saves: everything love.filesystem writes goes to the game's save folder (save.lua, two slots
-- per file). Reading looks there first and then in the game folder, like LÖVE.
---------------------------------------------------------------------------
local Save = runtime_module("save.lua")
local saves
do
  local backend
  if l360.save_read and l360.save_write then
    backend = { get = l360.save_read, put = l360.save_write }
    -- What is in the save folder now, so that reading a game file does not first try to open two
    -- save slots that are not there.
    local names = l360.listdir and l360.listdir(game.save_dir)
    if names or (l360.filetype and not l360.filetype(game.save_dir)) then
      local present = {}
      for _, n in ipairs(names or {}) do present[n:lower()] = true end
      backend.has = function(n) return present[n:lower()] == true end
      backend.put = function(n, d) present[n:lower()] = true; return l360.save_write(n, d) end
    end
    log("  [save] at " .. tostring(l360.save_dir and l360.save_dir() or game.save_dir))
  else
    local mem = {}
    backend = { get = function(n) return mem[n] end, put = function(n, d) mem[n] = d; return true end }
    log("  [save] no l360.save_read/save_write: saves are kept in memory only")
  end
  saves = Save.new(backend, log, l360.time)
end
local made_dirs = {}

local function fs_read(path)
  path = clean_path(path)
  local d = saves.read(path) or game_file(path)
  if d then return d, #d end
  return nil, "Could not open file " .. path .. ". Does not exist."
end

local function fs_info(path, filter)
  path = clean_path(path)
  local info
  local d = saves.read(path)
  if d then
    info = { type = "file", size = #d, modtime = 0 }
  elseif path == "" or made_dirs[path] or saves.isdir(path) then
    info = { type = "directory", size = 0, modtime = 0 }
  elseif l360.filetype then
    local kind, size = l360.filetype(path)
    if kind then info = { type = kind, size = size or 0, modtime = 0 } end
  else
    d = game_file(path)
    if d then info = { type = "file", size = #d, modtime = 0 } end
  end
  if info and type(filter) == "string" and info.type ~= filter then return nil end
  return info
end

-- The game folder plus what was saved in this run. Saves of earlier runs are not listed (their
-- names on disk are flattened), only found by name.
local function fs_items(path)
  path = clean_path(path)
  local seen, out = {}, {}
  local function add(n) if not seen[n] then seen[n] = true; out[#out + 1] = n end end
  for n in pairs(saves.items(path)) do add(n) end
  local pre = path == "" and "" or path .. "/"
  for d in pairs(made_dirs) do
    local n = d:sub(1, #pre) == pre and d:sub(#pre + 1):match("^[^/]+")
    if n then add(n) end
  end
  local names = l360.listdir and l360.listdir(path)
  for _, n in ipairs(names or {}) do add(n) end
  table.sort(out)
  return out
end

---------------------------------------------------------------------------
-- Audio: love.sound and love.audio over l360.audio
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

-- Returns from (a byte offset, 0-based like newbuffer), bytes, channels, rate and
-- frames of a 16-bit PCM or mono IMA ADPCM WAV; in ADPCM, also block_align.
local function parse_wav(data)
  if type(data) ~= "string" or #data < 12 or data:sub(1, 4) ~= "RIFF"
      or data:sub(9, 12) ~= "WAVE" then
    return nil, "not a WAV"
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
    -- IMA ADPCM: blocks of block_align bytes with 1 + 2 * (block_align - 4) frames (mono)
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
  if fmt.format ~= 1 then return nil, "not PCM" end
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

-- Whole ADPCM buffer (long effects): newstream with its final size and a single append
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

-- The game keeps asking for .ogg because that is what its list holds. The PC
-- tool leaves .wav with the same base name; we try the .wav first so as not to request
-- over TFTP an .ogg that does not exist. So the game's code needs no changes.
local function read_sound(path)
  if path:match("%.ogg$") then
    local wav = l360.read((path:gsub("%.ogg$", ".wav")))
    if wav and wav:sub(1, 4) ~= "OggS" then return wav end
    local ogg = l360.read(path)
    if ogg and ogg:sub(1, 4) ~= "OggS" then return ogg end
    if ogg or wav then return nil, "OGG not converted" end
    return nil, "does not exist"
  end
  local data = l360.read(path)
  if data and data:sub(1, 4) ~= "OggS" then return data end
  if data then return nil, "OGG not converted" end
  return nil, "does not exist"
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
  if source:sub(1, 4) == "RIFF" then return make_sound_data(source, "data") end
  return load_sound_data(source)
end

---------------------------------------------------------------------------
-- Background music: IMA ADPCM split into chunks
-- musicN.idx gives the total size; the chunks musicN.p000.wav, p001... are fetched with
-- l360.fetch_* in the spare time of each frame, in the order "chunk 0 of every track,
-- chunk 1 of every track...", and appended to the buffer with append. If the game asks to play a track
-- before all the chunk 0s are in, the request waits and all of them start together.
---------------------------------------------------------------------------
local streams = {}            -- tracks in the order they were created
local stream_cache = {}       -- path -> SoundData of the track
local pending_plays = {}      -- Sources waiting for the chunk 0s
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

-- Ready to start: every created track has its chunk 0 (or it failed)
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

-- Fetches chunks until the moment `deadline` (l360.time seconds). Once per frame,
-- before l360.wait_frame: uses the time left in the frame and does not go past it.
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
    if r == "pending" then return end
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
    -- music: wait for every track's chunk 0 and start them all together
    if self._pending == nil then pending_plays[#pending_plays + 1] = self end
    self._pending = "play"
    active_sources[self] = true
    return true
  end
  return start_voice(self)
end

function SourceMethods:stop()
  if self._pending then self._pending = "stop" end   -- release_pending skips it
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
  if p <= 0 then p = 1 end -- l360.audio counts 0 or negative as 1
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
    local sd = new_stream_data(path)        -- with .idx: chunked music, non-blocking
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
-- The love table
---------------------------------------------------------------------------
love = module("love", {})
love.getVersion = function() return 11, 5, 0, "Mysterious Mysteries" end
local identity, title = game.identity, game.name
local quit_requested = false
local last_dt = DT

-- love.graphics: what draws comes from C; the rest is here
local G_ = {}
for k, v in pairs(gfx) do G_[k] = v end
local c_newImage, c_newShader = gfx.newImage, gfx.newShader
-- Image cache: console textures are never freed, so loading the same file again (some games
-- reload every texture when an option changes) must not upload it again.
local image_cache = {}
G_.newImage = function(path, opts)
  local dpi = (opts and opts.dpiscale) or 1
  local key = tostring(path) .. "@" .. dpi
  local img = image_cache[key]
  if img then return img end
  local data = type(path) == "string" and game_file(path)
  if not data then log("  [missing image] " .. tostring(path)) end
  img = c_newImage(tostring(path), data or "", dpi)
  image_cache[key] = img
  return img
end
-- Shaders (docs/SHADERS.md). The console runs no GLSL: each shader the game uses is declared in
-- game.lua (shaders = { name = "x.glsl" } or { pixel = , vertex = }) and built on PC into
-- shaders/<name>.psu/.vsu and shaders/<name>.meta.lua. newShader takes what LÖVE takes (a path or
-- the code, for one or both stages) and finds the declared shader built from those files.
local shader_names, shader_codes, shader_metas = {}, nil, {}
local function shader_key(a, b)
  if not b or a == b then return a end
  if b < a then a, b = b, a end
  return a .. "|" .. b
end
for name, d in pairs(game.shaders) do
  shader_names[shader_key(d.glsl or d.pixel or d.vertex, d.glsl or d.vertex)] = name
end
-- The declared file an argument of newShader stands for: a path as it is; code, by its text.
local function shader_file(src)
  src = tostring(src)
  if not src:find("\n", 1, true) then return clean_path(src) end
  if not shader_codes then
    shader_codes = {}
    for _, d in pairs(game.shaders) do
      for _, path in pairs(d) do
        local code = game_file(path)
        if code then shader_codes[code:gsub("\r\n", "\n")] = path end
      end
    end
  end
  return shader_codes[src:gsub("\r\n", "\n")]
end
local function shader_meta(name)
  local meta = shader_metas[name]
  if meta == nil then
    local path = "shaders/" .. name .. ".meta.lua"
    local src = game_file(path)
    local chunk = src and src:sub(1, 1) ~= "\27" and loadstring(src, "@" .. path)
    local ok
    if chunk then ok, meta = pcall(setfenv(chunk, {})) end
    if not ok or type(meta) ~= "table" then
      meta = false
      note_missing("shader " .. name .. ": " .. path .. " (build the shaders: docs/SHADERS.md); drawn with the default one")
    end
    shader_metas[name] = meta
  end
  return meta or nil
end
G_.newShader = function(a, b)
  local fa, fb = shader_file(a), b ~= nil and shader_file(b) or nil
  local name = fa and (b == nil or fb) and shader_names[shader_key(fa, fb)]
  if not name then
    local what = tostring(a):find("\n", 1, true) and "(shader code)" or tostring(a)
    note_missing("shader " .. what .. ": not declared in game.lua (shaders); drawn with the default one")
    return (c_newShader(what))
  end
  return (c_newShader(name, shader_meta(name)))
end
-- Fonts: newFont(path, size) loads that TTF from the game folder; newFont(size) uses game.lua's
-- default_font. Without a TTF the font only measures (roughly).
local c_newFont, c_newText = gfx.newFont, gfx.newText
local font_files = {}
local drawable_fonts = setmetatable({}, { __mode = "k" })  -- the fonts gfx.print can draw with
local function real_font(path, size)
  if type(path) ~= "string" then path, size = game.default_font, path end
  size = tonumber(size) or 12
  if not path then
    note_missing("default font (set default_font in game.lua)")
    return new_font(nil, size)
  end
  path = clean_path(path)
  local ttf = font_files[path]
  if ttf == nil then
    ttf = l360.read(path) or false
    font_files[path] = ttf
    if not ttf then log("  [missing font] " .. path) end
  end
  local font = ttf and c_newFont(path, ttf, size)
  if not font then return new_font(nil, size) end
  drawable_fonts[font] = true
  return font
end
local default_font, current_font
local background = { 0, 0, 0, 1 }
G_.newFont = real_font
G_.getFont = function()
  if current_font then return current_font end
  default_font = default_font or real_font(12)
  return default_font
end
G_.setFont = function(font) current_font = font end
G_.setNewFont = function(...) current_font = real_font(...); return current_font end
-- print(text, x, y, r, sx, sy, ox, oy, kx, ky) and printf(text, x, y, limit, align, r, sx, ...),
-- or with a font before x. A font without a TTF only measures: gfx.print counts it as not drawn.
local c_print, c_printf = gfx.print, gfx.printf
local function print_font(font)
  font = font or current_font or G_.getFont()
  return drawable_fonts[font] and font or nil
end
G_.print = function(text, x, ...)
  if x ~= nil and type(x) ~= "number" then return c_print(print_font(x), text, ...) end
  return c_print(print_font(), text, x, ...)
end
G_.printf = function(text, x, ...)
  if x ~= nil and type(x) ~= "number" then return c_printf(print_font(x), text, ...) end
  return c_printf(print_font(), text, x, ...)
end
G_.newText = function(font, s)
  if type(font) == "userdata" then return c_newText(font, s) end
  return new_text(font, s)
end
G_.setBackgroundColor = function(r, g, b, a)
  if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
  background = { tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0, tonumber(a) or 1 }
end
G_.getBackgroundColor = function() return background[1], background[2], background[3], background[4] end
G_.newVideo = function() return object("Video", {}) end
G_.getDPIScale = function() return 1 end
G_.isActive = function() return true end
G_.isCreated = function() return true end
G_.setLineStyle = nop
-- setBlendMode(mode, alphamode): "alpha" and "add" are drawn; LÖVE's other modes are drawn as
-- "alpha" and logged once. getBlendMode answers the mode in use.
local c_setBlendMode = gfx.setBlendMode
local blend_modes = { alpha = "alpha", add = "add", subtract = false, multiply = false, lighten = false,
  darken = false, screen = false, replace = false, none = false }
G_.setBlendMode = function(mode, alphamode)
  local known = blend_modes[mode]
  if known == nil then error("Invalid blend mode '" .. tostring(mode) .. "'", 2) end
  if alphamode ~= nil and alphamode ~= "alphamultiply" and alphamode ~= "premultiplied" then
    error("Invalid blend alpha mode '" .. tostring(alphamode) .. "'", 2)
  end
  if not known then
    note_missing("love.graphics.setBlendMode(\"" .. mode .. "\"): drawn as \"alpha\"")
    known = "alpha"
  end
  c_setBlendMode(known, alphamode)
end
G_.setScissor = nop
G_.reset = nop
G_.setStencilTest = nop
G_.setColorMask = nop
love.graphics = module("love.graphics", G_)
love.filesystem = module("love.filesystem", {
  read = function(path) return fs_read(path) end,
  write = function(path, data) return saves.write(clean_path(path), data) end,
  append = function(path, data) return saves.append(clean_path(path), data) end,
  getInfo = fs_info,
  createDirectory = function(path) made_dirs[clean_path(path)] = true; return true end,
  remove = function(path)
    path = clean_path(path)
    if made_dirs[path] then made_dirs[path] = nil; return true end
    return saves.remove(path)
  end,
  getDirectoryItems = fs_items,
  getSaveDirectory = function() return l360.save_dir and l360.save_dir() or game.save_dir end,
  getSourceBaseDirectory = function() return "." end,
  getSource = function() return "." end,
  isFused = function() return true end,
  getIdentity = function() return identity end,
  setIdentity = function(name) identity = tostring(name) end,  -- the save folder is game.lua's
  load = function(path)
    local d, err = fs_read(path)
    if not d then return nil, err end
    return loadstring(d, "@" .. clean_path(path))
  end,
})
love.data = module("love.data", {
  compress = function(_, _, s) return s end,
  decompress = function(_, _, s) return s end,
})
love.thread = module("love.thread", {
  newThread = new_thread,
  getChannel = get_channel, newChannel = new_channel,
})
-- love.timer, as in LÖVE: step measures the time since the last step (the main loop calls it once
-- per frame; a game may call it again after a long load so the next dt does not include it), and
-- the FPS and the average delta are taken over the last second or so.
local timer_last, fps, average_dt = now(), 0, DT
local fps_frames, fps_since = 0, timer_last
local function timer_step()
  local t = now()
  local dt = math.min(t - timer_last, 0.1)
  timer_last = t
  if dt > 0 then last_dt = dt end
  fps_frames = fps_frames + 1
  local span = t - fps_since
  if span > 1 then
    fps = math.floor(fps_frames / span + 0.5)
    average_dt = span / fps_frames
    fps_since, fps_frames = t, 0
  end
  return last_dt
end
love.timer = module("love.timer", {
  getTime = now, step = timer_step,
  sleep = function() if current_thread then coroutine.yield() end end,
  getFPS = function() return fps end, getDelta = function() return last_dt end,
  getAverageDelta = function() return average_dt end,
})
love.event = module("love.event", {
  pump = nop, poll = function() return nop end, clear = nop,
  quit = function() quit_requested = true end,
  push = function(name) if name == "quit" then quit_requested = true end end,
})
love.mouse = module("love.mouse", {
  getPosition = function() return W / 2, H / 2 end, getX = function() return W / 2 end,
  getY = function() return H / 2 end, setVisible = nop, isVisible = function() return false end,
  setGrabbed = nop, setRelativeMode = nop, isDown = function() return false end,
  setPosition = nop, getSystemCursor = nop, setCursor = nop,
})
-- There is no keyboard on the console and the controller is not turned into keys: nothing is ever
-- down and love.keypressed / keyreleased / textinput never fire.
love.keyboard = module("love.keyboard", {
  isDown = function() return false end, isScancodeDown = function() return false end,
  getKeyFromScancode = function(scancode) return scancode end,
  getScancodeFromKey = function(key) return key end,
  setKeyRepeat = nop, hasKeyRepeat = function() return false end,
  setTextInput = nop, hasTextInput = function() return false end,
  hasScreenKeyboard = function() return false end,
})
local input = runtime_module("input.lua").new(love, l360)
love.touch = module("love.touch", { getTouches = function() return {} end })
love.window = module("love.window", {
  setMode = function() return true end, updateMode = function() return true end,
  getMode = function() return W, H, { fullscreen = true, fullscreentype = "exclusive", vsync = 1,
    display = 1, resizable = false, borderless = false, highdpi = false, msaa = 0 } end,
  getDesktopDimensions = function() return W, H end,
  getFullscreenModes = function() return { { width = W, height = H } } end,
  getDisplayCount = function() return 1 end, isOpen = function() return true end,
  toPixels = function(x) return x end, fromPixels = function(x) return x end,
  setTitle = function(s) title = tostring(s) end, getTitle = function() return title end,
  showMessageBox = function() return 1 end,
  setIcon = nop, getDPIScale = function() return 1 end, setVSync = nop, getVSync = function() return 1 end,
  isMinimized = function() return false end, hasFocus = function() return true end,
  getDisplayName = function() return "Xbox 360" end, setFullscreen = nop,
  getFullscreen = function() return true, "exclusive" end,
})
love.system = module("love.system", {
  getOS = function() return "Xbox 360" end, openURL = nop,
  getClipboardText = function() return "" end, setClipboardText = nop,
  getProcessorCount = function() return 6 end,
})
love.sound = module("love.sound", { newSoundData = new_sound_data })
love.audio = module("love.audio", Audio)
love.math = module("love.math", { random = math.random })
love.arg = module("love.arg", { parseGameArguments = function(a) return a end })
love.handlers = {}
arg = arg or {}

-- print goes to the log
print = function(...)
  local out = {}
  for i = 1, select("#", ...) do out[i] = tostring((select(i, ...))) end
  log(table.concat(out, "\t"))
end

for _, m in ipairs({"love", "love.filesystem", "love.timer", "love.thread", "love.audio", "love.sound",
    "love.system", "love.data", "love.graphics", "love.event", "love.math", "love.window",
    "love.keyboard", "love.mouse", "love.joystick", "love.touch"}) do
  package.preload[m] = function() return love end
end

-- require of the game's modules from the game folder: a.b -> a/b.lua, then a/b/init.lua
table.insert(package.loaders, 2, function(name)
  local base = name:gsub("%.", "/")
  for _, path in ipairs({ base .. ".lua", base .. "/init.lua" }) do
    local d = game_file(path)
    if d then
      local f, err = loadstring(d, "@" .. path)
      if not f then error(err, 0) end
      return f
    end
  end
  return "\n\tno file " .. base .. ".lua or " .. base .. "/init.lua in the game folder"
end)

---------------------------------------------------------------------------
-- Start of the game: conf.lua, main.lua, love.load
---------------------------------------------------------------------------
local function callback(name) return rawget(love, name) end   -- without the "missing" stub

local function run_file(path)
  local src = game_file(path)
  if not src then return false, "not found" end
  local f, err = loadstring(src, "@" .. path)
  if not f then return false, err end
  return xpcall(f, debug.traceback)
end

local t_boot = now()
local conf = {
  identity = nil, appendidentity = false, version = "11.5", console = false,
  accelerometerjoystick = false, externalstorage = false, gammacorrect = false,
  audio = { mic = false, mixwithsystem = true },
  window = { title = game.name, icon = nil, width = W, height = H, borderless = false,
    resizable = false, minwidth = 1, minheight = 1, fullscreen = true, fullscreentype = "exclusive",
    vsync = 1, msaa = 0, depth = nil, stencil = nil, display = 1, highdpi = false,
    usedpiscale = true, x = nil, y = nil },
  modules = { audio = true, data = true, event = true, font = true, graphics = true, image = true,
    joystick = true, keyboard = true, math = true, mouse = true, physics = true, sound = true,
    system = true, thread = true, timer = true, touch = true, video = true, window = true },
}
local ok, err = run_file("conf.lua")
if not ok and err ~= "not found" then log("ERROR loading conf.lua: " .. tostring(err)); return end
if callback("conf") then
  ok, err = xpcall(function() love.conf(conf) end, debug.traceback)
  if not ok then log("ERROR in love.conf: " .. tostring(err)); return end
end
if type(conf.identity) == "string" and conf.identity ~= "" then identity = conf.identity end
if type(conf.window) == "table" and type(conf.window.title) == "string" then title = conf.window.title end
log(string.format("conf.lua: identity %s, title %s (the screen is %dx%d)", identity, title, W, H))

ok, err = run_file("main.lua")
if not ok then log("ERROR loading main.lua: " .. tostring(err)); return end
package.loaded.main = package.loaded.main or true
log(string.format("main.lua and modules: %.0f ms", (now() - t_boot) * 1000))

local t_load = now()
if callback("load") then
  ok, err = xpcall(function() love.load(arg, arg) end, debug.traceback)
  if not ok then log("ERROR in love.load: " .. tostring(err)); return end
end
log(string.format("love.load: %.0f ms (%.1f s since the program started)", (now() - t_load) * 1000, now()))

---------------------------------------------------------------------------
-- Main loop: 30 FPS
---------------------------------------------------------------------------
l360.start_render()
l360.set_context(title)
local frame = 0
timer_last, fps_since = now(), now()
while true do
  local t0 = now()
  timer_step()
  frame = frame + 1
  if frame % 300 == 0 then
    local used, arena = 0, 0
    if l360.heap then used, arena = l360.heap() end
    log(string.format("  [memory] frame %d, %.0f s, Lua %.0f KB, malloc %.0f / %.0f MB",
      frame, now(), collectgarbage("count"), used / 1024, arena / 1024))
    if l360.audio then
      local a = l360.audio.stats()
      log(string.format("  [audio] voices %d, chunks %d, underruns %d, starved %d, mix max %d us, thread %s",
        a.voices, a.chunks, a.underruns, a.starved or 0, a.mix_us_max, a.running and "yes" or "NO"))
    end
  end

  ok, err = xpcall(function()
    l360.poll_input()   -- the controller, once per frame; l360.pad reads that snapshot
    input:update()      -- gamepad callbacks before love.update
    local update = callback("update")
    if update then update(last_dt) end
    threads_step()
  end, debug.traceback)
  if not ok then log("ERROR in update (frame " .. frame .. "): " .. tostring(err)); break end
  gfx.sync()            -- the GPU finished the previous frame while update ran
  ok, err = xpcall(function()
    gfx.origin()
    gfx.clear(background[1], background[2], background[3], background[4])
    local draw = callback("draw")
    if draw then draw() end
  end, debug.traceback)
  if not ok then log("ERROR in draw (frame " .. frame .. "): " .. tostring(err)); break end
  gfx.present()

  if quit_requested then
    quit_requested = false
    local quit = callback("quit")
    local stay
    if quit then
      ok, stay = xpcall(quit, debug.traceback)
      if not ok then log("ERROR in love.quit: " .. tostring(stay)); stay = false end
    end
    if not stay then
      log("love.event.quit: leaving the game")
      if l360.quit then l360.quit() end
      break
    end
  end

  -- 30 FPS: music chunks are loaded in what is left of the frame; then wait for the rest
  streams_step(t0 + DT)
  l360.wait_frame(t0 + DT)
end
