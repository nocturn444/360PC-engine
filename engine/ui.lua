-- engine.ui: menus driven by the controller. A screen holds a tree of widgets, one of them has
-- the focus, and the directions move it. See docs/ENGINE.md.
--
--   local ui = require("engine.ui")
--   local menu = ui.screen({
--     transparent = true,                       -- as a state: the game is drawn under it
--     on_back = function() states:pop() end,
--     root = ui.vstack({ background = true, wrap = true,
--       ui.label({ text = "PAUSED" }),
--       ui.button({ label = "Resume", on_press = function() states:pop() end }),
--       ui.slider({ label = "Volume", value = 0.5, on_change = function(s, v) ... end }),
--     }),
--   })
--   states:push(menu)
--
-- A screen is a state (engine.state): input(input) once per fixed step, update(dt), draw().
-- It reads the actions ui_up, ui_down, ui_left, ui_right, ui_accept and ui_back (M.actions has
-- default bindings; a game may define them itself, or point a screen at its own action names)
-- and, where there is a mouse, the pointer and its left button. Everything is drawn with
-- rectangles and text. Nothing is allocated per step or per frame; the layout is computed when
-- the screen is built and after screen:layout() or a change that marks it dirty.
local floor, abs, max, min = math.floor, math.abs, math.max, math.min
local pairs, ipairs, type, tostring, setmetatable = pairs, ipairs, type, tostring, setmetatable

local M = {}

-- The engine's Pixel, set by engine.init: mouse coordinates go through pixel:toGame and the
-- screens take its size. A screen's own `pixel` option wins.
M.pixel = nil

---------------------------------------------------------------------------
-- Actions and theme (data)
---------------------------------------------------------------------------
M.actions = {
  ui_up = { keys = { "up", "w" }, buttons = { "dpup" }, axes = { "lefty-" } },
  ui_down = { keys = { "down", "s" }, buttons = { "dpdown" }, axes = { "lefty+" } },
  ui_left = { keys = { "left", "a" }, buttons = { "dpleft" }, axes = { "leftx-" } },
  ui_right = { keys = { "right", "d" }, buttons = { "dpright" }, axes = { "leftx+" } },
  ui_accept = { keys = { "return", "space" }, buttons = { "a" } },
  ui_back = { keys = { "escape", "backspace" }, buttons = { "b" } },
}

-- Defines the ui_* actions an Input does not have yet; overrides = { ui_accept = bindings }
-- replaces them. (A screen does this by itself for the actions it finds missing.)
function M.defineActions(input, overrides)
  for name, b in pairs(M.actions) do
    local o = overrides and overrides[name]
    if o then input:define(name, o)
    elseif not input.actions[name] then input:define(name, b) end
  end
end

M.theme = {
  font = nil,                              -- a Font; nil: the current one
  padding = 4, spacing = 2, border = 1,    -- game pixels
  text = { 1, 1, 1, 1 }, text_dim = { 0.7, 0.7, 0.75, 1 },
  text_focus = { 1, 1, 1, 1 }, text_disabled = { 0.45, 0.45, 0.5, 1 },
  panel = { 0.08, 0.08, 0.12, 0.92 }, panel_border = { 0.35, 0.35, 0.45, 1 },
  widget = { 0.18, 0.18, 0.24, 1 }, widget_focus = { 0.26, 0.26, 0.36, 1 },
  focus = { 1, 0.82, 0.25, 1 },            -- the outline of the focused widget
  accent = { 0.35, 0.75, 1, 1 }, track = { 0.1, 0.1, 0.14, 1 },
  select = { 0.3, 0.3, 0.4, 1 },           -- a list's selected item when the list is not focused
  dim = { 0, 0, 0, 0.6 },                  -- over the game, under a screen with dim = true
}

-- A theme: the default one with some values replaced.
function M.newTheme(overrides)
  local t = {}
  for k, v in pairs(overrides or {}) do t[k] = v end
  return setmetatable(t, { __index = M.theme })
end

---------------------------------------------------------------------------
-- Drawing helpers
---------------------------------------------------------------------------
local function col(g, c) g.setColor(c[1], c[2], c[3], c[4] or 1) end

-- An outline t pixels thick, inside the rectangle (filled rectangles: crisp at any scale)
local function outline(g, x, y, w, h, t)
  g.rectangle("fill", x, y, w, t)
  g.rectangle("fill", x, y + h - t, w, t)
  g.rectangle("fill", x, y + t, t, h - 2 * t)
  g.rectangle("fill", x + w - t, y + t, t, h - 2 * t)
end

local function box(g, th, w, focused)
  col(g, focused and not w.disabled and th.widget_focus or th.widget)
  g.rectangle("fill", w.x, w.y, w.w, w.h)
  if focused then
    col(g, th.focus)
    outline(g, w.x, w.y, w.w, w.h, th.border)
  end
end

local function text_col(g, th, w, focused)
  col(g, w.disabled and th.text_disabled or focused and th.text_focus or th.text)
end

-- Text with the theme's font: an engine.text font draws itself (rectangles, so it works on the
-- console without a TTF); a real LÖVE font goes through love.graphics.
local function printf(g, th, text, x, y, w, align)
  local f = th.font
  if f and f.printf then return f:printf(text, x, y, w, align) end
  return g.printf(text, x, y, w, align)
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------
local Widget = {}
Widget.__index = Widget

local function class(parent)
  local c = setmetatable({}, parent or Widget)
  c.__index = c
  return c
end

-- Every option becomes a field: id, width, height, padding, disabled, visible, and the focus
-- overrides up / down / left / right / next / prev (a widget or an id).
local function new(cls, opts)
  local w = setmetatable({}, cls)
  for k, v in pairs(opts or {}) do w[k] = v end
  w.x, w.y, w.w, w.h, w.pw, w.ph = 0, 0, 0, 0, 0, 0
  return w
end

function Widget:canFocus() return self.focusable and not self.disabled end
function Widget:measure(th, font) self.pw, self.ph = self.width or 0, self.height or 0 end
function Widget:arrange(x, y, w, h) self.x, self.y, self.w, self.h = x, y, w, h end
function Widget:nav(dir) return false end          -- true: the widget used the direction itself
function Widget:accept(screen) end
function Widget:click(screen, gx, gy) self:accept(screen) end
function Widget:hover(gx, gy) end
function Widget:draw(g, th, focused) end

local function relayout(w) if w.screen then w.screen.dirty = true end end

-- label: text; with `width` it wraps (printf). align: "left", "center", "right".
local Label = class()
function Label:measure(th, font)
  local tw, lines = font:getWrap(self.text, self.width or 1e6)
  self.pw = self.width or tw
  self.ph = self.height or max(1, #lines) * font:getHeight()
end
function Label:draw(g, th)
  col(g, self.color or (self.dim and th.text_dim) or th.text)
  printf(g, th, self.text, self.x, self.y, self.w, self.align or "left")
end
function Label:setText(text)
  if text ~= self.text then self.text = text; relayout(self) end
end

-- button: label, on_press(button, screen)
local Button = class()
Button.focusable = true
function Button:measure(th, font)
  local pad = self.padding or th.padding
  self.pad, self.fh = pad, font:getHeight()
  self.pw = self.width or font:getWidth(self.label) + 2 * pad
  self.ph = self.height or self.fh + 2 * pad
end
function Button:draw(g, th, focused)
  local on = focused == self
  box(g, th, self, on)
  text_col(g, th, self, on)
  printf(g, th, self.label, self.x + self.pad, self.y + floor((self.h - self.fh) / 2),
    self.w - 2 * self.pad, self.align or "center")
end
function Button:accept(screen)
  if self.on_press then self.on_press(self, screen) end
end

-- toggle: label, value (boolean), on_change(toggle, value, screen)
local Toggle = class()
Toggle.focusable = true
function Toggle:measure(th, font)
  local pad = self.padding or th.padding
  self.pad, self.fh = pad, font:getHeight()
  self.pw = self.width or font:getWidth(self.label) + 3 * pad + self.fh
  self.ph = self.height or self.fh + 2 * pad
end
function Toggle:draw(g, th, focused)
  local on = focused == self
  local pad, fh = self.pad, self.fh
  local ty = self.y + floor((self.h - fh) / 2)
  box(g, th, self, on)
  text_col(g, th, self, on)
  printf(g, th, self.label, self.x + pad, ty, self.w - 3 * pad - fh, "left")
  local bx = self.x + self.w - pad - fh
  outline(g, bx, ty, fh, fh, th.border)
  if self.value then
    col(g, th.accent)
    g.rectangle("fill", bx + 2, ty + 2, fh - 4, fh - 4)
  end
end
function Toggle:accept(screen)
  self.value = not self.value
  if self.on_change then self.on_change(self, self.value, screen) end
end

-- slider: label, min (0), max (1), step (0.1), value, track (its width, 40),
-- on_change(slider, value). Left and right change the value.
local Slider = class()
Slider.focusable = true
function Slider:measure(th, font)
  local pad = self.padding or th.padding
  self.pad, self.fh = pad, font:getHeight()
  self.min, self.max, self.step = self.min or 0, self.max or 1, self.step or 0.1
  self.track = self.track or 40
  self.value = max(self.min, min(self.max, self.value or self.min))
  self.pw = self.width or font:getWidth(self.label or "") + 3 * pad + self.track
  self.ph = self.height or self.fh + 2 * pad
end
function Slider:setValue(v)
  -- on the grid of steps counted from min, so repeated steps do not drift
  local lo, hi, step = self.min or 0, self.max or 1, self.step or 0.1
  v = lo + floor((v - lo) / step + 0.5) * step
  v = max(lo, min(hi, v))
  if v ~= self.value then
    self.value = v
    if self.on_change then self.on_change(self, v) end
  end
end
function Slider:nav(dir)
  if dir == "left" then self:setValue(self.value - self.step); return true end
  if dir == "right" then self:setValue(self.value + self.step); return true end
  return false
end
function Slider:click(screen, gx)
  local f = (gx - (self.x + self.w - self.pad - self.track)) / self.track
  self:setValue(self.min + max(0, min(1, f)) * (self.max - self.min))
end
function Slider:draw(g, th, focused)
  local on = focused == self
  local pad, fh, track = self.pad, self.fh, self.track
  local ty = self.y + floor((self.h - fh) / 2)
  box(g, th, self, on)
  text_col(g, th, self, on)
  if self.label then printf(g, th, self.label, self.x + pad, ty, self.w - 3 * pad - track, "left") end
  local tx, my = self.x + self.w - pad - track, self.y + floor(self.h / 2) - 1
  local f = self.max > self.min and (self.value - self.min) / (self.max - self.min) or 0
  col(g, th.track)
  g.rectangle("fill", tx, my, track, 2)
  col(g, th.accent)
  g.rectangle("fill", tx, my, floor(track * f), 2)
  g.rectangle("fill", tx + floor((track - 3) * f), ty, 3, fh)
end

-- list: items (strings, or tables with label or name; or format(item, i) -> string),
-- orientation ("vertical" / "horizontal"), rows (how many are shown; the rest scroll),
-- selected, wrap, on_change(list, i, item) when the selection moves,
-- on_select(list, i, item, screen) on accept. The list is one widget: the directions along it
-- move the selection, and leave the list at its ends unless wrap is set.
local List = class()
List.focusable = true
function List:setItems(items)
  self.items = items or {}
  local labels = {}
  for i, item in ipairs(self.items) do
    if self.format then labels[i] = self.format(item, i)
    elseif type(item) == "table" then labels[i] = tostring(item.label or item.name)
    else labels[i] = tostring(item) end
  end
  self.labels = labels
  self.selected = max(1, min(#labels, self.selected or 1))
  self.first = 1
  relayout(self)
end
function List:canFocus() return not self.disabled and #self.items > 0 end
function List:measure(th, font)
  local pad = self.padding or th.padding
  local vertical = self.orientation ~= "horizontal"
  local n = self.rows or min(#self.items, 5)
  if n < 1 then n = 1 end
  self.pad, self.fh, self.vertical, self.shown = pad, font:getHeight(), vertical, n
  self.ih = self.item_height or self.fh + pad
  local iw = self.item_width
  if not iw then
    iw = 0
    for i = 1, #self.labels do iw = max(iw, font:getWidth(self.labels[i])) end
    iw = iw + 2 * pad + (vertical and 3 or 0)
  end
  self.iw = iw
  self.pw = self.width or (vertical and iw or iw * n)
  self.ph = self.height or (vertical and self.ih * n or self.ih + 2)
  self:scroll()
end
function List:arrange(x, y, w, h)
  self.x, self.y, self.w, self.h = x, y, w, h
  if self.vertical then self.iw = w end
end
-- Keeps the selected item among the ones shown
function List:scroll()
  local n, sel = self.shown or 1, self.selected
  local first = self.first
  if sel < first then first = sel end
  if sel > first + n - 1 then first = sel - n + 1 end
  self.first = max(1, min(first, max(1, #self.items - n + 1)))
end
function List:select(i)
  i = max(1, min(#self.items, i))
  if i ~= self.selected and #self.items > 0 then
    self.selected = i
    self:scroll()
    if self.on_change then self.on_change(self, i, self.items[i]) end
  end
end
function List:nav(dir)
  local d
  if self.vertical then d = dir == "down" and 1 or dir == "up" and -1
  else d = dir == "right" and 1 or dir == "left" and -1 end
  if not d then return false end
  local n, i = #self.items, self.selected + d
  if i < 1 or i > n then
    if not self.wrap then return false end
    i = i < 1 and n or 1
  end
  self:select(i)
  return true
end
function List:accept(screen)
  local i = self.selected
  if self.on_select and self.items[i] ~= nil then self.on_select(self, i, self.items[i], screen) end
end
function List:indexAt(gx, gy)
  local k = self.vertical and floor((gy - self.y) / self.ih) or floor((gx - self.x) / self.iw)
  local i = self.first + k
  if k >= 0 and k < self.shown and i <= #self.items then return i end
end
function List:hover(gx, gy)
  local i = self:indexAt(gx, gy)
  if i then self:select(i) end
end
function List:click(screen, gx, gy)
  local i = self:indexAt(gx, gy)
  if i then self:select(i); self:accept(screen) end
end
function List:draw(g, th, focused)
  local on = focused == self
  local x, y, w, h = self.x, self.y, self.w, self.h
  local pad, fh, ih, vertical = self.pad, self.fh, self.ih, self.vertical
  local total, shown = #self.items, self.shown
  local more = total > shown
  local iw = vertical and (more and w - 3 or w) or self.iw
  col(g, th.widget)
  g.rectangle("fill", x, y, w, h)
  for k = 0, shown - 1 do
    local i = self.first + k
    if i > total then break end
    local ix, iy = vertical and x or x + k * iw, vertical and y + k * ih or y
    if i == self.selected then
      col(g, on and th.accent or th.select)
      g.rectangle("fill", ix, iy, iw, ih)
    end
    text_col(g, th, self, on and i == self.selected)
    printf(g, th, self.labels[i], ix + pad, iy + floor((ih - fh) / 2), iw - 2 * pad,
      self.align or (vertical and "left" or "center"))
  end
  if more then                                   -- the scroll bar
    col(g, th.text_dim)
    local a, b = (self.first - 1) / total, shown / total
    if vertical then g.rectangle("fill", x + w - 2, y + floor(h * a), 2, max(1, floor(h * b)))
    else g.rectangle("fill", x + floor(w * a), y + h - 1, max(1, floor(w * b)), 1) end
  end
  if on then
    col(g, th.focus)
    outline(g, x, y, w, h, th.border)
  end
end

-- stack: children in a column or a row. dir ("vertical" / "horizontal"), padding, spacing,
-- align (across: "start", "center", "end", "stretch"), justify (along, when the stack is given
-- a larger width / height: "start", "center", "end"), background (a panel behind it),
-- wrap (true, "vertical" or "horizontal": the focus wraps inside this stack).
-- The children are the array part of the options, or `children`.
local Stack = class()
function Stack:measure(th, font)
  local pad = self.padding or (self.background and th.padding or 0)
  local gap = self.spacing or th.spacing
  local vertical = self.dir ~= "horizontal"
  local along, across, n = 0, 0, 0
  for _, c in ipairs(self.children) do
    if c.visible ~= false then
      c:measure(th, font)
      n = n + 1
      if vertical then along, across = along + c.ph, max(across, c.pw)
      else along, across = along + c.pw, max(across, c.ph) end
    end
  end
  along = along + gap * max(0, n - 1)
  self.pad, self.gap, self.vertical, self.along = pad, gap, vertical, along
  self.pw = self.width or (vertical and across or along) + 2 * pad
  self.ph = self.height or (vertical and along or across) + 2 * pad
end
local JUSTIFY = { start = 0, center = 0.5, ["end"] = 1 }
function Stack:arrange(x, y, w, h)
  self.x, self.y, self.w, self.h = x, y, w, h
  local pad, vertical, align = self.pad, self.vertical, self.align or "start"
  local room = (vertical and w or h) - 2 * pad            -- across
  local free = (vertical and h or w) - 2 * pad - self.along
  local at = pad + floor(max(0, free) * (JUSTIFY[self.justify or "start"] or 0))
  for _, c in ipairs(self.children) do
    if c.visible ~= false then
      local size = vertical and c.pw or c.ph
      if align == "stretch" or size > room then size = room end
      local off = pad + floor((room - size) * (JUSTIFY[align] or 0))
      if vertical then
        c:arrange(x + off, y + at, size, c.ph)
        at = at + c.ph + self.gap
      else
        c:arrange(x + at, y + off, c.pw, size)
        at = at + c.pw + self.gap
      end
    end
  end
end
function Stack:draw(g, th, focused)
  if self.background then
    col(g, th.panel)
    g.rectangle("fill", self.x, self.y, self.w, self.h)
    col(g, th.panel_border)
    outline(g, self.x, self.y, self.w, self.h, th.border)
  end
  local children = self.children
  for i = 1, #children do
    local c = children[i]
    if c.visible ~= false then c:draw(g, th, focused) end
  end
end

-- card: a button that shows a choice = { name, description, icon, quad }. icon is an Image (with
-- an optional Quad) or a function(x, y, size, card) that draws it; icon_size for a function.
local Card = class(Button)
function Card:measure(th, font)
  local pad = self.padding or th.padding
  local c = self.choice
  local w = self.width or 80
  local fh = font:getHeight()
  self.pad, self.fh = pad, fh
  local _, lines = font:getWrap(tostring(c.name or ""), w - 2 * pad)
  local h = pad + max(1, #lines) * fh + pad
  self.icon_w, self.icon_h = 0, 0
  if c.icon then
    local iw, ih = self.icon_size or 16, self.icon_size or 16
    if type(c.icon) ~= "function" then
      if c.quad then _, _, iw, ih = c.quad:getViewport() else iw, ih = c.icon:getDimensions() end
    end
    self.icon_w, self.icon_h = iw, ih
    h = h + ih + pad
  end
  self.name_h = max(1, #lines) * fh
  if c.description then
    _, lines = font:getWrap(c.description, w - 2 * pad)
    h = h + #lines * fh + pad
  end
  self.pw, self.ph = w, self.height or h
end
function Card:draw(g, th, focused)
  local on = focused == self
  local c, pad = self.choice, self.pad
  local x, y, inner = self.x + pad, self.y + pad, self.w - 2 * pad
  box(g, th, self, on)
  if c.icon then
    local ix = self.x + floor((self.w - self.icon_w) / 2)
    g.setColor(1, 1, 1, 1)
    if type(c.icon) == "function" then c.icon(ix, y, self.icon_w, self)
    elseif c.quad then g.draw(c.icon, c.quad, ix, y)
    else g.draw(c.icon, ix, y) end
    y = y + self.icon_h + pad
  end
  col(g, self.disabled and th.text_disabled or on and th.focus or th.text)
  printf(g, th, tostring(c.name or ""), x, y, inner, "center")
  if c.description then
    col(g, self.disabled and th.text_disabled or th.text_dim)
    printf(g, th, c.description, x, y + self.name_h + pad, inner, "center")
  end
end

function M.label(opts) return new(Label, opts) end
function M.button(opts) return new(Button, opts) end
function M.toggle(opts)
  local w = new(Toggle, opts)
  w.value = w.value and true or false
  return w
end
function M.slider(opts) return new(Slider, opts) end
function M.card(opts) return new(Card, opts) end
function M.list(opts)
  local w = new(List, opts)
  w:setItems(w.items)
  return w
end
function M.stack(opts)
  local w = new(Stack, opts)
  local children = w.children or {}
  for i = 1, #w do children[#children + 1] = w[i]; w[i] = nil end
  w.children = children
  for _, c in ipairs(children) do c.parent = w end
  return w
end
function M.vstack(opts) local w = M.stack(opts); w.dir = "vertical"; return w end
function M.hstack(opts) local w = M.stack(opts); w.dir = "horizontal"; return w end

---------------------------------------------------------------------------
-- Screen
---------------------------------------------------------------------------
local Screen = {}
Screen.__index = Screen

local ANCHORS = {
  center = { 0.5, 0.5 }, top = { 0.5, 0 }, bottom = { 0.5, 1 }, left = { 0, 0.5 }, right = { 1, 0.5 },
  topleft = { 0, 0 }, topright = { 1, 0 }, bottomleft = { 0, 1 }, bottomright = { 1, 1 },
}
local DIRS = { "up", "down", "left", "right" }
local DX = { up = 0, down = 0, left = -1, right = 1 }
local DY = { up = -1, down = 1, left = 0, right = 0 }

-- opts: root (a widget, usually a stack), width, height (the game's resolution; default: the
-- pixel's, or the window's), anchor ("center", "top", "bottomleft"... or { ax, ay } in 0..1),
-- margin, theme (a table of overrides), transparent, dim (default: transparent), focus (the
-- widget or id focused first), on_back(screen), on_focus(screen, widget, previous),
-- actions = { up, down, left, right, accept, back } (action names, default ui_*),
-- repeat_delay (0.4 s), repeat_interval (0.1 s), mouse (false: ignore it), pixel.
function M.screen(opts)
  opts = opts or {}
  local self = setmetatable({}, Screen)
  local px = opts.pixel or M.pixel
  self.pixel = opts.pixel
  self.root = assert(opts.root, "a screen needs a root widget")
  self.width = opts.width or (px and px.width) or love.graphics.getWidth()
  self.height = opts.height or (px and px.height) or love.graphics.getHeight()
  local anchor = opts.anchor or "center"
  if type(anchor) == "string" then anchor = assert(ANCHORS[anchor], "unknown anchor: " .. anchor) end
  self.ax, self.ay = anchor[1], anchor[2]
  self.margin = opts.margin or 0
  self.theme = opts.theme and M.newTheme(opts.theme) or M.theme
  self.transparent = opts.transparent and true or false
  self.dim = opts.dim
  if self.dim == nil then self.dim = self.transparent end
  self.on_back, self.on_focus = opts.on_back, opts.on_focus
  self.act = { up = "ui_up", down = "ui_down", left = "ui_left", right = "ui_right",
    accept = "ui_accept", back = "ui_back" }
  for k, v in pairs(opts.actions or {}) do self.act[k] = v end
  self.repeat_delay = opts.repeat_delay or 0.4
  self.repeat_interval = opts.repeat_interval or 0.1
  self.step_dt = 1 / 60                    -- update(dt) corrects it
  self.use_mouse = opts.mouse ~= false
  self.initial = opts.focus
  self.widgets, self.ids = {}, {}
  self.focused = nil
  self.held, self.held_steps = nil, 0
  self.mx, self.my, self.mdown = nil, nil, nil
  self.checked = nil
  self:layout()
  return self
end

local function collect(self, w)
  w.screen = self
  if w.id then self.ids[w.id] = w end
  if w.focusable then self.widgets[#self.widgets + 1] = w end
  if w.children then
    for _, c in ipairs(w.children) do
      c.parent = w
      if c.visible ~= false then collect(self, c) end
    end
  end
end

-- Measures and places the widgets. Call it after adding, removing, showing or hiding widgets.
function Screen:layout()
  local th, root = self.theme, self.root
  root:measure(th, th.font or love.graphics.getFont())
  local m = self.margin
  local x = floor(m + (self.width - 2 * m - root.pw) * self.ax + 0.5)
  local y = floor(m + (self.height - 2 * m - root.ph) * self.ay + 0.5)
  root:arrange(x, y, root.pw, root.ph)
  local list = self.widgets
  for i = #list, 1, -1 do list[i] = nil end
  for k in pairs(self.ids) do self.ids[k] = nil end
  collect(self, root)
  self.dirty = false
  local f = self.focused
  if f and f.screen == self and f:canFocus() then
    for i = 1, #list do if list[i] == f then return end end
  end
  self.focused = nil
  if self.initial and self:focus(self.initial) then return end
  for i = 1, #list do
    if list[i]:canFocus() then self:focus(list[i]); return end
  end
end

function Screen:get(id) return self.ids[id] end

-- Gives the focus to a widget (or the widget with that id). False if it cannot have it.
function Screen:focus(w)
  if type(w) ~= "table" then w = self.ids[w] end
  if not w or not w:canFocus() then return false end
  local old = self.focused
  if w ~= old then
    self.focused = w
    if self.on_focus then self.on_focus(self, w, old) end
  end
  return true
end

local function inside(w, scope)
  while w do
    if w == scope then return true end
    w = w.parent
  end
  return false
end

-- How far apart two widgets are across the direction of travel: 0 if they overlap there
local function across(a, b, dx)
  if dx ~= 0 then
    if a.y < b.y + b.h and b.y < a.y + a.h then return 0 end
    return abs((a.y + a.h / 2) - (b.y + b.h / 2))
  end
  if a.x < b.x + b.w and b.x < a.x + a.w then return 0 end
  return abs((a.x + a.w / 2) - (b.x + b.w / 2))
end

-- The nearest widget of `scope` in that direction; with `wrapping`, the farthest one the other way.
local function search(self, cur, dir, scope, wrapping)
  local dx, dy = DX[dir], DY[dir]
  local cx, cy = cur.x + cur.w / 2, cur.y + cur.h / 2
  local list = self.widgets
  local best, best_score
  for i = 1, #list do
    local w = list[i]
    if w ~= cur and w:canFocus() and inside(w, scope) then
      local d = (w.x + w.w / 2 - cx) * dx + (w.y + w.h / 2 - cy) * dy
      local score
      if wrapping then
        if d < 0 then score = d * 1000 + across(cur, w, dx) end
      elseif d > 0 then
        score = d + 2 * across(cur, w, dx)
      end
      if score and (not best or score < best_score) then best, best_score = w, score end
    end
  end
  return best
end

-- Moves the focus: the widget's own use of the direction (slider, list), then its explicit
-- neighbour, then the nearest widget that way, looking first inside the innermost container and
-- wrapping in the first one that has wrap set. Returns whether anything changed.
function Screen:navigate(dir)
  local cur = self.focused
  if not cur then
    local list = self.widgets
    for i = 1, #list do if self:focus(list[i]) then return true end end
    return false
  end
  if cur:nav(dir) then return true end
  local forward = dir == "down" or dir == "right"
  local to = cur[dir]
  if to == nil then
    if forward then to = cur.next else to = cur.prev end
  end
  if to ~= nil then return self:focus(to) and self.focused ~= cur end
  local scope = cur.parent
  while scope do
    local w = search(self, cur, dir, scope, false)
    if not w then
      local wrap = scope.wrap
      if scope.focusable then wrap = nil end       -- a list's wrap is about its items
      if wrap == true or (wrap == "vertical" and DY[dir] ~= 0) or (wrap == "horizontal" and DX[dir] ~= 0) then
        w = search(self, cur, dir, scope, true)
      end
    end
    if w then return self:focus(w) end
    scope = scope.parent
  end
  return false
end

function Screen:accept()
  local w = self.focused
  if w and w:canFocus() then w:accept(self) end
end

function Screen:back()
  if self.on_back then self.on_back(self) end
end

function Screen:widgetAt(gx, gy)
  local list = self.widgets
  for i = 1, #list do
    local w = list[i]
    if gx >= w.x and gy >= w.y and gx < w.x + w.w and gy < w.y + w.h and w:canFocus() then return w end
  end
end

-- The pointer, in game pixels, and whether its button is held. Moving it over a widget gives
-- that widget the focus; a new press activates it. A pointer that stays still changes nothing,
-- so it does not fight the controller. (Screen:input calls this where there is a mouse.)
function Screen:mouse(gx, gy, down)
  local first = self.mx == nil
  local moved = gx ~= self.mx or gy ~= self.my
  local pressed = down and self.mdown == false
  self.mx, self.my, self.mdown = gx, gy, down and true or false
  if first or not (moved or pressed) then return end
  local w = self:widgetAt(gx, gy)
  if not w then return end
  self:focus(w)
  if moved then w:hover(gx, gy) end
  if pressed then w:click(self, gx, gy) end
end

-- Once per fixed step (engine.state's input hook). A held direction repeats after
-- repeat_delay, every repeat_interval; both are rounded to whole steps.
function Screen:input(input)
  if self.dirty then self:layout() end
  local act = self.act
  if self.checked ~= input then
    for _, name in pairs(act) do
      if not input.actions[name] and M.actions[name] then input:define(name, M.actions[name]) end
    end
    self.checked = input
  end
  local ms = love.mouse
  if ms and self.use_mouse then
    local px = self.pixel or M.pixel
    local gx, gy = ms.getPosition()
    if px then gx, gy = px:toGame(gx, gy) end
    self:mouse(gx, gy, ms.isDown(1))
  end
  local dt = self.step_dt
  local delay = max(1, floor(self.repeat_delay / dt + 0.5))
  local every = max(1, floor(self.repeat_interval / dt + 0.5))
  for i = 1, 4 do
    local dir = DIRS[i]
    local name = act[dir]
    if input:pressed(name) then
      self.held, self.held_steps = dir, 0
      self:navigate(dir)
    elseif self.held == dir then
      if input:down(name) then
        local n = self.held_steps + 1
        self.held_steps = n
        if n >= delay and (n - delay) % every == 0 then self:navigate(dir) end
      else
        self.held = nil
      end
    end
  end
  if input:pressed(act.accept) then self:accept()
  elseif input:pressed(act.back) then self:back() end
end

function Screen:update(dt) self.step_dt = dt end

local function fresh(self)
  self.held, self.held_steps = nil, 0
  self.mx, self.my, self.mdown = nil, nil, nil
  if self.dirty then self:layout() end
end
Screen.enter = fresh       -- as a state: forget the held direction and the pointer
Screen.resume = fresh

function Screen:draw()
  local g, th = love.graphics, self.theme
  if self.dirty then self:layout() end
  local r, gg, b, a = g.getColor()
  local real_font = th.font and not th.font.printf
  local old = real_font and g.getFont()
  if real_font then g.setFont(th.font) end
  if self.dim then
    col(g, th.dim)
    g.rectangle("fill", 0, 0, self.width, self.height)
  end
  self.root:draw(g, th, self.focused)
  if old then g.setFont(old) end
  g.setColor(r, gg, b, a)
end

---------------------------------------------------------------------------
-- Pick 1 of N
---------------------------------------------------------------------------
-- A screen with a title and one card per choice. opts:
--   title, hint (a line under the cards, e.g. the button prompts)
--   choices = { { name = , description = , icon = , quad = , disabled = }, ... }
--   on_choose(index, choice, screen)    accept on a card
--   on_cancel(screen)                   back; leave it out and the choice cannot be skipped
--   dir ("horizontal" / "vertical"), card_width, card_height, icon_size, selected (first focus)
--   and the screen's options (width, height, anchor, theme, transparent, dim, actions...).
-- screen.cards are the card widgets; screen:choose(i) picks one from code.
function M.pick(opts)
  local choices = assert(opts.choices, "pick needs choices")
  local n = #choices
  local th = opts.theme and M.newTheme(opts.theme) or M.theme
  local px = opts.pixel or M.pixel
  local W = opts.width or (px and px.width) or love.graphics.getWidth()
  local vertical = opts.dir == "vertical"
  local pad, gap = th.padding, opts.spacing or th.padding
  local cw = opts.card_width
  if not cw then
    local room = W - 2 * (opts.margin or 0) - 2 * pad
    cw = vertical and min(160, room) or min(96, floor((room - gap * (n - 1)) / max(1, n)))
  end
  local screen
  local cards = {}
  for i, c in ipairs(choices) do
    cards[i] = M.card({ choice = c, index = i, width = cw, height = opts.card_height,
      icon_size = opts.icon_size, disabled = c.disabled,
      on_press = function() screen:choose(i) end })
  end
  local column = { background = opts.background ~= false, align = "center", spacing = pad }
  if opts.title then column[#column + 1] = M.label({ text = opts.title, id = "title" }) end
  column[#column + 1] = M.stack({ dir = vertical and "vertical" or "horizontal", spacing = gap,
    align = "stretch", wrap = true, children = cards })
  if opts.hint then column[#column + 1] = M.label({ text = opts.hint, dim = true, id = "hint" }) end
  local so = {}
  for k, v in pairs(opts) do so[k] = v end
  so.root = M.vstack(column)
  so.focus = cards[opts.selected or 1]
  so.on_back = function(s)
    if opts.on_cancel then opts.on_cancel(s) end
  end
  screen = M.screen(so)
  screen.cards, screen.choices = cards, choices
  function screen:choose(i)
    local c = self.choices[i]
    if c and not c.disabled and opts.on_choose then opts.on_choose(i, c, self) end
  end
  return screen
end

return M
