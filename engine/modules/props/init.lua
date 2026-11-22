-- engine.modules.props: modular room props (platforms, vines, crates, spikes, turrets...) as a
-- registry of types plus the live set of one room. A type is data (category, size, collision,
-- flags, per-instance fields with defaults and limits, editor metadata) and optional hooks
-- (init, update, hit, draw). A room lists its props as placements in tiles; the set turns them
-- into instances, stamps the solid and one-way ones onto the room's collision grid, keeps their
-- persistent state in a table the game saves, and answers overlap and flag queries without
-- allocating. The engine never interprets a flag: "climbable" or "hazard" means what the game
-- says. A genre module: nothing in engine/ requires it and it knows nothing about a game.
-- Reference: engine/modules/props/README.md and docs/PROPS.md (the placement and catalog schema).
--
--   local props = require("engine.modules.props")
--   local types = props.registry()
--   types:define("vine", { category = "climb", size = { w = 1, h = 3 }, resize = "y",
--     flags = { climbable = true }, editor = { label = "Vine", glyph = "|", color = { 0.3, 0.7, 0.3 } } })
--   local set = props.set(types, room.props, { tile_size = 16, state = room_state.props })
--   local grid = set:grid(room.grid)             -- the room grid with the props stamped on it
--   set:update(dt, ctx); set:draw(love.graphics)
local type, tostring, floor, pairs, ipairs, next = type, tostring, math.floor, pairs, ipairs, next

local M = { CATALOG_FORMAT = "360pc-props-catalog", CATALOG_VERSION = 1 }

local COLLISIONS = { solid = true, one_way = true }
local RESIZE = { none = true, x = true, y = true, xy = true }
local FIELD_TYPES = { number = true, integer = true, bool = true, string = true, enum = true }
local HOOKS = { "init", "update", "hit", "draw" }

local function whole(v, min) return type(v) == "number" and v == floor(v) and v >= min end

---------------------------------------------------------------------------
-- Field values
---------------------------------------------------------------------------

-- nil when the value fits the field spec, else the reason
local function check_value(spec, v)
  local t = spec.type
  if t == "bool" then
    if type(v) ~= "boolean" then return "is a boolean" end
  elseif t == "string" then
    if type(v) ~= "string" then return "is a string" end
  elseif t == "enum" then
    for i = 1, #spec.options do if spec.options[i] == v then return nil end end
    return "is one of " .. table.concat(spec.options, ", ")
  else
    if type(v) ~= "number" or v ~= v then return "is a number" end
    if t == "integer" and v ~= floor(v) then return "is a whole number" end
    if spec.min and v < spec.min then return "is >= " .. spec.min end
    if spec.max and v > spec.max then return "is <= " .. spec.max end
  end
  return nil
end

local function check_field_spec(name, i, f)
  local where = "props: type " .. name .. ", field " .. i
  if type(f) ~= "table" or type(f.key) ~= "string" or f.key == "" then error(where .. " needs a key", 4) end
  where = "props: type " .. name .. ", field " .. f.key
  if not FIELD_TYPES[f.type] then
    error(where .. ": type is number, integer, bool, string or enum", 4)
  end
  if f.type == "enum" then
    if type(f.options) ~= "table" or #f.options == 0 then error(where .. ": an enum needs options", 4) end
    for j = 1, #f.options do
      if type(f.options[j]) ~= "string" then error(where .. ": enum options are strings", 4) end
    end
  end
  for _, k in ipairs({ "min", "max" }) do
    if f[k] ~= nil and (type(f[k]) ~= "number" or (f.type ~= "number" and f.type ~= "integer")) then
      error(where .. ": " .. k .. " is a number, only for number and integer fields", 4)
    end
  end
  if f.default == nil then error(where .. " needs a default", 4) end
  local why = check_value(f, f.default)
  if why then error(where .. ": the default " .. why, 4) end
end

---------------------------------------------------------------------------
-- The registry
---------------------------------------------------------------------------
local Registry = {}
Registry.__index = Registry

function M.registry()
  return setmetatable({ defs = {}, order = {} }, Registry)
end

-- registry:define(name, def) -> def (validated, defaults filled in). def:
--   category   string (editor grouping), default "prop"
--   size       { w, h } default size in tiles (default 1 x 1)
--   resize     "none" (default), "x", "y" or "xy": which sides a placement may change
--   min, max   optional { w, h } size limits in tiles for a resizable type
--   collision  nil, "solid" or "one_way": stamped onto the room grid over the prop's tiles
--   flags      { name = true }: free tags the game queries ("climbable", "hazard", ...)
--   fields     ordered { { key, type, default, options, min, max } }: per-instance values
--   editor     { label, glyph (1-2 chars), color = { r, g, b } } for the level editors
--   init(p, ctx), update(p, dt, ctx), hit(p, amount, ctx) -> true to remove, draw(p, g)
function Registry:define(name, def)
  if type(name) ~= "string" or not name:find("^[%a_][%w_]*$") then
    error("props: a type name is letters, digits and _ (got " .. tostring(name) .. ")", 2)
  end
  if self.defs[name] then error("props: type " .. name .. " is defined twice", 2) end
  if type(def) ~= "table" then error("props: type " .. name .. " needs a table", 2) end
  local where = "props: type " .. name .. ": "
  def.name = name
  def.category = def.category or "prop"
  if type(def.category) ~= "string" then error(where .. "category is a string", 2) end
  def.size = def.size or { w = 1, h = 1 }
  if not whole(def.size.w, 1) or not whole(def.size.h, 1) then error(where .. "size is { w, h } in whole tiles >= 1", 2) end
  def.resize = def.resize or "none"
  if not RESIZE[def.resize] then error(where .. "resize is none, x, y or xy", 2) end
  for _, k in ipairs({ "min", "max" }) do
    local s = def[k]
    if s ~= nil and (type(s) ~= "table" or not whole(s.w, 1) or not whole(s.h, 1)) then
      error(where .. k .. " is { w, h } in whole tiles >= 1", 2)
    end
  end
  if def.collision ~= nil and not COLLISIONS[def.collision] then
    error(where .. "collision is nil, solid or one_way", 2)
  end
  def.flags = def.flags or {}
  if type(def.flags) ~= "table" then error(where .. "flags is a table", 2) end
  for k, v in pairs(def.flags) do
    if type(k) ~= "string" or v ~= true then error(where .. "flags are { name = true }", 2) end
  end
  def.fields = def.fields or {}
  if type(def.fields) ~= "table" then error(where .. "fields is a list", 2) end
  def.field_by_key = {}
  for i, f in ipairs(def.fields) do
    check_field_spec(name, i, f)
    if def.field_by_key[f.key] then error(where .. "field " .. f.key .. " is listed twice", 2) end
    def.field_by_key[f.key] = f
  end
  def.editor = def.editor or {}
  local ed = def.editor
  if type(ed) ~= "table" then error(where .. "editor is a table", 2) end
  ed.label = ed.label or name
  ed.glyph = ed.glyph or name:sub(1, 1)
  ed.color = ed.color or { 0.8, 0.8, 0.8 }
  if type(ed.label) ~= "string" or type(ed.glyph) ~= "string" or #ed.glyph < 1 or #ed.glyph > 2 then
    error(where .. "editor.label is a string and editor.glyph 1 or 2 characters", 2)
  end
  if type(ed.color) ~= "table" or type(ed.color[1]) ~= "number" or type(ed.color[2]) ~= "number"
    or type(ed.color[3]) ~= "number" then
    error(where .. "editor.color is { r, g, b }", 2)
  end
  for _, h in ipairs(HOOKS) do
    if def[h] ~= nil and type(def[h]) ~= "function" then error(where .. h .. " is a function", 2) end
  end
  self.defs[name] = def
  self.order[#self.order + 1] = name
  return def
end

function Registry:get(name) return self.defs[name] end

-- registry:check(placement) -> nil, or the reason a placement is wrong (unknown type, bad
-- position or size, a size the type cannot take, an unknown field or a bad value).
function Registry:check(p)
  if type(p) ~= "table" then return "a prop is a table" end
  local def = self.defs[p.type]
  if not def then return "unknown prop type " .. tostring(p.type) end
  local where = "prop " .. p.type .. ": "
  if not whole(p.tx, 1) or not whole(p.ty, 1) then return where .. "tx, ty are whole tiles >= 1" end
  local w, h = p.w or def.size.w, p.h or def.size.h
  if not whole(w, 1) or not whole(h, 1) then return where .. "w, h are whole tiles >= 1" end
  local rz = def.resize
  if w ~= def.size.w and rz ~= "x" and rz ~= "xy" then return where .. "its width cannot change" end
  if h ~= def.size.h and rz ~= "y" and rz ~= "xy" then return where .. "its height cannot change" end
  if def.min and (w < def.min.w or h < def.min.h) then return where .. "smaller than its minimum size" end
  if def.max and (w > def.max.w or h > def.max.h) then return where .. "bigger than its maximum size" end
  if p.fields ~= nil then
    if type(p.fields) ~= "table" then return where .. "fields is a table" end
    for k, v in pairs(p.fields) do
      local spec = def.field_by_key[k]
      if not spec then return where .. "unknown field " .. tostring(k) end
      local why = check_value(spec, v)
      if why then return where .. "field " .. k .. " " .. why end
    end
  end
  return nil
end

-- registry:catalog() -> the data the level editors read (docs/PROPS.md), in definition order.
-- Plain tables only: engine.save serializes it as it is.
function Registry:catalog()
  local types = {}
  for i, name in ipairs(self.order) do
    local def = self.defs[name]
    local flags = {}
    for k in pairs(def.flags) do flags[#flags + 1] = k end
    table.sort(flags)
    local fields = {}
    for j, f in ipairs(def.fields) do
      local out = { key = f.key, type = f.type, default = f.default, min = f.min, max = f.max }
      if f.options then
        out.options = {}
        for k = 1, #f.options do out.options[k] = f.options[k] end
      end
      fields[j] = out
    end
    local c = def.editor.color
    types[i] = { id = name, label = def.editor.label, glyph = def.editor.glyph,
      color = { c[1], c[2], c[3] }, category = def.category, w = def.size.w, h = def.size.h,
      resizable = def.resize, collision = def.collision, flags = flags, fields = fields,
      placement = "prop",
      min = def.min and { w = def.min.w, h = def.min.h } or nil,
      max = def.max and { w = def.max.w, h = def.max.h } or nil }
  end
  return { format = M.CATALOG_FORMAT, version = M.CATALOG_VERSION, types = types }
end

---------------------------------------------------------------------------
-- The set of one room
---------------------------------------------------------------------------
local Set = {}
Set.__index = Set

-- The collision grid a set hands out: the room grid, with prop tiles on top
local Overlay = {}
Overlay.__index = Overlay

function Overlay:kind(tx, ty)
  if tx < 1 or ty < 1 or tx > self.width or ty > self.height then return nil end
  local k = self.cells[(ty - 1) * self.width + tx]
  if k then return k end
  return self.base:kind(tx, ty)
end

-- props.set(registry, placements, opts) -> the live props of a room. placements: the room's
-- `props` list (nil is an empty room). opts:
--   tile_size   pixels per tile (default 16); x, y: where tile (1, 1) starts (default 0)
--   state       the room's persistent table for its props (one sub-table per placement, by
--               index); the game keeps it between visits and in its run save. Nil: a fresh one.
--   ctx         passed to each type's init
-- A bad placement raises, naming it.
function M.set(registry, placements, opts)
  opts = opts or {}
  local ts = opts.tile_size or 16
  local ox, oy = opts.x or 0, opts.y or 0
  local state = opts.state or {}
  local self = setmetatable({ registry = registry, list = {}, n = 0, tile_size = ts, ox = ox, oy = oy,
    state = state, overlay = nil }, Set)
  for i, p in ipairs(placements or {}) do
    local why = registry:check(p)
    if why then error("props: placement " .. i .. ": " .. why, 2) end
    local def = registry.defs[p.type]
    local saved = state[i]
    if not saved then saved = {}; state[i] = saved end
    local fields = {}
    for _, f in ipairs(def.fields) do fields[f.key] = f.default end
    if p.fields then for k, v in pairs(p.fields) do fields[k] = v end end
    local tw, th = p.w or def.size.w, p.h or def.size.h
    local inst = { type = p.type, def = def, index = i, tx = p.tx, ty = p.ty, tw = tw, th = th,
      x = ox + (p.tx - 1) * ts, y = oy + (p.ty - 1) * ts, w = tw * ts, h = th * ts,
      fields = fields, state = saved, flags = def.flags, removed = saved.removed == true }
    self.n = self.n + 1
    self.list[self.n] = inst
    if def.init and not inst.removed then def.init(inst, opts.ctx) end
  end
  return self
end

function Set:count() return self.n end
function Set:at(i) return self.list[i] end

local function stamp(self, inst, value)
  local o = self.overlay
  if not o or not inst.def.collision then return end
  local w = o.width
  for ty = inst.ty, inst.ty + inst.th - 1 do
    for tx = inst.tx, inst.tx + inst.tw - 1 do
      if tx <= w and ty <= o.height then o.cells[(ty - 1) * w + tx] = value end
    end
  end
end

-- set:grid(base) -> a grid (platformer grid interface: width, height, tile_size, kind) that
-- answers the props' collision first and the base grid elsewhere. Removed props are not on it,
-- and removing one later (set:remove, a hit) takes its tiles off at once. Call it once per room.
function Set:grid(base)
  local o = setmetatable({ base = base, width = base.width, height = base.height,
    tile_size = base.tile_size, cells = {} }, Overlay)
  for i = 1, base.width * base.height do o.cells[i] = false end
  self.overlay = o
  for i = 1, self.n do
    local inst = self.list[i]
    if not inst.removed then stamp(self, inst, inst.def.collision) end
  end
  return o
end

-- set:remove(p): the prop is gone for good (state.removed persists): no collision, no hooks.
function Set:remove(inst)
  if inst.removed then return end
  inst.removed = true
  inst.state.removed = true
  stamp(self, inst, false)
end

-- set:hit(p, amount, ctx) -> true if the prop was removed by it. Calls the type's hit hook;
-- a type without one ignores hits.
function Set:hit(inst, amount, ctx)
  if inst.removed then return false end
  local hook = inst.def.hit
  if hook and hook(inst, amount or 1, ctx) then
    self:remove(inst)
    return true
  end
  return false
end

function Set:update(dt, ctx)
  local list = self.list
  for i = 1, self.n do
    local inst = list[i]
    local hook = inst.def.update
    if hook and not inst.removed then hook(inst, dt, ctx) end
  end
end

function Set:draw(g)
  local list = self.list
  for i = 1, self.n do
    local inst = list[i]
    local hook = inst.def.draw
    if hook and not inst.removed then hook(inst, g) end
  end
end

-- set:first(x, y, w, h, flag, after) -> the first live prop (after index `after`, default 0)
-- that overlaps the box and has the flag (nil flag: any prop), and its index; or nil.
-- Allocates nothing: loop with `local p, i = set:first(..., flag, 0)` then `after = i`.
function Set:first(x, y, w, h, flag, after)
  local list = self.list
  for i = (after or 0) + 1, self.n do
    local inst = list[i]
    if not inst.removed and (flag == nil or inst.flags[flag])
      and x < inst.x + inst.w and x + w > inst.x and y < inst.y + inst.h and y + h > inst.y then
      return inst, i
    end
  end
  return nil
end

-- set:tile_flag(tx, ty, flag) -> the first live prop covering the tile with the flag, or nil.
function Set:tile_flag(tx, ty, flag)
  local list = self.list
  for i = 1, self.n do
    local inst = list[i]
    if not inst.removed and inst.flags[flag] and tx >= inst.tx and tx < inst.tx + inst.tw
      and ty >= inst.ty and ty < inst.ty + inst.th then
      return inst
    end
  end
  return nil
end

return M
