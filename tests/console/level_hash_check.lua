-- 360PC-Engine: the PC vs 360 level hash test. Reads a hash list written on the PC by
-- tools/seed_validator.lua (--out level_hashes.txt), generates the same seeds again with the
-- game's spec module and logs every seed whose layout hash or number of attempts differs.
-- Procedure: docs/NEW_GAME.md ("Level hash test").
-- On the PC:      luajit tests/console/level_hash_check.lua <game folder> [hash list]
--                 (from the base's root; the list defaults to <game folder>/level_hashes.txt)
-- On the console: put this file and level_hashes.txt next to the game's main.lua (the spec
--                 module named in the list is already there), add require("level_hash_check")
--                 as the first line of main.lua, and read default.log. It must end with
--                 "== level hashes: 0 of N wrong ==". Remove both files and the line afterwards.
-- Called as a function with a log function and the list's text, it logs there (the tests do).
local arg1, arg2 = ...
local as_function = type(arg1) == "function"
local log = as_function and arg1 or (l360 and l360.log) or print
local text
if as_function then
  text = arg2
elseif love and love.filesystem and love.filesystem.read then
  text = love.filesystem.read("level_hashes.txt")
else
  local game = (arg and arg[1] or "."):gsub("[/\\]+$", "")
  package.path = game .. "/?.lua;" .. game .. "/?/init.lua;./?.lua;./?/init.lua;" .. package.path
  local f = io.open(arg and arg[2] or (game .. "/level_hashes.txt"), "rb")
  if f then text = f:read("*a"); f:close() end
end

local seeds = require("engine.modules.procgen.seeds")
local list, err = seeds.parse(text)
if not list then
  log("[BAD] level hashes: " .. tostring(err))
  log("== level hashes: 1 of 1 wrong ==")
  return 1
end
local ok, spec = pcall(require, list.spec)
if not ok or type(spec) ~= "table" then
  log("[BAD] level hashes: cannot load the spec module " .. list.spec .. ": " .. tostring(spec))
  log("== level hashes: 1 of 1 wrong ==")
  return 1
end
return (seeds.check(list, spec, log))
