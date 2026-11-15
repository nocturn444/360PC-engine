-- PC check of tools/compat_check.lua against a small fake love table (no LÖVE needed): what is
-- wrapped, that calls pass through unchanged, that each line is printed once, the argument checks,
-- the callbacks, the log file and report(). Also that the generated list is up to date.
-- Usage, from the repository root: luajit -joff tests/pc/compat_check_test.lua
local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print('FAILED: ' .. tostring(what)); os.exit(1) end
end

package.path = 'tools/?.lua;' .. package.path
check(rawget(_G, 'love') == nil, 'the test runs without a love table')
local compat = require('compat_check')
local data = compat.data
check(type(data.modules['love.graphics']) == 'table' and data.modules['love.physics'] == nil, 'the data was loaded')
check(compat.report().total == 0, 'required without a love table: not installed, report() still answers')

-- The data and the argument checks agree
local function status(e) return type(e) == 'table' and e[1] or e end
for key in pairs(compat.checks) do
  local owner, sep, name = key:match('^(.-)([.:])([%w_]+)$')
  local entries = sep == '.' and data.modules[owner] or data.types[owner]
  check(entries and status(entries[name]) == 'partial', 'the check for ' .. key .. ' is about a partial function')
end
check(status(data.modules['love.graphics'].setBlendMode) == 'partial' and status(data.modules['love.graphics'].setScissor) == 'stub'
  and data.modules['love.graphics'].arc == nil and status(data.modules['love.graphics'].getWidth) == 'full',
  'statuses of setBlendMode, setScissor, arc and getWidth')
check(status(data.callbacks.gamepadpressed) == 'full' and status(data.callbacks.keypressed) == 'never'
  and status(data.callbacks.update) == 'full' and status(data.callbacks.run) == 'never', 'callbacks')
for _, ty in ipairs({ 'Image', 'Canvas', 'Quad', 'Font', 'Text', 'Shader', 'SpriteBatch', 'ParticleSystem', 'Source',
    'SoundData', 'Joystick', 'Channel', 'Thread' }) do
  check(type(data.types[ty]) == 'table' and next(data.types[ty]) ~= nil, 'type ' .. ty .. ' is in the data')
end

-- A fake LÖVE: a few modules, two object types and LÖVE's own callbacks
local calls = {}
local function rec(name, ...)
  local results = { n = select('#', ...), ... }
  return function(...)
    calls[#calls + 1] = { name = name, n = select('#', ...), ... }
    return unpack(results, 1, results.n)
  end
end
local saved, files = {}, {
  ['game.lua'] = 'return { name = "Fake", shaders = { tint = "fx/tint.glsl", glow = { pixel = "fx/glow.frag" } } }',
  ['fx/tint.glsl'] = 'vec4 effect(vec4 c, Image t, vec2 tc, vec2 sc)\n{ return c; }\n',
}
local default_run = function() end
local Image = { getWidth = rec('Image:getWidth', 32), setFilter = rec('Image:setFilter'), replacePixels = rec('Image:replacePixels'),
  setWrap = rec('Image:setWrap'), __gc = function() end }
Image.__index = Image
local ParticleSystem = { setSizes = rec('ParticleSystem:setSizes'), setEmissionArea = rec('ParticleSystem:setEmissionArea') }
ParticleSystem.__index = ParticleSystem
local Mesh = { setVertex = rec('Mesh:setVertex') }
local image = setmetatable({}, Image)
local fake = {
  _version = '11.5',
  run = default_run,
  getVersion = rec('love.getVersion', 11, 5, 0, 'Mysterious Mysteries'),
  handlers = { quit = rec('handlers.quit') },
  graphics = {
    getWidth = rec('love.graphics.getWidth', 800),
    setBlendMode = rec('love.graphics.setBlendMode'),
    setScissor = rec('love.graphics.setScissor'),
    arc = rec('love.graphics.arc', 'a', nil, 'c', nil),
    newImage = function() return image end,
    newShader = rec('love.graphics.newShader', 'shader'),
    newCanvas = rec('love.graphics.newCanvas', 'canvas'),
    rectangle = rec('love.graphics.rectangle'),
    polygon = function() error('polygon failed', 0) end,
    limits = { not_a_function = 1 },
  },
  physics = { newWorld = rec('love.physics.newWorld', 'world') },
  event = { pump = rec('love.event.pump'), push = rec('love.event.push') },
  filesystem = {
    read = function(path) return files[path] end,
    append = function(path, text) saved[path] = (saved[path] or '') .. text; return true end,
  },
}
local originals = {}
for k, v in pairs(fake.graphics) do originals[k] = v end
local printed = {}
local function count(text)
  local n = 0
  for _, l in ipairs(printed) do if l:find(text, 1, true) then n = n + 1 end end
  return n
end

local same = compat.install({ love = fake, registry = { Image = Image, ParticleSystem = ParticleSystem, Mesh = Mesh },
  print = function(s) printed[#printed + 1] = s end, file = 'compat_check.txt' })
check(same == compat, 'install returns the module')
check(#printed == 0, 'installing prints nothing')

-- What is wrapped
local g = fake.graphics
for k, v in pairs(originals) do
  check((g[k] ~= v) == (type(v) == 'function'), 'love.graphics.' .. k .. ' wrapped only if a function')
end
check(fake.getVersion ~= nil and fake.run == default_run and fake.handlers.quit ~= nil and #calls == 0, 'love.run and love.handlers are left alone')
check(type(Image.__gc) == 'function' and Image.__index == Image and Mesh.setVertex ~= nil, 'metamethods are left alone')
local before = g.getWidth
compat.install()
check(g.getWidth == before, 'install() again does not wrap twice')

-- Pass-through: arguments and results, nils included, and errors
local a, b, c, d = g.arc('fill', nil, 3, nil)
check(a == 'a' and b == nil and c == 'c' and d == nil and select('#', g.arc()) == 4, 'results pass through, nils included')
check(calls[1].name == 'love.graphics.arc' and calls[1].n == 4 and calls[1][1] == 'fill' and calls[1][2] == nil
  and calls[1][3] == 3, 'arguments pass through, nils included')
check(g.getWidth() == 800 and select('#', g.setScissor()) == 0, 'results of a full function and of one that returns nothing')
local ok, err = pcall(g.polygon, 'fill', 0, 0, 1, 1, 2, 0)
check(not ok and err == 'polygon failed', 'errors pass through')
check(image:getWidth() == 32 and calls[#calls].name == 'Image:getWidth' and calls[#calls][1] == image, 'methods pass through, with self')
local v1, v2, v3, v4 = fake.getVersion()
check(v1 == 11 and v2 == 5 and v3 == 0 and v4 == 'Mysterious Mysteries', 'love.getVersion passes through')

-- Missing and stubs: one line per name, however many calls
for _ = 1, 5 do g.arc('fill', 0, 0, 10, 0, 1); g.setScissor(0, 0, 10, 10); g.getWidth() end
check(count('love.graphics.arc: not on the console (missing)') == 1, 'a missing function is logged once')
check(count('love.graphics.setScissor: a stub on the console') == 1, 'a stub is logged once')
check(count('getWidth') == 0, 'a full function is not logged')
check(fake.physics.newWorld(0, 0) == 'world' and count('love.physics.newWorld: not on the console (missing: there is no love.physics') == 1,
  'a function of an absent module')
fake.event.pump(); fake.event.pump()
check(count('love.event.pump') == 0, 'love.event.pump (called by LÖVE\'s own love.run) is not logged')
image:replacePixels(); image:replacePixels(); image:setWrap('repeat')
check(count('Image:replacePixels: not on the console (missing)') == 1 and count('Image:setWrap: a stub') == 1, 'methods: missing and stub')

-- Partial functions: only the unsupported use is logged
g.setBlendMode('alpha'); g.setBlendMode('add', 'premultiplied'); g.setBlendMode('alpha', 'alphamultiply')
check(count('setBlendMode') == 0, 'supported blend modes are not logged')
g.setBlendMode('multiply', 'premultiplied'); g.setBlendMode('multiply', 'premultiplied'); g.setBlendMode('screen')
check(count('love.graphics.setBlendMode: "multiply" is drawn as "alpha"') == 1 and count('setBlendMode: "screen"') == 1,
  'an unsupported blend mode is logged once per mode')
check(calls[#calls].name == 'love.graphics.setBlendMode' and calls[#calls][1] == 'screen', 'and the call still reaches LÖVE')
check(g.newShader('fx/tint.glsl') == 'shader' and g.newShader(files['fx/tint.glsl']) == 'shader'
  and g.newShader('fx/glow.frag') == 'shader' and count('newShader') == 0, 'declared shaders (by name or by their code) are not logged')
g.newShader('fx/other.glsl')
g.newShader('vec4 effect(vec4 c, Image t, vec2 tc, vec2 sc)\n{ return c * 2.0; }')
check(count('newShader: "fx/other.glsl" is not declared in game.lua') == 1 and count('newShader: shader code in a string') == 1,
  'an undeclared shader and inline shader code are logged')
g.newCanvas(); g.newCanvas(1280, 720)
check(count('newCanvas') == 0, 'a screen-size canvas is not logged')
g.newCanvas(320, 180)
check(count('newCanvas: a 320x180 canvas') == 1, 'a small canvas is logged')
g.rectangle('fill', 0, 0, 10, 10); g.rectangle('line', 0, 0, 10, 10, 4, 4)
check(count('rectangle: rounded corners') == 1, 'rounded rectangles are logged')
fake.event.push('quit'); fake.event.push('resize', 1, 2)
check(count('love.event.push: "resize" is dropped') == 1 and count('"quit"') == 1, 'love.event.push')
local ps = setmetatable({}, ParticleSystem)
ps:setSizes(1, 2, 3); ps:setEmissionArea('borderellipse', 4, 4)
check(count('ParticleSystem') == 0, 'ParticleSystem within the limits (every emission area is supported)')
ps:setSizes(1, 2, 3, 4, 5, 6, 7, 8, 9)
check(count('ParticleSystem:setSizes: more than 8 sizes') == 1, 'ParticleSystem:setSizes beyond the limit')
image:setFilter('nearest', 'nearest'); image:setFilter('linear', 'nearest')
check(count('Image:setFilter: min "linear" and mag "nearest"') == 1, 'Image:setFilter with two modes')

-- Callbacks
function fake.update() end
function fake.gamepadpressed() end
check(count('love.update') == 0 and count('love.gamepadpressed') == 0, 'callbacks the console calls are not logged')
function fake.keypressed() end
check(count('love.keypressed: the console never calls it') == 1 and type(rawget(fake, 'keypressed')) == 'function',
  'love.keypressed is logged when defined, and is defined')
check(count('love.run') == 0, 'LÖVE\'s default love.run is not logged')
fake.run = function() end

-- The file and the report
local lines = #printed
check(saved['compat_check.txt'] == table.concat(printed, '\n') .. '\n', 'every line went to the file too')
local r = compat.report()
check(count('love.run: the console never calls it') == 2, 'a replaced love.run is found by report() (line and its repeat)')
check(r.missing == 3 and r.stub == 2 and r.limit == 9 and r.callback == 2 and r.total == 16,
  string.format('report counts: %d missing, %d stub, %d limit, %d callback', r.missing, r.stub, r.limit, r.callback))
check(r.called == 18, 'distinct functions called: ' .. r.called)
check(#compat.lines() == r.total and #printed == lines + 1 + 1 + r.total, 'report() prints the totals and each line again')
check(count('[compat] report: 18 LÖVE functions called; 3 missing on the console, 2 stubs, 9 used beyond a limit, 2 callbacks never called') == 1,
  'the report line')

-- The committed list matches the code
local p = assert(io.popen('luajit tools/gen_api_subset.lua --check 2>&1'))
local out = p:read('*a'); p:close()
check(out:find('\nOK: ', 1, true) or out:sub(1, 4) == 'OK: ', 'tools/gen_api_subset.lua --check: ' .. out)

print('OK: ' .. checks .. ' checks; ' .. r.total .. ' compat lines from the fake game')
