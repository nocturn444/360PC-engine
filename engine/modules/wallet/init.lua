-- engine.modules.wallet: a small bag of named integer currencies for a run. The game names
-- them when it makes the wallet (for example `virus`), adds and spends whole amounts, and saves
-- `state()` as plain data through engine.save. A currency it does not know is an error, so a
-- typo cannot quietly spend nothing. A genre module: nothing in engine/ requires it and it
-- knows nothing about a game.
-- Reference: engine/modules/wallet/README.md.
--
--   local wallet = require("engine.modules.wallet")
--   local w = wallet.new({ virus = 0 })
--   w:add("virus", 5)
--   if w:spend("virus", 3) then ... end
local type, floor, tostring = type, math.floor, tostring

local M = {}
local Wallet = {}
Wallet.__index = Wallet

local function is_count(n)
  return type(n) == "number" and n >= 0 and n == floor(n)
end

local function check_name(name)
  if type(name) ~= "string" or name == "" then
    error("wallet: a currency name is a non-empty string", 4)
  end
end

-- wallet.new(initial): initial maps each currency name to its starting whole amount (>= 0).
-- Only the names given exist; any other name is an error when used, so a game declares its
-- currencies once and a typo is noticed.
function M.new(initial)
  if initial == nil then initial = {} end
  if type(initial) ~= "table" then error("wallet: new needs a table of starting amounts", 2) end
  local self = setmetatable({ amounts = {} }, Wallet)
  for name, n in next, initial do
    check_name(name)
    if not is_count(n) then
      error("wallet: starting " .. name .. " must be a whole number >= 0", 2)
    end
    self.amounts[name] = n
  end
  return self
end

function Wallet:_amount(name)
  check_name(name)
  local n = self.amounts[name]
  if n == nil then error("wallet: unknown currency " .. name, 3) end
  return n
end

-- wallet:add(name, n) -> the new amount. n is a whole number >= 0.
function Wallet:add(name, n)
  local have = self:_amount(name)
  if not is_count(n) then error("wallet: add needs a whole amount >= 0", 2) end
  self.amounts[name] = have + n
  return self.amounts[name]
end

-- wallet:get(name) -> amount.
function Wallet:get(name)
  return self:_amount(name)
end

-- wallet:can(name, n) -> true if there are at least n. An invalid n is a programming error.
function Wallet:can(name, n)
  local have = self:_amount(name)
  if not is_count(n) then error("wallet: can needs a whole amount >= 0", 2) end
  return have >= n
end

-- wallet:spend(name, n) -> true and it is taken, or false (nothing changes; never negative).
function Wallet:spend(name, n)
  if not self:can(name, n) then return false end
  self.amounts[name] = self.amounts[name] - n
  return true
end

-- wallet:state() -> a plain { [name] = amount } table for the run's save.
function Wallet:state()
  local out = {}
  for name, n in next, self.amounts do out[name] = n end
  return out
end

-- wallet:set_state(state) puts saved amounts back. A name the wallet does not know is ignored
-- (a save from a version with another currency still loads); a bad amount is an error.
function Wallet:set_state(state)
  if type(state) ~= "table" then error("wallet: set_state needs a table", 2) end
  for name, n in next, state do
    if self.amounts[name] ~= nil then
      if not is_count(n) then
        error("wallet: saved " .. tostring(name) .. " is not a whole number >= 0", 2)
      end
      self.amounts[name] = n
    end
  end
  return self
end

return M
