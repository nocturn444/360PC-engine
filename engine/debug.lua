-- engine.debug: a generic debug mode for development builds. Off by default. See docs/ENGINE.md.
--   * shows the current seed code (engine.rng seed codes) and lets the player enter one
--     with the controller;
--   * a list that grants modifiers from a registry the game provides;
--   * a hitbox overlay that draws rectangles the game (or a combat world) provides.
-- It knows nothing about a game or a genre: everything it shows comes from functions and
-- tables the game hands over. Menus are engine.ui screens pushed on the state machine.
--
--   local dbg = engine.debug.new({
--     action = "debug",                                   -- opens the menu while enabled
--     seed = function() return run.seed end,              -- number or string
--     on_seed = function(seed, code) start_run(seed) end, -- a seed was entered
--     modifiers = registry,                               -- engine.modifiers registry, or { { id =, name = }, ... }
--     grant = function(id, def) player.mods:add(id) end,
--     hitboxes = engine.debug.boxes(combat_world),        -- or any function(emit)
--   })
--   function play:input(input) dbg:input(input) end
--   function play:draw(alpha) camera:attach(alpha) ... dbg:drawHitboxes() camera:detach() dbg:draw() end
local ENGINE = (...):gsub("%.debug$", "")
local rng = require(ENGINE .. ".rng")
local ui = require(ENGINE .. ".ui")

local M = {}
local Debug = {}
Debug.__index = Debug

-- Colours of the hitbox overlay by rectangle kind; `other` is used for unknown kinds.
M.colors = {
  hit = { 1, 0.2, 0.2, 1 }, hurt = { 0.2, 1, 0.3, 1 }, body = { 0.3, 0.6, 1, 1 },
  solid = { 1, 1, 1, 0.6 }, other = { 1, 0.9, 0.2, 1 },
}

-- The `debug` flag of game.lua: l360.game on the console, the file itself on PC. False when
-- there is no game.lua, when it does not load, or when the flag is not `true`.
function M.flag()
  local l = rawget(_G, "l360")
  if type(l) == "table" and type(l.game) == "table" then return l.game.debug == true end
  local lv = rawget(_G, "love")
  local read = lv and lv.filesystem and lv.filesystem.read
  if not read then return false end
  local ok, source = pcall(read, "game.lua")
  if not ok or type(source) ~= "string" or source:sub(1, 1) == "\27" then return false end
  local chunk = loadstring(source, "@game.lua")
  if not chunk then return false end
  setfenv(chunk, {})
  local ok2, t = pcall(chunk)
  return ok2 and type(t) == "table" and t.debug == true
end

-- A hitbox source for a combat world (engine/modules/combat), without requiring the module:
-- it reads world.hitboxes and world.hurtboxes and each box's rect(). Active hitboxes are
-- "hit", enabled hurtboxes "hurt"; inactive ones are left out unless `all` is true.
function M.boxes(world, all)
  return function(emit)
    local list = world.hurtboxes
    for i = 1, #list do
      local b = list[i]
      if not b.removed and (all or b.enabled ~= false) then emit("hurt", b:rect()) end
    end
    list = world.hitboxes
    for i = 1, #list do
      local b = list[i]
      if not b.removed and (all or b.active) then emit("hit", b:rect()) end
    end
  end
end

-- opts (all optional):
--   enabled        true / false. Default: the `debug` flag of game.lua (M.flag()).
--   action         the action that opens the menu while enabled (default "debug"; define it
--                  in the game's input config)
--   enable_action  an action that turns the mode on and off, even when it is off (a game
--                  that wants this in a release should bind it to something hard to press)
--   states, input  the state machine and the Input (default: engine.states, engine.controls)
--   seed           the current seed: a number, a string, or a function returning one
--   on_seed        function(seed_number, code): the player entered a seed
--   modifiers      an engine.modifiers registry, or an array of ids or { id =, name = }
--   grant          function(id, def): give that modifier (def: the registry's definition)
--   hitboxes       a hitbox source, or an array of them (see addHitboxes)
--   show_hitboxes  draw them from the start (default false)
--   colors         overrides of M.colors
--   rows           modifiers shown at once in the list (default 5)
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Debug)
  self.enabled = opts.enabled
  if self.enabled == nil then self.enabled = M.flag() end
  self.enabled = self.enabled and true or false
  self.action = opts.action or "debug"
  self.enable_action = opts.enable_action
  self.states, self.controls = opts.states, opts.input
  self.seed, self.on_seed = opts.seed, opts.on_seed
  self.modifiers, self.grant = opts.modifiers, opts.grant
  self.rows = opts.rows or 5
  self.show_hitboxes = opts.show_hitboxes and true or false
  self.sources = {}
  if type(opts.hitboxes) == "function" then self.sources[1] = opts.hitboxes
  elseif type(opts.hitboxes) == "table" then
    for i, f in ipairs(opts.hitboxes) do self.sources[i] = f end
  end
  self.colors = setmetatable({}, { __index = M.colors })
  for k, v in pairs(opts.colors or {}) do self.colors[k] = v end
  self.message = nil                 -- the last thing done, shown in the menu
  self.menu, self.entry = nil, nil   -- the screens, while they are open
  self._seed, self._code, self._text = nil, nil, nil
  self.rect_count = 0                -- rectangles drawn by the last drawHitboxes
  self._emit = function(kind, x, y, w, h) self:_rect(kind, x, y, w, h) end
  return self
end

function Debug:setEnabled(on)
  self.enabled = on and true or false
  if not self.enabled then self:close() end
end

local function machine(self)
  return self.states or require(ENGINE).states
end

-- The current seed's number and its 7-character code, or nil without a seed.
function Debug:seedCode()
  local seed = self.seed
  if type(seed) == "function" then seed = seed() end
  if seed == nil then return nil end
  if seed ~= self._seed then
    self._seed = seed
    self._code = rng.seed_to_code(seed)
    self._text = "seed " .. self._code
  end
  return self._code, rng.seed_number(seed)
end

-- Adds a hitbox source: function(emit). It calls emit(kind, x, y, w, h) once per rectangle
-- (kind: "hit", "hurt", "body", "solid" or any name in colors), and/or returns an array of
-- { x, y, w, h, kind = } (or { x =, y =, w =, h =, kind = }). The rectangles are in the
-- coordinates in use when drawHitboxes is called.
function Debug:addHitboxes(source)
  assert(type(source) == "function", "a hitbox source is a function")
  self.sources[#self.sources + 1] = source
  return source
end

function Debug:_rect(kind, x, y, w, h)
  local c = self.colors[kind] or self.colors.other
  local g = love.graphics
  g.setColor(c[1], c[2], c[3], (c[4] or 1) * 0.25)
  g.rectangle("fill", x, y, w, h)
  g.setColor(c[1], c[2], c[3], c[4] or 1)
  g.rectangle("line", x, y, w, h)
  self.rect_count = self.rect_count + 1
end

-- Draws the rectangles of every source. Call it inside the camera, after the game's world.
-- Does nothing unless the mode is enabled and the overlay is switched on.
function Debug:drawHitboxes()
  self.rect_count = 0
  if not (self.enabled and self.show_hitboxes) then return 0 end
  local g = love.graphics
  local r, gg, b, a = g.getColor()
  for i = 1, #self.sources do
    local list = self.sources[i](self._emit)
    if type(list) == "table" then
      for j = 1, #list do
        local q = list[j]
        self:_rect(q.kind or q[5], q.x or q[1], q.y or q[2], q.w or q[3], q.h or q[4])
      end
    end
  end
  g.setColor(r, gg, b, a)
  return self.rect_count
end

-- Draws the seed code in a corner (game pixels). Call it after the camera is detached.
function Debug:draw(x, y)
  if not self.enabled then return end
  if not self:seedCode() then return end
  local g = love.graphics
  local r, gg, b, a = g.getColor()
  g.setColor(1, 1, 1, 0.8)
  g.print(self._text, x or 2, y or 2)
  g.setColor(r, gg, b, a)
end

-- Once per fixed step, from the state's input hook. True if it opened or closed something.
function Debug:input(input)
  input = input or self.controls or require(ENGINE).controls
  if not input then return false end
  local toggle = self.enable_action
  if toggle and input.actions[toggle] and input:pressed(toggle) then
    self:setEnabled(not self.enabled)
    return true
  end
  if self.enabled and not self.menu and input.actions[self.action] and input:pressed(self.action) then
    self:open()
    return true
  end
  return false
end

local function modifier_items(source)
  local items = {}
  if type(source) ~= "table" then return items end
  if type(source.defs) == "table" then               -- an engine.modifiers registry
    for id, c in pairs(source.defs) do
      items[#items + 1] = { id = id, name = tostring(c.name or id), def = c.def }
    end
    table.sort(items, function(p, q) return tostring(p.id) < tostring(q.id) end)
  else
    for i, v in ipairs(source) do
      if type(v) == "table" then items[i] = { id = v.id, name = tostring(v.name or v.id), def = v }
      else items[i] = { id = v, name = tostring(v) } end
    end
  end
  return items
end

-- Grants a modifier by id, as the menu's list does. Returns true if the game's grant ran.
function Debug:grantModifier(id, def)
  if not (self.enabled and self.grant) then return false end
  self.grant(id, def)
  self.message = "granted " .. tostring(id)
  if self.menu then self.menu:get("message"):setText(self.message) end
  return true
end

-- Opens the menu (a transparent engine.ui screen pushed on the state machine).
function Debug:open()
  if not self.enabled or self.menu then return self.menu end
  local dbg = self
  local code = self:seedCode()
  local rows = {
    ui.label({ text = "DEBUG", align = "center" }),
    ui.label({ id = "seed", text = "seed " .. (code or "-") }),
  }
  if self.on_seed then
    rows[#rows + 1] = ui.button({ id = "enter_seed", label = "Enter seed",
      on_press = function() dbg:openSeedEntry() end })
  end
  if #self.sources > 0 then
    rows[#rows + 1] = ui.toggle({ id = "hitboxes", label = "Hitboxes", value = self.show_hitboxes,
      on_change = function(_, on) dbg.show_hitboxes = on end })
  end
  local items = modifier_items(self.modifiers)
  if #items > 0 and self.grant then
    rows[#rows + 1] = ui.label({ text = "Grant modifier", dim = true })
    rows[#rows + 1] = ui.list({ id = "modifiers", items = items, rows = math.min(self.rows, #items),
      on_select = function(_, _, item) dbg:grantModifier(item.id, item.def) end })
  end
  rows[#rows + 1] = ui.label({ id = "message", text = self.message or " ", dim = true })
  rows[#rows + 1] = ui.button({ id = "close", label = "Close", on_press = function() dbg:close() end })
  rows.background, rows.wrap, rows.align, rows.spacing = true, true, "stretch", 2
  self.menu = ui.screen({ transparent = true, root = ui.vstack(rows),
    on_back = function() dbg:close() end })
  machine(self):push(self.menu)
  return self.menu
end

-- Closes the menu and the seed entry, if they are open.
function Debug:close()
  local states = machine(self)
  if self.entry then
    if states:top() == self.entry then states:pop() end
    self.entry = nil
  end
  if self.menu then
    if states:top() == self.menu then states:pop() end
    self.menu = nil
  end
end

-- The seed entry: seven columns, one per character of the code. Up and down change the
-- character, left and right move, accept confirms, back cancels. The first column only has
-- 0 to 3: a seed is 32 bits and the code is 7 characters of 5 bits.
function Debug:openSeedEntry(code)
  if not self.enabled or self.entry then return self.entry end
  local dbg = self
  code = code or self:seedCode() or "0000000"
  local alphabet = {}
  for d = 0, 31 do alphabet[d + 1] = rng.seed_to_code(d):sub(7, 7) end
  local columns = {}
  local function confirm() dbg:submitSeed(dbg:entryCode()) end
  for i = 1, 7 do
    local items = alphabet
    if i == 1 then items = { alphabet[1], alphabet[2], alphabet[3], alphabet[4] } end
    local selected = 1
    for k = 1, #items do if items[k] == code:sub(i, i) then selected = k end end
    columns[i] = ui.list({ id = "c" .. i, items = items, rows = 1, wrap = true, selected = selected,
      align = "center", on_select = confirm })
  end
  columns.spacing = 1
  self.columns = columns
  self.entry = ui.screen({ transparent = true, on_back = function() dbg:closeSeedEntry() end,
    root = ui.vstack({ background = true, align = "center", spacing = 4,
      ui.label({ text = "ENTER SEED", align = "center" }),
      ui.hstack(columns),
      ui.label({ text = "up/down: change   accept: start", dim = true }),
    }) })
  machine(self):push(self.entry)
  return self.entry
end

-- The code the seed entry shows now.
function Debug:entryCode()
  local out = ""
  for i = 1, 7 do
    local list = self.columns[i]
    out = out .. list.items[list.selected]
  end
  return out
end

function Debug:closeSeedEntry()
  if not self.entry then return end
  local states = machine(self)
  if states:top() == self.entry then states:pop() end
  self.entry, self.columns = nil, nil
end

-- Takes a typed code (as rng.code_to_seed reads it): calls on_seed(number, code) and closes
-- the screens. Returns the number, or nil and the reason for a code that is not valid.
function Debug:submitSeed(code)
  if not self.enabled then return nil, "debug mode is off" end
  local seed, err = rng.code_to_seed(code)
  if not seed then
    self.message = err
    return nil, err
  end
  self.message = "seed " .. rng.seed_to_code(seed)
  self:close()
  if self.on_seed then self.on_seed(seed, rng.seed_to_code(seed)) end
  return seed
end

return M
