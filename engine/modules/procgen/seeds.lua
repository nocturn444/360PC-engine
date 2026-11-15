-- procgen.seeds: one seed -> one layout hash, the same way on PC and on the console. Used by
-- tools/seed_validator.lua (bulk validation on PC, writes a hash list) and by
-- tests/console/level_hash_check.lua (reads the list on the console and compares).
-- See engine/modules/procgen/README.md.
--
-- A spec is a table the game provides (usually a module both sides can require):
--   templates   the room templates, or a function returning them
--   abilities   the ability tags, in the order the player finds them
--   rooms       rooms per map (default 12)
--   check       optional function(map) -> true, or false and a reason (the game's own rule)
--   types, loops, attempts   as procgen.generate takes them
--   stream      the engine.rng stream the game generates levels with (default "level");
--               false: the seed goes straight to procgen.generate
local Rng = require("engine.rng")
local prefix = (...):gsub("seeds$", "")
local generator = require(prefix .. "generator")
local map_hash = require(prefix .. "map").hash

local M = {}
M.VERSION = 1
M.FILE = "level_hashes.txt"

local function templates_of(spec)
  local t = spec.templates
  if type(t) == "function" then t = t() end
  return t
end

-- The map of one seed (a whole number), or nil and the reason.
function M.generate(spec, seed)
  local opts = { templates = templates_of(spec), abilities = spec.abilities, rooms = spec.rooms,
    check = spec.check, types = spec.types, loops = spec.loops, attempts = spec.attempts }
  if spec.stream == false then opts.seed = seed
  else opts.rng = Rng.streams(seed):get(spec.stream or "level") end
  return generator.generate(opts)
end

-- hash, attempts for one seed; or nil, reason when no map came out.
function M.hash(spec, seed)
  local map, err = M.generate(spec, seed)
  if not map then return nil, err end
  return map_hash(map), map.attempts
end

-- The text of a hash list. entries: { { seed, hash or false, attempts }, ... }
function M.format(name, spec, entries)
  local out = { "# 360PC-Engine level hashes v" .. M.VERSION,
    string.format("# spec=%s rooms=%d stream=%s count=%d", name, spec.rooms or 12,
      spec.stream == false and "-" or (spec.stream or "level"), #entries) }
  for i = 1, #entries do
    local e = entries[i]
    out[#out + 1] = string.format("%.0f %s %d", e[1], e[2] and string.format("%.0f", e[2]) or "fail", e[3] or 0)
  end
  return table.concat(out, "\n") .. "\n"
end

-- Reads a hash list: { spec = name, entries = { { seed, hash or false, attempts }, ... } },
-- or nil and the reason.
function M.parse(text)
  if type(text) ~= "string" then return nil, "no hash list" end
  local version = text:match("^# 360PC%-Engine level hashes v(%d+)")
  if tonumber(version) ~= M.VERSION then return nil, "not a level hash list of version " .. M.VERSION end
  local list = { spec = text:match("\n# spec=(%S+)"), entries = {} }
  if not list.spec then return nil, "the hash list names no spec" end
  local n = 0
  for line in text:gmatch("[^\r\n]+") do
    n = n + 1
    if line:sub(1, 1) ~= "#" then
      local seed, hash, attempts = line:match("^(%d+) (%S+) (%d+)$")
      if not seed or not (hash == "fail" or hash:match("^%d+$")) then
        return nil, "line " .. n .. " of the hash list is not valid: " .. line
      end
      list.entries[#list.entries + 1] = { tonumber(seed), hash ~= "fail" and tonumber(hash), tonumber(attempts) }
    end
  end
  return list
end

-- Generates every seed of a parsed list again and compares hash and attempts. log gets one
-- line per mismatch and a summary; returns how many differ and how many were checked.
function M.check(list, spec, log)
  log = log or print
  local bad, entries = 0, list.entries
  for i = 1, #entries do
    local e = entries[i]
    local hash, attempts = M.hash(spec, e[1])
    local same = (hash or false) == e[2] and (not hash or attempts == e[3])
    if not same then
      bad = bad + 1
      log(string.format("[BAD] seed %.0f: got %s (%s), expected %s (%s attempts)", e[1],
        hash and string.format("%.0f", hash) or "no map", hash and (attempts .. " attempts") or tostring(attempts),
        e[2] and string.format("%.0f", e[2]) or "no map", tostring(e[3])))
    end
  end
  log(string.format("== level hashes: %d of %d wrong ==", bad, #entries))
  return bad, #entries
end

return M
