-- engine/modules/items: entries, room filters, unlocks, `max`, `requires`, weights (and the
-- game's weight rule), distinct draws, the run state for saves, determinism with the loot
-- stream, and a static check that the module uses nothing the console lacks.
local T = ...
local globals = {}
for k in pairs(_G) do globals[k] = true end
local Rng = require("engine.rng")
local Save = require("engine.save")
local items = require("engine.modules.items")

local function defs()
  return {
    { id = "heart", weight = 10 },
    { id = "coin", weight = 30, max = nil },
    { id = "sword", weight = 5, max = 1 },
    { id = "map", weight = 5, rooms = { "shop" } },
    { id = "key", weight = 5, rooms = { "shop", "treasure" } },
    { id = "wings", weight = 5, unlock = "beat_boss" },
    { id = "fins", weight = 5, requires = { "swim" } },
    { id = "nothing", weight = 0 },
  }
end

-- Entries
local pool = items.pool.new(defs())
T.check(pool.by_id.heart.weight == 10 and pool.by_id.sword.max == 1 and #pool.entries == 8, "entries are kept in order")
local function refuses(list, what, pattern)
  local ok, err = pcall(items.pool.new, list)
  T.check(not ok and tostring(err):find(pattern, 1, true), what .. " (" .. tostring(err) .. ")")
end
refuses({ { id = "a" }, { id = "a" } }, "two entries with one id", "two entries have the id a")
refuses({ { weight = 1 } }, "an entry without id", "needs a string id")
refuses({ { id = "a", weight = -1 } }, "a negative weight", "weight is a number")
refuses({ { id = "a", max = 0 } }, "max below one", "max is a whole number")
refuses({ { id = "a", rooms = "shop" } }, "rooms not an array", "rooms is an array")
T.check(items.pool.new({ { id = "a" } }).by_id.a.weight == 1, "weight defaults to 1")

-- What can come out
local function ids(list)
  local out = {}
  for i = 1, #list do out[i] = list[i].id end
  table.sort(out)
  return table.concat(out, " ")
end
local function avail(p, ctx)
  local out = {}
  for _, e in ipairs(p.entries) do if p:available(e, ctx) then out[#out + 1] = e end end
  return ids(out)
end
T.check(avail(pool) == "coin heart sword", "no context: entries without rooms, unlocks or requires")
T.check(avail(pool, { room = "shop" }) == "coin heart key map sword", "room filter: shop")
T.check(avail(pool, { room = "treasure" }) == "coin heart key sword", "room filter: treasure")
T.check(avail(pool, { have = { "swim" } }) == "coin fins heart sword", "requires: a tag the run has")
T.check(avail(pool, { have = { swim = true } }) == "coin fins heart sword", "requires: tags as a set")
T.check(avail(pool, { exclude = { coin = true } }) == "heart sword", "exclude")
T.check(avail(pool, { filter = function(e) return e.weight >= 10 end }) == "coin heart", "the game's filter")
pool:unlock("beat_boss")
T.check(pool:is_unlocked("beat_boss") and avail(pool) == "coin heart sword wings", "an unlock adds its entries")
T.check(avail(items.pool.new(defs(), { unlocked = { "beat_boss" } })) == "coin heart sword wings", "unlocks given to new")
T.check(avail(items.pool.new(defs(), { unlocked = { beat_boss = true } })) == "coin heart sword wings", "unlocks as a set")
pool:add({ id = "crown", weight = 1, unlock = "beat_boss" })
T.check(avail(pool) == "coin crown heart sword wings", "pool:add: new content at the end")
T.check(not pcall(pool.add, pool, { id = "crown" }), "pool:add refuses an id it has")

-- max and the run state
pool:take("sword")
T.check(pool:taken_count("sword") == 1 and avail(pool) == "coin crown heart wings", "max = 1: taken once, gone for the run")
pool:take(pool.by_id.coin); pool:take("coin")
T.check(pool:taken_count("coin") == 2 and avail(pool):find("coin", 1, true), "no max: it stays")
T.check(not pcall(pool.take, pool, "ghost"), "take: an unknown id is an error")
local state = pool:run_state()
T.check(state.sword == 1 and state.coin == 2 and state.heart == nil, "run_state")
local text = Save.serialize(state)
local back = items.pool.new(defs())
back:set_run_state(select(2, Save.parse(text)))
T.check(back:taken_count("sword") == 1 and back:taken_count("coin") == 2, "run_state through engine.save")
back:set_run_state({ ghost = 3, heart = -1 })
T.check(back:taken_count("ghost") == 0 and back:taken_count("heart") == 0, "set_run_state ignores what it does not know")
pool:new_run()
T.check(pool:taken_count("sword") == 0 and pool:is_unlocked("beat_boss"), "new_run forgets the run, keeps the unlocks")

-- Draws
local p = items.pool.new(defs())
local r = Rng.new(1)
local counts = {}
for _ = 1, 4500 do
  local e = p:draw(r)
  counts[e.id] = (counts[e.id] or 0) + 1
end
-- weights 10, 30, 5 over 45: about 1000, 3000, 500
T.check(counts.heart > 850 and counts.heart < 1150 and counts.coin > 2800 and counts.coin < 3200
  and counts.sword > 400 and counts.sword < 600 and counts.nothing == nil, "draws follow the weights")
local empty = items.pool.new({ { id = "a", rooms = { "shop" } } })
local r2 = Rng.new(5)
local before = r2:state()
T.check(empty:draw(r2) == nil and r2:state() == before, "nothing can come out: nil, and no draw")
local lucky = 0
for _ = 1, 1000 do
  if p:draw(r, { weight = function(e, w) return e.id == "sword" and w * 9 or w end }).id == "sword" then lucky = lucky + 1 end
end
T.check(lucky > 400 and lucky < 600, "ctx.weight changes a weight (" .. lucky .. " swords of 1000)")
T.check(not pcall(p.draw, p, r, { weight = function() return -1 end }), "ctx.weight must give a number >= 0")
local three = p:draw_many(Rng.new(3), 3, { room = "shop" })
T.check(#three == 3 and three[1] ~= three[2] and three[2] ~= three[3] and three[1] ~= three[3], "draw_many: distinct")
local ctx = { room = "shop", exclude = { coin = true } }
local all = p:draw_many(Rng.new(3), 10, ctx)
T.check(#all == 4 and ids(all) == "heart key map sword" and ctx.exclude.heart == nil and ctx.exclude.coin,
  "draw_many: stops when the pool runs out, and leaves ctx.exclude as it was")
T.check(p:taken_count("heart") == 0, "draws take nothing")

-- Same seed, same draws (the loot stream of a run)
local function sequence(seed)
  local q = items.pool.new(defs(), { unlocked = { "beat_boss" } })
  local loot = Rng.streams(seed):get("loot")
  local out = {}
  for i = 1, 20 do
    local e = q:draw(loot, { room = (i % 3 == 0) and "shop" or nil, have = { "swim" } })
    out[i] = e.id
    if e.max then q:take(e) end
  end
  return table.concat(out, ",")
end
T.check(sequence(77) == sequence(77) and sequence(77) ~= sequence(78), "same seed, same draws")
local lines = {}
local wrong = assert(loadfile("tests/console/items_check.lua"))(function(line) lines[#lines + 1] = line end)
T.check(wrong == 0 and lines[#lines] == "== items: 0 of 3 wrong ==", "tests/console/items_check.lua: " .. tostring(lines[#lines]))

-- Static checks
local f = assert(io.open("engine/modules/items/init.lua", "rb"))
local src = f:read("*a"):gsub("%-%-[^\n]*", ""); f:close()
T.check(not src:find("%f[%w]goto%f[%W]") and not src:find("ffi") and not src:find("%f[%w_]jit%."), "items: no goto, FFI or jit")
T.check(not src:find("%f[%w_]love%f[%W]") and not src:find("math%.random") and not src:find("os%.time"),
  "items: no love, nothing random of its own, no clock")
T.check(not src:find("[^%w_]pairs%("), "items: no pairs()")
T.no_new_globals(globals)
