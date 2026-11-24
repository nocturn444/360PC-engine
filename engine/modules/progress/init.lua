-- engine.modules.progress: a generic progress layer for achievements, unlocks and choices.
-- Conditions as plain data, run/floor counters of what happened, rules checked at an event, a
-- floor end or a run end, and a weighted pick for content chosen by conditions.
-- A genre module: nothing in engine/ requires it, it needs no other module, it uses no LOVE
-- and nothing random of its own (pick takes an engine.rng stream).
-- Reference: engine/modules/progress/README.md.
--
--   local progress = require("engine.modules.progress")
--   local run, floor = progress.counters.new(), progress.counters.new()
--   run:add("kills", 1); run:mark("items", "spring_heel")
--   local ctx = { run = run, floor = floor, profile = profile, result = "win" }
--   local earned = achievements:check("run_end", ctx, profile.achievements)
--   local boss = progress.pick(bosses, ctx, run.streams:get("final_boss"))
local prefix = (...):gsub("%.init$", "") .. "."

return {
  counters = require(prefix .. "counters"),
  conditions = require(prefix .. "conditions"),
  rules = require(prefix .. "rules"),
  pick = require(prefix .. "pick").pick,
}
