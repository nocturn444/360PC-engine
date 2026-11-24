-- The engine's tests, on plain LuaJIT with a fake love (tests/engine/fake_love.lua).
-- Usage, from the repository root: luajit -joff tests/engine/run.lua [test name...]
-- Without -joff it passes too: rng_test then runs with the JIT (its numbers have to be the same
-- both ways); the other files always run without it, because their "allocates nothing" checks
-- count the collector's bytes and the JIT's traces use them too.
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;" .. package.path

local T = { checks = 0 }
function T.check(cond, what)
  T.checks = T.checks + 1
  if not cond then error("FAILED: " .. what, 2) end
end
function T.near(a, b, what, eps)
  T.checks = T.checks + 1
  if math.abs(a - b) > (eps or 1e-6) then
    error(string.format("FAILED: %s (got %s, expected %s)", what, tostring(a), tostring(b)), 2)
  end
end
-- Globals the engine may not create
function T.no_new_globals(before)
  for k in pairs(_G) do
    if not before[k] then error("FAILED: the engine created the global " .. tostring(k), 2) end
  end
end

local names = { "state_test", "timestep_test", "input_test", "camera_test", "pixel_test",
  "layers_test", "anim_test", "entity_test", "modifiers_test", "rng_test", "save_test", "ui_test", "pixelgrid_test", "softbody_test", "softbody_shape_test", "wallet_test", "rooms_test", "tune_test", "text_test", "audio_test", "cutscene_test", "platformer_test", "combat_test", "attacks_test", "behaviours_test", "brains_test", "boss_test", "procgen_test", "floors_test", "roomtypes_run_test", "items_test", "progress_test", "seeds_test", "debug_test", "level_test", "engine_test", "demo_test", "autopause_test", "props_test" }
if arg[1] then names = { unpack(arg) } end

local jit_on = jit and jit.status()
local failed = 0
for _, name in ipairs(names) do
  if jit then
    if jit_on and name == "rng_test" then jit.on() else jit.off() end
  end
  local before = T.checks
  local ok, err = xpcall(function() assert(loadfile("tests/engine/" .. name .. ".lua"))(T) end, debug.traceback)
  if ok then
    print(string.format("ok   %-15s %3d checks", name, T.checks - before))
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n" .. tostring(err))
  end
end
if failed > 0 then print("FAILED: " .. failed .. " test files"); os.exit(1) end
print(string.format("OK: %d checks in %d test files", T.checks, #names))
