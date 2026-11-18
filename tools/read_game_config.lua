-- Prints fields of a game's game.lua for the build and the packaging.
-- Usage: luajit tools/read_game_config.lua <game folder or game.lua> [field]
--   without field: one "key=value" line for title_id, name, identity and save_dir
--   with "shaders": one "name<TAB>pixel file<TAB>vertex file" line per declared shader (a file
--                   can be empty; a single-file shader has the same file twice), for
--                   tools/shaders/build_shaders.py. Does not need title_id.
--   with "audio":   the audio conversion settings given in game.lua, "key=value" lines
--                   (music patterns as one "music=pattern" line each), for tools/package.py.
--   with field:    only that value, e.g.
--     cmake ... -DGAME_TITLE_ID="$(luajit tools/read_game_config.lua mygame title_id)" \
--               -DGAME_NAME="$(luajit tools/read_game_config.lua mygame name)"
-- Exits with 1 (and the reason on stderr) if game.lua is missing or invalid, or has no title_id.
local here = (arg[0] or ''):match('^(.*)[/\\][^/\\]*$') or '.'
local Config = dofile(here .. '/../runtime/lua/config.lua')

local function die(msg) io.stderr:write('read_game_config: ' .. msg .. '\n'); os.exit(1) end

local target, field = arg[1], arg[2]
if not target then die('usage: luajit tools/read_game_config.lua <game folder or game.lua> [field]') end
local path = target:match('%.lua$') and target or (target:gsub('[/\\]+$', '') .. '/game.lua')
local f = io.open(path, 'rb')
if not f then die(path .. ' not found') end
local source = f:read('*a')
f:close()

local cfg, err = Config.load(source, path)
if not cfg then die(err) end
if field == 'shaders' then
  local names = {}
  for name in pairs(cfg.shaders) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local d = cfg.shaders[name]
    print(name .. '\t' .. (d.glsl or d.pixel or '') .. '\t' .. (d.glsl or d.vertex or ''))
  end
  return
end
if field == 'audio' then
  -- one "key=value" line per field given in game.lua; music patterns one "music=pattern" each
  local a = cfg.audio or {}
  for _, k in ipairs({ 'rate', 'long_seconds', 'chunk_seconds' }) do
    if a[k] ~= nil then print(k .. '=' .. tostring(a[k])) end
  end
  for _, p in ipairs(a.music or {}) do print('music=' .. p) end
  return
end
if not cfg.title_id then die(path .. ': title_id is required to build or package the game') end

if field then
  local v = cfg[field]
  if type(v) ~= 'string' then die('no text field named ' .. field) end
  print(v)
else
  for _, k in ipairs({ 'title_id', 'name', 'identity', 'save_dir' }) do print(k .. '=' .. cfg[k]) end
end
