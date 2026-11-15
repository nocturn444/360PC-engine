-- 360PC-Engine: known answers of engine/modules/items: the ids drawn from a fixed pool with the
-- loot stream of a few seeds. They have to be the same on every platform.
-- On the PC:      luajit tests/console/items_check.lua  and  luajit -joff tests/console/items_check.lua
--                 (from the repository root; both must end with "== items: 0 of 3 wrong ==")
-- On the console: copy this file next to the main.lua of a game that has engine/, add
--                 require("items_check") as the first line of that main.lua, and read the log.
-- Called as a function with a log function as its argument, it logs there (the engine's tests do).
local arg1 = ...
local log = type(arg1) == "function" and arg1 or (l360 and l360.log) or print
if type(arg1) ~= "function" and not l360 then package.path = "./?.lua;./?/init.lua;" .. package.path end
local rng = require("engine.rng")
local items = require("engine.modules.items")
local bad, total = 0, 0

local function defs()
  return {
    { id = "heart", weight = 10 },
    { id = "coin", weight = 30 },
    { id = "sword", weight = 5, max = 1 },
    { id = "map", weight = 5, rooms = { "shop" } },
    { id = "key", weight = 5, rooms = { "shop", "treasure" } },
    { id = "wings", weight = 5, unlock = "beat_boss" },
    { id = "fins", weight = 5, requires = { "swim" } },
  }
end
local function sequence(seed)
  local pool = items.pool.new(defs(), { unlocked = { "beat_boss" } })
  local loot = rng.streams(seed):get("loot")
  local out = {}
  for i = 1, 12 do
    local e = pool:draw(loot, { room = (i % 3 == 0) and "shop" or nil, have = { "swim" } })
    out[i] = e.id
    if e.max then pool:take(e) end
  end
  local three = pool:draw_many(loot, 3, { room = "treasure" })
  for i = 1, #three do out[#out + 1] = three[i].id end
  return table.concat(out, ",")
end
local function check(name, got, want)
  total = total + 1
  local ok = got == want
  if not ok then bad = bad + 1 end
  log(string.format("%s %s%s", ok and "[ok] " or "[BAD]", name, ok and "" or (" = " .. tostring(got))))
end

check("streams(1) loot", sequence(1), "coin,coin,heart,coin,fins,fins,heart,coin,key,heart,wings,coin,coin,heart,wings")
check("streams(12345) loot", sequence(12345), "coin,coin,coin,sword,coin,coin,heart,coin,coin,coin,coin,key,wings,coin,key")
check("streams('360PC') loot", sequence("360PC"), "fins,coin,coin,heart,heart,coin,coin,coin,coin,sword,fins,fins,heart,coin,key")

log(string.format("== items: %d of %d wrong ==", bad, total))
return bad
