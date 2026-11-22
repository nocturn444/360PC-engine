-- examples/rooms: the bonus key (an optional key, not the per-floor `key` ability). It is a
-- pickup (pale cyan, label "KEY+"), its own content pool with a mob roll that luck scales, and a
-- currency of the run wallet.
-- Usage, from the repository root: luajit -joff tests/pc/rooms_bonus_key_test.lua   (ends "OK:")
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./examples/rooms/?.lua;" .. package.path

local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print("FAILED: " .. what); os.exit(1) end
end
local function refuses(f, what, pattern)
  local ok, err = pcall(f)
  check(not ok and tostring(err):find(pattern, 1, true), what .. " (" .. tostring(err) .. ")")
end

local Rng = require("engine.rng")
local wallet = require("engine.modules.wallet")
local pickups = require("rooms_pickups")
local C = require("rooms_content")

-- 1. Pickup creation, defaults and validation
local k = pickups.bonus_key(12, 34)
check(k.kind == "bonus_key" and k.x == 12 and k.y == 34 and k.amount == 1,
  "bonus key defaults to amount 1")
check(pickups.bonus_key(0, 0, 3).amount == 3, "bonus key keeps its amount")
check(pickups.bonus_key(0, 0, 0).amount == 0, "an amount of zero is allowed")
refuses(function() pickups.bonus_key("x", 0) end, "a non-numeric x", "numeric x and y")
refuses(function() pickups.bonus_key(0, nil) end, "a missing y", "numeric x and y")
refuses(function() pickups.bonus_key(0, 0, 1.5) end, "a fractional amount", "whole amount >= 0")
refuses(function() pickups.bonus_key(0, 0, -1) end, "a negative amount", "whole amount >= 0")

-- 2. Pale cyan colour and its label
local c = pickups.color(k)
check(c[2] >= 0.9 and c[3] >= 0.9 and c[1] > 0.5 and c[1] < c[2] and c[1] < c[3],
  "the bonus key is pale cyan")
check(pickups.label(k) == "KEY+", "the KEY+ label")

-- 3. The content entry and its own pool
local pools = C.new_pools()
check(type(pools.bonus_keys) == "table" and type(pools.bonus_keys.draw) == "function",
  "new_pools exposes bonus_keys")
check(#pools.bonus_keys.entries == 1 and pools.bonus_keys.entries[1].id == "bonus_key",
  "the bonus key is in the bonus_keys pool")
check(pools.bonus_keys.entries[1].kind == "bonus_key"
  and pools.bonus_keys.entries[1].sources[1] == "mob", "bonus key: kind and mob source")
check(pools.bonus_keys ~= C.new_pools().bonus_keys, "new_pools makes a fresh bonus key pool")

-- 4. Pool draw: only from a source it lists, and deterministic
local from_mob = C.draw_bonus_key(pools.bonus_keys, Rng.new(9), { source = "mob" })
check(from_mob and from_mob.id == "bonus_key", "draw_bonus_key takes it from a pool")
local from_pools = C.draw_bonus_key(pools, Rng.new(9), { source = "mob" })
check(from_pools and from_pools.id == "bonus_key", "draw_bonus_key accepts the pools table")
check(C.draw_bonus_key(pools, Rng.new(9), { source = "machine" }) == nil,
  "no bonus key from a machine")
check(C.draw_bonus_key(pools, Rng.new(9), { source = "mob" }).id
  == C.draw_bonus_key(pools, Rng.new(9), { source = "mob" }).id,
  "same seed, same bonus key draw")

-- 5. The mob roll is 0.05, and luck scales the chance through M.drop
check(C.chances.mob_bonus_key == 0.05, "the mob bonus key roll is 0.05")
local function count_drops(luck)
  local p = C.new_pools().bonus_keys
  local n = 0
  for seed = 1, 600 do
    local ctx = { source = "mob", build = { tags = {}, luck = luck } }
    if C.drop(p, Rng.new(seed), ctx, C.chances.mob_bonus_key) then n = n + 1 end
  end
  return n
end
local low, high = count_drops(0), count_drops(10)
check(low > 0, "some bonus keys drop at luck 0")
check(high > low, "more bonus keys drop at higher luck")
check(high < 600, "not every mob drops a bonus key")

-- 6. The run wallet holds them as the "bonus_key" currency
local w = wallet.new({ bonus_key = 0 })
check(w:get("bonus_key") == 0, "a bonus_key wallet starts empty")
w:add("bonus_key", 2)
check(w:can("bonus_key", 2) and w:get("bonus_key") == 2, "add bonus keys")
check(w:spend("bonus_key", 1) and w:get("bonus_key") == 1, "spend one bonus key")
check(not w:spend("bonus_key", 2) and w:get("bonus_key") == 1,
  "cannot spend more than it has, and nothing changes")
check(w:state().bonus_key == 1, "the wallet state carries the keys")

print(string.format("OK: %d checks; rooms bonus key", checks))
