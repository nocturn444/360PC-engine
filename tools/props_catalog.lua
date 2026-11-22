-- Props catalog (PC): writes the catalog of a game's prop types (engine/modules/props) for the
-- level editors, which cannot run the game's Lua: id, label, glyph, colour, category, default
-- size, resize, collision, flags and per-instance fields. Format: docs/PROPS.md.
-- Usage, from the base's root (or anywhere: paths are resolved from this file):
--   luajit tools/props_catalog.lua <game folder> <types module> [-o FILE] [--check]
--     <types module>  a Lua module name inside the game folder (e.g. "rooms_props") that
--                     returns a props registry, or a table with one in its `types` field
--     -o FILE         where to write it (default: stdout)
--     --check         compare with FILE instead of writing it; exit 1 when it is out of date
-- Exits with 0 on success, 1 when --check finds a difference, 2 on a usage or load error.
local here = (arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local base = here .. "/.."

local function die(msg, code) io.stderr:write("props_catalog: " .. msg .. "\n"); os.exit(code or 2) end

local game, module_name, out_path, check = nil, nil, nil, false
local i = 1
while i <= #arg do
  local a = arg[i]
  if a == "-o" then i = i + 1; out_path = arg[i]
  elseif a == "--check" then check = true
  elseif a:sub(1, 1) == "-" then die("unknown option " .. a)
  elseif not game then game = a
  elseif not module_name then module_name = a
  else die("unexpected argument " .. a) end
  i = i + 1
end
if not game or not module_name then
  die("usage: luajit tools/props_catalog.lua <game folder> <types module> [-o FILE] [--check]")
end
if check and not out_path then die("--check needs -o FILE") end

package.path = game .. "/?.lua;" .. game .. "/?/init.lua;" .. base .. "/?.lua;" .. base .. "/?/init.lua;" ..
  package.path

local Save = require("engine.save")
local ok, mod = pcall(require, module_name)
if not ok then die("cannot load " .. module_name .. ": " .. tostring(mod)) end
local registry = type(mod) == "table" and (mod.catalog and mod or mod.types) or nil
if type(registry) ~= "table" or type(registry.catalog) ~= "function" then
  die(module_name .. " returns neither a props registry nor a table with one in `types`")
end

local text = Save.serialize(registry:catalog()) .. "\n"

if check then
  local f = io.open(out_path, "rb")
  local old = f and f:read("*a")
  if f then f:close() end
  if old ~= text then
    io.stderr:write("props_catalog: " .. out_path .. " is out of date; run luajit tools/props_catalog.lua " ..
      game .. " " .. module_name .. " -o " .. out_path .. "\n")
    os.exit(1)
  end
  print("props_catalog: " .. out_path .. " is up to date (" .. #registry:catalog().types .. " types)")
elseif out_path then
  local f = io.open(out_path, "wb")
  if not f then die("cannot write " .. out_path) end
  f:write(text)
  f:close()
  print("props_catalog: wrote " .. out_path)
else
  io.write(text)
end
