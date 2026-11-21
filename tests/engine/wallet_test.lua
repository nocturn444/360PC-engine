-- engine/modules/wallet: construction and validation, add/get/can/spend, no negative balance,
-- unknown currencies, the plain state for a run save, and a static check of the module.
-- Usage, from the repository root: luajit -joff tests/engine/wallet_test.lua  (ends with "OK:")
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;" .. package.path

local passed = ...
local checks = 0
local T = passed
if not T then
  T = { check = function(cond, what)
    checks = checks + 1
    if not cond then print("FAILED: " .. what); os.exit(1) end
  end }
end

local globals = {}
for k in pairs(_G) do globals[k] = true end
local Save = require("engine.save")
local wallet = require("engine.modules.wallet")

-- Construction and validation
local w = wallet.new({ virus = 3, gold = 0 })
T.check(w:get("virus") == 3 and w:get("gold") == 0, "starting amounts")
T.check(type(wallet.new().state) == "function", "an empty wallet is allowed")
local function refuses(f, what, pattern)
  local ok, err = pcall(f)
  T.check(not ok and tostring(err):find(pattern, 1, true), what .. " (" .. tostring(err) .. ")")
end
refuses(function() wallet.new({ [""] = 0 }) end, "an empty currency name", "non-empty string")
refuses(function() wallet.new({ [1] = 0 }) end, "a numeric currency name", "non-empty string")
refuses(function() wallet.new({ virus = -1 }) end, "a negative start", "whole number >= 0")
refuses(function() wallet.new({ virus = 1.5 }) end, "a fractional start", "whole number >= 0")
refuses(function() wallet.new("virus") end, "a non-table", "table of starting amounts")

-- add, get, can
T.check(w:add("virus", 2) == 5 and w:get("virus") == 5, "add returns the new total")
T.check(w:can("virus", 5) and not w:can("virus", 6), "can")
refuses(function() w:add("virus", -1) end, "adding a negative amount", "whole amount >= 0")
refuses(function() w:add("virus", 0.5) end, "adding a fraction", "whole amount >= 0")
refuses(function() w:can("virus", -1) end, "can with a negative amount", "whole amount >= 0")

-- spend: all or nothing, never negative
T.check(w:spend("virus", 4) and w:get("virus") == 1, "spend success")
T.check(not w:spend("virus", 2) and w:get("virus") == 1, "spend too much: false, unchanged")
T.check(w:spend("virus", 1) and w:get("virus") == 0, "spend down to zero")
T.check(not w:spend("virus", 1) and w:get("virus") == 0, "never negative: " .. w:get("virus"))

-- Unknown currencies
refuses(function() return w:get("bones") end, "get an unknown currency", "unknown currency")
refuses(function() return w:add("bones", 1) end, "add to an unknown currency", "unknown currency")
refuses(function() return w:can("bones", 0) end, "can with an unknown currency", "unknown currency")
refuses(function() return w:spend("bones", 1) end, "spend an unknown currency", "unknown currency")

-- state / set_state: plain data through engine.save
local state = w:state()
state.virus = 99
T.check(w:get("virus") == 0, "state is a copy")
w:add("virus", 7); w:add("gold", 2)
local text = Save.serialize(w:state())
local ok, saved = Save.parse(text)
T.check(ok and saved.virus == 7 and saved.gold == 2, "state is plain data for a run save")
local back = wallet.new({ virus = 0, gold = 0 })
back:set_state(saved)
T.check(back:get("virus") == 7 and back:get("gold") == 2, "set_state restores")
back:set_state({ virus = 1, bones = 50 })
T.check(back:get("virus") == 1 and back:get("gold") == 2, "set_state ignores an unknown currency")
refuses(function() back:set_state({ virus = -1 }) end, "set_state with a bad amount", "whole number >= 0")
refuses(function() back:set_state(3) end, "set_state with a non-table", "needs a table")

-- Deterministic: the same operations give the same state text
local function sequence()
  local q = wallet.new({ virus = 0 })
  for i = 1, 10 do q:add("virus", i % 3); if i % 2 == 0 then q:spend("virus", 1) end end
  return Save.serialize(q:state())
end
T.check(sequence() == sequence(), "same operations, same state text")

-- Static checks
local f = assert(io.open("engine/modules/wallet/init.lua", "rb"))
local src = f:read("*a"):gsub("%-%-[^\n]*", ""); f:close()
T.check(not src:find("%f[%w]goto%f[%W]") and not src:find("ffi") and not src:find("%f[%w_]jit%."),
  "wallet: no goto, FFI or jit")
T.check(not src:find("%f[%w_]love%f[%W]") and not src:find("math%.random") and not src:find("os%.time"),
  "wallet: no love, nothing random of its own, no clock")
T.check(not src:find("[^%w_]pairs%("), "wallet: no pairs()")
if T.no_new_globals then T.no_new_globals(globals) end

if not passed then print(string.format("OK: %d checks; wallet", checks)) end
