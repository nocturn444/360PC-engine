-- engine.save: the serializer and its parser, the file format, migrations, the run and
-- progress helpers, with a fake love.filesystem (a table of files).
local T = ...
local F = require("fake_love")
F.install()
local globals = {}
for k in pairs(_G) do globals[k] = true end
local Save = require("engine.save")
local rng = require("engine.rng")

local function fake_fs()
  local fs = { files = {}, writes = 0 }
  function fs.read(name) return fs.files[name] end  -- nil when missing (LÖVE: nil, message)
  function fs.write(name, data)
    if fs.fail then return false, "disk full" end
    fs.files[name] = data
    fs.writes = fs.writes + 1
    return true
  end
  function fs.remove(name)
    if fs.files[name] == nil then return false end
    fs.files[name] = nil
    return true
  end
  return fs
end
local function new(fs, opts)
  opts = opts or {}
  opts.fs, opts.identity = fs, opts.identity or "test_game"
  local log = {}
  opts.log = function(s) log[#log + 1] = s end
  local s = Save.new(opts)
  return s, log
end
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b or (a ~= a and b ~= b) end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- the serializer: round trips -------------------------------------------------
local every_byte = {}
for i = 0, 255 do every_byte[#every_byte + 1] = string.char(i) end
every_byte = table.concat(every_byte)
local data = {
  1, 2, "three", { "nested", { deep = { deeper = true } } },
  int = 42, neg = -7, zero = 0, big = 2 ^ 53, bigger = 1e300, small = 5e-324,
  tenth = 0.1, third = 1 / 3, pi = math.pi, sum = 0.1 + 0.2, negf = -123.456e-7, u32 = 4294967295,
  inf = math.huge, ninf = -math.huge,
  yes = true, no = false,
  empty = {}, text = "", quote = 'say "hi" \\ back\\slash', lines = "a\nb\r\nc\td\0e",
  bytes = every_byte, utf8 = "ñandú ✓", code = "]] os.exit() --", ["key with spaces"] = 1,
  ["1"] = "string one", [0] = "zero", [-3] = "minus three", [2.5] = "two and a half", [10] = "ten",
  sparse = { 1, 2, nil, 4 },
}
local text = assert(Save.serialize(data))
local ok, back = Save.parse(text)
T.check(ok and same(data, back), "nested data survives a round trip")
T.check(back.tenth == 0.1 and back.third == 1 / 3 and back.pi == math.pi and back.sum == 0.1 + 0.2
  and back.small == 5e-324 and back.bigger == 1e300 and back.big == 2 ^ 53 and back.negf == -123.456e-7,
  "floats come back exactly")
T.check(back.inf == math.huge and back.ninf == -math.huge, "infinities")
T.check(back.bytes == every_byte and #back.lines == 10, "every byte value in a string")
T.check(back["1"] == "string one" and back[1] == 1 and back[0] == "zero" and back[2.5] == "two and a half",
  "number and string keys stay apart")
T.check(Save.serialize(back) == text, "serializing what was parsed gives the same text")
T.check(not text:find("[%z\1-\31]"), "no control bytes in the text")
for _, v in ipairs({ 0, -1, 1.5, true, false, "x", {} }) do
  local okv, bv = Save.parse(assert(Save.serialize(v)))
  T.check(okv and same(v, bv), "top-level " .. type(v))
end
local okn, bn = Save.parse(assert(Save.serialize(nil)))
T.check(okn and bn == nil, "a top-level nil")
local oknan, bnan = Save.parse(assert(Save.serialize(0 / 0)))
T.check(oknan and bnan ~= bnan, "nan")
local r = rng.new(99)
local exact = true
for _ = 1, 2000 do
  local v = (r:float() - 0.5) * 10 ^ r:int(-30, 30)
  local _, b = Save.parse(Save.serialize(v))
  if b ~= v then exact = false end
end
T.check(exact, "2000 random floats come back exactly")

-- deterministic: the same data built in another order gives the same text
local a, b = {}, {}
local names = { "x", "y", "hp", "name", "items", "seed", "alpha", "beta", "gamma", "delta" }
for i = 1, #names do a[names[i]] = i; a[i * 3] = names[i] end
for i = #names, 1, -1 do b[i * 3] = names[i]; b[names[i]] = i end
T.check(Save.serialize(a) == Save.serialize(b), "the text does not depend on the order of insertion")
T.check(Save.serialize({ b = 1, a = 2, [3] = 3, [1] = 1 }) == '1,[3]=3,["a"]=2,["b"]=1,}' or
  Save.serialize({ b = 1, a = 2, [3] = 3, [1] = 1 }) == '{1,[3]=3,["a"]=2,["b"]=1,}', "the array part, then numbers, then strings")

-- what cannot be saved
local function refuses(v, word)
  local out, err = Save.serialize(v)
  return out == nil and type(err) == "string" and err:find(word, 1, true) ~= nil
end
T.check(refuses({ f = function() end }, "function") and refuses({ f = function() end }, "root.f"), "functions are refused, with the place")
T.check(refuses({ list = { 1, coroutine.create(function() end) } }, "thread"), "threads are refused")
T.check(refuses({ u = io.stdout }, "userdata"), "userdata is refused")
T.check(refuses({ [true] = 1 }, "key of type boolean") and refuses({ [{}] = 1 }, "key of type table"), "odd keys are refused")
local cyc = { child = {} }
cyc.child.parent = cyc
T.check(refuses(cyc, "contains itself"), "cycles are refused")
local shared = { 1 }
local oks, bs = Save.parse(assert(Save.serialize({ a = shared, b = shared })))
T.check(oks and same(bs, { a = { 1 }, b = { 1 } }), "a table used twice (no cycle) is written twice")
local deep = {}
local cur = deep
for _ = 1, 150 do cur.t = {}; cur = cur.t end
T.check(refuses(deep, "too deep"), "too much nesting is refused")

-- the parser builds data and nothing else
local ran = false
rawset(_G, "save_test_hook", function() ran = true; return 1 end)
local bad = {
  "save_test_hook()", "{save_test_hook()}", '{["a"]=save_test_hook()}', "os.exit(1)", "return {}",
  "(function() end)()", "function() end", "{f=1}", "{a}", "1+1", '"a".."b"', "{1,2} 3", "{1 2}",
  "{[1]=}", "{[{}]=1}", "{[true]=1}", "{[nan]=1}", "{", "}", '"open', '"\\x41"', '"\\999"', '"\\',
  "0x10", "1e", "--[[ ]] 1", "[[long]]", "'single'", "truex", "nil nil", "", "  ", "-", "- 1", "{,}",
  "setmetatable({}, {})", "_G", "{[\"__index\"]=_G}",
}
local all_rejected = true
for _, src in ipairs(bad) do
  local okb, errb = Save.parse(src)
  if okb or type(errb) ~= "string" then all_rejected = false; print("accepted: " .. src) end
end
rawset(_G, "save_test_hook", nil)
T.check(all_rejected and not ran, "code-like and malformed payloads are rejected, and nothing runs")
T.check(not Save.parse(string.rep("{", 5000)) and not Save.parse(string.rep("{", 150) .. string.rep("}", 150)),
  "deep nesting does not overflow the stack")
T.check(not Save.parse(nil) and not Save.parse(12), "parse of something that is not a string")
local okw, bw = Save.parse(' { 1 , [ "a" ] = { } ,\n\t2 } ')
T.check(okw and same(bw, { 1, 2, a = {} }), "spaces between tokens are accepted")
local src = io.open("engine/save.lua"):read("*a")
T.check(not src:gsub("%-%-[^\n]*", ""):find("loadstring") and not src:gsub("%-%-[^\n]*", ""):find("[^%w_]load%s*%(")
  and not src:find("loadfile") and not src:find("dofile"), "engine/save.lua has no load, loadstring, loadfile or dofile")

-- the file format ---------------------------------------------------------------
local packed = Save.pack("test_game", "run", 3, '{1,}')
T.check(packed == string.format("360PCSAVE 1 test_game run 3 %08x 4\n{1,}", rng.hash("{1,}")), "the header line: " .. packed:match("^[^\n]*"))
local h = Save.unpack(packed)
T.check(h and h.format == 1 and h.identity == "test_game" and h.kind == "run" and h.version == 3 and h.payload == "{1,}", "unpack")
T.check(not Save.unpack(packed:sub(1, -2)) and not Save.unpack(packed .. " ") and not Save.unpack(packed:gsub("1,}", "2,}"))
  and not Save.unpack("") and not Save.unpack("hello\n{}") and not Save.unpack(nil), "cut, grown, edited or foreign files do not unpack")

-- the run ------------------------------------------------------------------------
local fs = fake_fs()
local s, log = new(fs)
T.check(s:has_run() == false and select(2, s:load_run()) == "none" and #log == 0, "no run at first, and that is not an error")
local streams = rng.streams(2024)
streams:get("level"):next_u32(); streams:get("loot"):int(1, 6)
local run = { rng = streams:state(), floor = 3, player = { hp = 7.5, x = 12.25, items = { "sword", "key" } } }
T.check(s:save_run(run) == true and s:has_run(), "save_run")
T.check(fs.files["run.sav"]:match("^360PCSAVE 1 test_game run 1 %x+ %d+\n") and fs.files["progress.sav"] == nil, "the run has its own file")
local s2 = new(fs)
T.check(s2:has_run(), "another session sees the run")
local loaded, why = s2:load_run()
T.check(why == nil and same(loaded, run), "load_run gives the state back")
local again = rng.streams(1):set_state(loaded.rng)
T.check(again:get("level"):next_u32() == streams:get("level"):next_u32()
  and again:get("loot"):int(1, 6) == streams:get("loot"):int(1, 6), "the random streams continue where they were")
local first = fs.files["run.sav"]
T.check(s:save_run(run) and fs.files["run.sav"] == first, "the same state gives the same file, byte for byte")
run.floor = 4
T.check(s:save_run(run) and fs.files["run.sav.bak"] == first and fs.files["run.sav"] ~= first, "the previous save is kept as .bak")
T.check(s:clear_run() and not s:has_run() and fs.files["run.sav"] == nil and fs.files["run.sav.bak"] == nil
  and select(2, s:load_run()) == "none", "clear_run")
T.check(s:clear_run() == true, "clear_run with nothing to clear")

-- what cannot be saved is reported, and the file stays as it was
T.check(s:save_run({ floor = 1 }), "a run to keep")
local kept = fs.files["run.sav"]
local okf, errf = s:save_run({ cb = function() end })
T.check(okf == nil and errf:find("function") and fs.files["run.sav"] == kept and log[#log]:find("not saved"), "a state with a function: reported, nothing written")
fs.fail = true
local okd, errd = s:save_run({ floor = 2 })
T.check(okd == nil and errd == "disk full" and s.last_error:find("disk full"), "a failed write is reported")
fs.fail = false
local raising = { read = function() error("boom") end, write = function() error("boom") end, remove = function() error("boom") end }
local sr = new(raising)
T.check(sr:save_run({}) == nil and sr:load_run() == nil and not sr:has_run() and sr:clear_run() == true
  and type(sr:load_progress()) == "table" and sr:unlock("x") == true, "a filesystem that raises does not crash the game")

-- corrupt files ----------------------------------------------------------------
fs = fake_fs()
s, log = new(fs)
s:save_run({ floor = 1 }); s:save_run({ floor = 2 })
local good = fs.files["run.sav"]
local broken = good:gsub("2,}$", "9,}")
T.check(broken ~= good, "the test edited the payload")
fs.files["run.sav"] = broken
local st, note = s:load_run()
T.check(st and st.floor == 1 and note == "backup", "checksum mismatch: the previous save (.bak) is used")
T.check(fs.files["run.sav.corrupt"] == broken and fs.files["run.sav"] == fs.files["run.sav.bak"], "the corrupt file is kept as .corrupt and the .bak restored")
T.check(log[1]:find("corrupt") and log[1]:find("checksum"), "and it is reported: " .. log[1])
fs.files["run.sav"] = good:sub(1, #good - 3)
fs.files["run.sav.bak"] = "garbage"
st, note = s:load_run()
T.check(st == nil and note == "corrupt" and fs.files["run.sav"] == nil and fs.files["run.sav.corrupt"] == good:sub(1, #good - 3)
  and not s:has_run(), "a cut file and no good .bak: no run")
T.check(s:save_run({ floor = 5 }) and s:load_run().floor == 5, "and saving works again")
-- a valid header and checksum around a payload that is code
fs.files["run.sav"] = Save.pack("test_game", "run", 1, "os.exit(1)")
fs.files["run.sav.bak"] = nil
st, note = s:load_run()
T.check(st == nil and note == "corrupt", "a well-formed file whose payload is code is corrupt")
-- another game's file, or the other kind
fs.files["run.sav"] = Save.pack("other_game", "run", 1, "{}")
T.check(select(2, s:load_run()) == "corrupt", "another game's save is not loaded")
fs.files["run.sav"] = Save.pack("test_game", "progress", 1, "{}")
T.check(select(2, s:load_run()) == "corrupt", "a progress file is not a run")
-- without backups (the console: the runtime's slots do that job)
fs = fake_fs()
s = new(fs, { backup = false })
s:save_run({ 1 }); s:save_run({ 2 })
T.check(fs.files["run.sav.bak"] == nil and fs.writes == 2, "backup = false: one write per save")
F.os = "Xbox 360"
T.check(Save.new({ fs = fs, identity = "g" }).backup == false, "no .bak on the console by default")
F.os = "Linux"
T.check(Save.new({ fs = fs, identity = "g" }).backup == true, "and .bak on PC")
-- a filesystem with rename (not LÖVE 11): temp file, then rename
fs = fake_fs()
fs.rename = function(from, to) fs.files[to], fs.files[from] = fs.files[from], nil; return true end
s = new(fs)
T.check(s:save_run({ 1 }) and s:save_run({ 2 }) and fs.files["run.sav.tmp"] == nil and fs.files["run.sav.bak"] == nil
  and s:load_run()[1] == 2, "with rename: written to .tmp and renamed")

-- migrations --------------------------------------------------------------------
fs = fake_fs()
local v1 = new(fs)
v1:save_run({ hp = 5 })
local v1_file = fs.files["run.sav"]
local order = {}
local migrate = {
  [1] = function(d) order[#order + 1] = 1; d.health, d.hp = d.hp, nil; return d end,
  [2] = function(d) order[#order + 1] = 2; return { player = { health = d.health }, floor = 1 } end,
}
local v3 = new(fs, { run = { version = 3, migrate = migrate } })
st, note = v3:load_run()
T.check(note == nil and same(st, { player = { health = 5 }, floor = 1 }) and table.concat(order, ",") == "1,2", "version 1 to 3: both migrations, in order")
T.check(fs.files["run.sav"] == v1_file, "loading does not rewrite the file")
T.check(v3:save_run(st) and fs.files["run.sav"]:match("^360PCSAVE 1 test_game run 3 "), "the next save is version 3")
order = {}
T.check(same(v3:load_run(), st) and #order == 0, "a current file runs no migration")
-- newer than this game knows
local old, old_log = new(fs)
st, note = old:load_run()
T.check(st == nil and note == "newer" and not old:has_run() and old_log[1]:find("newer version of the game"), "a newer version is refused: " .. tostring(old_log[1]))
local v3_file = fs.files["run.sav"]
T.check(old:save_run({ hp = 1 }) == nil and select(2, old:save_run({ hp = 1 })) == "newer" and old:clear_run() == false
  and fs.files["run.sav"] == v3_file and fs.files["run.sav.corrupt"] == nil, "and it is neither overwritten, cleared nor called corrupt")
T.check(new(fs):save_run({ hp = 1 }) == nil and fs.files["run.sav"] == v3_file, "nor by a session that saves without loading first")
fs.files["run.sav"] = "360PCSAVE 2 test_game run 1 00000000 0 some-new-field\nwhatever"
local future = fs.files["run.sav"]
local fut = new(fs)
T.check(select(2, fut:load_run()) == "newer" and fut:save_run({}) == nil and fs.files["run.sav"] == future,
  "a newer engine save format is refused, whatever its header holds, and kept")
fs.files["run.sav"] = "360PCSAVE 1 test_game run 1 00000000 0 extra\n"
fs.files["run.sav.bak"] = nil
T.check(select(2, new(fs):load_run()) == "corrupt", "a header of this format with something else in it is corrupt")
-- a missing or failing migration
fs.files["run.sav"] = v1_file
local gap, gap_log = new(fs, { run = { version = 3, migrate = { [2] = migrate[2] } } })
T.check(select(2, gap:load_run()) == "migration" and gap_log[1]:find("no migration from version 1") and fs.files["run.sav"] == v1_file, "a missing migration: refused, file kept")
local boom = new(fs, { run = { version = 2, migrate = { [1] = function() error("boom") end } } })
T.check(select(2, boom:load_run()) == "migration" and fs.files["run.sav"] == v1_file, "a migration that raises: refused, file kept")
T.check(not pcall(Save.new, { fs = fs, identity = "g", run = { version = 2, migrate = { [2] = function() end } } })
  and not pcall(Save.new, { fs = fs, identity = "g", run = { version = 1.5 } })
  and not pcall(Save.new, { fs = fs, identity = "bad identity" })
  and not pcall(Save.new, { fs = fs, identity = "g", run = { file = "s" }, progress = { file = "s" } }), "a wrong config is an error at Save.new")

-- progress and unlocks ------------------------------------------------------------
fs = fake_fs()
local defaults = { stats = { runs = 0, best = 0 }, settings = { volume = 0.8, fullscreen = false } }
s, log = new(fs, { progress = { defaults = defaults } })
local p, pwhy = s:load_progress()
T.check(pwhy == "none" and same(p, { stats = { runs = 0, best = 0 }, settings = { volume = 0.8, fullscreen = false }, unlocks = {} })
  and #log == 0, "no file: the defaults")
p.stats.runs = 3
T.check(defaults.stats.runs == 0, "the defaults are copied, not shared")
T.check(not s:is_unlocked("hard_mode") and s:unlock("hard_mode") == true and s:is_unlocked("hard_mode")
  and s:unlock("hard_mode") == false, "unlock and is_unlocked")
T.check(fs.files["progress.sav"]:match("^360PCSAVE 1 test_game progress 1 ") and fs.files["run.sav"] == nil, "unlock saves the progress, in its own file")
p.settings.volume = 0.25
T.check(s:save_progress() == true, "save_progress")
-- a later version of the game adds a setting: it gets its default without a migration
defaults.settings.music = true
defaults.stats.deaths = 0
local s3 = new(fs, { progress = { defaults = defaults } })
local p3, why3 = s3:load_progress()
T.check(why3 == nil and p3.stats.runs == 3 and p3.settings.volume == 0.25 and p3.settings.fullscreen == false
  and p3.settings.music == true and p3.stats.deaths == 0 and s3.progress == p3, "saved values win, new fields take their defaults")
T.check(s3:is_unlocked("hard_mode") and not s3:is_unlocked("other"), "unlocks persist")
T.check(new(fs):is_unlocked("hard_mode"), "is_unlocked loads the progress by itself")
-- corrupt progress: the defaults, and the copy
local pfile = fs.files["progress.sav"]
fs.files["progress.sav"] = pfile:sub(1, 40)
fs.files["progress.sav.bak"] = nil
local s4, log4 = new(fs, { progress = { defaults = defaults } })
local p4, why4 = s4:load_progress()
T.check(why4 == "corrupt" and p4.stats.runs == 0 and not s4:is_unlocked("hard_mode") and fs.files["progress.sav.corrupt"] == pfile:sub(1, 40)
  and #log4 == 1, "corrupt progress: defaults, a .corrupt copy, one report")
T.check(s4:save_progress() and select(2, new(fs):load_progress()) == nil, "and it can be saved again")
-- progress migrations and a newer file
fs.files["progress.sav"] = Save.pack("test_game", "progress", 1, '{["wins"]=2,}')
local s5 = new(fs, { progress = { version = 2, defaults = defaults,
  migrate = { [1] = function(d) return { stats = { best = d.wins } } end } } })
local p5 = s5:load_progress()
T.check(p5.stats.best == 2 and p5.stats.runs == 0, "progress migrates too, then the defaults fill it")
s5:save_progress()
local s6 = new(fs, { progress = { defaults = defaults } })
local p6, why6 = s6:load_progress()
T.check(why6 == "newer" and p6.stats.best == 0 and s6:save_progress() == nil and s6:unlock("x") == true
  and fs.files["progress.sav"]:match(" progress 2 "), "newer progress: defaults in memory, the file is left alone")
fs.files["progress.sav"] = Save.pack("test_game", "progress", 1, '"not a table"')
T.check(select(2, new(fs):load_progress()) == "corrupt", "progress that is not a table")
T.check(new(fake_fs()):save_progress({ a = 1 }) == true and new(fake_fs()):save_progress(5) == nil
  and new(fake_fs()):save_progress() == nil, "save_progress takes a table, or what load_progress gave")

T.no_new_globals(globals)
