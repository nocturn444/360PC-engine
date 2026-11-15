-- PC check of the console boot (runtime/lua/boot.lua) against tests/fixtures/minimal_game.
-- Builds the l360 table like runtime/main.c and runtime/l360_sys.c do (files from disk, saves in
-- memory, a fake controller), runs runtime/lua/l360_gfx_stub.lua and then boot.lua for FRAMES
-- frames, and checks that the game was loaded and run the way LÖVE would, and that what it drew
-- (SpriteBatch, ParticleSystem, text, lines, shapes) reached l360.gfx with the expected vertices. The fixture's shader
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
  if own_game and path == 'test_font.ttf' then return 'not a real TTF: the stub only measures' end
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
-- The controller callbacks, recorded as "frame name port args" (the game's own still run)
local pad_events, rumbles, pad_checks, watching = {}, {}, {}, false
local function watch_pad()
  if watching then return end
  watching = true
  for _, name in ipairs({ 'joystickadded', 'joystickremoved', 'gamepadpressed', 'gamepadreleased',
      'gamepadaxis', 'joystickpressed', 'joystickreleased', 'joystickaxis', 'joystickhat',
      'keypressed', 'keyreleased' }) do
    local game = rawget(love, name)
    love[name] = function(joy, ...)
      local e = { frames, name, type(joy) == 'table' and joy.port or tostring(joy), ... }
      for i = 1, #e do e[i] = tostring(e[i]) end
      pad_events[#pad_events + 1] = table.concat(e, ' ')
      if name == 'gamepadpressed' and joy.port == 0 and ... == 'a' then
        -- The state seen from inside a callback, and the rumble with a duration
        pad_checks.down = joy:isGamepadDown('a') and joy:isDown(1) and not joy:isGamepadDown('b', 'x')
        pad_checks.vib = joy:setVibration(0.5, 1, 0.05)
        local l, r = joy:getVibration()
        pad_checks.vib_get = l == 0.5 and r == 1
      elseif name == 'gamepadaxis' and ... == 'triggerleft' and select(2, ...) == 1 then
        local lx, ly, rx, ry, lt, rt = joy:getAxes()
        pad_checks.axes = joy:getGamepadAxis('leftx') == 1 and joy:getGamepadAxis('lefty') == -1
          and joy:getGamepadAxis('triggerleft') == 1 and joy:getGamepadAxis('triggerright') == 0
          and lx == 1 and ly == -1 and rx == 0 and ry == 0 and lt == 1 and rt == -1 and joy:getAxis(5) == 1
      elseif name == 'joystickhat' and select(2, ...) == 'u' then
        pad_checks.hat = joy:getHat(1) == 'u' and joy:isGamepadDown('dpup') and not joy:isDown(1, 2, 3)
      elseif name == 'joystickadded' and joy.port == 1 then
        pad_checks.second = love.joystick.getJoystickCount() == 2 and love.joystick.getJoysticks()[2] == joy
          and joy:isConnected() and joy:getID() == 2
      elseif name == 'joystickremoved' then
        pad_checks.removed = not joy:isConnected() and love.joystick.getJoystickCount() == 1
          and not joy:isGamepadDown('x') and joy:setVibration(1, 1) == false
      end
      if game then return game(joy, ...) end
    end
  end
end

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
  -- Port 0: connected from the start; A on frames 10 to 12, left stick right/up and the left trigger
  -- on 20 to 22, d-pad up on 24, guide on 26. Port 1: connected on frames 30 to 39, X held from 38.
  pad = function(port)
    watch_pad()
    local f = frames
    if port == 1 and not (f >= 30 and f <= 39) then return nil end
    if port ~= 0 and port ~= 1 then return nil end
    local p = { s1_x = 0, s1_y = 0, s2_x = 0, s2_y = 0, s1_z = 0, s2_z = 0, lb = 0, rb = 0,
      start = 0, back = 0, a = 0, b = 0, x = 0, y = 0,
      up = 0, down = 0, left = 0, right = 0, lt = 0, rt = 0, logo = 0 }
    if port == 1 then p.x = f >= 38 and 1 or 0; return p end
    p.a = (f >= 10 and f <= 12) and 1 or 0
    if f >= 20 and f <= 22 then p.s1_x, p.s1_y, p.lt = 32767, 32767, 255 end
    p.up = f == 24 and 1 or 0
    p.logo = f == 26 and 1 or 0
    return p
  end,
  rumble = function(port, left, right)
    rumbles[#rumbles + 1] = port .. ':' .. left .. ':' .. right
    return true
  end,
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
    -- Each frame of the fixture: 2 rectangles, a 40x4 tile SpriteBatch, a line of 4 points, a
    -- circle outline (24 segments for radius 30), a filled one of 16 and a ParticleSystem (one
    -- draw, a quad per live particle); print and printf are not drawn, because the fixture has no
    -- default_font
    local drawn = st.draws / 7
    check(drawn >= FRAMES - 1 and drawn == math.floor(drawn), 'seven submits per frame: ' .. st.draws)
    check(st.submits == st.draws, 'the stub counts one draw per submit')
    check(st.verts == drawn * (6 + 6 + 40 * 4 * 6 + 3 * 6 + 24 * 6 + 16 * 3) + 6 * st.particles,
      'vertices per frame: ' .. st.verts / drawn)
    -- the fixture's system holds 24 particles and is asked for more
    check(st.particles > 12 * drawn and st.particles <= 24 * drawn, 'particles per frame: ' .. st.particles / drawn)
    check(logged('minimal_game: frame 30, x = 200, 24 sparks'), 'the fixture\'s ParticleSystem fills up')
    check(love.graphics.getBlendMode() == 'alpha', 'the fixture left the blend mode at alpha')
    check(st.skipped == 2 * drawn, 'print and printf without a font are counted as not drawn: ' .. st.skipped)
    check(logged('[missing] default font'), 'the missing default font is logged')

    -- love.graphics, called directly
    local g = love.graphics
    local function verts(f) local a = l360.gfxstats().verts; f(); return l360.gfxstats().verts - a end
    local function skipped(f) local a = l360.gfxstats().skipped; f(); return l360.gfxstats().skipped - a end
    -- SpriteBatch
    local img = g.newImage('tiles.png')
    check(img:getWidth() == 32 and img:getHeight() == 16, 'tiles.png size')
    local quad = g.newQuad(0, 0, 16, 16, img)
    local batch = g.newSpriteBatch(img, 2, 'static')
    check(batch:getCount() == 0 and batch:getBufferSize() == 2, 'a new SpriteBatch is empty')
    check(batch:add(quad, 0, 0) == 1 and batch:add(16, 0) == 2 and batch:add(quad, 32, 0, 0, 2, 2) == 3,
      'SpriteBatch:add returns the sprite number')
    check(batch:getCount() == 3 and batch:getBufferSize() >= 3, 'the SpriteBatch grows when full')
    batch:set(2, quad, 5, 5)
    check(not pcall(batch.set, batch, 4, quad, 0, 0), 'SpriteBatch:set of a sprite that is not there fails')
    batch:setColor(1, 0, 0, 0.5)
    local r, _, _, a = batch:getColor()
    check(r == 1 and a == 0.5 and batch:getTexture() == img, 'SpriteBatch colour and texture')
    batch:flush()
    check(verts(function() g.draw(batch, 10, 10, 0, 2, 2) end) == 18, 'drawing a SpriteBatch sends its 3 sprites')
    batch:clear()
    check(batch:getCount() == 0 and verts(function() g.draw(batch) end) == 0, 'SpriteBatch:clear')
    check(not pcall(g.newSpriteBatch, 'tiles.png'), 'newSpriteBatch needs an Image')
    -- ParticleSystem
    local function draws(f) local a = l360.gfxstats().draws; f(); return l360.gfxstats().draws - a end
    local function particles(f) local a = l360.gfxstats().particles; f(); return l360.gfxstats().particles - a end
    local ps = g.newParticleSystem(img, 8)
    check(ps:getCount() == 0 and ps:getBufferSize() == 8 and ps:isActive(), 'a new ParticleSystem is empty and active')
    check(ps:getTexture() == img and ps:type() == 'ParticleSystem' and ps:typeOf('Drawable'), 'ParticleSystem texture and type')
    check(select('#', ps:getOffset()) == 2 and ps:getOffset() == 16, 'the default offset is the middle of the texture')
    check(draws(function() g.draw(ps, 10, 10) end) == 0, 'an empty ParticleSystem draws nothing')
    ps:setParticleLifetime(0.5, 1)
    local lmin, lmax = ps:getParticleLifetime()
    check(lmin == 0.5 and lmax == 1, 'setParticleLifetime(min, max)')
    ps:emit(5)
    check(ps:getCount() == 5, 'emit(5): ' .. ps:getCount())
    ps:emit(100)
    check(ps:getCount() == 8, 'emit never goes past the buffer size: ' .. ps:getCount())
    check(draws(function() check(verts(function() check(particles(function() g.draw(ps, 10, 10, 0, 2, 2) end) == 8,
      'gfxstats counts the particles drawn') end) == 48, 'a quad per live particle') end) == 1, 'one draw per ParticleSystem')
    ps:update(0.49)
    check(ps:getCount() == 8, 'no particle dies before the shortest lifetime: ' .. ps:getCount())
    ps:update(0.52)
    check(ps:getCount() == 0, 'every particle is gone after the longest lifetime: ' .. ps:getCount())
    ps:setEmissionRate(30)
    check(ps:getEmissionRate() == 30, 'setEmissionRate')
    ps:setParticleLifetime(0.1)
    for _ = 1, 30 do ps:update(1 / 30) end
    check(ps:getCount() >= 2 and ps:getCount() <= 4, 'rate 30/s with a 0.1 s lifetime keeps about 3 alive: ' .. ps:getCount())
    ps:setParticleLifetime(60)
    for _ = 1, 30 do ps:update(1 / 30); check(ps:getCount() <= 8, 'update never goes past the buffer size') end
    check(ps:getCount() == 8, 'the emission rate fills the buffer: ' .. ps:getCount())
    ps:pause()
    check(not ps:isActive() and not ps:isStopped(), 'pause')
    ps:emit(1); ps:reset()
    check(ps:getCount() == 0, 'reset removes the particles')
    ps:update(1)
    check(ps:getCount() == 0, 'a paused ParticleSystem emits nothing')
    ps:stop()
    check(ps:isStopped() and not ps:isPaused(), 'stop')
    ps:start()
    ps:setEmitterLifetime(0.5)
    for _ = 1, 30 do ps:update(1 / 30) end
    check(ps:isStopped() and ps:getCount() >= 7, 'the emitter stops after its lifetime: ' .. ps:getCount())
    ps:setBufferSize(4)
    check(ps:getBufferSize() == 4 and ps:getCount() == 0, 'setBufferSize empties the system')
    ps:setSizes(1, 2, 0.5); ps:setColors(1, 1, 1, 1, 1, 0, 0, 0); ps:setQuads(quad, quad)
    ps:setSpeed(10); ps:setLinearAcceleration(0, 100); ps:setEmissionArea('uniform', 4, 2, 0, true)
    ps:setInsertMode('random'); ps:setSpread(1); ps:setDirection(2); ps:setRotation(0, 1); ps:setSpin(1)
    ps:setLinearDamping(1, 2); ps:setSizeVariation(0.5); ps:setRelativeRotation(true); ps:setPosition(5, 6)
    local smin, smax = ps:getSpeed()
    local c1, c2 = ps:getColors()
    local ax0, ay0, ax1, ay1 = ps:getLinearAcceleration()
    check(smin == 10 and smax == 10 and select('#', ps:getSizes()) == 3 and c2[1] == 1 and c2[4] == 0 and c1[4] == 1
      and ax0 == 0 and ay0 == 100 and ax1 == 0 and ay1 == 100 and #ps:getQuads() == 2 and ps:getQuads()[1] == quad
      and ps:getInsertMode() == 'random' and ps:hasRelativeRotation() and ps:getOffset() == 8,
      'ParticleSystem setters and getters')
    local dist, dx, dy, angle, rel = ps:getEmissionArea()
    check(dist == 'uniform' and dx == 4 and dy == 2 and angle == 0 and rel == true, 'setEmissionArea')
    check(not pcall(ps.setEmissionArea, ps, 'square', 1, 1) and not pcall(ps.setSizeVariation, ps, 2)
      and not pcall(ps.setSizes, ps, 1, 2, 3, 4, 5, 6, 7, 8, 9) and not pcall(g.newParticleSystem, 'tiles.png', 8),
      'bad ParticleSystem arguments fail')
    local copy = ps:clone()
    ps:emit(2)
    check(copy:getCount() == 0 and copy:getBufferSize() == 4 and copy:getSpeed() == 10 and copy:getTexture() == img,
      'clone copies the settings, not the particles')
    -- Blend modes
    local mode, alphamode = g.getBlendMode()
    check(mode == 'alpha' and alphamode == 'alphamultiply', 'the default blend mode')
    g.setBlendMode('add')
    check(g.getBlendMode() == 'add', 'setBlendMode add')
    g.setBlendMode('alpha', 'premultiplied')
    mode, alphamode = g.getBlendMode()
    check(mode == 'alpha' and alphamode == 'premultiplied', 'setBlendMode with an alpha mode')
    g.setBlendMode('multiply'); g.setBlendMode('multiply')
    mode, alphamode = g.getBlendMode()
    check(mode == 'alpha' and alphamode == 'alphamultiply', 'an unsupported blend mode is drawn as alpha')
    n = 0
    for _, l in ipairs(log_lines) do if l:find('[missing] love.graphics.setBlendMode("multiply")', 1, true) then n = n + 1 end end
    check(n == 1, 'an unsupported blend mode is logged once: ' .. n)
    check(not pcall(g.setBlendMode, 'nope') and not pcall(g.setBlendMode, 'add', 'nope'), 'an unknown blend mode fails')
    -- Text: a font with a file can draw (the stub measures 0.44 of the size per byte)
    local font = g.newFont('test_font.ttf', 20)
    g.setFont(font)
    check(g.getFont() == font and font:getHeight() == 20, 'setFont and getFont')
    check(math.abs(font:getWidth('abcd') - 4 * 8.8) < 1e-9 and math.abs(font:getWidth('a\nabc') - 3 * 8.8) < 1e-9,
      'Font:getWidth, with lines')
    local w, lines = font:getWrap('aaa bbb ccc\nd', 7 * 8.8 + 1)
    check(#lines == 3 and lines[1] == 'aaa bbb' and lines[2] == 'ccc' and lines[3] == 'd'
      and math.abs(w - 7 * 8.8) < 1e-9, 'Font:getWrap: ' .. table.concat(lines, '|'))
    check(verts(function() g.print('ab c', 10, 10) end) == 18, 'print sends a quad per character')
    check(verts(function() g.print('ab', font, 10, 10, 0, 2, 2) end) == 12, 'print with a font argument')
    check(verts(function() g.print({ { 1, 0, 0, 1 }, 'ab', { 0, 1, 0, 1 }, 'cd' }, 0, 0) end) == 24, 'coloured text')
    check(verts(function() g.printf('aaa bbb ccc', 0, 0, 7 * 8.8 + 1, 'center') end) == 54, 'printf')
    check(verts(function() g.printf('aaa bbb', font, 0, 0, 100) end) == 36, 'printf with a font, default align')
    check(not pcall(g.printf, 'x', 0, 0, 100, 'middle'), 'printf rejects an unknown align')
    g.setFont(g.newFont(14))
    check(skipped(function() g.print('abc', 0, 0) end) == 1, 'a font without a file does not draw')
    g.setFont(font)
    -- Lines and shapes
    check(verts(function() g.line(0, 0, 10, 0, 10, 10) end) == 12, 'line: a quad per segment')
    check(verts(function() g.line({ 0, 0, 10, 0 }) end) == 6, 'line with a table')
    check(verts(function() g.rectangle('line', 0, 0, 10, 10) end) == 24, 'rectangle outline')
    check(verts(function() g.circle('fill', 0, 0, 10, 12) end) == 36, 'filled circle with 12 segments')
    check(verts(function() g.circle('line', 0, 0, 30) end) == 144, 'circle outline, default segments')
    check(verts(function() g.ellipse('fill', 0, 0, 20, 10) end) == 51, 'filled ellipse, default segments')
    check(verts(function() g.points(1, 1, 2, 2) end) == 12, 'points')
    check(verts(function() g.points({ { 1, 1, 1, 0, 0, 1 } }) end) == 6, 'coloured points')
    g.setPointSize(4)
    check(g.getPointSize() == 4, 'setPointSize')
    -- love.timer: the frames last 1/30 s here
    check(love.timer.getFPS() == 30, 'getFPS is averaged over a second: ' .. love.timer.getFPS())
    check(math.abs(love.timer.getAverageDelta() - 1 / 30) < 1e-6 and math.abs(love.timer.getDelta() - 1 / 30) < 1e-6,
      'getAverageDelta and getDelta')
    check(love.timer.getTime() == t and type(love.timer.step()) == 'number', 'getTime and step')
    check(logged('minimal_game: gamepadpressed a'), 'the controller reached love.gamepadpressed')
    -- The controller, as LOVE shows an Xbox controller on PC
    local expected = {
      '0 joystickadded 0',
      '10 joystickpressed 0 1', '10 gamepadpressed 0 a',
      '13 joystickreleased 0 1', '13 gamepadreleased 0 a',
      '20 joystickaxis 0 1 1', '20 gamepadaxis 0 leftx 1',
      '20 joystickaxis 0 2 -1', '20 gamepadaxis 0 lefty -1',
      '20 joystickaxis 0 5 1', '20 gamepadaxis 0 triggerleft 1',
      '23 joystickaxis 0 1 0', '23 gamepadaxis 0 leftx 0',
      '23 joystickaxis 0 2 0', '23 gamepadaxis 0 lefty 0',
      '23 joystickaxis 0 5 -1', '23 gamepadaxis 0 triggerleft 0',
      '24 joystickhat 0 1 u', '24 gamepadpressed 0 dpup',
      '25 joystickhat 0 1 c', '25 gamepadreleased 0 dpup',
      '26 joystickpressed 0 11', '26 gamepadpressed 0 guide',
      '27 joystickreleased 0 11', '27 gamepadreleased 0 guide',
      '30 joystickadded 1',
      '38 joystickpressed 1 3', '38 gamepadpressed 1 x',
      '40 joystickremoved 1',
    }
    for i = 1, math.max(#expected, #pad_events) do
      check(pad_events[i] == expected[i], 'controller event ' .. i .. ': ' .. tostring(pad_events[i])
        .. ', expected ' .. tostring(expected[i]))
    end
    for _, k in ipairs({ 'down', 'vib', 'vib_get', 'axes', 'hat', 'second', 'removed' }) do
      check(pad_checks[k], 'controller state inside the callbacks: ' .. k)
    end
    check(table.concat(rumbles, ' ') == '0:128:255 0:0:0', 'setVibration and its duration: ' .. table.concat(rumbles, ' '))
    local joys = love.joystick.getJoysticks()
    local joy = joys[1]
    check(#joys == 1 and love.joystick.getJoystickCount() == 1, 'getJoysticks after the second one left')
    check(joy:isConnected() and joy:isGamepad() and joy:getName() == 'Xbox 360 Controller'
      and #joy:getGUID() == 32 and joy:getID() == 1 and select(2, joy:getID()) == 1, 'Joystick identity')
    check(joy:getAxisCount() == 6 and joy:getButtonCount() == 11 and joy:getHatCount() == 1
      and joy:getAxis(1) == 0 and joy:getAxis(6) == -1 and joy:getHat(1) == 'c', 'Joystick raw layout')
    check(joy:isVibrationSupported() and select('#', joy:getVibration()) == 2 and joy:getVibration() == 0,
      'the vibration stopped')
    check(not pcall(joy.getGamepadAxis, joy, 'nope') and not pcall(joy.isGamepadDown, joy, 'nope'),
      'unknown gamepad names are errors')
    check(select(1, joy:getGamepadMapping('a')) == 'button' and select(2, joy:getGamepadMapping('start')) == 8
      and select(3, joy:getGamepadMapping('dpleft')) == 'l', 'getGamepadMapping')
    check(love.keyboard.isDown('space', 'a') == false and love.keyboard.isScancodeDown('a') == false
      and love.keyboard.getKeyFromScancode('a') == 'a' and love.keyboard.getScancodeFromKey('z') == 'z',
      'love.keyboard: nothing is down')
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
  raw_print(string.format('OK: %d checks; love.load and %d frames; %d draws (%d vertices), %d not drawn; %d files (%d KB)',
    checks, frames, st.draws, st.verts, st.skipped, files, bytes / 1024))
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
