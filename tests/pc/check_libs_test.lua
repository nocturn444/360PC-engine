-- tools/check_libs.lua: passes on the repository, and finds each kind of problem in a copy with
-- a broken library. Usage, from the repository root: luajit tests/pc/check_libs_test.lua
local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then error("FAILED: " .. what, 2) end
end
local function run(dir)
  local p = assert(io.popen("cd " .. dir .. " && luajit tools/check_libs.lua 2>&1; echo \"exit=$?\""))
  local out = p:read("*a"); p:close()
  return out
end

local here = run(".")
check(here:find("\nOK: %d+ libraries") or here:find("^OK: %d+ libraries"), "the repository passes: " .. here)
check(here:find("exit=0", 1, true), "and exits with 0")

local tmp = os.getenv("TMPDIR") or "/tmp"
local dir = tmp .. "/check_libs_test_" .. tostring(os.time())
assert(os.execute("mkdir -p " .. dir .. "/tools " .. dir .. "/lib/bad " .. dir .. "/lib/good") == 0)
assert(os.execute("cp tools/check_libs.lua tools/api_subset_data.lua " .. dir .. "/tools/") == 0)
local function write(path, text)
  local f = assert(io.open(dir .. "/" .. path, "wb")); f:write(text); f:close()
end
write("lib/good/LICENSE", "MIT")
write("lib/good/good.lua", "local q = love.graphics.newQuad(0, 0, 1, 1, 2, 2)\n-- love.physics.newWorld in a comment is fine\nreturn q")
write("lib/bad/bad.lua", table.concat({
  "local ffi = require('ffi')",
  "goto skip",
  "::skip::",
  "local w = love.physics.newWorld(0, 0)",
  "love.graphics.thisDoesNotExist()",
  "love.graphics.setScissor(0, 0, 1, 1)",
  "if jit.status() then end",
}, "\n"))
write("lib/README.md", "| `good/` | good | v1.0.0 (`abcdef1`) | MIT | ok |\n| `bad/` | bad | | MIT | no |\n")
write("THIRD_PARTY_NOTICES.md", "good, commit `" .. ("a"):rep(40) .. "`, copied to `lib/good/`\n")
local out = run(dir)
os.execute("rm -rf " .. dir)
check(out:find("exit=1", 1, true) and out:find("FAILED: ", 1, true), "a broken library fails: " .. out)
check(not out:find("lib/good", 1, true), "the good library has no problem")
for _, want in ipairs({
  "lib/bad: no license file",
  "lib/bad: the lib/README.md row needs a version and a pinned commit",
  "lib/bad: THIRD_PARTY_NOTICES.md does not name lib/bad/",
  "lib/bad: bad.lua uses the FFI",
  "lib/bad: bad.lua uses goto",
  "lib/bad: bad.lua uses jit.*",
  "lib/bad: bad.lua uses love.physics.newWorld: love.physics is not on the console",
  "lib/bad: bad.lua uses love.graphics.thisDoesNotExist, which the console does not have",
  "warning: lib/bad: bad.lua uses love.graphics.setScissor, a stub on the console",
}) do
  check(out:find(want, 1, true), "reports: " .. want)
end
print("OK: " .. checks .. " checks")
