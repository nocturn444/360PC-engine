-- engine.audio: sound effects and music for any game, over love.audio. The game lists its
-- sounds and tracks as data; this module keeps a few voices per effect (so the same hit can
-- overlap itself), varies pitch and volume a little, crossfades music, keeps the volumes of
-- named buses ("master", "music", "sfx" or any the game adds) and pauses everything at once.
-- See docs/ENGINE.md.
--
--   local sfx = engine.audio.new({
--     sounds = { jump = { file = "sfx/jump.wav", volume = 0.8, pitch_var = 0.08, voices = 3 },
--                hit  = { file = "sfx/hit.wav", min_gap = 0.05 } },
--     music  = { cave = { file = "music/cave.ogg", volume = 0.7 } },
--     volumes = { music = 0.8 },
--   })
--   sfx:preload()                          -- in load: no file is read in the middle of play
--   sfx:play("jump")                       -- in a step
--   sfx:music("cave", { fade = 1 })        -- crossfade from whatever was playing
--   sfx:update(dt)                         -- every step or frame (fades, min_gap)
--
-- Console limits (docs/API_SUBSET.md): WAV only (16-bit PCM or mono IMA ADPCM; "x.ogg" loads
-- "x.wav" next to it), pitch up to 16, 32 voices in the mixer. Only newSource, the Source
-- methods play / stop / pause / setVolume / setPitch / setLooping / isPlaying / clone and
-- love.audio.getActiveSourceCount are used. A warm play allocates nothing.
local floor, max, min = math.floor, math.max, math.min

local M = {}
local Audio = {}
Audio.__index = Audio

M.MAX_PITCH = 16          -- the console's limit
M.MIN_PITCH = 1 / 16
M.DEFAULT_VOICES = 4
M.DEFAULT_MAX_ACTIVE = 28 -- below the console mixer's 32, so music always has room

local function clamp01(v) return v < 0 and 0 or (v > 1 and 1 or v) end

-- The module's own generator (an LCG; every product stays below 2^53, so it is exact in doubles
-- and the same on PC and console): pitch and volume variation never touches the game's rng.
local function next_random(self)
  local s = (self.seed * 1664525 + 1013904223) % 4294967296
  self.seed = s
  return s / 4294967296
end

-- audio.new(opts):
--   sounds       { name = { file, volume (1), pitch (1), pitch_var (0), volume_var (0),
--                  voices (4), bus ("sfx"), min_gap (0 s), loop (false) } }
--   music        { name = { file, volume (1), bus ("music"), loop (true) } }
--   volumes      starting bus volumes, 0..1 (master, music and sfx are 1 unless given)
--   max_active   no new effect starts while love.audio has this many sources playing (28)
--   seed         for the pitch / volume variation (1)
--   audio        the love.audio to use (tests); log: function(text), default print
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    la = opts.audio or love.audio, log = opts.log or print,
    sounds = {}, tracks = {}, volumes = { master = 1, music = 1, sfx = 1 },
    max_active = opts.max_active or M.DEFAULT_MAX_ACTIVE,
    seed = floor(opts.seed or 1) % 4294967296,
    time = 0, paused = false, held = {}, held_n = 0,
    current = nil, fading = {}, fading_n = 0, warned = {},
  }, Audio)
  for bus, v in next, opts.volumes or {} do self.volumes[bus] = clamp01(v) end
  for name, def in next, opts.sounds or {} do self:addSound(name, def) end
  for name, def in next, opts.music or {} do self:addMusic(name, def) end
  return self
end

function Audio:_warn(key, text)
  if self.warned[key] then return end
  self.warned[key] = true
  self.log("[audio] " .. text)
end

-- Adds or replaces an effect (fields as in audio.new). Returns the Audio.
function Audio:addSound(name, def)
  assert(type(def) == "table" and type(def.file) == "string", "audio:addSound: " .. tostring(name) .. " needs a file")
  local voices = max(1, floor(def.voices or M.DEFAULT_VOICES))
  self.sounds[name] = {
    file = def.file, volume = def.volume or 1, pitch = def.pitch or 1,
    pitch_var = def.pitch_var or 0, volume_var = def.volume_var or 0,
    voices = voices, bus = def.bus or "sfx", min_gap = def.min_gap or 0, loop = def.loop == true,
    pool = nil, base = {}, next = 1, last = -math.huge, failed = false,
  }
  if self.volumes[self.sounds[name].bus] == nil then self.volumes[self.sounds[name].bus] = 1 end
  return self
end

-- Adds or replaces a music track (fields as in audio.new). Returns the Audio.
function Audio:addMusic(name, def)
  assert(type(def) == "table" and type(def.file) == "string", "audio:addMusic: " .. tostring(name) .. " needs a file")
  self.tracks[name] = { name = name, file = def.file, volume = def.volume or 1, bus = def.bus or "music",
    loop = def.loop ~= false, src = nil, gain = 0, target = 0, speed = 0, failed = false }
  if self.volumes[self.tracks[name].bus] == nil then self.volumes[self.tracks[name].bus] = 1 end
  return self
end

function Audio:_new_source(file, kind)
  local ok, src = pcall(self.la.newSource, file, kind)
  if ok and src then return src end
  self:_warn(file, "could not load " .. file .. ": " .. tostring(src))
  return nil
end

function Audio:_bus_gain(bus)
  return (self.volumes.master or 1) * (self.volumes[bus] or 1)
end

-- Creates the voices of an effect (the first one reads the file, the others are clones).
function Audio:_load_sound(s)
  if s.pool or s.failed then return s.pool end
  local first = self:_new_source(s.file, "static")
  if not first then s.failed = true; return nil end
  first:setLooping(s.loop)
  local pool = { first }
  for i = 2, s.voices do
    local c = first:clone()
    c:setLooping(s.loop)
    pool[i] = c
  end
  for i = 1, s.voices do s.base[i] = 0 end
  s.pool = pool
  return pool
end

function Audio:_load_track(t)
  if t.src or t.failed then return t.src end
  local src = self:_new_source(t.file, "stream")
  if not src then t.failed = true; return nil end
  src:setLooping(t.loop)
  t.src = src
  return src
end

-- Loads every effect and track now (or only the names given), so play never reads a file.
-- Returns the number of names that failed to load.
function Audio:preload(names)
  local failed = 0
  if names then
    for _, n in ipairs(names) do
      local s, t = self.sounds[n], self.tracks[n]
      if s then failed = failed + (self:_load_sound(s) and 0 or 1)
      elseif t then failed = failed + (self:_load_track(t) and 0 or 1)
      else self:_warn(n, "unknown sound or track " .. tostring(n)); failed = failed + 1 end
    end
    return failed
  end
  for _, s in next, self.sounds do failed = failed + (self:_load_sound(s) and 0 or 1) end
  for _, t in next, self.tracks do failed = failed + (self:_load_track(t) and 0 or 1) end
  return failed
end

-- Plays an effect. volume and pitch multiply the sound's own (default 1). Returns the Source,
-- or nil when it did not play: unknown or unloadable sound, paused, inside its min_gap, or
-- the mixer is full. With every voice of the sound busy, the oldest started one is reused.
function Audio:play(name, volume, pitch)
  local s = self.sounds[name]
  if not s then self:_warn(name, "unknown sound " .. tostring(name)); return nil end
  if self.paused then return nil end
  if self.time - s.last < s.min_gap then return nil end
  local pool = s.pool or self:_load_sound(s)
  if not pool then return nil end
  -- a free voice of this sound, else the next one in turn (the oldest started)
  local n, i = s.voices, s.next
  local src, slot
  for k = 0, n - 1 do
    local j = (i - 1 + k) % n + 1
    if not pool[j]:isPlaying() then src, slot = pool[j], j; break end
  end
  if not src then
    slot = i; src = pool[i]
    src:stop()
  elseif self.la.getActiveSourceCount and self.la.getActiveSourceCount() >= self.max_active then
    return nil
  end
  s.next = slot % n + 1
  s.last = self.time
  local vol = s.volume * (volume or 1)
  if s.volume_var > 0 then vol = vol * (1 - s.volume_var * next_random(self)) end
  local p = s.pitch * (pitch or 1)
  if s.pitch_var > 0 then p = p * (1 + s.pitch_var * (2 * next_random(self) - 1)) end
  p = p < M.MIN_PITCH and M.MIN_PITCH or (p > M.MAX_PITCH and M.MAX_PITCH or p)
  s.base[slot] = clamp01(vol)
  src:setVolume(s.base[slot] * self:_bus_gain(s.bus))
  src:setPitch(p)
  src:play()
  return src
end

-- Stops every voice of an effect (a looping one too).
function Audio:stop(name)
  local s = self.sounds[name]
  if not (s and s.pool) then return end
  for i = 1, s.voices do s.pool[i]:stop() end
end

-- Is any voice of the effect playing?
function Audio:isPlaying(name)
  local s = self.sounds[name]
  if not (s and s.pool) then return false end
  for i = 1, s.voices do if s.pool[i]:isPlaying() then return true end end
  return false
end

local function add_fading(self, t)
  for i = 1, self.fading_n do if self.fading[i] == t then return end end
  self.fading_n = self.fading_n + 1
  self.fading[self.fading_n] = t
end

-- Plays a music track, crossfading from the one playing. name nil fades the music out.
-- opts.fade: seconds (0 = cut, default 0.5); opts.restart: start the same track again from
-- the beginning instead of leaving it alone. Returns true if the track is (now) playing.
function Audio:music(name, opts)
  local fade = opts and opts.fade or 0.5
  local old = self.current
  local new = name and self.tracks[name]
  if name and not new then self:_warn(name, "unknown track " .. tostring(name)); return false end
  if new and new == old and not (opts and opts.restart) then
    new.target = 1
    if new.gain < 1 then new.speed = fade > 0 and 1 / fade or math.huge; add_fading(self, new) end
    return new.src ~= nil
  end
  if old then
    old.target = 0
    old.speed = fade > 0 and 1 / fade or math.huge
    add_fading(self, old)
  end
  self.current = nil
  if not new then self:update(0); return true end
  local src = new.src or self:_load_track(new)
  if not src then self:update(0); return false end
  if new == old or src:isPlaying() then src:stop() end
  new.gain, new.target = fade > 0 and 0 or 1, 1
  new.speed = fade > 0 and 1 / fade or math.huge
  src:setVolume(new.gain * new.volume * self:_bus_gain(new.bus))
  if not self.paused then src:play() end
  self.current = new
  add_fading(self, new)
  self:update(0)
  return true
end

-- The name of the track playing (or fading in), or nil.
function Audio:currentMusic() return self.current and self.current.name end

-- Advances fades and the clock used by min_gap. Call it every step or every frame.
function Audio:update(dt)
  if not self.paused then self.time = self.time + dt end
  local i = 1
  while i <= self.fading_n do
    local t = self.fading[i]
    if t.speed == math.huge then
      t.gain = t.target
    elseif not self.paused then
      if t.gain < t.target then t.gain = min(t.target, t.gain + t.speed * dt)
      elseif t.gain > t.target then t.gain = max(t.target, t.gain - t.speed * dt) end
    end
    if t.src then t.src:setVolume(t.gain * t.volume * self:_bus_gain(t.bus)) end
    if t.gain == t.target then
      if t.target == 0 and t.src then t.src:stop() end
      self.fading[i] = self.fading[self.fading_n]
      self.fading[self.fading_n] = nil
      self.fading_n = self.fading_n - 1
    else
      i = i + 1
    end
  end
end

-- Re-applies the bus volumes to everything that is playing.
function Audio:_refresh()
  for _, s in next, self.sounds do
    if s.pool then
      local g = self:_bus_gain(s.bus)
      for i = 1, s.voices do s.pool[i]:setVolume(s.base[i] * g) end
    end
  end
  for _, t in next, self.tracks do
    if t.src then t.src:setVolume(t.gain * t.volume * self:_bus_gain(t.bus)) end
  end
end

-- Volume of a bus, 0..1 ("master" scales every bus). Takes effect at once, on what is playing too.
function Audio:setVolume(bus, v)
  self.volumes[bus] = clamp01(v)
  self:_refresh()
end
function Audio:getVolume(bus) return self.volumes[bus] or 1 end

-- The bus volumes as a new plain table, to keep in the permanent progress (engine.save); and
-- setVolumes to apply such a table back (unknown or broken values are skipped).
function Audio:getVolumes()
  local out = {}
  for k, v in next, self.volumes do out[k] = v end
  return out
end
function Audio:setVolumes(t)
  if type(t) ~= "table" then return end
  for k, v in next, t do
    if type(k) == "string" and type(v) == "number" and v == v then self.volumes[k] = clamp01(v) end
  end
  self:_refresh()
end

-- Pauses everything this Audio is playing (a pause menu); resume plays it on from where it was.
-- While paused, play does nothing and fades wait.
function Audio:pause()
  if self.paused then return end
  self.paused = true
  local held = self.held
  for _, s in next, self.sounds do
    if s.pool then
      for i = 1, s.voices do
        local src = s.pool[i]
        if src:isPlaying() then src:pause(); self.held_n = self.held_n + 1; held[self.held_n] = src end
      end
    end
  end
  for _, t in next, self.tracks do
    if t.src and t.src:isPlaying() then t.src:pause(); self.held_n = self.held_n + 1; held[self.held_n] = t.src end
  end
end
function Audio:resume()
  if not self.paused then return end
  self.paused = false
  for i = 1, self.held_n do self.held[i]:play(); self.held[i] = nil end
  self.held_n = 0
end

-- Stops every effect and the music at once (no fade): leaving a level, quitting to the title.
function Audio:stopAll()
  for name in next, self.sounds do self:stop(name) end
  for _, t in next, self.tracks do
    if t.src then t.src:stop() end
    t.gain, t.target = 0, 0
  end
  for i = 1, self.fading_n do self.fading[i] = nil end
  self.fading_n = 0
  for i = 1, self.held_n do self.held[i] = nil end
  self.held_n = 0
  self.paused = false
  self.current = nil
end

return M
