-- Shop stock and treasure pedestals of the rooms example. Game layer only: the pools come from
-- rooms_content, the currency is engine.modules.wallet's `virus`, and this file never removes
-- anything from a pool until an offer is bought. No love at load: only draw_offer touches love,
-- through engine.text.
--
--   local shop = require("rooms_shop")
--   local offers = shop.stock(self.pools, rng, ctx, 3)   -- once per room; keep in the room state
--   if shop.buy(offers[i], state[i], self.wallet) then ... end
--
-- A shop's stock is drawn once per room and stored in that room's persistent state (for example
-- rooms_play's rooms_state[index]). The rng is consumed, so drawing the stock again would give a
-- different shop for the same seed.
local type, floor, tostring = type, math.floor, tostring
local text = require("engine.text")

local M = {}

-- Prices in virus of one offer, by kind. A pool entry with `kind` is a consumable (heart, ...);
-- one without `kind` is a mutation. Change these numbers to tune the shop.
M.tuning = {
  prices = { mutation = 15, heart = 3, bomb = 5 },
  size = 3,
}

local function price_of(entry)
  local kind = entry.kind or "mutation"
  local price = M.tuning.prices[kind]
  if price == nil then price = M.tuning.prices.mutation end
  return price
end

-- Draws up to `count` distinct entries of one pool into `offers`, remembering what was drawn so
-- the next pool cannot repeat an id. Nothing is taken from the pool.
local POOL_ORDER = { "mutations", "hearts", "bombs" }

local function draw_into(pool, rng, ctx, count, offers, exclude)
  if count <= 0 or pool == nil then return end
  if type(pool) ~= "table" or type(pool.draw_many) ~= "function" then
    error("rooms_shop: stock needs item pools", 4)
  end
  local c = {}
  if ctx ~= nil then
    for k, v in next, ctx do c[k] = v end
  end
  c.exclude = exclude
  local entries = pool:draw_many(rng, count, c)
  for i = 1, #entries do
    local entry = entries[i]
    exclude[entry.id] = true
    offers[#offers + 1] = { entry = entry, price = price_of(entry), pool = pool }
  end
end

-- M.stock(pools, rng, ctx, n) -> an array of up to n (default M.tuning.size, 3) offers. Each
-- offer is { entry = mutation or consumable, price = virus, pool = the items pool }. The stock
-- fills from the mutation pool first, then from the hearts and bombs pools, without repeats and without
-- taking anything (a bought item is taken later by M.buy). Same rng and context, same stock.
-- `ctx` is the pool's own context (room, biome, have, exclude, filter, weight); pass the content
-- filter in ctx.filter if the game's source rules should apply.
function M.stock(pools, rng, ctx, n)
  if type(pools) ~= "table" then error("rooms_shop: stock needs the run's pools", 3) end
  if rng == nil or type(rng.weighted) ~= "function" then
    error("rooms_shop: stock needs an rng", 3)
  end
  if ctx ~= nil and type(ctx) ~= "table" then error("rooms_shop: ctx is a table", 3) end
  if n == nil then n = M.tuning.size end
  if type(n) ~= "number" or n < 0 or n ~= floor(n) then
    error("rooms_shop: the stock size is a whole number >= 0", 3)
  end
  local offers, exclude = {}, {}
  if ctx and ctx.exclude then
    for id, flag in next, ctx.exclude do exclude[id] = flag end
  end
  for i = 1, #POOL_ORDER do
    local left = n - #offers
    if left <= 0 then break end
    draw_into(pools[POOL_ORDER[i]], rng, ctx, left, offers, exclude)
  end
  return offers
end

-- M.buy(offer, state, wallet) -> true when the offer is bought, or false, reason ("sold" or
-- "not enough"). It spends virus and marks the offer sold. `state` is the offer's persistent
-- table (one per offer, like a machine's) and gets `sold = true`; nil uses the offer itself.
-- A bought mutation or consumable is taken from its pool, so later shops cannot offer it twice.
-- A price of 0 (a free treasure pedestal) needs no wallet.
function M.buy(offer, state, wallet)
  if type(offer) ~= "table" or type(offer.entry) ~= "table" then
    error("rooms_shop: buy needs an offer", 2)
  end
  if type(offer.price) ~= "number" or offer.price < 0 then
    error("rooms_shop: the offer's price is a number >= 0", 2)
  end
  if state == nil then state = offer end
  if type(state) ~= "table" then error("rooms_shop: state is a table", 2) end
  if state.sold or offer.sold then return false, "sold" end
  if offer.price > 0 then
    if wallet == nil or type(wallet.can) ~= "function" or type(wallet.spend) ~= "function" then
      return false, "not enough"
    end
    if not wallet:can("virus", offer.price) then return false, "not enough" end
    if not wallet:spend("virus", offer.price) then return false, "not enough" end
  end
  state.sold, offer.sold = true, true
  if offer.pool ~= nil and type(offer.pool.take) == "function" then
    offer.pool:take(offer.entry)
  end
  return true
end

-- Pedestal positions in tiles (1-based tx, ty, like rooms_data): ty is the floor row the
-- pedestal stands on. A treasure room has one, centered; a super treasure room has three,
-- spread on the floor of the same room shape. All three super treasure items are free and can
-- all be taken: the caller uses price 0 (or M.buy with no wallet) for each.
local PEDESTALS = {
  treasure = { { tx = 10, ty = 11 } },
  super_treasure = { { tx = 5, ty = 11 }, { tx = 10, ty = 11 }, { tx = 15, ty = 11 } },
}

-- M.pedestals(kind) -> a fresh array of { tx, ty } for "treasure" (1) or "super_treasure" (3).
function M.pedestals(kind)
  local list = PEDESTALS[kind]
  if list == nil then
    error("rooms_shop: unknown pedestal kind " .. tostring(kind), 2)
  end
  local out = {}
  for i = 1, #list do out[i] = { tx = list[i].tx, ty = list[i].ty } end
  return out
end

local WHITE = { 1, 1, 1 }

-- M.draw_offer(offer, x, y, g, near): optional; g is love.graphics. Draws the item and its
-- price in virus, dimmed when it is sold. `near` highlights the offer the player can reach.
function M.draw_offer(offer, x, y, g, near)
  local entry = offer.entry
  local c = entry.color or WHITE
  local sold = offer.sold == true
  local k = sold and 0.35 or 1
  g.setColor(c[1] * k, c[2] * k, c[3] * k, 1)
  g.rectangle("fill", x, y, 8, 8)
  g.setColor(0, 0, 0, 0.3)
  g.rectangle("line", x, y, 8, 8)
  local label = tostring(offer.price) .. " V"
  if sold then
    g.setColor(0.45, 0.45, 0.45, 1)
  elseif near then
    g.setColor(1, 1, 1, 1)
  else
    g.setColor(0.85, 0.85, 0.85, 1)
  end
  text.draw(label, x + 4 - text.width(label) / 2, y - 10)
  if near and not sold then
    g.setColor(1, 1, 1, 0.8)
    g.rectangle("line", x - 1, y - 1, 10, 10)
  end
  g.setColor(1, 1, 1, 1)
end

return M
