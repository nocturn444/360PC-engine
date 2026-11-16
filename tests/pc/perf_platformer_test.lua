-- examples/perf_platformer: the performance test boots on the console's boot
-- (tests/pc/boot_pc.lua), as shipped and with the automatic benchmark on, and runs on the engine
-- tests' fake love: the level is the same for the same seed, the enemy and particle counts
-- cycle with a key and with a controller button, and the benchmark goes through every pair
-- and writes its results file.
-- Usage, from the repository root: luajit -joff tests/pc/perf_platformer_test.lua   (must end with "OK:")
local GAME = "examples/perf_platformer"
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./tools/?.lua;./" .. GAME .. "/?.lua;" .. package.path
local checks = 0
local raw_print = print
local function check(cond, what)
  checks = checks + 1
  if not cond then raw_print("FAILED: " .. what); os.exit(1) end
end
local function read(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local d = f:read("*a"); f:close(); return d
end
local function run(cmd)
  local p = assert(io.popen(cmd .. " 2>&1"))
  local out = p:read("*a"); p:close()
  return out, out:match("([^\n]*)\n*$")
end
local function count(text, pattern)
  local n = 0
  for _ in text:gmatch(pattern) do n = n + 1 end
  return n
end

---------------------------------------------------------------------------
-- 1. The files, the config and the image
---------------------------------------------------------------------------
local LUA = { "main.lua", "conf.lua", "game.lua", "perf_settings.lua", "perf/atlas.lua", "perf/text.lua",
  "perf/meter.lua", "perf/rooms.lua", "perf/level.lua", "perf/actors.lua", "perf/bench.lua", "perf/play.lua" }
for _, name in ipairs(LUA) do check(read(GAME .. "/" .. name), GAME .. "/" .. name .. " exists") end
for _, name in ipairs({ "tiles.png", "README.md", ".gitignore", "tools/make_tiles.py" }) do
  check(read(GAME .. "/" .. name), GAME .. "/" .. name .. " exists")
end
local Config = dofile("runtime/lua/config.lua")
local cfg, err = Config.load(read(GAME .. "/game.lua"), GAME .. "/game.lua")
check(cfg and cfg.title_id and cfg.identity == "perf_platformer" and cfg.debug == nil,
  "game.lua is valid, with a Title ID and no debug mode: " .. tostring(err))
local png = read(GAME .. "/tiles.png")
check(png:sub(1, 8) == "\137PNG\r\n\26\n" and png:sub(17, 24) == "\0\0\0\128\0\0\0\32", "tiles.png is a 128x32 PNG")
local settings_src = read(GAME .. "/perf_settings.lua")
check(settings_src:find("benchmark = false", 1, true), "the benchmark does not start by itself as shipped")

---------------------------------------------------------------------------
-- 2. Static check: what the game calls in love against the console's subset
---------------------------------------------------------------------------
do
  local data = require("api_subset_data")
  local function status(e) return type(e) == "table" and e[1] or e end
  local guarded = { ["love.filesystem.setRequirePath"] = true }      -- main.lua: only where it exists (PC)
  local bad = {}
  for _, name in ipairs(LUA) do
    local src = read(GAME .. "/" .. name)
    check(not src:find("%f[%w]goto%f[%W]") and not src:find("require%(?%s*[\"']ffi[\"']")
      and not src:find("math%.random") and not src:find("love%.math%.random"),
      name .. ": no goto, no FFI, no unseeded random numbers")
    src = src:gsub("%-%-[^\n]*", "")
    for mod, fn in src:gmatch("love%.(%l+)%.([%a_]+)") do
      local full = "love." .. mod .. "." .. fn
      local st = data.modules["love." .. mod] and status(data.modules["love." .. mod][fn]) or "missing"
      if (st == "missing" or st == "stub") and not guarded[full] then bad[#bad + 1] = full .. " (" .. st .. ")" end
    end
    for fn in src:gmatch("%f[%w_]g%.([%a_]+)%(") do
      local st = status(data.modules["love.graphics"][fn]) or "missing"
      if st == "missing" or st == "stub" then bad[#bad + 1] = "love.graphics." .. fn .. " (" .. st .. ")" end
    end
    check(not src:find("g%.print") and not src:find("graphics%.print"),
      name .. ": no love.graphics.print (the console has no font without a TTF)")
  end
  check(#bad == 0, "the game calls nothing missing or stubbed on the console: " .. table.concat(bad, ", "))
  for _, m in ipairs({ "newSpriteBatch", "newParticleSystem", "getStats", "setBlendMode", "newQuad", "newImage" }) do
    check(status(data.modules["love.graphics"][m]), "love.graphics." .. m .. " is in the subset")
  end
  for ty, methods in pairs({
    SpriteBatch = { "add", "clear", "flush", "setColor" },
    ParticleSystem = { "setBufferSize", "setQuads", "setParticleLifetime", "setEmissionRate", "setEmissionArea",
      "setSpeed", "setSpread", "setLinearAcceleration", "setSizes", "setColors", "setPosition", "update",
      "getCount", "start", "stop" },
    Image = { "getDimensions" },
  }) do
    for _, m in ipairs(methods) do
      local st = status(data.types[ty][m])
      check(st == "full" or st == "partial", ty .. ":" .. m .. " is in the subset: " .. tostring(st))
    end
  end
end

---------------------------------------------------------------------------
-- 3. On the console's boot, without a GPU: as shipped, then with the benchmark on
---------------------------------------------------------------------------
local out, last = run("luajit -joff tests/pc/boot_pc.lua " .. GAME)
check(last:sub(1, 3) == "OK:", "boot_pc.lua " .. GAME .. " ends with OK: " .. last)
check(not out:find("ERROR", 1, true), "and logs no error")
local level_line = out:match("perf: level seed [^\n]*")
check(level_line and level_line:find("seed 000AZJJ (360018)", 1, true) and level_line:find("12 rooms", 1, true),
  "the level is generated at boot from the default seed: " .. tostring(level_line))
local draws = tonumber(last:match("(%d+) draws"))
check(draws and draws >= 90 * 4 and draws <= 90 * 12, "a handful of draw calls per frame: " .. tostring(draws) .. " in 90 frames")
check(not out:find("perf: benchmark started", 1, true), "no benchmark as shipped")

local tmp = run("mktemp -d"):match("[^\n]+")
check(tmp and tmp ~= "", "mktemp")
os.execute("cp -r " .. GAME .. "/. " .. tmp .. "/")
local f = assert(io.open(tmp .. "/perf_settings.lua", "wb"))
f:write((settings_src:gsub("benchmark = false", "benchmark = true"):gsub("bench_seconds = 10", "bench_seconds = 0.5")
  :gsub("bench_warmup = 2", "bench_warmup = 0.2")))
f:close()
-- 12 pairs of 0.2 + 0.5 s at the stub's 30 FPS, and some to spare
out, last = run("L360_FRAMES=320 luajit -joff tests/pc/boot_pc.lua " .. tmp)
os.execute("rm -rf " .. tmp)
check(last:sub(1, 3) == "OK:", "boot_pc.lua with the benchmark on ends with OK: " .. last)
check(not out:find("ERROR", 1, true), "and logs no error")
check(out:find("perf: benchmark started, 12 pairs, 0.5 s each after 0.2 s of warm-up", 1, true), "the benchmark starts at boot")
check(count(out, "perf: | %d+ | %d+ | 30%.0 | 30%.0 | ") == 12, "a row per pair in the log, at the stub's 30 FPS")
check(out:find("perf: | 200 | 2000 | ", 1, true) and out:find("perf: | 0 | 500 | ", 1, true), "from 0 / 500 to 200 / 2000")
check(out:find("perf: benchmark done, 12 rows", 1, true), "the benchmark ends")
check(out:find("perf: results written to perf_results.md in the save folder (12 rows, ", 1, true),
  "the results file went to the console's save folder and reads back")
check(level_line == out:match("perf: level seed [^\n]*"), "the same level on both runs")

---------------------------------------------------------------------------
-- 4. On the fake love, with what this game needs added: SpriteBatch, ParticleSystem, getStats,
--    a clock and a save folder in memory
---------------------------------------------------------------------------
local F = require("fake_love")
F.install({ width = 1280, height = 720, image_w = 128, image_h = 32 })
local g = love.graphics
local batches, drawn_sprites = {}, 0
function g.newSpriteBatch(image, size)
  local b = { kind = "batch", image = image, n = 0, adds = 0 }
  function b:add() self.n = self.n + 1; self.adds = self.adds + 1; return self.n end
  function b:clear() self.n = 0 end
  function b:flush() end
  function b:setColor() end
  function b:getCount() return self.n end
  batches[#batches + 1] = b
  return b
end
local systems = {}
function g.newParticleSystem(image, size)
  local ps = { kind = "particles", image = image, size = size, n = 0, rate = 0, active = true, acc = 0, calls = {} }
  function ps:setBufferSize(n) self.size, self.n = n, 0 end
  function ps:getBufferSize() return self.size end
  function ps:setEmissionRate(r) self.rate = r end
  function ps:getCount() return self.n end
  function ps:start() self.active = true end
  function ps:stop() self.active = false end
  function ps:setPosition(x, y) self.x, self.y = x, y end
  function ps:update(dt)                               -- fills up at its rate; nothing dies
    if not self.active then return end
    self.acc = self.acc + self.rate * dt
    local whole = math.floor(self.acc)
    self.acc = self.acc - whole
    self.n = math.min(self.size, self.n + whole)
  end
  systems[#systems + 1] = ps
  return setmetatable(ps, { __index = function(t, k)     -- the other setters: remembered, nothing else
    if type(k) == "string" and k:sub(1, 3) == "set" then
      return function(self, ...) self.calls[k] = { ... } end
    end
  end })
end
local draw_calls = 0
local fake_draw = g.draw
function g.draw(what, ...)
  draw_calls = draw_calls + 1
  if type(what) == "table" and what.kind == "batch" then drawn_sprites = drawn_sprites + what.n end
  return fake_draw(what, ...)
end
function g.getStats() return { drawcalls = draw_calls, texturememory = 0 } end
local clock = 0
love.timer.getTime = function() clock = clock + 0.0005; return clock end   -- every reading takes half a millisecond
local saved = {}
love.filesystem.write = function(name, text) saved[name] = text; return true end
love.filesystem.read = function(name) return saved[name] end

local printed = {}
local real_print = print
print = function(s) printed[#printed + 1] = tostring(s) end
local settings = require("perf_settings")
check(settings.benchmark == false and #settings.enemy_counts == 4 and #settings.particle_counts == 3
  and settings.enemy_counts[1] == 0 and settings.enemy_counts[4] == 200 and settings.particle_counts[3] == 2000,
  "the settings: N = 0, 50, 100, 200 and 500, 1000, 2000 particles")
settings.bench_seconds, settings.bench_warmup = 0.25, 0.1      -- short, for the test
assert(loadfile(GAME .. "/main.lua"))()
love.load()
local engine = require("engine")
local play = engine.states:top()
check(play == require("perf.play") and engine.time.rate == 60 and engine.screen.width == 320,
  "the play state is entered: 60 Hz, 320x180")
local function frames(n, dt)
  for _ = 1, n do
    clock = clock + (dt or 1 / 60) - 0.002          -- four readings of the clock per frame
    love.update(dt or 1 / 60); love.draw()
  end
end
local function tap(key) F.keys[key] = true; frames(1); F.keys[key] = nil; frames(1) end

-- The level
local level, actors = play.level, play.actors
check(printed[1] == level_line, "the same level as on the console's boot: " .. tostring(printed[1]))
check(level.code == "000AZJJ" and #level.rooms == 12 and level.cells_w >= 4 and level.width >= 4 * 320,
  "12 rooms, at least 4 screens wide: " .. level.cells_w .. " rooms")
local Level = require("perf.level")
local again = Level.new(settings)
check(again.hash == level.hash and #again.spots == #level.spots, "the same seed gives the same level")
local other = Level.new({ seed = "0000C1S", rooms = 12, min_width = 4 })
check(other.hash ~= level.hash and other.cells_w >= 4, "another seed (as a seed code) gives another level")
check(#level.spots >= 200, "room for 200 enemies: " .. #level.spots .. " standing spots")
local first = level.rooms[level.map.start]
check(level.grid.width == level.tiles_w and level.grid:kind(first.tx + 1, first.ty + 1) == "solid"
  and level.grid:kind(first.tx + 2, first.ty + 2) == nil, "the level is one platformer grid")
check(level.sprites == drawn_sprites + level.sprites and #batches >= 12 + 2, "a SpriteBatch per room, one for the actors, one for the overlay")

-- The scene as it starts: 50 enemies, 500 particles
check(actors.count == 50 and play.particles.size == 500, "it starts with 50 enemies and 500 particles")
frames(120)
check(play.particles:getCount() == 500, "the particle buffer fills up: " .. play.particles:getCount())
local body = actors.player.body
check(body.on_ground, "the player stands on the floor of the start room")
local moved = 0
for i = 1, actors.count do
  local e = actors.enemies[i]
  if e.body.x ~= e.spawn_x then moved = moved + 1 end
end
check(moved >= 25, "the enemies patrol: " .. moved .. " of 50 moved")
F.reset_calls(); drawn_sprites = 0
local before = draw_calls
love.draw()
local per_frame = draw_calls - before
check(per_frame >= 4 and per_frame <= 10, "a frame is a few draw calls (rooms in view, actors, particles, overlay, canvas): " .. per_frame)
check(#F.find("print") == 0 and #F.find("rectangle") <= 1, "the overlay is not drawn with print")
check(drawn_sprites >= 240 + 1 + 20, "tiles, actors and the overlay's glyphs go through SpriteBatches: " .. drawn_sprites)
local blends = F.find("setBlendMode")
local additive = false
for k = 1, #blends - 1 do additive = additive or (blends[k][2] == "add" and blends[k + 1][2] == "alpha") end
check(additive, "the particles are drawn with additive blending, and alpha is put back")
local meter = require("perf.meter")
check(math.abs(meter.fps - 60) < 0.5 and math.abs(meter.update_ms - 0.5) < 1e-6 and math.abs(meter.draw_ms - 0.5) < 1e-6
  and math.abs(meter.draw_calls - per_frame) < 0.5,
  string.format("the meter: %.2f FPS, update %.3f ms, draw %.3f ms, %.1f calls", meter.fps, meter.update_ms,
    meter.draw_ms, meter.draw_calls))
local text = table.concat(play.lines, "\n")
check(text:find("FPS  60.0", 1, true) and text:find("ENEMIES 50", 1, true) and text:find("PARTICLES 500/500", 1, true)
  and text:find("SEED 000AZJJ", 1, true) and text:find("CALLS " .. per_frame, 1, true) and text:find("BENCH OFF", 1, true),
  "the overlay shows FPS, timings, draw calls, particles, N and the seed:\n" .. text)

-- The player moves and fights
local x0 = body.x
F.keys.right = true; frames(30); F.keys.right = nil
check(body.x > x0 + 20, "the player walks with the actions: " .. (body.x - x0))
tap("space")
check(not body.on_ground, "and jumps")
frames(60)
local e1 = actors.enemies[1]
e1.body:teleport(body.x + 12, body.y)
body.facing = 1
local hits = actors.hits
tap("x")
frames(10)
check(actors.hits > hits and e1.fighter.health < 3, "the player's attack hits an enemy next to it")
frames(120)
check(e1.machine.state ~= "patrol" or e1.fighter.dead or actors.hits > hits + 1, "an enemy next to the player chases or attacks")

-- Cycling: a key and a controller button for each
tap("e"); check(actors.count == 100, "E: 100 enemies")
tap("e"); check(actors.count == 200, "E: 200 enemies")
frames(60)
check(actors.fight and #actors.enemies == 200, "200 enemies run")
tap("e"); check(actors.count == 0 and #actors.enemies == 0, "E: 0 enemies")
frames(30)
local pad = F.add_pad()
love.joystickadded(pad)
local function press(button) pad.buttons[button] = true; frames(1); pad.buttons[button] = nil; frames(1) end
press("rightshoulder"); check(actors.count == 50, "RB: 50 enemies again")
tap("p"); check(play.particles.size == 1000, "P: 1000 particles")
frames(120); check(play.particles:getCount() == 1000, "and they fill up")
press("leftshoulder"); check(play.particles.size == 2000, "LB: 2000 particles")
frames(150); check(play.particles:getCount() == 2000, "and they fill up")
local tick = engine.time.tick
frames(30, 1 / 30)
check(engine.time.tick == tick + 60, "frames at the console's 30 FPS run two steps: " .. engine.time.tick - tick)
tap("p"); check(play.particles.size == 500, "P: 500 particles again")
tap("o"); F.reset_calls(); before = draw_calls; love.draw()
local hidden = draw_calls - before
tap("o"); before = draw_calls; love.draw()
check(draw_calls - before == hidden + 1, "O hides the overlay (one draw call less) and shows it again")

-- The benchmark: Start (or B) runs every pair with the autopilot and writes the file
check(saved["perf_results.md"] == nil and not play.bench.active, "no results before the benchmark")
x0 = body.x
press("start")
check(play.bench.active and actors.count == 0 and play.particles.size == 500, "Start: the benchmark begins with 0 / 500")
tap("e")
check(actors.count == 0, "the counts are the benchmark's while it runs")
local guard = 0
while play.bench.active and guard < 5000 do frames(1); guard = guard + 1 end
check(play.bench.done and not play.bench.active, "the benchmark ends: " .. guard .. " frames")
check(guard >= 12 * 0.35 * 60 - 12 and guard <= 12 * 0.35 * 60 + 40, "after 12 pairs of 0.1 + 0.25 s")
check(math.abs(body.x - x0) > 100, "the autopilot moved the player: " .. (body.x - x0))
local results = saved["perf_results.md"]
check(type(results) == "string", "the results file is written")
check(results:find("| N enemies | Particles | FPS avg | FPS min | Update ms | Draw ms | Draw calls |\n|---|---|---|---|---|---|---|\n", 1, true),
  "with the table's header")
check(results:find("Seed 000AZJJ (360018), level hash " .. string.format("%08x", level.hash), 1, true)
  and results:find("Platform: Linux, 1280x720, pixel mode canvas", 1, true), "and the run's description")
local rows = {}
for line in results:gmatch("[^\n]+") do
  local n, p, fps, fps_min, upd, drw, calls =
    line:match("^| (%d+) | (%d+) | ([%d%.]+) | ([%d%.]+) | ([%d%.]+) | ([%d%.]+) | ([%d%.]+) |$")
  if n then
    rows[#rows + 1] = { tonumber(n), tonumber(p), tonumber(fps), tonumber(fps_min), tonumber(upd), tonumber(drw), tonumber(calls) }
  end
end
check(#rows == 12, "12 rows: " .. #rows)
local i = 0
for _, n in ipairs(settings.enemy_counts) do
  for _, p in ipairs(settings.particle_counts) do
    i = i + 1
    local r = rows[i]
    check(r[1] == n and r[2] == p, "row " .. i .. " is " .. n .. " enemies, " .. p .. " particles")
    check(math.abs(r[3] - 60) < 0.2 and math.abs(r[4] - 60) < 0.2 and r[5] == 0.5 and r[6] == 0.5 and r[7] >= 4 and r[7] <= 10,
      "row " .. i .. ": 60 FPS, 0.5 ms and 0.5 ms on the test's clock, a few draw calls: " .. table.concat(r, " "))
  end
end
check(count(results, "\n| %d+ | %d+ | %d+ | 1%.00 | ") == 12, "and a row of details each, one step per frame")
check(count(table.concat(printed, "\n"), "perf: | %d+ | %d+ | ") == 12, "the rows are logged too")
check(printed[#printed]:find("perf: results written to perf_results.md", 1, true)
  or printed[#printed - 1]:find("perf: results written to perf_results.md", 1, true), "and the file is announced")
check(table.concat(play.lines, "\n"):find("BENCH DONE 12 ROWS", 1, true) and actors.count == 200, "the overlay says so")
check(actors.hits > hits + 2, "the fight went on during the benchmark: " .. actors.hits .. " hits")
-- A second press starts again, and a press while it runs stops it
press("start"); check(play.bench.active, "Start again: a new run")
frames(10)
tap("b"); check(not play.bench.active and not play.bench.done, "B while it runs stops it")
check(not table.concat(printed, "\n"):find("ERROR", 1, true), "nothing logged an error")
F.keys.escape = true; frames(1)
check(F.quit == true, "Escape leaves the game")
print = real_print

print(string.format("OK: %d checks; perf_platformer boots, cycles its settings and writes its benchmark", checks))
