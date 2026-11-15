-- Prints fields of a game's game.lua for the build and the packaging.
-- Usage: luajit tools/read_game_config.lua <game folder or game.lua> [field]
--   without field: one "key=value" line for title_id, name, identity and save_dir
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
if not cfg.title_id then die(path .. ': title_id is required to build or package the game') end

if field then
  local v = cfg[field]
  if type(v) ~= 'string' then die('no text field named ' .. field) end
  print(v)
else
  for _, k in ipairs({ 'title_id', 'name', 'identity', 'save_dir' }) do print(k .. '=' .. cfg[k]) end
end
