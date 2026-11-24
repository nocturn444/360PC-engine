-- engine.modules.progress.pick: choose one entry of a list by its `when` condition, then by its
-- `priority` (only the highest counts) and a weighted draw with an engine.rng stream to break
-- ties. The same rng state and ctx give the same entry on PC and console. Used for a final boss
-- and reusable for special rooms or endings.
-- Reference: engine/modules/progress/README.md.
--
--   local boss = progress.pick(list, ctx, run.streams:get("final_boss"))
local type, tostring = type, tostring

local conditions = require((...):gsub("pick$", "conditions"))

local M = {}

local function weight_of(entry, i)
  local weight = entry.weight
  if weight == nil then return 1 end
  if type(weight) ~= "number" or weight < 0 then
    error("progress.pick: entry " .. i .. ": weight is a number >= 0", 4)
  end
  return weight
end

-- progress.pick(list, ctx, rng, opts) -> an entry, or nil when none matches. Each entry may have
-- `when` (nil: always), `priority` (default 0) and `weight` (default 1; 0 is never picked).
-- opts.tests: predicates for conditions of kind "test". Only the entries at the highest
-- priority count; among them the rng draws by weight. One candidate: no draw.
function M.pick(list, ctx, rng, opts)
  if type(list) ~= "table" then error("progress.pick: needs an array of entries", 2) end
  if rng == nil then error("progress.pick: needs an rng stream", 2) end
  local tests = opts and opts.tests

  local best, best_priority, best_count, candidates = nil, nil, 0, nil
  for i = 1, #list do
    local entry = list[i]
    if type(entry) ~= "table" then error("progress.pick: entry " .. i .. " is not a table", 2) end
    local matches = entry.when == nil or conditions.test(entry.when, ctx, tests)
    if matches then
      local priority = entry.priority or 0
      if type(priority) ~= "number" then
        error("progress.pick: entry " .. i .. ".priority is a number", 2)
      end
      if best_priority == nil or priority > best_priority then
        best, best_priority, best_count, candidates = entry, priority, 1, nil
      elseif priority == best_priority then
        if best_count == 1 then candidates = { best } end
        best_count = best_count + 1
        candidates[best_count] = entry
      end
    end
  end

  if best == nil then return nil end
  if best_count == 1 then
    if weight_of(best, 1) <= 0 then return nil end
    return best
  end

  local weights, total = {}, 0
  for i = 1, best_count do
    local weight = weight_of(candidates[i], i)
    weights[i] = weight
    total = total + weight
  end
  if total <= 0 then return nil end
  local _, index = rng:weighted(weights)
  return candidates[index]
end

return M
