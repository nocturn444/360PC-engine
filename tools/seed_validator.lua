-- Bulk seed validator (PC): generates N seeds with engine.modules.procgen from a spec the game
-- provides and reports failures, attempts statistics and layout hashes. With --out it writes
-- the hash list that tests/console/level_hash_check.lua compares on the console.
-- Usage, from the base's root (or anywhere: paths are resolved from this file):
--   luajit tools/seed_validator.lua <game folder> <spec module> [options]
--     --count N      seeds to generate (default 1000)
--     --first S      the first seed, a whole number (default 1); seeds are S, S+1, ...
--     --out FILE     write the hash list (level_hashes.txt format) there
--     --verbose      one line per seed
--   <spec module> is a Lua module name inside the game folder (e.g. "level_spec" for
--   level_spec.lua) returning { templates, abilities, rooms, check?, types?, loops?,
--   attempts?, stream? } (engine/modules/procgen/seeds.lua).
-- Exits with 0 when every seed gave a map, 1 when some failed, 2 on a usage error.
local here = (arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local base = here .. "/.."

local function die(msg, code) io.stderr:write("seed_validator: " .. msg .. "\n"); os.exit(code or 2) end

local game, spec_name
local count, first, out_path, verbose = 1000, 1, nil, false
local i = 1
while i <= #arg do
  local a = arg[i]
  if a == "--count" then i = i + 1; count = tonumber(arg[i])
  elseif a == "--first" then i = i + 1; first = tonumber(arg[i])
  elseif a == "--out" then i = i + 1; out_path = arg[i]
  elseif a == "--verbose" then verbose = true
  elseif a:sub(1, 2) == "--" then die("unknown option " .. a)
  elseif not game then game = a
  elseif not spec_name then spec_name = a
  else die("unexpected argument " .. a) end
  i = i + 1
end
if not game or not spec_name then
  die("usage: luajit tools/seed_validator.lua <game folder> <spec module> [--count N] [--first S] [--out FILE] [--verbose]")
end
if not count or count < 1 or count ~= math.floor(count) then die("--count takes a whole number >= 1") end
if not first or first < 0 or first ~= math.floor(first) or first + count - 1 >= 2 ^ 32 then
  die("--first takes a whole number, with every seed below 2^32")
end

game = game:gsub("[/\\]+$", "")
-- The game's own files first (and its engine/, if it has a pinned copy), then the base's.
package.path = game .. "/?.lua;" .. game .. "/?/init.lua;" .. base .. "/?.lua;" .. base .. "/?/init.lua;" .. package.path

local ok, spec = pcall(require, spec_name)
if not ok then die("cannot load the spec module " .. spec_name .. ": " .. tostring(spec)) end
if type(spec) ~= "table" or spec.templates == nil then die("the spec module must return a table with templates") end
local seeds = require("engine.modules.procgen.seeds")
local rng = require("engine.rng")

local entries, failed = {}, 0
local attempts_total, attempts_max, histogram = 0, 0, {}
local started = os.clock()
for n = 0, count - 1 do
  local seed = first + n
  local hash, info = seeds.hash(spec, seed)
  if hash then
    entries[#entries + 1] = { seed, hash, info }
    attempts_total = attempts_total + info
    if info > attempts_max then attempts_max = info end
    histogram[info] = (histogram[info] or 0) + 1
    if verbose then print(string.format("seed %d (%s): hash %.0f, %d attempts", seed, rng.seed_to_code(seed), hash, info)) end
  else
    failed = failed + 1
    entries[#entries + 1] = { seed, false, 0 }
    print(string.format("[FAIL] seed %d (%s): %s", seed, rng.seed_to_code(seed), tostring(info)))
  end
end
local good = count - failed

-- A hash of all the hashes, to compare two runs at a glance (FNV-1a over the list's text)
local text = seeds.format(spec_name, spec, entries)
print(string.format("seeds %d to %d: %d generated, %d failed", first, first + count - 1, good, failed))
if good > 0 then
  print(string.format("attempts: average %.2f, most %d", attempts_total / good, attempts_max))
  local keys = {}
  for k in pairs(histogram) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do print(string.format("  %2d attempt%s: %d seeds", k, k == 1 and " " or "s", histogram[k])) end
end
print(string.format("list hash: %08X", rng.hash(text)))
print(string.format("time: %.2f s", os.clock() - started))
if out_path then
  local f, err = io.open(out_path, "wb")
  if not f then die("cannot write " .. out_path .. ": " .. tostring(err)) end
  f:write(text)
  f:close()
  print("hash list written to " .. out_path)
end
os.exit(failed == 0 and 0 or 1)
