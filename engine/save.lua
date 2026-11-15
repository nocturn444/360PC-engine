-- 360PC-Engine: saves. Reference: docs/ENGINE.md.
--
-- Two kinds of save, one file each: the run in progress ("run": seed, random streams, whatever
-- the game needs to continue) and the permanent progress ("progress": unlocks, stats, settings).
-- A file is one header line and the payload:
--     360PCSAVE <engine format> <identity> <kind> <game version> <fnv1a, 8 hex> <payload bytes>\n
--     <payload>
-- The payload is data written by Save.serialize and read by Save.parse, a small parser: the
-- file is never handed to load()/loadstring(), so a broken or edited save cannot run code.
-- Only love.filesystem.read / write / remove are used (docs/API_SUBSET.md). On the console
-- those go through the runtime's two slots per file; on PC, where LÖVE 11 has no rename, the
-- last good file is kept as <file>.bak before it is overwritten.
-- Nothing here raises: every function reports through its return values and the log.
local prefix = (...):gsub("save$", "")
local fnv1a = require(prefix .. "rng").hash

local Save = { FORMAT = 1 }
local Obj = {}
Obj.__index = Obj

local MAGIC = "360PCSAVE"
local MAX_DEPTH = 100
local floor, huge = math.floor, math.huge
local fmt, byte, sub, find = string.format, string.byte, string.sub, string.find

---------------------------------------------------------------------------
-- Serializer: nil, booleans, numbers, strings and tables of those. The same data always gives
-- the same text (keys are sorted).
---------------------------------------------------------------------------
local ESCAPES = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function escape_char(c) return ESCAPES[c] or fmt("\\%03d", byte(c)) end

local function number_text(v)
  if v ~= v then return "nan" end
  if v == huge then return "inf" end
  if v == -huge then return "-inf" end
  -- whole numbers without an exponent (exact up to 2^53); the rest with 17 significant digits,
  -- which is enough to read back the same double
  if v == floor(v) and v > -1e15 and v < 1e15 then return fmt("%.0f", v) end
  return fmt("%.17g", v)
end

local function key_less(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return ta == "number" end
  return a < b
end

local function write_value(v, out, path, depth, where)
  local t = type(v)
  if t == "nil" then
    out[#out + 1] = "nil"
  elseif t == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    out[#out + 1] = number_text(v)
  elseif t == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\\127]', escape_char) .. '"'
  elseif t == "table" then
    if path[v] then error("cannot save a table that contains itself (at " .. where .. ")", 0) end
    if depth >= MAX_DEPTH then error("tables nested too deep (at " .. where .. ")", 0) end
    path[v] = true
    out[#out + 1] = "{"
    -- 1..n first, without keys; then the other keys, sorted (numbers before strings)
    local n = 0
    while rawget(v, n + 1) ~= nil do
      n = n + 1
      write_value(rawget(v, n), out, path, depth + 1, where .. "[" .. n .. "]")
      out[#out + 1] = ","
    end
    local keys = {}
    for k in next, v do
      local tk = type(k)
      if tk == "number" then
        if k ~= k then error("cannot save a nan key (at " .. where .. ")", 0) end
        if not (k >= 1 and k <= n and k == floor(k)) then keys[#keys + 1] = k end
      elseif tk == "string" then
        keys[#keys + 1] = k
      else
        error("cannot save a key of type " .. tk .. " (at " .. where .. ")", 0)
      end
    end
    table.sort(keys, key_less)
    for i = 1, #keys do
      local k = keys[i]
      out[#out + 1] = "["
      write_value(k, out, path, depth + 1, where)
      out[#out + 1] = "]="
      write_value(rawget(v, k), out, path, depth + 1,
        where .. (type(k) == "string" and "." .. k or "[" .. number_text(k) .. "]"))
      out[#out + 1] = ","
    end
    out[#out + 1] = "}"
    path[v] = nil
  else
    error("cannot save a " .. t .. " (at " .. where .. ")", 0)
  end
end

-- value -> text, or nil and the reason (a function, a userdata, a thread, a cycle...)
function Save.serialize(value)
  local out = {}
  local ok, err = pcall(write_value, value, out, {}, 0, "root")
  if not ok then return nil, tostring(err) end
  return table.concat(out)
end

---------------------------------------------------------------------------
-- Parser of what the serializer writes (spaces and line ends between tokens are accepted).
-- It only builds data: there is nothing in the grammar that calls or looks up anything.
---------------------------------------------------------------------------
local UNESCAPES = { ["\\"] = "\\", ['"'] = '"', n = "\n", r = "\r", t = "\t" }
local parse_value

local function skip(s, i)
  return find(s, "[^ \t\r\n]", i) or #s + 1
end

local function fail(s, i, what)
  error(fmt("%s at byte %d", what, i), 0)
end

local function parse_string(s, i)  -- i is at the opening quote
  local parts, from = nil, i + 1
  while true do
    local j = find(s, '["\\]', from)
    if not j then fail(s, i, "unfinished string") end
    if byte(s, j) == 34 then
      local last = sub(s, from, j - 1)
      if parts then parts[#parts + 1] = last; return table.concat(parts), j + 1 end
      return last, j + 1
    end
    parts = parts or {}
    parts[#parts + 1] = sub(s, from, j - 1)
    local c = sub(s, j + 1, j + 1)
    if UNESCAPES[c] then
      parts[#parts + 1] = UNESCAPES[c]
      from = j + 2
    else
      local digits = s:match("^%d%d%d", j + 1)
      local code = digits and tonumber(digits)
      if not code or code > 255 then fail(s, j, "bad escape in a string") end
      parts[#parts + 1] = string.char(code)
      from = j + 4
    end
  end
end

local function parse_number(s, i)
  local text = s:match("^-?%d+%.?%d*[eE][-+]?%d+", i) or s:match("^-?%d+%.?%d*", i)
  local n = text and tonumber(text)
  if not n then fail(s, i, "unexpected text") end
  return n, i + #text
end

local function parse_table(s, i, depth)  -- i is at the opening brace
  if depth >= MAX_DEPTH then fail(s, i, "tables nested too deep") end
  local t, n = {}, 0
  i = skip(s, i + 1)
  while true do
    local c = byte(s, i)
    if c == 125 then return t, i + 1 end  -- }
    if c == 91 then  -- [key]=value
      local k
      k, i = parse_value(s, skip(s, i + 1), depth + 1)
      local tk = type(k)
      if (tk ~= "number" and tk ~= "string") or k ~= k then fail(s, i, "bad table key") end
      i = skip(s, i)
      if byte(s, i) ~= 93 then fail(s, i, "expected ]") end
      i = skip(s, i + 1)
      if byte(s, i) ~= 61 then fail(s, i, "expected =") end
      t[k], i = parse_value(s, skip(s, i + 1), depth + 1)
    else
      n = n + 1
      t[n], i = parse_value(s, i, depth + 1)
    end
    i = skip(s, i)
    c = byte(s, i)
    if c == 44 then i = skip(s, i + 1)  -- ,
    elseif c ~= 125 then fail(s, i, "expected , or }") end
  end
end

local WORDS = { { "true", true }, { "false", false }, { "nil", nil }, { "nan", 0 / 0 },
  { "inf", huge }, { "-inf", -huge } }

function parse_value(s, i, depth)
  local c = byte(s, i)
  if c == 123 then return parse_table(s, i, depth) end
  if c == 34 then return parse_string(s, i) end
  if c and ((c >= 48 and c <= 57) or (c == 45 and sub(s, i, i + 3) ~= "-inf")) then
    return parse_number(s, i)
  end
  for w = 1, #WORDS do
    local word = WORDS[w][1]
    if sub(s, i, i + #word - 1) == word and not find(s, "^[%w_]", i + #word) then
      return WORDS[w][2], i + #word
    end
  end
  fail(s, i, c and "unexpected text" or "unexpected end")
end

-- text -> true and the value, or false and the reason (so a saved nil can be told from an error)
function Save.parse(text)
  if type(text) ~= "string" then return false, "not a string" end
  local ok, value, i = pcall(parse_value, text, skip(text, 1), 0)
  if not ok then return false, tostring(value) end
  i = skip(text, i)
  if i <= #text then return false, fmt("unexpected text at byte %d", i) end
  return true, value
end

---------------------------------------------------------------------------
-- The file: header line + payload
---------------------------------------------------------------------------
function Save.pack(identity, kind, version, payload)
  return fmt("%s %d %s %s %d %08x %d\n", MAGIC, Save.FORMAT, identity, kind, version,
    fnv1a(payload), #payload) .. payload
end

-- text -> { format, identity, kind, version, payload }, or nil and the reason. Checks the
-- header, the length and the checksum; not the payload's contents.
function Save.unpack(text)
  if type(text) ~= "string" then return nil, "not a string" end
  local nl = find(text, "\n", 1, true)
  if not nl or nl > 200 then return nil, "no header" end
  local line = sub(text, 1, nl - 1)
  local magic, format = line:match("^(%w+) (%d+) ")
  if magic ~= MAGIC then return nil, "no header" end
  -- a newer engine format may have another layout: do not judge the rest
  if tonumber(format) > Save.FORMAT then return { format = tonumber(format) } end
  local identity, kind, version, sum, len =
    line:match("^%w+ %d+ ([%w_%-]+) (%l+) (%d+) (%x%x%x%x%x%x%x%x) (%d+)$")
  if not identity then return nil, "bad header" end
  local h = { format = tonumber(format), identity = identity, kind = kind,
    version = tonumber(version) }
  local payload = sub(text, nl + 1)
  if #payload ~= tonumber(len) then return nil, "wrong length (the file was cut or edited)" end
  if fnv1a(payload) ~= tonumber(sum, 16) then return nil, "wrong checksum" end
  h.payload = payload
  return h
end

---------------------------------------------------------------------------
-- The save object
---------------------------------------------------------------------------
local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

-- what `data` does not have is taken from `defaults` (tables inside tables too)
local function fill(data, defaults)
  for k, d in pairs(defaults) do
    if data[k] == nil then
      data[k] = copy(d)
    elseif type(d) == "table" and type(data[k]) == "table" then
      fill(data[k], d)
    end
  end
  return data
end

local function is_version(v) return type(v) == "number" and v >= 0 and v == floor(v) and v < 2 ^ 31 end

-- Save.new({
--   identity = "my_game",   -- game.lua's identity (default: love.filesystem.getIdentity())
--   run      = { version = 1, file = "run.sav",      migrate = { [1] = function(data) return data end } },
--   progress = { version = 1, file = "progress.sav", migrate = {}, defaults = { ... } },
--   log      = function(text) end,   -- default: print
--   backup   = true,                 -- keep <file>.bak; default: everywhere but on the console
--   fs       = love.filesystem,      -- read, write, remove (for tests)
-- })
-- Raises on a wrong config (a programming error); nothing else here raises.
function Save.new(opts)
  opts = opts or {}
  local love = rawget(_G, "love")
  local fs = opts.fs or (love and love.filesystem)
  if type(fs) ~= "table" then error("engine.save: no love.filesystem", 2) end
  local identity = opts.identity or (fs.getIdentity and fs.getIdentity())
  if type(identity) ~= "string" or not identity:match("^[%w_%-]+$") then
    error("engine.save: identity must be letters, digits, _ or - (game.lua's identity)", 2)
  end
  local backup = opts.backup
  if backup == nil then
    backup = not (love and love.system and love.system.getOS and love.system.getOS() == "Xbox 360")
  end
  local self = setmetatable({ identity = identity, fs = fs, backup = backup and true or false,
    log = opts.log or function(text) print(text) end, kinds = {}, last_error = nil,
    progress = nil }, Obj)
  for _, kind in ipairs({ "run", "progress" }) do
    local k = opts[kind] or {}
    local version = k.version or 1
    if not is_version(version) then error("engine.save: " .. kind .. ".version must be a whole number", 2) end
    local file = k.file or (kind .. ".sav")
    if type(file) ~= "string" or file == "" then error("engine.save: " .. kind .. ".file must be a name", 2) end
    local migrate = k.migrate or {}
    for from, f in pairs(migrate) do
      if not is_version(from) or from >= version or type(f) ~= "function" then
        error("engine.save: " .. kind .. ".migrate[from version] = function, with from < version", 2)
      end
    end
    self.kinds[kind] = { name = kind, version = version, file = file, migrate = migrate,
      defaults = k.defaults or {}, locked = false, checked = false, has = nil }
  end
  if self.kinds.run.file == self.kinds.progress.file then
    error("engine.save: run and progress need different files", 2)
  end
  return self
end

function Obj:_report(text)
  self.last_error = text
  pcall(self.log, "[save] " .. text)
end

-- love.filesystem, without letting it raise
function Obj:_read(name)
  local ok, data = pcall(self.fs.read, name)
  if ok and type(data) == "string" then return data end
  return nil
end
function Obj:_write(name, data)
  local ok, done, err = pcall(self.fs.write, name, data)
  if ok and done then return true end
  return false, tostring(ok and err or done)
end
function Obj:_remove(name)
  local ok, done = pcall(self.fs.remove, name)
  return ok and done and true or false
end

-- header -> the data at the current version, or nil, reason ("corrupt", "newer", "migration")
-- and the detail
function Obj:_decode(k, h)
  if h.format > Save.FORMAT then
    return nil, "newer", fmt("written by a newer engine (save format %d, this one reads %d)", h.format, Save.FORMAT)
  end
  if h.identity ~= self.identity or h.kind ~= k.name then
    return nil, "corrupt", fmt("it is a %s save of %s", h.kind, h.identity)
  end
  if h.version > k.version then
    return nil, "newer", fmt("written by a newer version of the game (%d, this one reads %d)", h.version, k.version)
  end
  local ok, data = Save.parse(h.payload)
  if not ok then return nil, "corrupt", data end
  for v = h.version, k.version - 1 do
    local f = k.migrate[v]
    if not f then return nil, "migration", fmt("no migration from version %d", v) end
    local done, out = pcall(f, data)
    if not done then return nil, "migration", fmt("the migration from version %d failed: %s", v, tostring(out)) end
    if out == nil then return nil, "migration", fmt("the migration from version %d returned nothing", v) end
    data = out
  end
  return data
end

-- Reads a kind's file: data, or nil and "none" / "corrupt" / "newer" / "migration".
-- A corrupt file is copied to <file>.corrupt and removed; with a good .bak, that one is
-- restored and returned (second value "backup").
function Obj:_load(k)
  k.checked, k.locked = true, false
  local text = self:_read(k.file)
  if not text then
    k.has = false
    return nil, "none"
  end
  local data, reason, detail
  local h, err = Save.unpack(text)
  if h then data, reason, detail = self:_decode(k, h) else reason, detail = "corrupt", err end
  if reason == nil then
    k.has = true
    return data
  end
  if reason ~= "corrupt" then
    -- the file is fine, this game cannot read it: leave it alone and do not write over it
    k.locked, k.has = true, false
    self:_report(fmt("%s: %s; the file is kept and will not be overwritten", k.file, detail))
    return nil, reason
  end
  self:_report(fmt("%s is corrupt (%s); a copy is kept as %s.corrupt", k.file, detail, k.file))
  self:_write(k.file .. ".corrupt", text)
  self:_remove(k.file)
  k.has = false
  if self.backup then
    local old = self:_read(k.file .. ".bak")
    local oh = old and Save.unpack(old)
    if oh then
      local odata, oreason = self:_decode(k, oh)
      if oreason == nil then
        self:_report(fmt("%s: using the previous save (%s.bak)", k.file, k.file))
        self:_write(k.file, old)
        k.has = true
        return odata, "backup"
      end
    end
  end
  return nil, "corrupt"
end

-- Writes a kind's file: true, or nil and the reason
function Obj:_save(k, data)
  if not k.checked then
    -- never loaded in this session: make sure a newer game's file is not about to be replaced
    k.checked = true
    local old = self:_read(k.file)
    local h = old and Save.unpack(old)
    if h and (h.format > Save.FORMAT
      or (h.identity == self.identity and h.kind == k.name and h.version > k.version)) then
      k.locked = true
    end
  end
  if k.locked then
    self:_report(fmt("%s was written by a newer version: not overwritten", k.file))
    return nil, "newer"
  end
  local payload, err = Save.serialize(data)
  if not payload then
    self:_report(fmt("%s not saved: %s", k.file, err))
    return nil, err
  end
  local text = Save.pack(self.identity, k.name, k.version, payload)
  local fs = self.fs
  if self.backup then
    if type(fs.rename) == "function" then
      -- not in LÖVE 11; used when the filesystem has it
      if self:_write(k.file .. ".tmp", text) then
        local ok, done = pcall(fs.rename, k.file .. ".tmp", k.file)
        if ok and done then
          k.has = true
          return true
        end
        self:_remove(k.file .. ".tmp")
      end
    end
    -- the last good file becomes the .bak, so a write cut in half loses one save, not all
    local old = self:_read(k.file)
    if old and Save.unpack(old) then self:_write(k.file .. ".bak", old) end
  end
  local ok, werr = self:_write(k.file, text)
  if not ok then
    k.has = nil
    self:_report(fmt("%s not saved: %s", k.file, werr))
    return nil, werr
  end
  k.has = true
  return true
end

-- The run in progress ----------------------------------------------------

-- state: a table of plain data (see docs/ENGINE.md for what to put in it). true, or nil and the reason.
function Obj:save_run(state)
  return self:_save(self.kinds.run, state)
end

-- The saved state, or nil and "none" (no run), "corrupt", "newer" or "migration"
function Obj:load_run()
  local data, reason = self:_load(self.kinds.run)
  if data == nil and reason == nil then return nil, "none" end
  return data, reason
end

-- Is there a run to continue? Reads and checks the file the first time; then it is remembered.
function Obj:has_run()
  local k = self.kinds.run
  if k.has == nil then self:_load(k) end
  return k.has == true
end

-- Forgets the run (on death, on victory). A run of a newer version of the game is kept.
function Obj:clear_run()
  local k = self.kinds.run
  if not k.checked then self:_load(k) end
  if k.locked then return false end
  self:_remove(k.file)
  self:_remove(k.file .. ".bak")
  k.has = false
  return true
end

-- The permanent progress ---------------------------------------------------

-- Always a table: the saved progress with the defaults filled in, or the defaults. The second
-- value is nil, or why the file was not used ("none", "corrupt", "newer", "migration",
-- or "backup" when the previous save was restored). It is also left in save.progress.
function Obj:load_progress()
  local k = self.kinds.progress
  local data, reason = self:_load(k)
  if type(data) ~= "table" then
    if data ~= nil then
      reason = "corrupt"
      self:_report(k.file .. " does not hold a table: using the defaults")
    end
    data = {}
  end
  fill(data, k.defaults)
  if type(data.unlocks) ~= "table" then data.unlocks = {} end
  self.progress = data
  return data, reason
end

-- data: default save.progress. true, or nil and the reason.
function Obj:save_progress(data)
  if data == nil then data = self.progress end
  if type(data) ~= "table" then
    self:_report("save_progress: nothing to save (call load_progress first, or pass a table)")
    return nil, "no data"
  end
  self.progress = data
  return self:_save(self.kinds.progress, data)
end

-- Unlocks live in progress.unlocks[id] = true. unlock saves at once: true if it was new.
function Obj:unlock(id)
  local p = self.progress or self:load_progress()
  if type(p.unlocks) ~= "table" then p.unlocks = {} end
  if p.unlocks[id] then return false end
  p.unlocks[id] = true
  self:save_progress(p)
  return true
end

function Obj:is_unlocked(id)
  local p = self.progress or self:load_progress()
  return type(p.unlocks) == "table" and p.unlocks[id] == true
end

return Save
