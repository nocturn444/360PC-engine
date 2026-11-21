-- procgen.seeds, tools/seed_validator.lua and tests/console/level_hash_check.lua: the hash
-- list a PC run writes is what the console check reads, and a difference is reported.
local T = ...
local saved_path = package.path
package.path = "tests/fixtures/seed_spec/?.lua;" .. package.path
local procgen = require("engine.modules.procgen")
local rng = require("engine.rng")
local seeds = procgen.seeds
local spec = require("level_spec")

-- one seed: the same map as the game would make from the run's "level" stream
local hash, attempts = seeds.hash(spec, 360)
local map = assert(procgen.generate({ templates = spec.templates, rooms = spec.rooms, abilities = spec.abilities,
  rng = rng.streams(360):get("level") }))
T.check(hash == procgen.hash(map) and attempts == map.attempts, "seeds.hash is the hash of the run's level stream")
T.check(seeds.hash(spec, 360) == hash, "and the same again")
local plain = { templates = spec.templates, rooms = 16, abilities = spec.abilities, stream = false }
T.check(seeds.hash(plain, 1) == 4051614553, "stream = false: the seed itself (procgen_check's known answer)")

-- format and parse
local entries = {}
for s = 4294967290, 4294967295 do
  local h, a = seeds.hash(spec, s)
  entries[#entries + 1] = { s, h or false, a or 0 }
end
entries[#entries + 1] = { 7, false, 0 }
local text = seeds.format("level_spec", spec, entries)
local list = assert(seeds.parse(text))
T.check(list.spec == "level_spec" and #list.entries == 7, "the list names its spec and has every seed")
T.check(list.entries[1][1] == 4294967290 and list.entries[1][2] == entries[1][2] and list.entries[1][3] == entries[1][3],
  "32-bit seeds and hashes survive the text")
T.check(list.entries[7][2] == false, "a seed without a map is kept as a failure")
T.check(seeds.parse(text:gsub("\n", "\r\n")), "Windows line ends are read")
T.check(seeds.parse(nil) == nil and seeds.parse("hello") == nil and seeds.parse(text .. "1 x 2\n") == nil
  and seeds.parse(text:gsub("# spec=%S+", "# rooms")) == nil, "bad lists are refused")

-- check: the failure entry now generates, so it is one mismatch; a changed hash is another
local lines = {}
local function log(s) lines[#lines + 1] = s end
local bad, total = seeds.check(list, spec, log)
T.check(bad == 1 and total == 7 and lines[1]:find("[BAD] seed 7:", 1, true) and lines[2] == "== level hashes: 1 of 7 wrong ==",
  "a seed that differs is logged: " .. tostring(lines[1]))
list.entries[7] = nil
list.entries[2][2] = list.entries[2][2] + 1
list.entries[3][3] = list.entries[3][3] + 1
lines = {}
bad = seeds.check(list, spec, log)
T.check(bad == 2 and #lines == 3, "a different hash and a different number of attempts both count")

-- the validator, as a program
local dir = os.getenv("TMPDIR") or "/tmp"
local out = dir .. "/seed_validator_test_" .. os.time() .. ".txt"
local function run(cmd)
  local p = assert(io.popen(cmd .. " 2>&1; echo status=$?"))
  local s = p:read("*a"); p:close()
  return s, tonumber(s:match("status=(%d+)%s*$"))
end
local printed, status = run("luajit tools/seed_validator.lua tests/fixtures/seed_spec level_spec --count 40 --first 100 --out " .. out)
T.check(status == 0 and printed:find("seeds 100 to 139: 40 generated, 0 failed", 1, true), "the validator's summary: " .. printed)
T.check(printed:find("attempts: average", 1, true) and printed:find("list hash: %x%x%x%x%x%x%x%x"), "attempts and the list hash")
local f = assert(io.open(out, "rb")); local written = f:read("*a"); f:close()
local joff = run("luajit -joff tools/seed_validator.lua tests/fixtures/seed_spec level_spec --count 40 --first 100")
T.check(joff:match("list hash: (%x+)") == printed:match("list hash: (%x+)"), "the same hashes with and without the JIT")

-- the console check reads that file (called as a function, as the engine tests do)
local check = assert(loadfile("tests/console/level_hash_check.lua"))
lines = {}
T.check(check(log, written) == 0 and lines[1] == "== level hashes: 0 of 40 wrong ==", "the console check agrees with the PC list")
lines = {}
local changed = written:gsub("\n100 %d+ ", "\n100 12345 ")
T.check(check(log, changed) == 1 and lines[1]:find("[BAD] seed 100", 1, true) and lines[2] == "== level hashes: 1 of 40 wrong ==",
  "and logs a mismatch")
lines = {}
T.check(check(log, nil) == 1 and lines[2] == "== level hashes: 1 of 1 wrong ==", "a missing list is a failure, not a pass")
lines = {}
T.check(check(log, (written:gsub("spec=level_spec", "spec=no_such_spec"))) == 1, "so is a spec that is not in the game")
-- and as a program on PC
local pc = run("luajit -joff tests/console/level_hash_check.lua tests/fixtures/seed_spec " .. out)
T.check(pc:find("== level hashes: 0 of 40 wrong ==", 1, true), "run from the shell: " .. pc)
os.remove(out)

-- seeds that fail the game's rule are reported and make the exit status 1
printed, status = run("luajit tools/seed_validator.lua tests/fixtures/seed_spec strict_spec --count 30")
local fails = select(2, printed:gsub("%[FAIL%] seed %d+ %(%w+%): procgen: no map after 2 attempts", ""))
T.check(status == 1 and fails > 0 and printed:find(", " .. fails .. " failed", 1, true)
  and printed:find("check: odd number of doors", 1, true), "failures are listed with their reason: " .. fails)
printed, status = run("luajit tools/seed_validator.lua tests/fixtures/seed_spec")
T.check(status == 2 and printed:find("usage:", 1, true), "usage error")
printed, status = run("luajit tools/seed_validator.lua tests/fixtures/seed_spec nope")
T.check(status == 2 and printed:find("cannot load the spec module", 1, true), "a missing spec module")

package.path = saved_path
package.loaded.level_spec = nil
