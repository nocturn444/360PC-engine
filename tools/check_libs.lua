-- check_libs: the rules every third-party library in lib/ follows (objective 16).
-- Usage, from the repository root: luajit tools/check_libs.lua
-- Ends with "OK: <n> libraries" or lists what is wrong and exits with 1.
--
-- For each folder lib/<name>/:
--   * a license file is there (LICENSE*, COPYING*, *LICENSE*.txt);
--   * lib/README.md has a row for it with a version and a pinned commit;
--   * THIRD_PARTY_NOTICES.md names lib/<name>/ with a full 40-hex commit;
--   * its Lua files use no FFI, no goto and no jit.* (the console runs the LuaJIT interpreter);
--   * every love.<module>.<function> it names is in the console subset (tools/api_subset_data.lua):
--     a missing one or one in an absent module is an error, a stub is a warning.
-- The calls a library makes through objects (image:getWidth()) cannot be seen without running
-- it: the engine's tests and tools/compat_check.lua on LÖVE cover those.
package.path = "./tools/?.lua;" .. package.path
local data = require("api_subset_data")

local errors, warnings = {}, {}
local function err(lib, text) errors[#errors + 1] = "lib/" .. lib .. ": " .. text end
local function warn(lib, text) warnings[#warnings + 1] = "lib/" .. lib .. ": " .. text end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return s
end
local function list(cmd)
  local out, p = {}, assert(io.popen(cmd))
  for line in p:lines() do out[#out + 1] = line end
  p:close()
  table.sort(out)
  return out
end

local readme = read("lib/README.md") or ""
local notices = read("THIRD_PARTY_NOTICES.md") or ""
local libs = list("find lib -mindepth 1 -maxdepth 1 -type d -printf '%f\\n'")
if #libs == 0 then errors[#errors + 1] = "lib/: no libraries found (run from the repository root)" end

local function status(entry)
  if type(entry) == "table" then return entry[1] end
  return entry
end

for _, lib in ipairs(libs) do
  local files = list("find lib/" .. lib .. " -type f")
  local license = false
  for _, f in ipairs(files) do
    local base = f:match("[^/]+$"):upper()
    if base:find("LICENSE", 1, true) or base:find("COPYING", 1, true) then license = true end
  end
  if not license then err(lib, "no license file") end

  local row
  for line in readme:gmatch("[^\n]+") do
    if line:find("| `" .. lib .. "/` |", 1, true) then row = line end
  end
  if not row then
    err(lib, "no row in lib/README.md")
  elseif not row:find("v?%d+%.%d+[%.%d]*") or not row:find("`%x%x%x%x%x%x%x+`") then
    err(lib, "the lib/README.md row needs a version and a pinned commit")
  end
  local pinned = false
  for line in notices:gmatch("[^\n]+") do
    if line:find("lib/" .. lib .. "/", 1, true) and line:find("%x" .. ("%x"):rep(39)) then pinned = true end
  end
  if not pinned then err(lib, "THIRD_PARTY_NOTICES.md does not name lib/" .. lib .. "/ with a full commit") end

  for _, f in ipairs(files) do
    if f:match("%.lua$") then
      local src = (read(f) or ""):gsub("%-%-%[(=*)%[.-%]%1%]", ""):gsub("%-%-[^\n]*", "")
      local short = f:sub(#("lib/" .. lib .. "/") + 1)
      if src:find("require%s*%(?%s*[\"']ffi[\"']") then err(lib, short .. " uses the FFI") end
      if src:find("%f[%w_]goto%f[^%w_]") then err(lib, short .. " uses goto") end
      if src:find("%f[%w_]jit%.") then err(lib, short .. " uses jit.*") end
      local seen = {}
      for mod, fn in src:gmatch("%f[%w_]love%.([%a_][%w_]*)%.([%a_][%w_]*)") do
        local name = "love." .. mod
        local key = name .. "." .. fn
        if not seen[key] then
          seen[key] = true
          if data.absent_modules[name] then
            err(lib, short .. " uses " .. key .. ": " .. name .. " is not on the console")
          elseif data.modules[name] then
            local s = status(data.modules[name][fn])
            if s == nil then err(lib, short .. " uses " .. key .. ", which the console does not have")
            elseif s == "stub" then warn(lib, short .. " uses " .. key .. ", a stub on the console") end
          end
        end
      end
    end
  end
end

for _, w in ipairs(warnings) do print("warning: " .. w) end
if #errors > 0 then
  for _, e in ipairs(errors) do print("ERROR: " .. e) end
  print("FAILED: " .. #errors .. " problems in " .. #libs .. " libraries")
  os.exit(1)
end
print("OK: " .. #libs .. " libraries (" .. table.concat(libs, ", ") .. ")")
