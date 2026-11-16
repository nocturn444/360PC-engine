-- The automatic benchmark: every (enemies, particles) pair in turn, a fixed number of seconds
-- each. It logs one markdown table row per pair (print: the console's log) and writes the
-- whole table to a file in the save folder, again after each pair so a run that is cut short
-- keeps what it measured.
local format = string.format

local Bench = {}
Bench.__index = Bench

Bench.HEADER = "| N enemies | Particles | FPS avg | FPS min | Update ms | Draw ms | Draw calls |"
Bench.RULE = "|---|---|---|---|---|---|---|"
local DETAIL_HEADER = "| N enemies | Particles | Frames | Steps/frame | Worst frame ms | Worst update ms | Worst draw ms | Active particles | Enemies drawn |"
local DETAIL_RULE = "|---|---|---|---|---|---|---|---|---|"

-- opts:
--   enemy_counts, particle_counts   the lists to go through
--   seconds, warmup                 measured seconds per pair, and seconds left out before them
--   file                            the results file's name
--   apply(enemy_index, particle_index)   switches the game to that pair
--   info()                          the lines that describe the run (platform, seed...), for the file
--   on_done(bench)                  the last pair was measured
--   log                             default: print
function Bench.new(opts)
  local self = setmetatable({}, Bench)
  self.enemy_counts, self.particle_counts = opts.enemy_counts, opts.particle_counts
  self.seconds, self.warmup = opts.seconds or 10, opts.warmup or 2
  self.file = opts.file or "perf_results.md"
  self.apply, self.info, self.on_done = opts.apply, opts.info, opts.on_done
  self.log = opts.log or print
  self.active, self.done = false, false
  self.pairs, self.rows, self.details = {}, {}, {}
  self.index, self.phase, self.t = 0, "idle", 0
  return self
end

local function reset(self)
  self.t = 0
  self.frames, self.time, self.steps = 0, 0, 0
  self.update, self.draw, self.calls, self.particles, self.drawn = 0, 0, 0, 0, 0
  self.worst_frame, self.worst_update, self.worst_draw = 0, 0, 0
end

local function next_pair(self)
  self.index = self.index + 1
  local pair = self.pairs[self.index]
  if not pair then
    self.active, self.done, self.phase = false, true, "done"
    self.log(format("perf: benchmark done, %d rows", #self.rows))
    if self.on_done then self.on_done(self) end
    return
  end
  self.apply(pair[1], pair[2])
  self.phase = self.warmup > 0 and "warmup" or "measure"
  reset(self)
end

function Bench:start()
  self.pairs, self.rows, self.details = {}, {}, {}
  for e = 1, #self.enemy_counts do
    for p = 1, #self.particle_counts do self.pairs[#self.pairs + 1] = { e, p } end
  end
  self.active, self.done, self.index, self.written = true, false, 0, nil
  self.log(format("perf: benchmark started, %d pairs, %g s each after %g s of warm-up",
    #self.pairs, self.seconds, self.warmup))
  self.log("perf: " .. Bench.HEADER)
  next_pair(self)
end

function Bench:cancel()
  if not self.active then return end
  self.active, self.phase = false, "idle"
  self.log(format("perf: benchmark stopped after %d of %d pairs", #self.rows, #self.pairs))
end

-- The results file's text: the description, the table, and a second table with the details
function Bench:text()
  local out = { "# perf_platformer results", "" }
  local info = self.info and self.info() or {}
  for i = 1, #info do out[#out + 1] = "- " .. info[i] end
  out[#out + 1] = format("- %g s measured per row, after %g s of warm-up; %d of %d rows",
    self.seconds, self.warmup, #self.rows, #self.pairs)
  out[#out + 1] = ""
  out[#out + 1] = Bench.HEADER
  out[#out + 1] = Bench.RULE
  for i = 1, #self.rows do out[#out + 1] = self.rows[i] end
  out[#out + 1] = ""
  out[#out + 1] = "Details of the same rows:"
  out[#out + 1] = ""
  out[#out + 1] = DETAIL_HEADER
  out[#out + 1] = DETAIL_RULE
  for i = 1, #self.details do out[#out + 1] = self.details[i] end
  return table.concat(out, "\n") .. "\n"
end

-- Writes the file and reads it back; logs the outcome. Returns true if it is there.
function Bench:write()
  local text = self:text()
  local fs = love.filesystem
  local ok, err = fs.write(self.file, text)
  local back = ok and fs.read(self.file) or nil
  if back ~= text then
    self.written = false
    self.log(format("perf: ERROR: could not write %s (%s)", self.file, tostring(err or "it does not read back")))
    return false
  end
  self.written = true
  if #self.rows == #self.pairs then
    self.log(format("perf: results written to %s in the save folder (%d rows, %d bytes)", self.file, #self.rows, #text))
  end
  return true
end

local function finish_pair(self)
  local pair = self.pairs[self.index]
  local n, p = self.enemy_counts[pair[1]], self.particle_counts[pair[2]]
  local frames = self.frames
  local fps = self.time > 0 and frames / self.time or 0
  local fps_min = self.worst_frame > 0 and 1 / self.worst_frame or 0
  local row = format("| %d | %d | %.1f | %.1f | %.2f | %.2f | %.1f |", n, p, fps, fps_min,
    self.update / frames * 1000, self.draw / frames * 1000, self.calls / frames)
  self.rows[#self.rows + 1] = row
  self.details[#self.details + 1] = format("| %d | %d | %d | %.2f | %.2f | %.2f | %.2f | %.0f | %.1f |", n, p,
    frames, self.steps / frames, self.worst_frame * 1000, self.worst_update * 1000,
    self.worst_draw * 1000, self.particles / frames, self.drawn / frames)
  self.log(format("perf: %s worst frame %.2f ms", row, self.worst_frame * 1000))
  self:write()
  next_pair(self)
end

-- Once per frame, after the draw. frame, update, draw: seconds; calls: draw calls; steps:
-- fixed steps the frame ran; particles: live particles; drawn: enemies drawn.
function Bench:frame(frame, update, draw, calls, steps, particles, drawn)
  if not self.active then return end
  self.t = self.t + frame
  if self.phase == "warmup" then
    if self.t >= self.warmup then
      self.phase = "measure"
      reset(self)
    end
    return
  end
  self.frames, self.time, self.steps = self.frames + 1, self.time + frame, self.steps + steps
  self.update, self.draw, self.calls = self.update + update, self.draw + draw, self.calls + calls
  self.particles, self.drawn = self.particles + particles, self.drawn + drawn
  if frame > self.worst_frame then self.worst_frame = frame end
  if update > self.worst_update then self.worst_update = update end
  if draw > self.worst_draw then self.worst_draw = draw end
  if self.time >= self.seconds - 1e-9 then finish_pair(self) end
end

-- "3/12 4.2 S" for the overlay
function Bench:status()
  if self.done then return format("DONE %d ROWS%s", #self.rows, self.written and "" or " (NOT WRITTEN)") end
  if not self.active then return "OFF" end
  return format("%d/%d %s %.1f S", self.index, #self.pairs, self.phase == "warmup" and "WARM-UP" or "MEASURE",
    self.phase == "warmup" and self.warmup - self.t or self.seconds - self.time)
end

return Bench
