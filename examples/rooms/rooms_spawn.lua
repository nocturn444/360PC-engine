-- Spawn rules of the new special rooms (casino, super treasure, pact, trap, obstacle) as data
-- plus pure functions, and the run state the game updates at the end of each floor. This is the
-- game layer only: it does not require love, does not draw and does not know the map. The
-- definitions are written for procgen.roomtypes with `run` (the run argument of chance) and
-- `replaces` / `max`; they are wired in later. Every number lives in M.tuning.
local type, min = type, math.min

local M = {}

M.tuning = {
  -- Starting values of the run state
  casino_start = 0.00,
  trap_start = 0.05,
  obstacle_start = 0.05,
  -- Per-floor changes
  casino_step = 0.05,
  casino_reset = 0.00,
  trap_step = 0.10,
  trap_reset = 0.05,
  obstacle_step = 0.30,
  obstacle_reset = 0.05,
  cap = 0.95,
  -- Trap chance from luck: factor = clamp(base - slope * luck, min, max); luck 5 gives x1
  luck_base = 1.5,
  luck_slope = 0.1,
  luck_min = 0.5,
  luck_max = 1.5,
  luck_default = 5,
  -- Chances and floors
  super_treasure_chance = 0.33,
  pact_chance = 0.15,
  pact_floor = 3,
  special_depth = 2,
  -- Counts and placement
  casino_count = 1,
  casino_max_floor = -2,
  super_treasure_count = 1,
  pact_count = 1,
  trap_count_min = 1,
  trap_count_max = 2,
  trap_max = 2,
  obstacle_count = 1,
}

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- M.new_state() -> the spawn state of a new run.
function M.new_state()
  local t = M.tuning
  return {
    casino = t.casino_start,
    trap = t.trap_start,
    obstacle = t.obstacle_start,
    treasure_skipped = false,
  }
end

-- M.end_floor(state, summary) -> state, updated from the floor that just ended. `summary` has
-- shop_existed, shop_entered, casino_appeared, treasure_existed, treasure_entered, trap_count,
-- obstacle_appeared and damaged. Missing fields count as false or zero.
function M.end_floor(state, summary)
  if type(state) ~= "table" then error("rooms_spawn: state is a table", 2) end
  if type(summary) ~= "table" then error("rooms_spawn: summary is a table", 2) end
  local t = M.tuning

  if summary.casino_appeared then
    state.casino = t.casino_reset
  elseif summary.shop_existed and not summary.shop_entered then
    state.casino = min(t.cap, state.casino + t.casino_step)
  end

  if (summary.trap_count or 0) > 0 then
    state.trap = t.trap_reset
  else
    state.trap = min(t.cap, state.trap + t.trap_step)
  end

  if summary.damaged then
    state.obstacle = t.obstacle_reset
  else
    state.obstacle = min(t.cap, state.obstacle + t.obstacle_step)
  end

  state.treasure_skipped = summary.treasure_existed == true and summary.treasure_entered ~= true
  return state
end

local function spawn_of(run)
  if run == nil then return M.new_state() end
  if type(run) ~= "table" then error("rooms_spawn: run is a table", 3) end
  local state = run.spawn
  if state == nil then return M.new_state() end
  if type(state) ~= "table" then error("rooms_spawn: run.spawn is the run state", 3) end
  return state
end

local function luck_of(run)
  if run == nil or run.luck == nil then return M.tuning.luck_default end
  local luck = run.luck
  if type(luck) ~= "number" then error("rooms_spawn: run.luck is a number", 3) end
  return luck
end

-- The chance functions share the procgen.roomtypes signature: chance(floor, total, run), where
-- run is { spawn = state, luck = number }. The floor number is unused except by the pact.

function M.casino_chance(floor, total, run)
  return spawn_of(run).casino or 0
end

function M.super_treasure_chance(floor, total, run)
  if spawn_of(run).treasure_skipped then return M.tuning.super_treasure_chance end
  return 0
end

function M.trap_chance(floor, total, run)
  local t = M.tuning
  local factor = clamp(t.luck_base - t.luck_slope * luck_of(run), t.luck_min, t.luck_max)
  return clamp((spawn_of(run).trap or 0) * factor, 0, t.cap)
end

function M.obstacle_chance(floor, total, run)
  return spawn_of(run).obstacle or 0
end

function M.pact_chance(floor, total, run)
  if floor >= M.tuning.pact_floor then return M.tuning.pact_chance end
  return 0
end

-- The roomtypes definitions to install later, in order: { { name, def }, ... }. `chance` gets
-- the run so the rules above can read the spawn state and luck.
M.defs = {
  { name = "casino", def = {
    count = M.tuning.casino_count,
    replaces = "shop",
    max_floor = M.tuning.casino_max_floor,
    min_depth = M.tuning.special_depth,
    chance = function(n, total, run) return M.casino_chance(n, total, run) end,
  } },
  { name = "super_treasure", def = {
    count = M.tuning.super_treasure_count,
    replaces = "treasure",
    min_depth = M.tuning.special_depth,
    chance = function(n, total, run) return M.super_treasure_chance(n, total, run) end,
  } },
  { name = "pact", def = {
    count = M.tuning.pact_count,
    min_floor = M.tuning.pact_floor,
    min_depth = M.tuning.special_depth,
    chance = function(n, total, run) return M.pact_chance(n, total, run) end,
  } },
  { name = "trap", def = {
    count = { M.tuning.trap_count_min, M.tuning.trap_count_max },
    max = M.tuning.trap_max,
    distance = "far",
    chance = function(n, total, run) return M.trap_chance(n, total, run) end,
  } },
  { name = "obstacle", def = {
    count = M.tuning.obstacle_count,
    min_depth = M.tuning.special_depth,
    chance = function(n, total, run) return M.obstacle_chance(n, total, run) end,
  } },
}

return M
