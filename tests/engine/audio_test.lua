-- engine.audio on a fake love.audio: voices per effect and stealing, min_gap, pitch / volume
-- variation within range and the same for the same seed, the mixer cap, buses and master,
-- crossfades and cuts, pause / resume, missing files, nothing allocated per warm play, and a
-- static check that the module uses nothing the console lacks.
local T = ...
local F = require("fake_love")
F.install()
local globals = {}
for k in pairs(_G) do globals[k] = true end
local audio = require("engine.audio")

-- fake love.audio: Sources that remember volume, pitch, looping and play state
local created, active, logs = {}, 0, {}
local Src = {}
Src.__index = Src
local function new_src(file, kind)
  local s = setmetatable({ file = file, kind = kind, vol = 1, pitch = 1, loop = false, state = "stopped", plays = 0 }, Src)
  created[#created + 1] = s
  return s
end
function Src:play() if self.state ~= "playing" then active = active + 1 end; self.state = "playing"; self.plays = self.plays + 1 end
function Src:stop() if self.state == "playing" then active = active - 1 end; self.state = "stopped" end
function Src:pause() if self.state == "playing" then active = active - 1 end; self.state = "paused" end
function Src:isPlaying() return self.state == "playing" end
function Src:setVolume(v) self.vol = v end
function Src:setPitch(p) self.pitch = p end
function Src:setLooping(l) self.loop = l end
function Src:clone() local c = new_src(self.file, self.kind); c.cloned = true; return c end
local LA = {
  newSource = function(file, kind)
    if file:find("missing") then error("Could not open file " .. file) end
    return new_src(file, kind)
  end,
  getActiveSourceCount = function() return active end,
}

local function make(opts)
  opts = opts or {}
  opts.audio, opts.log = LA, function(t) logs[#logs + 1] = t end
  opts.sounds = opts.sounds or {
    jump = { file = "sfx/jump.wav", volume = 0.5, voices = 2 },
    hit = { file = "sfx/hit.wav", pitch_var = 0.2, volume_var = 0.3, min_gap = 0.1 },
    gone = { file = "sfx/missing.wav" },
  }
  opts.music = opts.music or { a = { file = "music/a.ogg", volume = 0.5 }, b = { file = "music/b.ogg" } }
  return audio.new(opts)
end

-- loading
local a = make()
T.check(#created == 0, "nothing is read before preload or the first play")
T.check(a:preload() == 1 and #logs == 1 and logs[1]:find("missing.wav"), "preload: one failure, logged once")
T.check(#created == 2 + 4 + 2, "voices: jump 2, hit 4 (default), plus one stream per track")
T.check(created[1].kind == "static" or created[3].kind == "static", "effects are static sources")
local streams = 0
for _, s in ipairs(created) do if s.kind == "stream" then streams = streams + 1; T.check(s.loop, "tracks loop by default") end end
T.check(streams == 2, "music uses stream sources")
T.check(a:play("gone") == nil and #logs == 1, "a missing file: play returns nil, no second log")
T.check(a:play("nope") == nil and logs[2]:find("unknown sound"), "an unknown name is logged")

-- voices and stealing
local s1 = a:play("jump")
local s2 = a:play("jump")
T.check(s1 and s2 and s1 ~= s2, "two voices play at once")
T.near(s1.vol, 0.5, "volume: the sound's own times the buses")
local s3 = a:play("jump")
T.check(s3 == s1 and s1.plays == 2, "with every voice busy, the oldest started is reused")
s2:stop()
T.check(a:play("jump") == s2, "a free voice is taken before stealing")
a:stop("jump")
T.check(not a:isPlaying("jump"), "stop stops every voice")

-- min_gap
T.check(a:play("hit") ~= nil and a:play("hit") == nil, "min_gap: the same effect twice in one step plays once")
a:update(0.1)
T.check(a:play("hit") ~= nil, "it plays again once the gap has passed")

-- variation in range, the same for the same seed
local function series(seed)
  local b = make({ seed = seed })
  local out = {}
  for i = 1, 20 do
    b:update(0.2)
    local src = b:play("hit")
    T.check(src.pitch >= 0.8 - 1e-9 and src.pitch <= 1.2 + 1e-9, "pitch_var 0.2 keeps the pitch in 0.8..1.2")
    T.check(src.vol >= 0.7 - 1e-9 and src.vol <= 1 + 1e-9, "volume_var 0.3 keeps the volume in 0.7..1")
    out[i] = src.pitch
  end
  return out
end
local p1, p2, p3 = series(7), series(7), series(8)
local same, differ, spread = true, false, false
for i = 1, 20 do
  if p1[i] ~= p2[i] then same = false end
  if p1[i] ~= p3[i] then differ = true end
  if math.abs(p1[i] - p1[1]) > 0.02 then spread = true end
end
T.check(same and differ and spread, "the variation varies, and the same seed gives the same series")
local hi = make({ sounds = { up = { file = "u.wav", pitch = 12, voices = 1 } } })
T.check(hi:play("up", 1, 3).pitch == 16, "pitch is capped at the console's 16")

-- mixer cap
local c = make({ max_active = 3 })
local before = active
active = 3
T.check(c:play("jump") == nil, "no new effect while love.audio already has max_active playing")
active = before

-- buses
local d = make()
local j = d:play("jump")
d:setVolume("sfx", 0.5)
T.near(j.vol, 0.25, "a bus change reaches what is playing")
d:setVolume("master", 0.5)
T.near(j.vol, 0.125, "master scales every bus")
d:setVolume("sfx", 3)
T.check(d:getVolume("sfx") == 1, "volumes are clamped to 0..1")
local saved = d:getVolumes()
saved.sfx = 0.2
T.check(d:getVolume("sfx") == 1, "getVolumes returns a copy")
d:setVolumes({ sfx = 0.2, music = "loud", [1] = 0.5, master = 0 / 0 })
T.check(d:getVolume("sfx") == 0.2 and d:getVolume("music") == 1 and d:getVolume("master") == 0.5,
  "setVolumes applies good numbers and skips broken ones")

-- music: crossfade and cut
local m = make()
T.check(m:music("a", { fade = 1 }) and m:currentMusic() == "a", "a track starts")
local ta = m.tracks.a.src
T.check(ta:isPlaying() and ta.vol == 0, "fading in from silence")
m:update(0.5)
T.near(ta.vol, 0.25, "half way: half of the track's 0.5")
m:update(0.6)
T.near(ta.vol, 0.5, "faded in")
T.check(m:music("a") and ta.plays == 1, "asking for the track that plays leaves it alone")
m:music("b", { fade = 2 })
local tb = m.tracks.b.src
m:update(1)
T.near(ta.vol, 0.25, "crossfade: the old track halfway down")
T.near(tb.vol, 0.5, "crossfade: the new track halfway up")
m:update(1)
T.check(not ta:isPlaying() and tb.vol == 1 and m:currentMusic() == "b", "the old track stops once silent")
m:music(nil, { fade = 0 })
T.check(not tb:isPlaying() and m:currentMusic() == nil, "music(nil) with fade 0 cuts at once")
T.check(tb.vol == tb.vol, "no NaN volume on a cut")
T.check(not m:music("zzz") and logs[#logs]:find("unknown track"), "an unknown track is logged")
local bad = make({ music = { x = { file = "missing.ogg" } } })
T.check(bad:music("x") == false, "a track that cannot load reports false")

-- pause and resume
local p = make()
p:music("b", { fade = 0 })
local pj = p:play("jump")
p:pause()
T.check(pj.state == "paused" and p.tracks.b.src.state == "paused", "pause pauses effects and music")
T.check(p:play("jump") == nil, "nothing new plays while paused")
p:resume()
T.check(pj.state == "playing" and p.tracks.b.src.state == "playing", "resume plays them on")
p:stopAll()
T.check(not pj:isPlaying() and not p.tracks.b.src:isPlaying() and p:currentMusic() == nil, "stopAll")

-- a warm play allocates nothing
local w = make()
w:preload()
w:music("a", { fade = 0.5 })
for _ = 1, 10 do w:play("jump"); w:update(1 / 60) end
collectgarbage(); collectgarbage("stop")
local kb = collectgarbage("count")
for _ = 1, 500 do w:play("jump"); w:play("hit"); w:update(1 / 60) end
local grown = collectgarbage("count") - kb
collectgarbage("restart")
T.check(grown < 1, "play and update allocate nothing once warm (" .. grown .. " KB)")

-- static check against the console subset
package.path = "tools/?.lua;" .. package.path
local data = require("api_subset_data")
local function status(e) return type(e) == "table" and e[1] or e end
local f = assert(io.open("engine/audio.lua", "rb"))
local src = f:read("*a"):gsub("%-%-[^\n]*", "")
f:close()
for _, fn in ipairs({ "newSource", "getActiveSourceCount" }) do
  T.check(src:find("la%." .. fn) or src:find("%." .. fn .. "[,)]"), "audio.lua uses love.audio." .. fn)
  T.check(status(data.modules["love.audio"][fn]) ~= "missing", "love.audio." .. fn .. " is on the console")
end
local used = 0
for recv, m in src:gmatch("([%w_%.%[%]]+):(%a+)%(") do
  if recv ~= "self" and recv ~= "Audio" then
    used = used + 1
    local st = status(data.types.Source[m])
    T.check(st == "full" or st == "partial", "Source:" .. m .. " (called on " .. recv .. ") is on the console")
  end
end
T.check(used >= 10, "the scan found the Source calls (" .. used .. ")")
T.check(not src:find("love%.audio%.") or src:find("opts%.audio or love%.audio"), "only love.audio itself is read, as the default")

T.check(require("engine").audio == audio, "engine.audio")
T.no_new_globals(globals)
