-- The rooms example's HUD, in the style of The Binding of Isaac: a column on the left with the
-- health (hearts) and the shield (pips), the consumable counters (virus, bombs, keys) and the
-- run stats (speed, jump, damage, luck), each with a small icon drawn with rectangles. The floor
-- and the biome sit small at the top centre. Game layer only.
--
--   local hud = require("rooms_hud")
--   self.hud = hud.new()                                   -- once
--   hud.draw(self.hud, self, love.graphics, W, FLOORS)     -- after camera:detach()
--
-- Every text is cached and rebuilt only when its number changes, so a frame where nothing
-- changes builds no strings and no tables.
local text = require("engine.text")
local floor, format, tostring = math.floor, string.format, tostring

local M = {}

M.tuning = {
  x = 4, y = 4,          -- top-left corner of the column
  hearts_per_row = 10,
  row = 9,               -- px between two lines of the column
  icon_text = 10,        -- px from an icon to its number
}
local T = M.tuning

local COLORS = {
  heart = { 0.95, 0.30, 0.40 }, heart_empty = { 0.30, 0.12, 0.16 },
  shield = { 0.45, 0.75, 1.00 }, shield_empty = { 0.16, 0.24, 0.34 },
  virus = { 0.55, 0.90, 0.40 }, bomb = { 0.35, 0.35, 0.40 }, fuse = { 0.95, 0.65, 0.25 },
  key = { 0.65, 0.95, 0.95 },
  speed = { 0.95, 0.85, 0.40 }, jump = { 0.60, 0.95, 1.00 }, damage = { 0.95, 0.45, 0.35 },
  luck = { 0.55, 0.95, 0.55 },
}

-- The stats column: id, the stats name, and how its number is written.
local STATS = {
  { id = "speed", fmt = "%.2f" },
  { id = "jump", fmt = "%.2f" },
  { id = "damage", fmt = "%d" },
  { id = "luck", fmt = "%d" },
}

-- A cached text: rebuilt only when the value changes.
local function cached(cache, key, value, fmt)
  local c = cache[key]
  if c.value ~= value then
    c.value = value
    if fmt then c.text = format(fmt, value) else c.text = tostring(value) end
  end
  return c.text
end

function M.new()
  local cache = {}
  local keys = { "virus", "bomb", "key", "floor", "speed", "jump", "damage", "luck" }
  for i = 1, #keys do cache[keys[i]] = { value = false, text = "" } end
  return { cache = cache, floor_biome = false }
end

local function color(g, c, a) g.setColor(c[1], c[2], c[3], a or 1) end

-- A 7x6 heart at x, y.
local function heart(g, x, y)
  g.rectangle("fill", x + 1, y, 2, 1)
  g.rectangle("fill", x + 4, y, 2, 1)
  g.rectangle("fill", x, y + 1, 7, 2)
  g.rectangle("fill", x + 1, y + 3, 5, 1)
  g.rectangle("fill", x + 2, y + 4, 3, 1)
  g.rectangle("fill", x + 3, y + 5, 1, 1)
end

-- The small icons of the counters and the stats, 7x7 at x, y.
local ICONS = {
  virus = function(g, x, y)
    color(g, COLORS.virus)
    g.rectangle("fill", x + 2, y + 1, 3, 5)
    g.rectangle("fill", x + 1, y + 2, 5, 3)
    g.rectangle("fill", x, y + 3, 1, 1); g.rectangle("fill", x + 6, y + 3, 1, 1)
    g.rectangle("fill", x + 3, y, 1, 1); g.rectangle("fill", x + 3, y + 6, 1, 1)
  end,
  bomb = function(g, x, y)
    color(g, COLORS.bomb)
    g.rectangle("fill", x + 1, y + 2, 5, 5)
    g.rectangle("fill", x, y + 3, 7, 3)
    color(g, COLORS.fuse)
    g.rectangle("fill", x + 4, y, 2, 2)
  end,
  key = function(g, x, y)
    color(g, COLORS.key)
    g.rectangle("fill", x, y + 1, 3, 3)
    g.rectangle("fill", x + 3, y + 2, 4, 1)
    g.rectangle("fill", x + 5, y + 3, 1, 2)
  end,
  speed = function(g, x, y)        -- an arrow
    color(g, COLORS.speed)
    g.rectangle("fill", x, y + 3, 5, 1)
    g.rectangle("fill", x + 3, y + 1, 1, 5)
    g.rectangle("fill", x + 4, y + 2, 1, 3)
    g.rectangle("fill", x + 5, y + 3, 1, 1)
  end,
  jump = function(g, x, y)         -- an up arrow
    color(g, COLORS.jump)
    g.rectangle("fill", x + 3, y + 1, 1, 6)
    g.rectangle("fill", x + 1, y + 3, 5, 1)
    g.rectangle("fill", x + 2, y + 2, 3, 1)
    g.rectangle("fill", x + 3, y, 1, 1)
  end,
  damage = function(g, x, y)       -- a fang
    color(g, COLORS.damage)
    g.rectangle("fill", x + 1, y, 5, 2)
    g.rectangle("fill", x + 2, y + 2, 3, 2)
    g.rectangle("fill", x + 3, y + 4, 1, 3)
  end,
  luck = function(g, x, y)         -- a clover
    color(g, COLORS.luck)
    g.rectangle("fill", x + 1, y, 2, 2); g.rectangle("fill", x + 4, y, 2, 2)
    g.rectangle("fill", x + 1, y + 3, 2, 2); g.rectangle("fill", x + 4, y + 3, 2, 2)
    g.rectangle("fill", x + 3, y + 2, 1, 5)
  end,
}

local function line(g, cache, key, x, y, value, fmt)
  ICONS[key](g, x, y)
  g.setColor(1, 1, 1, 1)
  text.draw(cached(cache, key, value, fmt), x + T.icon_text, y + 1)
end

-- M.draw(state, play, g, width, floors): play is the play state (fight, stats, wallet, abilities,
-- floor, biome).
function M.draw(state, play, g, width, floors)
  local cache = state.cache
  local x, y = T.x, T.y
  -- hearts: full up to the current health, dark up to the maximum, wrapped every row
  local health = play.fight.player.health
  local max = play.stats:get("health")
  local per = T.hearts_per_row
  for i = 1, max do
    local col, row = (i - 1) % per, floor((i - 1) / per)
    color(g, i <= health and COLORS.heart or COLORS.heart_empty)
    heart(g, x + col * 8, y + row * 7)
  end
  y = y + floor((max - 1) / per + 1) * 7 + 1
  -- shield pips, only when there is a capacity
  local sh, shmax = play.stats:shield()
  if shmax > 0 then
    for i = 1, shmax do
      color(g, i <= sh and COLORS.shield or COLORS.shield_empty)
      g.rectangle("fill", x + (i - 1) * 6, y, 5, 5)
    end
    y = y + 7
  end
  y = y + 2
  -- consumables
  local wallet = play.wallet
  line(g, cache, "virus", x, y, wallet:get("virus")); y = y + T.row
  line(g, cache, "bomb", x, y, wallet:get("bomb")); y = y + T.row
  local keys = play.abilities and play.abilities.key and 1 or 0
  line(g, cache, "key", x, y, keys); y = y + T.row + 4
  -- stats
  local stats = play.stats
  for i = 1, #STATS do
    local s = STATS[i]
    local v = stats:get(s.id)
    if s.fmt == "%d" then v = floor(v + 0.5) end
    line(g, cache, s.id, x, y, v, s.fmt)
    y = y + T.row
  end
  -- floor and biome, small at the top centre
  local fb = cache.floor
  if fb.value ~= play.floor or state.floor_biome ~= play.biome then
    fb.value, state.floor_biome = play.floor, play.biome
    fb.text = "FLOOR " .. play.floor .. "/" .. floors .. " " .. play.biome.name
  end
  g.setColor(1, 1, 1, 0.8)
  text.draw(fb.text, floor((width - text.width(fb.text)) / 2), 3)
  g.setColor(1, 1, 1, 1)
end

return M
