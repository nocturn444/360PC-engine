-- The engine's tests, on plain LuaJIT with a fake love (tests/engine/fake_love.lua).
-- Usage, from the repository root: luajit -joff tests/engine/run.lua [test name...]
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
  "layers_test", "anim_test", "engine_test", "demo_test" }
if arg[1] then names = { unpack(arg) } end

local failed = 0
for _, name in ipairs(names) do
  local before = T.checks
  local ok, err = xpcall(function() assert(loadfile("tests/engine/" .. name .. ".lua"))(T) end, debug.traceback)
  if ok then
    print(string.format("ok   %-14s %3d checks", name, T.checks - before))
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n" .. tostring(err))
  end
end
if failed > 0 then print("FAILED: " .. failed .. " test files"); os.exit(1) end
print(string.format("OK: %d checks in %d test files", T.checks, #names))
