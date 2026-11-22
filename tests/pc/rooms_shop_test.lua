-- examples/rooms shop: stock of three distinct offers from the content pools, prices, buying
-- (spends virus, marks sold, takes the item, refuses twice or when broke), the same stock for
-- the same rng, and the treasure / super treasure pedestal counts.
-- Usage, from the repository root: luajit -joff tests/pc/rooms_shop_test.lua   (must end "OK:")
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
local C = require("rooms_content")
local S = require("rooms_shop")

-- 1. Prices are data: a mutation defaults to 15 virus, a heart to 3
check(S.tuning.prices.mutation == 15, "a mutation costs 15 virus")
check(S.tuning.prices.heart == 3, "a heart costs 3 virus")
check(S.tuning.size == 3, "the default stock size is 3")

-- 2. Three distinct offers, with an entry and a price, drawn without taking from the pool
local pools = C.new_pools()
local offers = S.stock(pools, Rng.new(42), { room = "shop", floor = 1 }, 3)
check(#offers == 3, "three offers")
local seen = {}
for i = 1, #offers do
  local o = offers[i]
  check(type(o.entry) == "table" and type(o.entry.id) == "string", "offer " .. i .. ": an entry")
  check(type(o.price) == "number" and o.price >= 0, "offer " .. i .. ": a price")
  check(not seen[o.entry.id], "offer " .. i .. ": no repeat")
  seen[o.entry.id] = true
  check(o.price == 15 and o.entry.kind == nil, "offer " .. i .. ": a 15 virus mutation")
  check(pools.mutations:taken_count(o.entry.id) == 0, "stock does not take from the pool")
end
check(#S.stock(C.new_pools(), Rng.new(7), {}, nil) == 3, "no n means the default three")
check(#S.stock(C.new_pools(), Rng.new(7), {}, 1) == 1, "n can be smaller")
check(#S.stock(C.new_pools(), Rng.new(7), {}, 0) == 0, "n can be zero")
check(#S.stock(C.new_pools(), Rng.new(7), {}, 10) <= #C.mutations + #C.hearts,
  "n is capped by what is available")
refuses(function() S.stock(nil, Rng.new(1), {}, 3) end, "no pools", "pools")
refuses(function() S.stock(C.new_pools(), nil, {}, 3) end, "no rng", "rng")
refuses(function() S.stock(C.new_pools(), Rng.new(1), {}, 1.5) end, "a fractional n", "whole number")

-- 3. When the mutations are taken, hearts fill the shop at their own price
local heart_pools = C.new_pools()
for i = 1, #heart_pools.mutations.entries do heart_pools.mutations:take(heart_pools.mutations.entries[i]) end
local hearts = S.stock(heart_pools, Rng.new(3), {}, 3)
check(#hearts == 1 and hearts[1].entry.kind == "heart", "a heart fills an empty mutation pool")
check(hearts[1].price == 3, "the heart costs 3 virus")

-- 4. Same rng and context, same stock; another seed differs
local function stock_ids(seed)
  local list = S.stock(C.new_pools(), Rng.new(seed), { room = "shop", floor = 1 }, 3)
  local out = {}
  for i = 1, #list do out[i] = list[i].entry.id .. ":" .. list[i].price end
  return table.concat(out, ",")
end
check(stock_ids(42) == stock_ids(42), "same seed, same stock")
check(stock_ids(42) ~= stock_ids(43), "another seed, another stock")

-- 5. Buying: pays the price, marks it sold, takes it from its pool, and cannot happen twice
local buy_pools = C.new_pools()
local offer = S.stock(buy_pools, Rng.new(7), {}, 3)[1]
local state = {}
local w = wallet.new({ virus = offer.price })
local ok, reason = S.buy(offer, state, w)
check(ok == true and reason == nil, "buy succeeds at exactly the price")
check(w:get("virus") == 0, "buy spends the price")
check(state.sold == true and offer.sold == true, "buy marks it sold in the state and the offer")
check(buy_pools.mutations:taken_count(offer.entry.id) == 1, "buy takes it from the pool")
local again, why = S.buy(offer, state, w)
check(again == false and why == "sold", "the same offer cannot be bought twice")
check(w:get("virus") == 0, "a refused second buy spends nothing")
local other_state = {}
local other_offer = S.stock(C.new_pools(), Rng.new(7), {}, 3)[1]
check(S.buy(other_offer, other_state, w) == false, "a fresh offer with no money is refused")

-- 6. Broke: refuses, spends nothing and does not mark it sold; one more virus is enough
local broke_pools = C.new_pools()
local broke_offer = S.stock(broke_pools, Rng.new(9), {}, 3)[1]
local broke_state = {}
local broke_wallet = wallet.new({ virus = broke_offer.price - 1 })
local bought, why_not = S.buy(broke_offer, broke_state, broke_wallet)
check(bought == false and why_not == "not enough", "one short: not enough")
check(broke_wallet:get("virus") == broke_offer.price - 1, "a refused buy spends nothing")
check(broke_state.sold ~= true and broke_offer.sold ~= true, "a refused buy is not sold")
check(broke_pools.mutations:taken_count(broke_offer.entry.id) == 0, "a refused buy takes nothing")
broke_wallet:add("virus", 1)
check(S.buy(broke_offer, broke_state, broke_wallet) == true and broke_wallet:get("virus") == 0,
  "exactly the price is enough")
check(S.buy(broke_offer, broke_state, nil) == false, "a sold offer is refused even without a wallet")

-- 7. Free pedestals: a price of 0 needs no wallet and can all be taken
local free_entry = { id = "free_heart", kind = "heart", color = { 1, 1, 1 } }
local free_state = {}
local free = { entry = free_entry, price = 0 }
check(S.buy(free, free_state, nil) == true and free_state.sold == true, "a free offer needs no wallet")
check(S.buy(free, free_state, nil) == false, "a free offer is still only once")

-- 8. Pedestals: one centered for treasure, three spread on the floor for super treasure
local p = S.pedestals("treasure")
check(#p == 1 and p[1].tx == 10 and p[1].ty == 11, "treasure: one centered pedestal on the floor")
local sp = S.pedestals("super_treasure")
check(#sp == 3, "super treasure: three pedestals")
local xs = {}
for i = 1, #sp do
  check(type(sp[i].tx) == "number" and sp[i].ty == 11, "super treasure: pedestal " .. i .. " on the floor")
  check(not xs[sp[i].tx], "super treasure: pedestal " .. i .. " has its own column")
  xs[sp[i].tx] = true
end
check(xs[p[1].tx], "super treasure keeps the treasure room's center")
check(S.pedestals("treasure") ~= p, "pedestals returns a fresh list")
refuses(function() S.pedestals("nope") end, "an unknown pedestal kind", "unknown pedestal kind")

print(string.format("OK: %d checks; rooms shop stock and pedestals", checks))
