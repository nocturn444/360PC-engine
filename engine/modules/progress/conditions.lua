-- engine.modules.progress.conditions: rules as plain data, tested against what a run did and
-- what the profile has. A condition is a table whose first item is its kind; all / any / none
-- nest arrays of conditions. The engine knows nothing about the game's names: the game picks
-- the counter keys and set names, and registers predicate functions by name for the escape
-- hatch ("test").
-- Reference: engine/modules/progress/README.md.
--
--   local conditions = require("engine.modules.progress").conditions
--   conditions.compile({ "all", { "result", value = "win" },
--     { "count", key = "kills", at_least = 10 } })                       -- validates, names the path
--   conditions.test(c, { run = run, floor = floor, profile = profile, result = "win" })
local type, tostring, next = type, tostring, next

local M = {}

local SCOPES = { run = true, floor = true, profile = true }
local RESULTS = { win = true, loss = true }

local function bad(path, message)
  error("progress.conditions: " .. path .. ": " .. message, 0)
end

local function array_of_ids(t)
  if type(t) ~= "table" then return false end
  for i = 1, #t do
    if type(t[i]) ~= "string" or t[i] == "" then return false end
  end
  return true
end

local function check_scope(c, path)
  local scope = c.scope
  if scope ~= nil and not SCOPES[scope] then
    bad(path .. ".scope", "\"run\", \"floor\" or \"profile\"")
  end
end

local function check_range(c, path, what)
  if c.at_least == nil and c.at_most == nil then
    bad(path, what .. " needs at_least or at_most")
  end
  if c.at_least ~= nil and type(c.at_least) ~= "number" then
    bad(path .. ".at_least", "a number")
  end
  if c.at_most ~= nil and type(c.at_most) ~= "number" then
    bad(path .. ".at_most", "a number")
  end
end

local compile_condition

compile_condition = function(c, path, tests)
  if type(c) ~= "table" then bad(path, "a condition is a table") end
  local kind = c[1]
  if type(kind) ~= "string" then bad(path .. "[1]", "the condition kind is a string") end

  if kind == "all" or kind == "any" or kind == "none" then
    for i = 2, #c do
      compile_condition(c[i], path .. "[" .. i .. "]", tests)
    end
  elseif kind == "count" then
    if type(c.key) ~= "string" or c.key == "" then bad(path .. ".key", "a non-empty string") end
    check_scope(c, path)
    check_range(c, path, "count")
  elseif kind == "has" then
    if type(c.set) ~= "string" or c.set == "" then bad(path .. ".set", "a non-empty string") end
    if type(c.id) ~= "string" or c.id == "" then bad(path .. ".id", "a non-empty string") end
    check_scope(c, path)
  elseif kind == "build" then
    if c.all ~= nil and not array_of_ids(c.all) then bad(path .. ".all", "an array of ids (strings)") end
    if c.any ~= nil and not array_of_ids(c.any) then bad(path .. ".any", "an array of ids (strings)") end
    if c.all == nil and c.any == nil then bad(path, "build needs all or any") end
    if c.set ~= nil and (type(c.set) ~= "string" or c.set == "") then
      bad(path .. ".set", "a non-empty string")
    end
    if c.at_least ~= nil and type(c.at_least) ~= "number" then
      bad(path .. ".at_least", "a number")
    end
    check_scope(c, path)
  elseif kind == "size" then
    if type(c.set) ~= "string" or c.set == "" then bad(path .. ".set", "a non-empty string") end
    check_scope(c, path)
    check_range(c, path, "size")
  elseif kind == "result" then
    if not RESULTS[c.value] then bad(path .. ".value", "\"win\" or \"loss\"") end
  elseif kind == "test" then
    if type(c.name) ~= "string" or c.name == "" then bad(path .. ".name", "a non-empty string") end
    if tests ~= nil and tests[c.name] == nil then
      bad(path .. ".name", "no test named " .. c.name)
    end
  else
    bad(path .. "[1]", "unknown condition kind " .. tostring(kind))
  end
  return c
end

-- conditions.compile(c, path, tests) -> c, after checking it. `path` names the condition in an
-- error (default "when", so a nested field reads "when[2].at_least"); when `tests` is given, a
-- "test" condition must name one of its functions.
function M.compile(c, path, tests)
  return compile_condition(c, path or "when", tests)
end

local function profile_counter(profile, key)
  if profile == nil then return 0 end
  local counters = profile.counters
  if counters == nil then return 0 end
  local value = counters[key]
  if type(value) == "number" then return value end
  return 0
end

local function counter_value(scope, ctx, key)
  if scope == "run" then
    local counters = ctx.run
    if counters == nil then return 0 end
    return counters:get(key)
  elseif scope == "floor" then
    local counters = ctx.floor
    if counters == nil then return 0 end
    return counters:get(key)
  end
  return profile_counter(ctx.profile, key)
end

local function set_has(scope, ctx, set, id)
  if scope == "run" then
    return ctx.run ~= nil and ctx.run:has(set, id)
  elseif scope == "floor" then
    return ctx.floor ~= nil and ctx.floor:has(set, id)
  end
  local profile = ctx.profile
  if profile == nil then return false end
  local ids = profile[set]
  return ids ~= nil and ids[id] == true
end

local function set_size(scope, ctx, set)
  if scope == "run" then
    if ctx.run == nil then return 0 end
    return ctx.run:count(set)
  elseif scope == "floor" then
    if ctx.floor == nil then return 0 end
    return ctx.floor:count(set)
  end
  local profile = ctx.profile
  if profile == nil then return 0 end
  local ids = profile[set]
  if ids == nil then return 0 end
  local n = 0
  for _ in next, ids do n = n + 1 end
  return n
end

local function test_condition(c, ctx, tests)
  local kind = c[1]
  if kind == "all" then
    for i = 2, #c do
      if not test_condition(c[i], ctx, tests) then return false end
    end
    return true
  elseif kind == "any" then
    for i = 2, #c do
      if test_condition(c[i], ctx, tests) then return true end
    end
    return false
  elseif kind == "none" then
    for i = 2, #c do
      if test_condition(c[i], ctx, tests) then return false end
    end
    return true
  elseif kind == "count" then
    local value = counter_value(c.scope or "run", ctx, c.key)
    if c.at_least ~= nil and value < c.at_least then return false end
    if c.at_most ~= nil and value > c.at_most then return false end
    return true
  elseif kind == "has" then
    return set_has(c.scope or "profile", ctx, c.set, c.id)
  elseif kind == "build" then
    local scope, set = c.scope or "run", c.set or "items"
    local all = c.all
    if all ~= nil then
      for i = 1, #all do
        if not set_has(scope, ctx, set, all[i]) then return false end
      end
    end
    local any = c.any
    if any ~= nil then
      local need = c.at_least or 1
      local found = 0
      for i = 1, #any do
        if set_has(scope, ctx, set, any[i]) then
          found = found + 1
          if found >= need then break end
        end
      end
      if found < need then return false end
    end
    return true
  elseif kind == "size" then
    local value = set_size(c.scope or "run", ctx, c.set)
    if c.at_least ~= nil and value < c.at_least then return false end
    if c.at_most ~= nil and value > c.at_most then return false end
    return true
  elseif kind == "result" then
    return ctx.result == c.value
  elseif kind == "test" then
    local predicate = tests and tests[c.name]
    if predicate == nil then
      error("progress.conditions: no test named " .. tostring(c.name), 3)
    end
    return predicate(ctx) and true or false
  end
  error("progress.conditions: unknown condition kind " .. tostring(kind), 3)
end

-- conditions.test(c, ctx, tests) -> true or false. ctx: { run = counters, floor = counters,
-- profile = table, result = "win" | "loss" | nil }. Missing counters and sets read as 0 / empty.
-- Allocates nothing on the normal path (it only walks the data).
function M.test(c, ctx, tests)
  return test_condition(c, ctx, tests)
end

return M
