-- game.lua loader: the per-game config, a data-only Lua file that returns a table.
-- Shared by the console boot (l360/boot.lua), by tools (tools/read_game_config.lua) and by games
-- on PC. Plain Lua 5.1 / LuaJIT, no dependencies. Schema: docs/GAME_CONFIG.md.
--   local cfg, err = Config.load(source)   -- source: the text of game.lua
--   local cfg = Config.defaults()          -- what a game without game.lua gets
local M = {}

M.DEFAULT_NAME = 'Untitled game'
M.DEFAULT_SAVE_DIR = 'save'
-- Folders of the console layout that the save folder cannot use (compared in lower case).
M.RESERVED_DIRS = { l360 = true, shaders = true }
M.AURORA_KEYS = { icon = true, cover = true, background = true, banner = true }
M.SHADER_KEYS = { glsl = true, pixel = true, vertex = true }

local function fail(msg) error({ config_error = msg }, 0) end

-- A path inside the game folder: relative, '/' separators, no '..'.
local function check_path(v, what)
  if type(v) ~= 'string' or v == '' or #v > 200 then fail(what .. ' must be a path (a non-empty string)') end
  if v:find('\\', 1, true) or v:find(':', 1, true) or v:sub(1, 1) == '/' or v:find('%.%.') or v:find('%c') then
    fail(what .. ' must be a relative path inside the game folder, with / separators: ' .. v)
  end
  return v
end

local function flat_name(v, what)
  if type(v) ~= 'string' or not v:match('^[%w_%-]+$') or #v > 32 then
    fail(what .. ' must be 1 to 32 characters: letters, digits, _ and -')
  end
  return v
end

-- 'My Game!' -> 'my_game'
local function identity_from(name)
  local id = name:lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', ''):sub(1, 32)
  return id ~= '' and id or 'game'
end

local function validate(t)
  if type(t) ~= 'table' then fail('game.lua must return a table') end
  local known = { name = true, identity = true, title_id = true, save_dir = true, aurora = true,
    shaders = true, default_font = true, debug = true, audio = true }
  for k in pairs(t) do
    if not known[k] then fail('unknown field: ' .. tostring(k)) end
  end
  local cfg = {}

  -- name: shown by Aurora and used as the window title. Printable ASCII, so that it is safe in
  -- the .xex header and on a CMake command line.
  local name = t.name
  if type(name) ~= 'string' or name == '' or #name > 64 or name:find('[^\32-\126]') or name:find('["\\;]')
      or name ~= name:match('^%s*(.-)%s*$') then
    fail('name is required: 1 to 64 printable ASCII characters, without " \\ ; or spaces at the ends')
  end
  cfg.name = name

  cfg.identity = t.identity == nil and identity_from(name) or flat_name(t.identity, 'identity')

  -- title_id: 8 hex digits, with or without 0x. Used by the build and the packaging only.
  if t.title_id ~= nil then
    local hex = type(t.title_id) == 'string' and t.title_id:match('^0[xX](%x%x%x%x%x%x%x%x)$')
      or type(t.title_id) == 'string' and t.title_id:match('^(%x%x%x%x%x%x%x%x)$')
    if not hex or hex:upper() == '00000000' then
      fail('title_id must be a string with 8 hex digits, like "0x4D470001"')
    end
    cfg.title_id = '0x' .. hex:upper()
  end

  cfg.save_dir = t.save_dir == nil and M.DEFAULT_SAVE_DIR or flat_name(t.save_dir, 'save_dir')
  if M.RESERVED_DIRS[cfg.save_dir:lower()] then fail('save_dir cannot be ' .. cfg.save_dir .. ' (used by the runtime)') end

  cfg.aurora = {}
  if t.aurora ~= nil then
    if type(t.aurora) ~= 'table' then fail('aurora must be a table') end
    for k, v in pairs(t.aurora) do
      if not M.AURORA_KEYS[k] then fail('unknown field: aurora.' .. tostring(k)) end
      cfg.aurora[k] = check_path(v, 'aurora.' .. k)
    end
  end

  -- shaders: name -> the GLSL it is built from (docs/SHADERS.md). "path" is { glsl = "path" }.
  cfg.shaders = {}
  if t.shaders ~= nil then
    if type(t.shaders) ~= 'table' then fail('shaders must be a table') end
    for name, decl in pairs(t.shaders) do
      if type(name) ~= 'string' or not name:match('^%a[%w_]*$') or #name > 24 or name:lower():sub(1, 5) == 'l360_' then
        fail('shader names must be 1 to 24 letters, digits or _, starting with a letter and not with l360_: '
          .. tostring(name))
      end
      local what = 'shaders.' .. name
      if type(decl) == 'string' then decl = { glsl = decl } end
      if type(decl) ~= 'table' then fail(what .. ' must be a path or a table') end
      local d = {}
      for k, v in pairs(decl) do
        if not M.SHADER_KEYS[k] then fail('unknown field: ' .. what .. '.' .. tostring(k)) end
        d[k] = check_path(v, what .. '.' .. k)
      end
      if d.glsl and (d.pixel or d.vertex) then fail(what .. ': give glsl, or pixel and/or vertex') end
      if not (d.glsl or d.pixel or d.vertex) then fail(what .. ' needs glsl, pixel or vertex') end
      cfg.shaders[name] = d
    end
  end

  -- audio: how tools/package.py converts the game's .ogg for the console (docs/GAME_CONFIG.md).
  -- The runtime does not use it; it is checked here so a typo fails on the PC too.
  cfg.audio = {}
  if t.audio ~= nil then
    if type(t.audio) ~= 'table' then fail('audio must be a table') end
    for k, v in pairs(t.audio) do
      if k == 'rate' then
        if type(v) ~= 'number' or v ~= math.floor(v) or v < 8000 or v > 48000 then
          fail('audio.rate must be a whole number of Hz from 8000 to 48000')
        end
      elseif k == 'long_seconds' then
        if type(v) ~= 'number' or v < 0 then fail('audio.long_seconds must be a number of seconds, 0 or more') end
      elseif k == 'chunk_seconds' then
        if type(v) ~= 'number' or v < 1 or v > 60 then fail('audio.chunk_seconds must be from 1 to 60') end
      elseif k == 'music' then
        if type(v) ~= 'table' then fail('audio.music must be a list of path patterns') end
        for i, p in ipairs(v) do
          if type(p) ~= 'string' or p == '' then fail('audio.music[' .. i .. '] must be a path pattern') end
        end
      else
        fail('unknown field: audio.' .. tostring(k))
      end
      cfg.audio[k] = v
    end
  end

  if t.default_font ~= nil then cfg.default_font = check_path(t.default_font, 'default_font') end

  -- debug: development builds only; engine.debug reads it (docs/ENGINE.md). Absent means off.
  if t.debug ~= nil then
    if type(t.debug) ~= 'boolean' then fail('debug must be true or false') end
    cfg.debug = t.debug or nil
  end
  return cfg
end

-- Checks a table that is already in memory. Returns the normalized config, or nil and the reason.
function M.validate(t)
  local ok, r = pcall(validate, t)
  if ok then return r end
  return nil, type(r) == 'table' and r.config_error or tostring(r)
end

-- source: the text of game.lua. It runs in an empty environment (no globals, no require): it can
-- only build and return a table. Returns the normalized config, or nil and the reason.
function M.load(source, chunkname)
  chunkname = chunkname or 'game.lua'
  if type(source) ~= 'string' then return nil, chunkname .. ' not found' end
  if source:sub(1, 1) == '\27' then return nil, chunkname .. ': bytecode is not accepted' end
  local chunk, err = loadstring(source, '@' .. chunkname)
  if not chunk then return nil, err end
  setfenv(chunk, {})
  local ok, t = pcall(chunk)
  if not ok then return nil, tostring(t) end
  local cfg, why = M.validate(t)
  if not cfg then return nil, chunkname .. ': ' .. why end
  return cfg
end

function M.defaults()
  return assert(M.validate({ name = M.DEFAULT_NAME }))
end

return M
