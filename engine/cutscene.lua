-- engine.cutscene: a data-driven cutscene player. A script is a list of steps (wait, fade,
-- show, hide, move, pan, shake, text, say, sound, music, call) run in order, with
-- `wait = false` letting the next step start at once. See docs/ENGINE.md.
--
--   local cs = engine.cutscene.new({
--     id = "intro",
--     background = { 0, 0, 0 },
--     steps = {
--       { "fade", to = 1, time = 0 }, { "fade", to = 0, time = 1 },
--       { "show", id = "sky", rect = { 320, 180 }, color = { 0.1, 0.1, 0.3 } },
--       { "text", text = "HELLO", x = 20, y = 80, w = 280 },
--     },
--   }, { audio = sfx, on_finish = function(c, skipped) ... end })
--   function state:input(input) cs:input(input) end
--   function state:update(dt) cs:update(dt) end
--   function state:draw() cs:draw() end
--
-- Text is drawn with engine.text (rectangles: no TTF on the console, no printf). Nothing is
-- allocated in update or draw: a step allocates its own state when it starts.
local prefix = (...):gsub("%.cutscene$", "")

local floor = math.floor

local M = {}
local Cutscene = {}
Cutscene.__index = Cutscene

local Text = require(prefix .. ".text")

local BLACK = { 0, 0, 0 }
local WHITE = { 1, 1, 1, 1 }
local SKIP_LABEL = "HOLD TO SKIP"
local SKIP_WIDTH = Text.width(SKIP_LABEL, 1)

local EASE = {
  linear = function(p) return p end,
  ["in"] = function(p) return p * p end,
  out = function(p) return 1 - (1 - p) * (1 - p) end,
  inout = function(p) return p * p * (3 - 2 * p) end,
}

local KINDS = {
  wait = true, fade = true, show = true, hide = true, move = true, pan = true, shake = true,
  text = true, say = true, sound = true, music = true, call = true,
}

---------------------------------------------------------------------------
-- Validation
---------------------------------------------------------------------------
local function bad(script, i, kind, field, message)
  local id = script.id and ("\"" .. tostring(script.id) .. "\" ") or ""
  error(string.format("cutscene %sstep %d (%s): field \"%s\": %s",
    id, i, tostring(kind or "?"), tostring(field), message))
end

local function is_num(v) return type(v) == "number" end

local function check_color(script, i, kind, step, field)
  local c = step[field]
  if c == nil then return end
  if type(c) ~= "table" or not is_num(c[1]) or not is_num(c[2]) or not is_num(c[3])
    or (c[4] ~= nil and not is_num(c[4])) then
    bad(script, i, kind, field, "must be { r, g, b } or { r, g, b, a } with numbers")
  end
end

local function check_number(script, i, kind, step, field, required, min)
  local v = step[field]
  if v == nil then
    if required then bad(script, i, kind, field, "is required") end
    return
  end
  if not is_num(v) then bad(script, i, kind, field, "must be a number") end
  if min ~= nil and v < min then bad(script, i, kind, field, "must be >= " .. min) end
end

local function check_ease(script, i, kind, step)
  local e = step.ease
  if e ~= nil and not EASE[e] then
    bad(script, i, kind, "ease", "must be linear, in, out or inout")
  end
end

local function check_wait(script, i, kind, step)
  local w = step.wait
  if w == nil then return end
  if kind == "text" or kind == "say" then
    if w ~= "button" and w ~= false and not is_num(w) then
      bad(script, i, kind, "wait", "must be \"button\", a number of seconds or false")
    end
    if is_num(w) and w < 0 then bad(script, i, kind, "wait", "must be >= 0") end
  elseif type(w) ~= "boolean" then
    bad(script, i, kind, "wait", "must be true or false")
  end
end

local function validate(script, opts)
  if type(script) ~= "table" then error("cutscene script must be a table") end
  if type(script.steps) ~= "table" then
    error("cutscene " .. (script.id and ("\"" .. tostring(script.id) .. "\" ") or "") ..
      "field \"steps\": must be a table")
  end
  if script.skippable ~= nil and type(script.skippable) ~= "boolean" then
    bad(script, 0, "script", "skippable", "must be true or false")
  end
  if script.background ~= nil then check_color(script, 0, "script", script, "background") end

  for i = 1, #script.steps do
    local step = script.steps[i]
    if type(step) ~= "table" then bad(script, i, "?", "step", "must be a table") end
    local kind = step[1]
    if type(kind) ~= "string" then bad(script, i, "?", "step", "its first item must be the kind") end
    if not KINDS[kind] then bad(script, i, kind, "step", "unknown kind") end

    if kind == "wait" then
      check_number(script, i, kind, step, "time", true, 0)
    elseif kind == "fade" then
      check_number(script, i, kind, step, "to", true)
      if step.to < 0 or step.to > 1 then bad(script, i, kind, "to", "must be between 0 and 1") end
      check_number(script, i, kind, step, "time", true, 0)
      check_color(script, i, kind, step, "color")
    elseif kind == "show" then
      if step.id == nil then bad(script, i, kind, "id", "is required") end
      if type(step.id) ~= "string" and not is_num(step.id) then
        bad(script, i, kind, "id", "must be a string or a number")
      end
      if step.image ~= nil and step.rect ~= nil then
        bad(script, i, kind, "image", "give image or rect, not both")
      end
      if step.image == nil and step.rect == nil then
        bad(script, i, kind, "image", "image or rect is required")
      end
      if step.image ~= nil then
        if type(step.image) ~= "string" then bad(script, i, kind, "image", "must be a file name") end
        if step.quad ~= nil then
          local q = step.quad
          if type(q) ~= "table" or not is_num(q[1]) or not is_num(q[2]) or not is_num(q[3])
            or not is_num(q[4]) then
            bad(script, i, kind, "quad", "must be { x, y, w, h } with numbers")
          end
        end
      else
        local r = step.rect
        if type(r) ~= "table" or not is_num(r[1]) or not is_num(r[2]) then
          bad(script, i, kind, "rect", "must be { w, h } with numbers")
        end
      end
      check_number(script, i, kind, step, "x")
      check_number(script, i, kind, step, "y")
      check_number(script, i, kind, step, "layer")
      check_number(script, i, kind, step, "alpha")
      check_number(script, i, kind, step, "scale", false, 0)
      check_number(script, i, kind, step, "parallax")
      check_color(script, i, kind, step, "color")
    elseif kind == "hide" then
      if step.id == nil then bad(script, i, kind, "id", "is required") end
      if type(step.id) ~= "string" and not is_num(step.id) then
        bad(script, i, kind, "id", "must be a string or a number")
      end
    elseif kind == "move" then
      if step.id == nil then bad(script, i, kind, "id", "is required") end
      check_number(script, i, kind, step, "time", true, 0)
      check_number(script, i, kind, step, "x")
      check_number(script, i, kind, step, "y")
      check_number(script, i, kind, step, "alpha")
      if step.x == nil and step.y == nil and step.alpha == nil then
        bad(script, i, kind, "x", "move needs x, y or alpha")
      end
      check_ease(script, i, kind, step)
    elseif kind == "pan" then
      check_number(script, i, kind, step, "x", true)
      check_number(script, i, kind, step, "y", true)
      check_number(script, i, kind, step, "time", true, 0)
      check_ease(script, i, kind, step)
    elseif kind == "shake" then
      check_number(script, i, kind, step, "amount", true, 0)
      check_number(script, i, kind, step, "time", true, 0)
    elseif kind == "text" then
      if type(step.text) ~= "string" then bad(script, i, kind, "text", "must be a string") end
      check_number(script, i, kind, step, "x", true)
      check_number(script, i, kind, step, "y", true)
      check_number(script, i, kind, step, "w", false, 0)
      check_number(script, i, kind, step, "scale", false, 0)
      check_number(script, i, kind, step, "speed", false, 0)
      if step.align ~= nil and step.align ~= "left" and step.align ~= "center"
        and step.align ~= "right" then
        bad(script, i, kind, "align", "must be left, center or right")
      end
      if step.id ~= nil and type(step.id) ~= "string" and not is_num(step.id) then
        bad(script, i, kind, "id", "must be a string or a number")
      end
      check_color(script, i, kind, step, "color")
      check_wait(script, i, kind, step)
    elseif kind == "say" then
      if type(step.text) ~= "string" then bad(script, i, kind, "text", "must be a string") end
      if step.speaker ~= nil and type(step.speaker) ~= "string" then
        bad(script, i, kind, "speaker", "must be a string")
      end
      check_number(script, i, kind, step, "speed", false, 0)
      check_color(script, i, kind, step, "color")
      check_wait(script, i, kind, step)
    elseif kind == "sound" then
      if type(step.name) ~= "string" then bad(script, i, kind, "name", "must be a string") end
      check_number(script, i, kind, step, "volume")
      check_number(script, i, kind, step, "pitch")
    elseif kind == "music" then
      if step.name ~= nil and type(step.name) ~= "string" then
        bad(script, i, kind, "name", "must be a string or nil")
      end
      check_number(script, i, kind, step, "fade")
    elseif kind == "call" then
      if type(step.fn) ~= "function" then bad(script, i, kind, "fn", "must be a function") end
      if step.always ~= nil and type(step.always) ~= "boolean" then
        bad(script, i, kind, "always", "must be true or false")
      end
    end

    if kind ~= "text" and kind ~= "say" then check_wait(script, i, kind, step) end
  end

  if opts.actions ~= nil then
    if type(opts.actions) ~= "table" then error("cutscene opts.actions must be a table") end
    for k, v in pairs(opts.actions) do
      if (k == "advance" or k == "skip") and type(v) ~= "string" then
        error("cutscene opts.actions." .. k .. " must be an action name")
      end
    end
  end
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------
-- The engine table is loaded as "engine" (init.lua): read it from package.loaded rather than
-- require(prefix .. ".init"), which would run init.lua again as another module with no screen.
local function screen_size()
  local engine = package.loaded[prefix] or package.loaded[prefix .. ".init"]
  local screen = type(engine) == "table" and engine.screen
  if screen then return screen.width, screen.height end
  return 320, 180
end

-- new(script, opts): opts.width, opts.height, opts.audio, opts.image(file), opts.actions
-- ({ advance = "ui_accept", skip = "ui_back" }), opts.skippable, opts.on_finish(cs, skipped).
function M.new(script, opts)
  opts = opts or {}
  validate(script, opts)

  local self = setmetatable({}, Cutscene)
  self.script, self.steps, self.id = script, script.steps, script.id
  self.skippable = script.skippable ~= false
  if opts.skippable ~= nil then self.skippable = opts.skippable and true or false end
  self.background = script.background
  self.audio = opts.audio
  self.image = opts.image
  self.images = {}

  self.actions = { advance = "ui_accept", skip = "ui_back" }
  for k, v in pairs(opts.actions or {}) do self.actions[k] = v end
  self.on_finish = opts.on_finish

  local sw, sh = screen_size()
  self.width, self.height = opts.width or sw, opts.height or sh

  self.elements = {}
  self.texts = {}
  self.active = {}
  self.next_index = 1
  self.step_index = 0
  self.done = false
  self.notified = false
  self.advance = false
  self.skip_held = false
  self.skip_hold = 0
  self.time = 0
  self.fade = 0
  self.fade_color = BLACK
  self.view_x, self.view_y = 0, 0
  self.shake_x, self.shake_y = 0, 0
  self.shake_seed = 12345

  self:advance_chain()
  return self
end

---------------------------------------------------------------------------
-- Elements and text blocks (allocated when a step starts)
---------------------------------------------------------------------------
local function find_element(self, id)
  local list = self.elements
  for i = 1, #list do if list[i].id == id then return i, list[i] end end
end

local function remove_element(self, id)
  local i = find_element(self, id)
  if i then table.remove(self.elements, i) end
end

local function find_text(self, id)
  local list = self.texts
  for i = 1, #list do if list[i].id == id and not list[i].say then return i, list[i] end end
end

local function remove_text(self, id)
  local i = find_text(self, id)
  if i then table.remove(self.texts, i) end
end

local function remove_say(self)
  local list = self.texts
  for i = #list, 1, -1 do
    if list[i].say then table.remove(list, i) end
  end
end

local function add_element(self, el)
  local list = self.elements
  local pos = #list + 1
  for i = 1, #list do
    if list[i].layer > el.layer then pos = i; break end
  end
  if pos > #list then list[pos] = el else table.insert(list, pos, el) end
end

local function load_image(self, file)
  local img = self.images[file]
  if img then return img end
  if self.image then img = self.image(file) else img = love.graphics.newImage(file) end
  self.images[file] = img
  return img
end

local function text_block(self, step, kind)
  local scale = step.scale or 1
  local x, y, w, align, color
  local say = kind == "say"
  local pad, margin = 4, 6
  local lh = Text.line_height * scale
  local box_x, box_y, box_w, box_h
  if say then
    box_w = self.width - 2 * margin
    box_h = 3 * lh + 2 * pad + (step.speaker and lh or 0)
    box_x = margin
    box_y = self.height - margin - box_h
    x, y = box_x + pad, box_y + pad + (step.speaker and lh or 0)
    w, align = box_w - 2 * pad, "left"
    color = step.color or WHITE
  else
    x, y = step.x, step.y
    w = step.w or (self.width - x)
    align = step.align or "left"
    color = step.color or WHITE
  end

  local lines = Text.wrap(step.text, w, scale)
  local prefixes, total = {}, 0
  for i = 1, #lines do
    local line = lines[i]
    local p = { [0] = "" }
    for k = 1, #line do p[k] = line:sub(1, k) end
    prefixes[i] = p
    total = total + #line
  end

  return {
    id = say and nil or step.id,
    say = say, lines = lines, prefixes = prefixes, total = total, shown = 0,
    x = x, y = y, w = w, align = align, color = color, scale = scale, lh = lh,
    speaker = step.speaker,
    box_x = box_x, box_y = box_y, box_w = box_w, box_h = box_h, pad = pad,
  }
end

local function add_text(self, block)
  if block.say then
    remove_say(self)
  elseif block.id ~= nil then
    remove_text(self, block.id)
  end
  self.texts[#self.texts + 1] = block
end

local function create_element(self, step)
  local el = {
    id = step.id,
    style = step.image and "image" or "rect",
    x = step.x or 0, y = step.y or 0,
    layer = step.layer or 0,
    alpha = step.alpha or 1,
    scale = step.scale or 1,
    parallax = step.parallax == nil and 1 or step.parallax,
    color = step.color or WHITE,
  }
  if el.style == "image" then
    el.image = load_image(self, step.image)
    if step.quad then
      local q = step.quad
      local iw, ih = el.image:getDimensions()
      el.quad = love.graphics.newQuad(q[1], q[2], q[3], q[4], iw, ih)
    end
  else
    el.rect_w, el.rect_h = step.rect[1], step.rect[2]
  end
  remove_element(self, el.id)
  add_element(self, el)
end

local function move_to(self, el, step)
  if step.x ~= nil then el.x = step.x end
  if step.y ~= nil then el.y = step.y end
  if step.alpha ~= nil then el.alpha = step.alpha end
end

---------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------
local function step_wait(kind, step)
  local w = step.wait
  if kind == "text" or kind == "say" then return w == nil and "button" or w end
  if w == nil then return true end
  return w
end

-- Starts step i. Returns a runtime table for a step that lasts, or nil when it is done at once.
function Cutscene:start_step(i)
  local step = self.steps[i]
  local kind = step[1]

  if kind == "show" then
    create_element(self, step)
    return nil
  elseif kind == "hide" then
    remove_element(self, step.id)
    remove_text(self, step.id)
    return nil
  elseif kind == "sound" then
    if self.audio then self.audio:play(step.name, step.volume, step.pitch) end
    return nil
  elseif kind == "music" then
    if self.audio then
      if step.fade ~= nil then self.audio:music(step.name, { fade = step.fade })
      else self.audio:music(step.name) end
    end
    return nil
  elseif kind == "call" then
    step.fn(self)
    return nil
  elseif kind == "wait" then
    if step.time <= 0 then return nil end
    return { kind = kind, elapsed = 0, duration = step.time }
  elseif kind == "fade" then
    self.fade_color = step.color or BLACK
    if step.time <= 0 then self.fade = step.to; return nil end
    return { kind = kind, elapsed = 0, duration = step.time, from = self.fade, to = step.to,
      color = self.fade_color }
  elseif kind == "move" then
    local _, el = find_element(self, step.id)
    if not el then
      error(string.format("cutscene step %d (move): field \"id\": no element \"%s\"",
        i, tostring(step.id)))
    end
    local has_x, has_y, has_a = step.x ~= nil, step.y ~= nil, step.alpha ~= nil
    if step.time <= 0 then
      move_to(self, el, step)
      return nil
    end
    return { kind = kind, elapsed = 0, duration = step.time, el = el,
      fx = el.x, fy = el.y, fa = el.alpha, tx = step.x, ty = step.y, ta = step.alpha,
      has_x = has_x, has_y = has_y, has_a = has_a, ease = EASE[step.ease or "inout"] }
  elseif kind == "pan" then
    if step.time <= 0 then self.view_x, self.view_y = step.x, step.y; return nil end
    return { kind = kind, elapsed = 0, duration = step.time,
      fx = self.view_x, fy = self.view_y, tx = step.x, ty = step.y,
      ease = EASE[step.ease or "inout"] }
  elseif kind == "shake" then
    if step.time <= 0 then return nil end
    self.shake_seed = 12345
    return { kind = kind, elapsed = 0, duration = step.time, amount = step.amount }
  elseif kind == "text" or kind == "say" then
    local block = text_block(self, step, kind)
    add_text(self, block)
    local speed = step.speed
    if speed == nil then speed = 30 end
    local wait = step_wait(kind, step)
    local typed = speed <= 0 or block.total == 0
    if typed then block.shown = block.total end
    return { kind = kind, block = block, speed = speed, wait_mode = wait,
      typed = typed, hold = 0 }
  end
end

-- Starts steps until one has to be waited for, or the script is over.
function Cutscene:advance_chain()
  while not self.done and self.next_index <= #self.steps do
    local i = self.next_index
    self.next_index = i + 1
    self.step_index = i
    local step = self.steps[i]
    local kind = step[1]
    if kind ~= "say" then remove_say(self) end
    local rt = self:start_step(i)
    if rt then
      rt.blocks = step_wait(kind, step) ~= false
      self.active[#self.active + 1] = rt
      if rt.blocks then return end
    end
  end
  self:check_done()
end

function Cutscene:check_done()
  if not self.done and self.next_index > #self.steps and #self.active == 0 then
    self:finish(false)
  end
end

function Cutscene:finish(skipped)
  if self.notified then return end
  self.notified = true
  self.done = true
  if self.on_finish then self.on_finish(self, skipped and true or false) end
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------
local function is_down(input, name)
  local f = input.down or input.isDown
  return f and f(input, name) or false
end

-- An engine.input without the default ui_* actions (no engine.ui screen has run yet) gets
-- them defined, as engine.ui does; checked once per Input.
local function ensure_actions(self, input)
  if self.checked_input == input then return end
  self.checked_input = input
  local actions = input.actions
  if type(actions) ~= "table" or not input.define then return end
  if not actions[self.actions.advance] or not actions[self.actions.skip] then
    require(prefix .. ".ui").defineActions(input)
  end
end

-- Once per fixed step: reads the advance action (an edge) and the skip action (held).
function Cutscene:input(input)
  if self.done then return end
  ensure_actions(self, input)
  self.advance = input.pressed and input:pressed(self.actions.advance) or false
  self.skip_held = is_down(input, self.actions.skip)
end

---------------------------------------------------------------------------
-- Update
---------------------------------------------------------------------------
local function update_step(self, a, dt, advance)
  local kind = a.kind
  if kind == "wait" then
    a.elapsed = a.elapsed + dt
    return a.elapsed >= a.duration
  elseif kind == "fade" then
    a.elapsed = a.elapsed + dt
    local p = a.elapsed / a.duration
    if p >= 1 then self.fade = a.to; return true end
    self.fade = a.from + (a.to - a.from) * p
    return false
  elseif kind == "move" then
    a.elapsed = a.elapsed + dt
    local p = a.elapsed / a.duration
    if p > 1 then p = 1 end
    local e = a.ease(p)
    if a.has_x then a.el.x = a.fx + (a.tx - a.fx) * e end
    if a.has_y then a.el.y = a.fy + (a.ty - a.fy) * e end
    if a.has_a then a.el.alpha = a.fa + (a.ta - a.fa) * e end
    return p >= 1
  elseif kind == "pan" then
    a.elapsed = a.elapsed + dt
    local p = a.elapsed / a.duration
    if p > 1 then p = 1 end
    local e = a.ease(p)
    self.view_x = a.fx + (a.tx - a.fx) * e
    self.view_y = a.fy + (a.ty - a.fy) * e
    return p >= 1
  elseif kind == "shake" then
    a.elapsed = a.elapsed + dt
    if a.elapsed >= a.duration then
      self.shake_x, self.shake_y = 0, 0
      return true
    end
    local m = a.amount * (1 - a.elapsed / a.duration)
    self.shake_seed = (self.shake_seed * 16807) % 2147483647
    local rx = self.shake_seed / 1073741823.5 - 1
    self.shake_seed = (self.shake_seed * 16807) % 2147483647
    local ry = self.shake_seed / 1073741823.5 - 1
    self.shake_x, self.shake_y = rx * m, ry * m
    return false
  elseif kind == "text" or kind == "say" then
    local b = a.block
    if not a.typed then
      if a.speed > 0 then b.shown = b.shown + a.speed * dt else b.shown = b.total end
      if b.shown >= b.total then b.shown = b.total; a.typed = true end
    end
    if advance then
      if not a.typed then
        b.shown, a.typed = b.total, true
      elseif a.wait_mode == "button" then
        return true
      end
    end
    if a.typed and a.wait_mode ~= "button" and a.wait_mode ~= false then
      a.hold = a.hold + dt
      if a.hold >= a.wait_mode then return true end
    end
    if a.wait_mode == false then return a.typed end
    return false
  end
  return true
end

-- Once per fixed step.
function Cutscene:update(dt)
  if self.done then return end
  self.time = self.time + dt

  if self.skippable and self.skip_held then
    self.skip_hold = self.skip_hold + dt
    if self.skip_hold >= 1 then self:skip(); return end
  else
    self.skip_hold = 0
  end

  local advance = self.advance
  self.advance = false
  local need_chain = false
  local i = 1
  while i <= #self.active do
    local a = self.active[i]
    if update_step(self, a, dt, advance) then
      if a.blocks then need_chain = true end
      local last = #self.active
      if i ~= last then self.active[i] = self.active[last] end
      self.active[last] = nil
    else
      i = i + 1
    end
  end

  if need_chain then self:advance_chain() end
  self:check_done()
end

---------------------------------------------------------------------------
-- Skip
---------------------------------------------------------------------------
-- Ends at once: done, on_finish(cs, true); call steps not reached with always = true still run.
function Cutscene:skip()
  if self.done then return end
  self.done = true
  for i = #self.active, 1, -1 do self.active[i] = nil end
  for i = self.next_index, #self.steps do
    local step = self.steps[i]
    if step[1] == "call" and step.always then step.fn(self) end
  end
  if #self.steps > 0 then self.step_index = #self.steps end
  self:finish(true)
end

---------------------------------------------------------------------------
-- Draw (game pixels)
---------------------------------------------------------------------------
local function outline(g, x, y, w, h, t)
  g.rectangle("fill", x, y, w, t)
  g.rectangle("fill", x, y + h - t, w, t)
  g.rectangle("fill", x, y + t, t, h - 2 * t)
  g.rectangle("fill", x + w - t, y + t, t, h - 2 * t)
end

local function draw_element(self, el)
  local g = love.graphics
  local vx = (self.view_x + self.shake_x) * el.parallax
  local vy = (self.view_y + self.shake_y) * el.parallax
  local x, y = floor(el.x - vx + 0.5), floor(el.y - vy + 0.5)
  if el.style == "image" then
    g.setColor(1, 1, 1, el.alpha)
    if el.quad then g.draw(el.image, el.quad, x, y, 0, el.scale, el.scale)
    else g.draw(el.image, x, y, 0, el.scale, el.scale) end
  else
    local c = el.color
    g.setColor(c[1], c[2], c[3], (c[4] or 1) * el.alpha)
    g.rectangle("fill", x, y, el.rect_w * el.scale, el.rect_h * el.scale)
  end
end

local function draw_lines(self, b, shown)
  local g = love.graphics
  local left = shown
  local line_h = b.lh
  for i = 1, #b.lines do
    local line = b.lines[i]
    local n = #line
    if left >= n then
      local dx = 0
      if b.align == "center" then dx = floor((b.w - Text.width(line, b.scale)) / 2)
      elseif b.align == "right" then dx = b.w - Text.width(line, b.scale) end
      Text.draw(line, b.x + dx, b.y + (i - 1) * line_h, b.scale)
      left = left - n
    else
      if left > 0 then
        local part = b.prefixes[i][left]
        local dx = 0
        if b.align == "center" then dx = floor((b.w - Text.width(part, b.scale)) / 2)
        elseif b.align == "right" then dx = b.w - Text.width(part, b.scale) end
        Text.draw(part, b.x + dx, b.y + (i - 1) * line_h, b.scale)
      end
      return
    end
  end
end

local function draw_text_block(self, b)
  local g = love.graphics
  if b.say then
    g.setColor(0.08, 0.08, 0.12, 0.92)
    g.rectangle("fill", b.box_x, b.box_y, b.box_w, b.box_h)
    g.setColor(0.35, 0.35, 0.45, 1)
    outline(g, b.box_x, b.box_y, b.box_w, b.box_h, 1)
  end
  local c = b.color
  g.setColor(c[1], c[2], c[3], c[4] or 1)
  if b.speaker then Text.draw(b.speaker, b.x, b.box_y + b.pad, b.scale) end
  draw_lines(self, b, floor(b.shown))
end

local function draw_marker(self, a)
  local b = a.block
  local g = love.graphics
  if floor(self.time * 2) % 2 == 0 then return end
  g.setColor(1, 1, 1, 1)
  if b.say then g.rectangle("fill", b.box_x + b.box_w - 7, b.box_y + b.box_h - 7, 3, 3)
  else
    local h = (#b.lines > 0 and #b.lines or 1) * b.lh
    g.rectangle("fill", b.x + b.w - 3, b.y + h - 3, 3, 3)
  end
end

local function draw_skip(self)
  local g = love.graphics
  local h = Text.height(1)
  local margin = 4
  local x = self.width - margin - SKIP_WIDTH
  local y = self.height - margin - h - 4
  g.setColor(1, 1, 1, 1)
  Text.draw(SKIP_LABEL, x, y, 1)
  g.setColor(0.2, 0.2, 0.24, 1)
  g.rectangle("fill", x, y + h + 2, SKIP_WIDTH, 2)
  g.setColor(1, 0.82, 0.25, 1)
  local p = self.skip_hold
  if p > 1 then p = 1 end
  g.rectangle("fill", x, y + h + 2, floor(SKIP_WIDTH * p), 2)
end

-- In game pixels, inside the engine.pixel frame.
function Cutscene:draw()
  local g = love.graphics
  local r, gg, b, a = g.getColor()
  if self.background then
    local c = self.background
    g.setColor(c[1], c[2], c[3], c[4] or 1)
    g.rectangle("fill", 0, 0, self.width, self.height)
  end
  local elements = self.elements
  for i = 1, #elements do draw_element(self, elements[i]) end
  local texts = self.texts
  for i = 1, #texts do draw_text_block(self, texts[i]) end
  local active = self.active
  for i = 1, #active do
    local s = active[i]
    if (s.kind == "text" or s.kind == "say") and s.typed and s.wait_mode == "button" then
      draw_marker(self, s)
    end
  end
  if self.fade > 0 then
    local c = self.fade_color
    g.setColor(c[1], c[2], c[3], self.fade)
    g.rectangle("fill", 0, 0, self.width, self.height)
  end
  if self.skippable and self.skip_held then draw_skip(self) end
  g.setColor(r, gg, b, a)
end

return M
