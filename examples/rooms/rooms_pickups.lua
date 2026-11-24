-- Pickups of the rooms example: a small piece of data on the floor that gives its amount when
-- the slime touches it. `heart` heals, `virus` is the run's currency, `bomb` a consumable and
-- `bonus_key` an optional key (currencies of engine.modules.wallet). This file is data only: no love,
-- no drawing. The room draws and collects them, and decides what an amount means.
local type, floor, abs = type, math.floor, math.abs

local M = {}

local HALF = 4   -- the pickup is a small square centered on x, y

local function make(kind, x, y, amount)
  if type(x) ~= "number" or type(y) ~= "number" then
    error("pickups: " .. kind .. " needs numeric x and y", 4)
  end
  if amount == nil then amount = 1 end
  if type(amount) ~= "number" or amount < 0 or amount ~= floor(amount) then
    error("pickups: " .. kind .. " needs a whole amount >= 0", 4)
  end
  return { kind = kind, x = x, y = y, amount = amount }
end

-- M.heart(x, y, amount) -> { kind = "heart", x, y, amount }, amount defaults to 1.
function M.heart(x, y, amount) return make("heart", x, y, amount) end

-- M.virus(x, y, amount) -> { kind = "virus", x, y, amount }, amount defaults to 1.
function M.virus(x, y, amount) return make("virus", x, y, amount) end

-- M.bomb(x, y, amount) -> { kind = "bomb", x, y, amount }, amount defaults to 1.
function M.bomb(x, y, amount) return make("bomb", x, y, amount) end

-- M.bonus_key(x, y, amount) -> { kind = "bonus_key", x, y, amount }, amount defaults to 1.
-- An optional key (first use: the super treasure room), not the per-floor `key` ability.
function M.bonus_key(x, y, amount) return make("bonus_key", x, y, amount) end

-- M.overlaps(pickup, cx, cy) -> true when the point (cx, cy) is on the pickup's small square.
function M.overlaps(pickup, cx, cy)
  return abs(cx - pickup.x) <= HALF and abs(cy - pickup.y) <= HALF
end

local COLORS = {
  heart = { 0.95, 0.30, 0.40 },
  virus = { 0.55, 0.90, 0.40 },
  bonus_key = { 0.65, 0.95, 0.95 },
  bomb = { 0.35, 0.35, 0.40 },
}

-- M.color(pickup) -> a shared { r, g, b }. Do not change it.
function M.color(pickup) return COLORS[pickup.kind] or COLORS.heart end

local LABELS = { heart = "HEART", virus = "VIRUS", bonus_key = "KEY+", bomb = "BOMB" }

-- M.label(pickup) -> a short name for a HUD or a floating text.
function M.label(pickup) return LABELS[pickup.kind] or "PICKUP" end

return M
