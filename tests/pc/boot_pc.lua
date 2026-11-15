-- PC check of the console boot (runtime/lua/boot.lua) against tests/fixtures/minimal_game.
-- Builds the l360 table like runtime/main.c and runtime/l360_sys.c do (files from disk, saves in
-- memory, a fake controller), runs runtime/lua/l360_gfx_stub.lua and then boot.lua for FRAMES
-- frames, and checks that the game was loaded and run the way LÖVE would. The fixture's shader
-- metadata (shaders/*.meta.lua) is generated first with tools/shaders/build_shaders.py --hlsl-only
-- (needs python3), as the shader build would leave it in the console folder.
-- Usage, from the repository root: luajit -joff tests/pc/boot_pc.lua [game folder]
local root = arg[1] or 'tests/fixtures/minimal_game'
local own_game = arg[1] == nil
local FRAMES = tonumber(os.getenv('L360_FRAMES')) or 90
local RT = 'l360/'
local raw_print = print

local function read_file(path)
  local f = io.open(path, 'rb'); if not f then return nil end
  local d = f:read('*a'); f:close(); return d
end

-- The shader build's output for the fixture, without compiling (no xost on this PC)
local built_shaders
if own_game then
  local p = assert(io.popen('mktemp -d'))
  built_shaders = p:read('*l'); p:close()
  assert(built_shaders and built_shaders ~= '', 'mktemp failed')
  local cmd = 'python3 tools/shaders/build_shaders.py ' .. root .. ' --out ' .. built_shaders .. ' --hlsl-only 2>&1'
  p = assert(io.popen(cmd))
  local out = p:read('*a'); p:close()
  if not out:find('1 shaders declared, 2 files written', 1, true) then
    raw_print('FAILED: ' .. cmd .. '\n' .. out); os.exit(1)
  end
end

-- The console folder: the game's files, l360/ with runtime/lua/ (plus the number test), and
-- shaders/ with the shader build's output.
local function game_file(path)
  if path:find('%.%.') then return nil end
  if built_shaders and path:match('^shaders/[%w_]+%.meta%.lua$') then
    return read_file(built_shaders .. '/' .. path:match('[^/]+$'))
  end
  local own = path:match('^l360/(.*)$')
  if own then return read_file('runtime/lua/' .. own) or read_file('tests/console/' .. own) end
  return read_file(root .. '/' .. path)
end

local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then raw_print('FAILED: ' .. what); os.exit(1) end
end

---------------------------------------------------------------------------
-- 1. The game.lua loader and tools/read_game_config.lua
---------------------------------------------------------------------------
local Config = assert(loadstring(assert(read_file('runtime/lua/config.lua')), '@config.lua'))()
do
  local cfg = assert(Config.load('return { name = "My Game!", title_id = "4d470001" }'))
  check(cfg.name == 'My Game!' and cfg.identity == 'my_game' and cfg.save_dir == 'save'
    and cfg.title_id == '0x4D470001', 'defaults and title_id normalization')
  check(type(cfg.aurora) == 'table' and type(cfg.shaders) == 'table', 'aurora and shaders default to tables')
  local sh = assert(Config.validate({ name = 'x', shaders = { crt = 'fx/crt.glsl', wave = { glsl = 'w.glsl' },
    glow = { pixel = 'glow.frag', vertex = 'glow.vert' } } })).shaders
  check(sh.crt.glsl == 'fx/crt.glsl' and sh.wave.glsl == 'w.glsl' and sh.glow.pixel == 'glow.frag'
    and sh.glow.vertex == 'glow.vert', 'shaders are normalized to tables')
  check(Config.defaults().save_dir == 'save', 'defaults()')
  local bad = {
    ['not found'] = nil,
    ['no table'] = 'return 5',
    ['no name'] = 'return {}',
    ['name with quote'] = 'return { name = "a\\"b" }',
    ['unknown field'] = 'return { name = "a", tittle_id = "0x4D470001" }',
    ['title_id as number'] = 'return { name = "a", title_id = 0x4D470001 }',
    ['short title_id'] = 'return { name = "a", title_id = "0x4D47" }',
    ['save_dir with slash'] = 'return { name = "a", save_dir = "a/b" }',
    ['save_dir with dots'] = 'return { name = "a", save_dir = ".." }',
    ['reserved save_dir'] = 'return { name = "a", save_dir = "L360" }',
    ['identity with space'] = 'return { name = "a", identity = "a b" }',
    ['aurora path leaves the folder'] = 'return { name = "a", aurora = { icon = "../x.png" } }',
    ['unknown aurora field'] = 'return { name = "a", aurora = { logo = "x.png" } }',
    ['shaders not a table'] = 'return { name = "a", shaders = "x" }',
    ['shader without a file'] = 'return { name = "a", shaders = { x = {} } }',
    ['shader with glsl and pixel'] = 'return { name = "a", shaders = { x = { glsl = "a.glsl", pixel = "b.glsl" } } }',
    ['shader path leaves the folder'] = 'return { name = "a", shaders = { x = "../x.glsl" } }',
    ['reserved shader name'] = 'return { name = "a", shaders = { l360_default = "x.glsl" } }',
    ['shader name with a dot'] = 'return { name = "a", shaders = { ["x.y"] = "x.glsl" } }',
    ['unknown shader field'] = 'return { name = "a", shaders = { x = { hlsl = "x.hlsl" } } }',
    ['uses a global'] = 'return { name = os.getenv("HOME") }',
    ['uses require'] = 'require("os") return { name = "a" }',
    ['syntax error'] = 'return {',
    ['bytecode'] = '\27LJ',
  }
  local names = { 'not found' }
  for k in pairs(bad) do names[#names + 1] = k end
  for _, k in ipairs(names) do
    local cfg2, err = Config.load(bad[k])
    check(cfg2 == nil and type(err) == 'string', 'game.lua must be rejected: ' .. k)
  end
  if own_game then
    local p = assert(io.popen('luajit tools/read_game_config.lua ' .. root))
    local out = p:read('*a'); p:close()
    check(out:find('title_id=0x4D470001\n', 1, true) and out:find('name=Minimal Game\n', 1, true),
      'tools/read_game_config.lua output: ' .. out)
    p = assert(io.popen('luajit tools/read_game_config.lua ' .. root .. ' shaders'))
    out = p:read('*a'); p:close()
    check(out == 'tint\tshaders/tint.glsl\tshaders/tint.glsl\n', 'tools/read_game_config.lua shaders: ' .. out)
  end
end

---------------------------------------------------------------------------
-- 2. The l360 table
---------------------------------------------------------------------------
local t = 0
local frames, ctx, start_render, quit_called = 0, '-', false, false
local log_lines = {}
local function log(s) s = tostring(s); raw_print(s); log_lines[#log_lines + 1] = s end
local function logged(text)
  for _, l in ipairs(log_lines) do if l:find(text, 1, true) then return true end end
  return false
end
local files, bytes = 0, 0
local SAVES, save_dir = {}, 'save'
local finish

l360 = {
  time = function() return t end,
  log = log,
  read = function(path)
    local d = game_file(path)
    if d then files = files + 1; bytes = bytes + #d end
    return d
  end,
  readstats = function() return { files = files, bytes = bytes, ms = 0 } end,
  heap = function() return 0, 0 end,
  poll = function() end,
  poll_input = function() end,
  wait_frame = function(until_t)
    frames = frames + 1
    if until_t > t then t = until_t end
    if frames >= FRAMES then finish() end
  end,
  set_context = function(s) ctx = s end,
  start_render = function() start_render = true end,
  -- A connected controller with nothing held, except A on frames 10 to 12.
  pad = function(port)
    if port and port ~= 0 then return nil end
    return { s1_x = 0, s1_y = 0, s2_x = 0, s2_y = 0, s1_z = 0, s2_z = 0, lb = 0, rb = 0,
      start = 0, back = 0, a = (frames >= 10 and frames <= 12) and 1 or 0, b = 0, x = 0, y = 0,
      up = 0, down = 0, left = 0, right = 0, lt = 0, rt = 0, logo = 0 }
  end,
  rumble = function() return true end,
  -- Like l360_sys.c: nothing to list in the save folder before the first save, files by stat.
  filetype = function(path)
    if path == save_dir then return nil end
    local d = game_file(path)
    if d then return 'file', #d end
    return nil
  end,
  listdir = function(path) if path == save_dir then return nil end return {} end,
  quit = function() quit_called = true end,
  save_set_dir = function(name)
    if type(name) ~= 'string' or not name:match('^[%w_%-]+$') or #name > 32 then return false end
    save_dir = name
    return true
  end,
  save_dir = function() return 'game:/' .. save_dir .. '/' end,
  save_read = function(name) return SAVES[name] end,
  save_write = function(name, data)
    if type(name) ~= 'string' or #name == 0 or #name > 80 or name:find('[^%w_%.%-]') then return false end
    SAVES[name] = data
    return true
  end,
  platform = 'xbox360-luajit', width = 1280, height = 720, runtime_dir = RT,
}

function finish()
  local st = l360.gfxstats()
  check(start_render, 'the boot reached start_render')
  check(frames >= FRAMES, 'the loop reached ' .. FRAMES .. ' frames')
  check(st.frames >= FRAMES - 1, 'love.graphics.present reached the stub: ' .. st.frames)
  check(not logged('ERROR'), 'no ERROR line in the log')
  if own_game then
    check(logged('game.lua: Minimal Game (identity minimal_game, save folder save)'), 'game.lua was read')
    check(logged('conf.lua: identity minimal_game, title Minimal Game'), 'conf.lua and love.conf ran')
    check(logged('minimal_game: love.load, run 1, window 1280x720'), 'love.load ran, with print in the log')
    check(logged('minimal_game: frame 60'), 'love.update ran on every frame')
    check(st.draws >= FRAMES - 1, 'love.draw drew a rectangle per frame: ' .. st.draws)
    check(logged('minimal_game: gamepadpressed a'), 'the controller reached love.gamepadpressed')
    check(love.window.getTitle() == 'Minimal Game' and love.filesystem.getIdentity() == 'minimal_game',
      'title and identity')
    check(ctx == 'Minimal Game', 'l360.set_context')
    -- love.filesystem: what the game wrote is in the save folder (slot .a), and reads back
    check(save_dir == 'save' and type(SAVES['l360save_runs.txt.a']) == 'string', 'runs.txt went to the save folder')
    check(love.filesystem.read('runs.txt') == '1', 'runs.txt reads back')
    check(love.filesystem.getInfo('runs.txt').type == 'file', 'getInfo of a saved file')
    check(love.filesystem.getInfo('main.lua', 'file') ~= nil and love.filesystem.getInfo('nope.txt') == nil,
      'getInfo of game files')
    check((love.filesystem.read('conf.lua')):find('love.conf', 1, true), 'game files read through love.filesystem')
    local items = love.filesystem.getDirectoryItems('')
    check(#items == 1 and items[1] == 'runs.txt', 'getDirectoryItems lists what was saved')
    check(type(l360.game) == 'table' and l360.game.aurora.icon == 'aurora/icon.png', 'l360.game has the config')
    -- Shaders: the game's newShader(path) found the declared shader and its metadata, and every
    -- send named a uniform of it
    check(l360.game.shaders.tint.glsl == 'shaders/tint.glsl', 'game.lua shaders')
    check(not logged('[missing] shader'), 'the declared shader was found, with its uniforms')
    check(st.sends >= FRAMES, 'shader:send reached the stub: ' .. st.sends)
    local by_code = love.graphics.newShader(assert(read_file(root .. '/shaders/tint.glsl')))
    check(by_code:hasUniform('tint') and by_code:hasUniform('amount') and not by_code:hasUniform('nope'),
      'newShader(code) finds the declared shader by its text')
    check(not logged('[missing] shader'), 'newShader(code) logged nothing')
    by_code:send('nope', 1); by_code:send('nope', 2)
    local n = 0
    for _, l in ipairs(log_lines) do if l:find('[missing] shader tint: uniform nope', 1, true) then n = n + 1 end end
    check(n == 1, 'an unknown uniform is logged once: ' .. n)
    local other = love.graphics.newShader('shaders/other.glsl')
    other:send('x', 1)
    check(logged('[missing] shader shaders/other.glsl: not declared in game.lua'), 'an undeclared shader is logged')
    check(not other:hasUniform('x'), 'an undeclared shader has no uniforms')
    check(not quit_called, 'nobody asked to quit')
  end
  if built_shaders then os.execute('rm -rf ' .. built_shaders) end
  raw_print(string.format('OK: %d checks; love.load and %d frames; %d draws, %d not drawn; %d files (%d KB)',
    checks, frames, st.draws, st.skipped, files, bytes / 1024))
  os.exit(0)
end

local function run(path)
  local code = assert(game_file(path), 'missing ' .. path)
  local f = assert(loadstring(code, '@' .. path:match('[^/]+$')))
  local ok, err = xpcall(f, debug.traceback)
  if not ok then raw_print('ERROR in ' .. path .. ': ' .. tostring(err)); os.exit(1) end
end

-- Like main.c: the number test, then the graphics stub (as when the GPU did not start), then the boot
local nums = assert(loadstring(assert(game_file(RT .. 'number_check.lua')), '@number_check.lua'))()
check(nums == 0, 'the number test: ' .. tostring(nums) .. ' wrong')
run(RT .. 'l360_gfx_stub.lua')
check(type(l360.gfx) == 'table' and type(l360.gfxstats) == 'function', 'the stub set l360.gfx and l360.gfxstats')
run(RT .. 'boot.lua')
-- The boot only returns if something failed before the loop (the errors are already in the log)
raw_print('ERROR: boot.lua returned before ' .. FRAMES .. ' frames')
os.exit(1)
