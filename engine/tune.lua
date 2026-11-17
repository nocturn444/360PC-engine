-- engine.tune: live tuning of numbers while the game runs. The game lists the fields it wants
-- to adjust (a table and a key, with a range and a step); a small overlay shows them, the
-- controller or the keyboard changes them on the spot, and the values can be saved to a file
-- in the save folder and loaded back at the next start. For finding how a jump, a body or an
-- enemy should feel, on the PC or on the console, without rebuilding. See docs/ENGINE.md.
--
--   local tuner = engine.tune.new({ file = "tune_slime.txt" })
--   tuner:add(slime, "stiffness", { min = 0.1, max = 1, step = 0.05 })
--   tuner:add(params, "jump", { min = 100, max = 500, step = 10, label = "jump speed" })
--   tuner:load()                                  -- the values saved last time, if any
--   function play:input(input) tuner:input(input) end
--   function play:draw(alpha) ...; tuner:draw(4, 4) end
--
-- Actions (names of engine.input actions the game defines; change them with opts.actions):
--   tune        open / close the overlay        tune_prev, tune_next   choose a field
--   tune_dec, tune_inc   change it by one step   tune_save              write the file
-- A step held down repeats after 0.3 s, ten steps a second (the overlay needs input:down).
-- Text is drawn with engine.text, the built-in pixel font, so the overlay shows on the console.
local Save = require((...):gsub("%.tune$", ".save"))
local text = require((...):gsub("%.tune$", ".text"))

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local M = {}
local Tune = {}
Tune.__index = Tune

M.actions = { toggle = "tune", prev = "tune_prev", next = "tune_next", dec = "tune_dec", inc = "tune_inc",
  save = "tune_save" }

-- tune.new(opts): opts.file (save folder file for save/load, default "tune.txt"), opts.actions
-- (overrides of tune.actions), opts.open (start open), opts.fs (read / write, for tests;
-- default love.filesystem), opts.log (function(text), default print), opts.print and
-- opts.line_height (draw text with the game's font instead of engine.text)
function M.new(opts)
  opts = opts or {}
  local actions = {}
  for k, v in next, M.actions do actions[k] = (opts.actions and opts.actions[k]) or v end
  return setmetatable({ file = opts.file or "tune.txt", actions = actions, fields = {}, by_label = {},
    selected = 1, open = opts.open == true, fs = opts.fs, log = opts.log or print, held = nil,
    print = opts.print, line_height = opts.line_height,
    held_time = 0, message = nil, message_time = 0 }, Tune)
end

local function decimals(step)
  local d = 0
  while d < 6 and abs(step * 10 ^ d - floor(step * 10 ^ d + 0.5)) > 1e-9 do d = d + 1 end
  return d
end

-- tuner:add(target, key, opts): target[key] must be a number. opts.min, opts.max (default
-- none), opts.step (default 1), opts.label (default the key; labels must be unique: they are
-- the names in the saved file), opts.on_change(value, target, key). Returns the tuner.
function Tune:add(target, key, opts)
  opts = opts or {}
  assert(type(target) == "table", "tune:add: target is a table")
  assert(type(target[key]) == "number", "tune:add: " .. tostring(key) .. " is not a number")
  local label = opts.label or tostring(key)
  assert(not self.by_label[label], "tune:add: two fields are labelled " .. label)
  local step = opts.step or 1
  assert(type(step) == "number" and step > 0, "tune:add: step > 0")
  local f = { target = target, key = key, label = label, min = opts.min, max = opts.max, step = step,
    decimals = decimals(step), on_change = opts.on_change, initial = target[key] }
  self.fields[#self.fields + 1] = f
  self.by_label[label] = f
  return self
end

local function set(f, v)
  if f.min then v = max(f.min, v) end
  if f.max then v = min(f.max, v) end
  local s = 10 ^ f.decimals
  v = floor(v * s + 0.5) / s                     -- no 0.30000000000000004 after a few steps
  f.target[f.key] = v
  if f.on_change then f.on_change(v, f.target, f.key) end
  return v
end

-- Changes the selected field by n steps (negative: down). Returns the new value.
function Tune:nudge(n)
  local f = self.fields[self.selected]
  if not f then return nil end
  return set(f, f.target[f.key] + n * f.step)
end

-- Sets a field by its label (clamped and rounded like a nudge). Returns the value, or nil.
function Tune:set(label, v)
  local f = self.by_label[label]
  if not f or type(v) ~= "number" then return nil end
  return set(f, v)
end

function Tune:get(label)
  local f = self.by_label[label]
  return f and f.target[f.key]
end

-- Every field back to the value it had when it was added
function Tune:reset()
  for i = 1, #self.fields do local f = self.fields[i]; set(f, f.initial) end
end

-- { label = value } of every field
function Tune:values()
  local out = {}
  for i = 1, #self.fields do local f = self.fields[i]; out[f.label] = f.target[f.key] end
  return out
end

local function fs(self)
  return self.fs or (rawget(_G, "love") and love.filesystem)
end

local function say(self, text)
  self.message, self.message_time = text, 2
  self.log("tune: " .. text)
end

-- Writes values() to the file (engine.save's text format: data only, sorted). Returns true, or
-- false and the reason. Nothing raises.
function Tune:save()
  local text, err = Save.serialize(self:values())
  if not text then say(self, "not saved: " .. tostring(err)); return false, err end
  local f = fs(self)
  local ok, res = pcall(f.write, self.file, text)
  if not ok or res == false or res == nil then
    local why = tostring(ok and "write failed" or res)
    say(self, "not saved: " .. why)
    return false, why
  end
  say(self, "saved " .. self.file)
  return true
end

-- Reads the file and sets the fields it names (others keep their value; unknown names are
-- ignored). Returns the number of fields set, or false and the reason (no file is not an error
-- worth raising: it returns false, "no file").
function Tune:load()
  local f = fs(self)
  local ok, text = pcall(f.read, self.file)
  if not ok or type(text) ~= "string" then return false, "no file" end
  local good, data = Save.parse(text)
  if not good or type(data) ~= "table" then say(self, "bad file " .. self.file); return false, "bad file" end
  local n = 0
  for i = 1, #self.fields do
    local fl = self.fields[i]
    local v = data[fl.label]
    if type(v) == "number" then set(fl, v); n = n + 1 end
  end
  say(self, "loaded " .. n .. " values")
  return n
end

-- One call per step with the game's engine.input object: opens and closes the overlay, and
-- while it is open chooses and changes fields. Returns true while the overlay is open.
function Tune:input(input, dt)
  local a = self.actions
  dt = dt or 1 / 60
  if self.message then
    self.message_time = self.message_time - dt
    if self.message_time <= 0 then self.message = nil end
  end
  if input:pressed(a.toggle) then self.open = not self.open end
  if not self.open or #self.fields == 0 then return self.open end
  local n = #self.fields
  if input:pressed(a.prev) then self.selected = (self.selected - 2) % n + 1 end
  if input:pressed(a.next) then self.selected = self.selected % n + 1 end
  if input:pressed(a.save) then self:save() end
  local dir = 0
  if input:down(a.dec) then dir = -1 elseif input:down(a.inc) then dir = 1 end
  if dir == 0 then
    self.held = nil
  elseif self.held ~= dir then
    self.held, self.held_time = dir, -0.2       -- first step now, the next one at 0.3 s
    self:nudge(dir)
  else
    self.held_time = self.held_time + dt
    while self.held_time >= 0.1 do
      self.held_time = self.held_time - 0.1
      self:nudge(dir)
    end
  end
  return true
end

local function format(f)
  local v = f.target[f.key]
  if f.decimals == 0 then return tostring(floor(v + 0.5)) end
  return string.format("%." .. f.decimals .. "f", v)
end

-- The overlay's lines (also what draw prints): "> label  value" with the selected one marked
function Tune:lines()
  local out = {}
  for i = 1, #self.fields do
    local f = self.fields[i]
    out[i] = (i == self.selected and "> " or "  ") .. f.label .. "  " .. format(f)
  end
  return out
end

-- Draws the overlay at x, y (game pixels) while it is open, and the last save / load message.
-- Text: engine.text (the built-in pixel font, shows on the console without a TTF), or the
-- game's opts.print(text, x, y) with opts.line_height.
function Tune:draw(x, y)
  local g = love.graphics
  x, y = x or 2, y or 2
  local r, gg, b, al = g.getColor()
  local print_line, lh = self.print or text.draw, self.line_height or (self.print and 10 or text.line_height)
  if not self.open then
    if self.message then g.setColor(1, 1, 1, 1); print_line(self.message, x, y) end
    g.setColor(r, gg, b, al)
    return
  end
  local lines = self:lines()
  local width = 0
  for i = 1, #lines do
    local w = text.width(lines[i])
    if w > width then width = w end
  end
  g.setColor(0, 0, 0, 0.7)
  g.rectangle("fill", x - 2, y - 2, width + 4, lh * (#lines + (self.message and 1 or 0)) + 3)
  for i = 1, #lines do
    if i == self.selected then g.setColor(1, 0.9, 0.3, 1) else g.setColor(1, 1, 1, 1) end
    print_line(lines[i], x, y + (i - 1) * lh)
  end
  if self.message then g.setColor(0.6, 1, 0.6, 1); print_line(self.message, x, y + #lines * lh) end
  g.setColor(r, gg, b, al)
end

return M
