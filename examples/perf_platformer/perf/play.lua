-- The test's only state: the level, the actors, the particles, the overlay and the benchmark.
local engine = require("engine")
local atlas = require("perf.atlas")
local meter = require("perf.meter")
local Level = require("perf.level")
local Actors = require("perf.actors")
local Text = require("perf.text")
local Bench = require("perf.bench")
local format = string.format

local W, H = 320, 180
local play = { show_overlay = true }

-- Called from engine.run's load (love.load): images exist from here on
function play:load(settings)
  self.settings = settings
  atlas.load()
  local level = Level.new(settings)
  level:build(atlas)
  self.level = level
  self.camera = engine.camera.new({ width = W, height = H, lerp = 8, deadzone_w = 32, deadzone_h = 16, snap = true })
  self.camera:setBounds(0, 0, level.width, level.height)
  self.actors = Actors.new(level, atlas)
  self.pilot = Actors.pilot()
  local body = self.actors.player.body
  self.camera:setPosition(body.x, body.y)

  self.particles = love.graphics.newParticleSystem(atlas.image, 1)
  self.overlay = Text.new(512)
  self.lines = {}
  self.overlay_t, self.frame_tick = 0, 0

  self.bench = Bench.new({
    enemy_counts = settings.enemy_counts, particle_counts = settings.particle_counts,
    seconds = settings.bench_seconds, warmup = settings.bench_warmup, file = settings.results_file,
    apply = function(e, p) self:set_enemies(e); self:set_particles(p) end,
    info = function()
      return {
        format("Platform: %s, %dx%d, pixel mode %s", love.system.getOS(), love.graphics.getWidth(),
          love.graphics.getHeight(), engine.screen.mode),
        format("Seed %s (%d), level hash %08x: %d rooms, %dx%d tiles, %d tile sprites", level.code, level.seed,
          level.hash, #level.rooms, level.tiles_w, level.tiles_h, level.sprites),
        format("Logic at %d Hz; the update time is the whole frame's (every fixed step it ran)", engine.time.rate),
      }
    end,
    on_done = function() if settings.bench_quit then love.event.quit() end end,
  })

  self:set_enemies(settings.start_enemies or 1)
  self:set_particles(settings.start_particles or 1)
  print(format("perf: level seed %s (%d), hash %08x, %d rooms, %dx%d tiles, %d standing spots, %d tile sprites",
    level.code, level.seed, level.hash, #level.rooms, level.tiles_w, level.tiles_h, #level.spots, level.sprites))
  self:refresh_overlay()
  if settings.benchmark then self.bench:start() end
end

function play:set_enemies(index)
  local counts = self.settings.enemy_counts
  self.enemy_index = (index - 1) % #counts + 1
  self.actors:setCount(counts[self.enemy_index])
end

-- One system whose buffer is the count: it emits faster than the particles die, so the
-- buffer stays full and the number alive is the number asked for
function play:set_particles(index)
  local counts = self.settings.particle_counts
  self.particle_index = (index - 1) % #counts + 1
  local n = counts[self.particle_index]
  local ps = self.particles
  ps:setBufferSize(math.max(n, 1))
  ps:setQuads(atlas.particle)
  ps:setParticleLifetime(1.5, 2.5)
  ps:setEmissionRate(n)
  ps:setEmissionArea("uniform", W / 2 - 8, H / 2 - 8)
  ps:setSpeed(4, 28)
  ps:setSpread(2 * math.pi)
  ps:setLinearAcceleration(-6, 8, 6, 36)
  ps:setSizes(1, 0.75, 0.25)
  ps:setColors(1, 0.95, 0.6, 0.9, 1, 0.55, 0.2, 0.6, 0.9, 0.2, 0.1, 0)
  if n == 0 then ps:stop() else ps:start() end
end

function play:input(input)
  if input:pressed("quit") then love.event.quit() end
  if input:pressed("overlay") then self.show_overlay = not self.show_overlay end
  if input:pressed("benchmark") then
    if self.bench.active then self.bench:cancel() else self.bench:start() end
    self:refresh_overlay()
  end
  if self.bench.active then return end       -- the benchmark chooses the counts
  if input:pressed("enemies") then
    self:set_enemies(self.enemy_index + 1)
    self:refresh_overlay()
  end
  if input:pressed("particles") then
    self:set_particles(self.particle_index + 1)
    self:refresh_overlay()
  end
end

function play:update(dt)
  local input = engine.controls
  if self.bench.active then            -- the autopilot plays, the same way on every run
    input = self.pilot
    input:step(self.actors.player.body)
  end
  self.actors:step(input, dt)
  local body, camera = self.actors.player.body, self.camera
  camera:follow(body.x + body.w / 2, body.y + body.h / 2)
  camera:update(dt)
  self.particles:setPosition(camera.x, camera.y)
  self.particles:update(dt)
end

function play:draw(alpha)
  local g, camera = love.graphics, self.camera
  camera:attach(alpha)
  local vx, vy, vw, vh = camera:getViewport(alpha)
  self.level:draw(vx, vy, vw, vh)
  self.actors:draw(alpha, vx, vy, vw, vh)
  g.setBlendMode("add")
  g.draw(self.particles, 0, 0)
  g.setBlendMode("alpha")
  camera:detach()
  if self.show_overlay then self.overlay:draw(2, 2) end
end

function play:refresh_overlay()
  local s, level, actors, lines = self.settings, self.level, self.actors, self.lines
  lines[1] = format("FPS %5.1f  FRAME %5.2f MS  WORST %5.2f MS", meter.fps, meter.frame_ms, meter:take_worst())
  lines[2] = format("UPDATE %5.2f MS  DRAW %5.2f MS  CALLS %.0f", meter.update_ms, meter.draw_ms, meter.draw_calls)
  lines[3] = format("ENEMIES %d (%d DRAWN)  PARTICLES %d/%d", actors.count, actors.drawn,
    self.particles:getCount(), s.particle_counts[self.particle_index])
  lines[4] = format("SEED %s  %d ROOMS  HITS %d  KILLS %d", level.code, #level.rooms, actors.hits, actors.kills)
  lines[5] = "BENCH " .. self.bench:status()
  lines[6] = "RB/E ENEMIES  LB/P PARTICLES  START/B BENCH  Y/O OVERLAY"
  self.overlay:set(lines, true)
end

-- Called by main.lua after each frame's draw with the frame's raw timings (seconds) and draw calls
function play:frame(frame, update, draw, calls)
  local tick = engine.time.tick
  local steps = tick - self.frame_tick
  self.frame_tick = tick
  local was_active = self.bench.active
  self.bench:frame(frame, update, draw, calls, steps, self.particles:getCount(), self.actors.drawn)
  self.overlay_t = self.overlay_t + frame
  if self.overlay_t >= self.settings.overlay_interval or was_active ~= self.bench.active then
    self.overlay_t = 0
    self:refresh_overlay()
  end
end

return play
