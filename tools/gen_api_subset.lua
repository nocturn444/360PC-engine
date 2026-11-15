-- Generates the list of LÖVE 11 functions the console implements, from the code:
--   tools/api_subset_data.lua   the list as Lua data (read by tools/compat_check.lua)
--   docs/API_SUBSET.md          the same list for people
-- It runs the console boot (runtime/lua/boot.lua) against the graphics stub with an empty game,
-- like tests/pc/boot_pc.lua, and enumerates the love table and the Lua object types it makes.
-- The methods of the C object types (Image, Quad, Font...) and of l360.gfx are read from the
-- luaL_Reg tables of runtime/l360_gfx.c; the callbacks, from the calls in boot.lua and input.lua.
-- What the code cannot tell (the limit of a partial function, what is a stub, what is missing)
-- is in tools/api_subset_notes.lua and is merged in; a note about a name that does not exist
-- stops the run.
-- Usage, from the repository root:
--   luajit tools/gen_api_subset.lua           writes both files
--   luajit tools/gen_api_subset.lua --check   writes nothing; fails if the files are out of date
local CHECK = arg[1] == '--check'
local DATA_PATH, DOC_PATH = 'tools/api_subset_data.lua', 'docs/API_SUBSET.md'
local raw_print = print

local function read_file(path)
  local f = io.open(path, 'rb'); if not f then return nil end
  local d = f:read('*a'); f:close(); return d
end
local function fail(msg) raw_print('gen_api_subset: ' .. msg); os.exit(1) end

---------------------------------------------------------------------------
-- 1. The C side: gfx_funcs and the method tables of runtime/l360_gfx.c
---------------------------------------------------------------------------
local c_src = assert(read_file('runtime/l360_gfx.c'), 'run from the repository root')
-- name of the luaL_Reg table -> { method = C function name }
local function c_table(name)
  local body = c_src:match('static const luaL_Reg ' .. name .. '%[%] = (%b{});')
  if not body then fail('no luaL_Reg ' .. name .. ' in runtime/l360_gfx.c') end
  local out, n = {}, 0
  for method, func in body:gmatch('{%s*"([%w_]+)"%s*,%s*([%w_]+)%s*}') do out[method] = func; n = n + 1 end
  if n == 0 then fail('luaL_Reg ' .. name .. ' is empty') end
  return out
end
-- LÖVE type -> luaL_Reg table. Image and Canvas share one metatable on the console.
local C_TYPES = { Image = 'tex_m', Canvas = 'tex_m', Quad = 'quad_m', Shader = 'shader_m', Font = 'font_m',
  Text = 'text_m', SpriteBatch = 'batch_m', ParticleSystem = 'ps_m' }
for _, reg in pairs(C_TYPES) do
  if not c_src:find('make_mt%(L, MT_%u+, ' .. reg .. '%)') then fail(reg .. ' is not registered with make_mt') end
end
local c_gfx = c_table('gfx_funcs')

---------------------------------------------------------------------------
-- 2. The Lua side: boot.lua against the stub, with an empty game, for one frame
---------------------------------------------------------------------------
local DONE = {}
local love_table, lua_types = nil, {}
local function upvalue(fn, name)
  for i = 1, 60 do
    local k, v = debug.getupvalue(fn, i)
    if k == nil then break end
    if k == name then return v end
  end
  fail('no upvalue ' .. name .. ' (boot.lua changed: update tools/gen_api_subset.lua)')
end
local function methods_of(t)
  local out = {}
  for k, v in pairs(t) do
    if type(k) == 'string' and type(v) == 'function' and k:sub(1, 2) ~= '__' then out[k] = v end
  end
  return out
end
local function enumerate()
  love_table = love
  local joy = love.joystick.getJoysticks()[1]
  lua_types.Joystick = methods_of(getmetatable(joy))
  local src = love.audio.newSource('none.wav', 'static')
  lua_types.Source = methods_of(upvalue(getmetatable(src).__index, 'SourceMethods'))
  local sound_mt = upvalue(love.sound.newSoundData, 'SoundMT')
  lua_types.SoundData = methods_of(upvalue(sound_mt.__index, 'SoundMethods'))
  lua_types.Channel = methods_of(love.thread.newChannel())
  lua_types.Thread = methods_of(love.thread.newThread('local a = 1\nreturn a'))
end

local files = { ['main.lua'] = '', }
l360 = {
  time = function() return 0 end,
  log = function() end,
  read = function(path)
    local own = path:match('^l360/(.*)$')
    if own then return read_file('runtime/lua/' .. own) end
    return files[path]
  end,
  poll_input = function() end,
  pad = function(port)
    if port ~= 0 then return nil end
    return { s1_x = 0, s1_y = 0, s2_x = 0, s2_y = 0, s1_z = 0, s2_z = 0, lb = 0, rb = 0, start = 0, back = 0,
      a = 0, b = 0, x = 0, y = 0, up = 0, down = 0, left = 0, right = 0, lt = 0, rt = 0, logo = 0 }
  end,
  rumble = function() return true end,
  wait_frame = function() enumerate(); error(DONE, 0) end,
  set_context = function() end, start_render = function() end,
  platform = 'xbox360-luajit', width = 1280, height = 720, runtime_dir = 'l360/',
}
assert(loadstring(assert(read_file('runtime/lua/l360_gfx_stub.lua')), '@l360_gfx_stub.lua'))()
local stub_gfx = {}
for k in pairs(l360.gfx) do stub_gfx[k] = true end
do
  local ok, err = pcall(assert(loadstring(assert(read_file('runtime/lua/boot.lua')), '@boot.lua')))
  if ok or err ~= DONE then fail('boot.lua did not reach the frame loop: ' .. tostring(err)) end
end
print = raw_print
for name in pairs(c_gfx) do
  if not stub_gfx[name] then fail('l360.gfx.' .. name .. ' is in l360_gfx.c and not in l360_gfx_stub.lua') end
end
for name in pairs(stub_gfx) do
  if not c_gfx[name] then fail('l360.gfx.' .. name .. ' is in l360_gfx_stub.lua and not in l360_gfx.c') end
end

-- The callbacks the console fires: callback("x") and rawget(love, "x") in boot.lua, emit('x') in input.lua
local fired = {}
do
  local boot = assert(read_file('runtime/lua/boot.lua'))
  for name in boot:gmatch('callback%("(%l+)"%)') do fired[name] = true end
  for name in boot:gmatch('rawget%(love, "(%l+)"%)') do fired[name] = true end
  local input = assert(read_file('runtime/lua/input.lua'))
  for args in input:gmatch("emit(%b())") do
    for name in args:match("^[^,]*"):gmatch("'(%l+)'") do fired[name] = true end
  end
  if not (fired.load and fired.update and fired.draw and fired.gamepadpressed and fired.gamepadreleased) then
    fail('the callbacks were not found in boot.lua and input.lua')
  end
end

---------------------------------------------------------------------------
-- 3. Merge with the notes
---------------------------------------------------------------------------
local notes = assert(loadfile('tools/api_subset_notes.lua'))()
local STATUS = { full = true, partial = true, stub = true }
local boot_nop = rawget(love_table.event, 'pump')   -- boot.lua's nop: what it gives to its stubs

-- entries: name -> { status, note }. found: name -> true if the function does nothing (nop).
local function merge(where, found, noted)
  noted = noted or {}
  local default = noted._default
  local out = {}
  for name, is_nop in pairs(found) do
    local n = noted[name] or default
    local status, note = is_nop and 'stub' or 'full', nil
    if n then status, note = n[1], n[2] end
    if not STATUS[status] then fail(where .. name .. ': bad status ' .. tostring(status)) end
    if status ~= 'full' and not note and not is_nop then fail(where .. name .. ': ' .. status .. ' needs a note') end
    if status == 'stub' and not note then note = 'Accepted, does nothing.' end
    out[name] = { status, note }
  end
  for name in pairs(noted) do
    if name:sub(1, 1) ~= '_' and found[name] == nil then
      fail('tools/api_subset_notes.lua: ' .. where .. name .. ' is not implemented (stale note?)')
    end
  end
  return out
end

local modules, module_notes = {}, {}
do
  local top = {}
  for k, v in pairs(love_table) do
    if type(v) == 'function' then top[k] = false end
  end
  modules['love'] = merge('love.', top, notes.modules['love'])
  for k, v in pairs(love_table) do
    local name = 'love.' .. k
    if type(v) == 'table' and not notes.internal[name] then
      local found = {}
      for f, fn in pairs(v) do
        if type(fn) == 'function' and not notes.internal[name .. '.' .. f] then
          found[f] = fn == boot_nop or (name == 'love.graphics' and c_gfx[f] == 'nop' and fn == l360.gfx[f])
        end
      end
      modules[name] = merge(name .. '.', found, notes.modules[name])
    end
  end
  for name, n in pairs(notes.modules) do
    if not modules[name] then fail('tools/api_subset_notes.lua: module ' .. name .. ' does not exist') end
    module_notes[name] = n._note
  end
end

local types, type_notes = {}, {}
for name, reg in pairs(C_TYPES) do
  local found = { release = false }   -- make_mt gives every C type a release that does nothing: right, nothing is freed
  for method, func in pairs(c_table(reg)) do found[method] = func == 'nop' end
  types[name] = merge(name .. ':', found, notes.types[name])
end
for name, methods in pairs(lua_types) do
  local found = {}
  for method, fn in pairs(methods) do found[method] = fn == boot_nop end
  types[name] = merge(name .. ':', found, notes.types[name])
end
for name, n in pairs(notes.types) do
  if not types[name] then fail('tools/api_subset_notes.lua: type ' .. name .. ' does not exist') end
  type_notes[name] = n._note
end

local callbacks = {}
do
  local known = {}
  for _, name in ipairs(notes.callbacks.all) do
    known[name] = true
    if fired[name] then
      callbacks[name] = { 'full', notes.callbacks.notes[name] }
    else
      callbacks[name] = { 'never', notes.callbacks.notes[name] or 'Never called.' }
    end
  end
  for name in pairs(fired) do
    if not known[name] then fail('callback ' .. name .. ' is fired and is not in notes.callbacks.all') end
  end
  for name in pairs(notes.callbacks.notes) do
    if not known[name] then fail('tools/api_subset_notes.lua: callback ' .. name .. ' is not in callbacks.all') end
  end
end

-- What games commonly use and is not there: every name must really be absent
for owner, list in pairs(notes.missing) do
  local have = modules[owner] or types[owner]
  for _, entry in ipairs(list) do
    if have and have[entry[1]] then
      fail('tools/api_subset_notes.lua: missing.' .. owner .. ' lists ' .. entry[1] .. ', which is implemented')
    end
  end
end
for name in pairs(notes.absent_modules) do
  if modules[name] then fail('tools/api_subset_notes.lua: ' .. name .. ' is listed as absent and exists') end
end

-- The argument checks of tools/compat_check.lua must be about functions that exist
do
  package.path = 'tools/?.lua;' .. package.path
  -- compat_check reads the data file this run is about to write: give it an empty one
  package.loaded['api_subset_data'] = { modules = { love = {} }, types = {}, callbacks = {}, absent_modules = {} }
  local compat = require('compat_check')
  for key in pairs(compat.checks) do
    local owner, sep, name = key:match('^(.-)([.:])([%w_]+)$')
    local have = sep == '.' and modules[owner] or types[owner]
    if not (have and have[name]) then fail('tools/compat_check.lua: check for ' .. key .. ', which is not implemented') end
    if have[name][1] ~= 'partial' then fail('tools/compat_check.lua: check for ' .. key .. ', which is not partial') end
  end
end

---------------------------------------------------------------------------
-- 4. Output
---------------------------------------------------------------------------
local function sorted(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end
local MODULE_ORDER = { 'love', 'love.graphics', 'love.filesystem', 'love.timer', 'love.audio', 'love.sound',
  'love.joystick', 'love.keyboard', 'love.mouse', 'love.touch', 'love.event', 'love.math', 'love.system',
  'love.window', 'love.data', 'love.thread' }
local MODULE_TYPES = { ['love.graphics'] = { 'Image', 'Canvas', 'Quad', 'Font', 'Text', 'Shader', 'SpriteBatch',
  'ParticleSystem' }, ['love.audio'] = { 'Source' }, ['love.sound'] = { 'SoundData' },
  ['love.joystick'] = { 'Joystick' }, ['love.thread'] = { 'Thread', 'Channel' } }
do
  local listed = {}
  for _, m in ipairs(MODULE_ORDER) do listed[m] = true end
  for m in pairs(modules) do if not listed[m] then MODULE_ORDER[#MODULE_ORDER + 1] = m end end
  local typed = {}
  for _, list in pairs(MODULE_TYPES) do for _, ty in ipairs(list) do typed[ty] = true end end
  for ty in pairs(types) do if not typed[ty] then fail('type ' .. ty .. ' has no module in MODULE_TYPES') end end
end

-- 4a. tools/api_subset_data.lua
local function q(s) return string.format('%q', s):gsub('\\\n', '\\n') end
local function data_entries(out, indent, entries)
  for _, name in ipairs(sorted(entries)) do
    local e = entries[name]
    local key = name:match('^[%a_][%w_]*$') and name or '[' .. q(name) .. ']'
    out[#out + 1] = indent .. key .. ' = ' .. (e[2] and '{ ' .. q(e[1]) .. ', ' .. q(e[2]) .. ' }' or q(e[1])) .. ','
  end
end
local d = {
  '-- GENERATED by tools/gen_api_subset.lua from runtime/ and tools/api_subset_notes.lua. Do not edit.',
  '-- The LÖVE 11 functions, methods and callbacks the console implements. Each entry is a status',
  '-- ("full", "partial", "stub"; for callbacks "full" or "never") or { status, note }.',
  '-- A name that is not here does not exist on the console. See docs/API_SUBSET.md.',
  'return {',
  '  modules = {',
}
for _, m in ipairs(MODULE_ORDER) do
  d[#d + 1] = '    [' .. q(m) .. '] = {'
  data_entries(d, '      ', modules[m])
  d[#d + 1] = '    },'
end
d[#d + 1] = '  },'
d[#d + 1] = '  absent_modules = {'
for _, m in ipairs(sorted(notes.absent_modules)) do
  d[#d + 1] = '    [' .. q(m) .. '] = ' .. q(notes.absent_modules[m]) .. ','
end
d[#d + 1] = '  },'
d[#d + 1] = '  types = {'
for _, ty in ipairs(sorted(types)) do
  d[#d + 1] = '    ' .. ty .. ' = {'
  data_entries(d, '      ', types[ty])
  d[#d + 1] = '    },'
end
d[#d + 1] = '  },'
d[#d + 1] = '  callbacks = {'
data_entries(d, '    ', callbacks)
d[#d + 1] = '  },'
d[#d + 1] = '}'
local data_text = table.concat(d, '\n') .. '\n'

-- 4b. docs/API_SUBSET.md
local md = {}
local function line(s) md[#md + 1] = s or '' end
local function md_table(prefix, entries, first)
  line('| ' .. first .. ' | Status | Limit |')
  line('|---|---|---|')
  for _, name in ipairs(sorted(entries)) do
    local e = entries[name]
    line('| `' .. prefix .. name .. '` | ' .. e[1] .. ' | ' .. (e[2] or '') .. ' |')
  end
  line()
end
local function md_missing(owner)
  local list = notes.missing[owner]
  if not list then return end
  local parts = {}
  for _, entry in ipairs(list) do
    parts[#parts + 1] = '`' .. entry[1] .. '`' .. (entry[2] and ' (' .. entry[2] .. ')' or '')
  end
  line('Commonly used and **missing**: ' .. table.concat(parts, ', ') .. '.')
  line()
end
local counts = { full = 0, partial = 0, stub = 0 }
for _, group in ipairs({ modules, types }) do
  for _, entries in pairs(group) do
    for _, e in pairs(entries) do counts[e[1]] = counts[e[1]] + 1 end
  end
end

line('# The LÖVE 11 subset on the console')
line()
line('<!-- GENERATED by tools/gen_api_subset.lua from runtime/ and tools/api_subset_notes.lua. Do not edit:')
line('     change the code or the notes and run `luajit tools/gen_api_subset.lua`. -->')
line()
line('Every LÖVE 11 function, method and callback the console runtime implements, taken from the')
line('code (`runtime/lua/boot.lua`, `runtime/lua/input.lua`, `runtime/l360_gfx.c`). **Anything not')
line('listed here does not exist on the console**: calling it there logs `[missing] <name>` once and')
line('does nothing (it returns nil).')
line()
line('- **full**: behaves as in LÖVE 11 for a 2D game.')
line('- **partial**: works within the limit given.')
line('- **stub**: can be called, does nothing useful (it may return a fixed value).')
line()
line(string.format('Now: %d full, %d partial, %d stub.', counts.full, counts.partial, counts.stub))
line()
line('## Checking a game on PC: tools/compat_check.lua')
line()
line('Copy `tools/compat_check.lua` and `tools/api_subset_data.lua` into the game folder and require')
line('the first one at the top of `main.lua`, before anything else:')
line()
line('```lua')
line('local compat = require("compat_check")   -- prints to the console window')
line('-- compat.install({ file = "compat_check.txt" })   -- optional: also append to that file in the save folder')
line('```')
line()
line('Play the game on official LÖVE 11.x. It runs exactly as before; each time it calls something')
line('the console does not have, a line is printed, once per name:')
line()
line('```')
line('[compat] love.graphics.arc: not on the console (missing)')
line('[compat] love.graphics.setBlendMode: "multiply" is drawn as "alpha" on the console (only "alpha" and "add")')
line('[compat] love.keypressed: the console never calls it (There is no keyboard...)')
line('```')
line()
line('- **missing**: the function, method or module is not in this list.')
line('- **stub**: it is here as a stub.')
line('- **limit**: a partial function called in a way the console does not support, where that is')
line('  cheap to see from the arguments (the *Checked* notes below say which). Other limits are not')
line('  checked: read the table.')
line('- **callback**: the game defines a callback the console never calls.')
line()
line('`compat.report()` prints the totals and every line again (call it from `love.quit`, for')
line('example) and returns the counts. The module only wraps functions (the calls, arguments,')
line('results and errors pass through unchanged), does nothing if it is not required, and does')
line('nothing on the console, so the `require` can stay in. If it is required from `conf.lua`, where')
line('most modules are not loaded yet, call `compat.install()` again at the top of `main.lua`.')
line('Only what the game actually calls while it is played is seen.')
line()
line('## Regenerating this file')
line()
line('```')
line('luajit tools/gen_api_subset.lua           # writes docs/API_SUBSET.md and tools/api_subset_data.lua')
line('luajit tools/gen_api_subset.lua --check   # fails if they are out of date')
line('```')
line()
line('The names come from the code; the limits, and what counts as a stub or as missing, are written')
line('by hand in `tools/api_subset_notes.lua`. A function added to the runtime shows up as **full**')
line('until it has a note there.')
line()
line('## Callbacks')
line()
do
  local yes, no = {}, {}
  for _, name in ipairs(sorted(callbacks)) do
    local e = callbacks[name]
    if e[1] == 'full' then yes[name] = { 'full', e[2] } else no[name] = { 'never', e[2] } end
  end
  line('Called by the console:')
  line()
  md_table('love.', yes, 'Callback')
  line('Never called (defining them is harmless, but nothing must depend on them):')
  line()
  md_table('love.', no, 'Callback')
end
for _, m in ipairs(MODULE_ORDER) do
  line('## ' .. m)
  line()
  if module_notes[m] then line(module_notes[m]); line() end
  md_table(m .. '.', modules[m], 'Function')
  md_missing(m)
  for _, ty in ipairs(MODULE_TYPES[m] or {}) do
    line('### ' .. ty)
    line()
    if type_notes[ty] then line(type_notes[ty]); line() end
    md_table(ty .. ':', types[ty], 'Method')
    md_missing(ty)
  end
end
line('## Modules that do not exist')
line()
line('| Module | |')
line('|---|---|')
for _, m in ipairs(sorted(notes.absent_modules)) do line('| `' .. m .. '` | ' .. notes.absent_modules[m] .. ' |') end
local doc_text = table.concat(md, '\n') .. '\n'

local stale = false
for _, out in ipairs({ { DATA_PATH, data_text }, { DOC_PATH, doc_text } }) do
  if CHECK then
    if read_file(out[1]) ~= out[2] then raw_print(out[1] .. ' is out of date'); stale = true end
  else
    local f = assert(io.open(out[1], 'wb')); f:write(out[2]); f:close()
    raw_print('wrote ' .. out[1])
  end
end
if stale then fail('run luajit tools/gen_api_subset.lua') end
raw_print(string.format('OK: %d full, %d partial, %d stub; %d callbacks called, %d types',
  counts.full, counts.partial, counts.stub, #sorted(fired), #sorted(types)))
