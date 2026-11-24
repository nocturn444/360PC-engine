-- engine.modules.progress.rules: achievements and unlocks as a list of rules checked at a
-- moment ("event", "floor_end" or "run_end"). A rule earns an id: for an unlock that id is the
-- tag content declares with `unlock = id`. Earned ids go into a profile set the game owns; the
-- module keeps nothing and writes nothing to disk.
-- Reference: engine/modules/progress/README.md.
--
--   local rules = progress.rules.new(list, { tests = { ... } })
--   local earned = rules:check("floor_end", ctx, profile.achievements)   -- only the new ones
--   if rules:is_earned("first_win", profile.achievements) then ... end
local type, tostring = type, tostring

local conditions = require((...):gsub("rules$", "conditions"))

local M = {}
local Rules = {}
Rules.__index = Rules

local MOMENTS = { event = true, floor_end = true, run_end = true }
local EMPTY = {}

local function check_ids(list, path)
  if type(list) ~= "table" then error("progress.rules: " .. path .. " is an array of ids", 3) end
  for i = 1, #list do
    if type(list[i]) ~= "string" or list[i] == "" then
      error("progress.rules: " .. path .. "[" .. i .. "] is a non-empty id", 3)
    end
  end
end

-- rules.new(list, opts) -> rules. Each rule:
--   id        unique string; for an unlock it is the tag (`unlock = id`)
--   when      a condition (see conditions.lua)
--   at        "event", "floor_end" or "run_end" (default "run_end")
--   requires  optional array of rule ids that must already be earned (chains)
--   hidden    the game shows "???" until it is earned
--   anything else (name, description, what it unlocks, icon) is the game's.
-- opts.tests: predicates by name for conditions of kind "test".
function M.new(list, opts)
  if type(list) ~= "table" then error("progress.rules: new needs an array of rules", 2) end
  opts = opts or {}
  if type(opts) ~= "table" then error("progress.rules: opts is a table", 2) end
  local tests = opts.tests or {}
  if type(tests) ~= "table" then error("progress.rules: opts.tests is a table", 2) end

  local self = setmetatable({ list = {}, by_id = {}, tests = tests }, Rules)
  for i = 1, #list do
    local rule = list[i]
    if type(rule) ~= "table" then error("progress.rules: rule " .. i .. " is not a table", 2) end
    if type(rule.id) ~= "string" or rule.id == "" then
      error("progress.rules: rule " .. i .. " needs a non-empty string id", 2)
    end
    if self.by_id[rule.id] ~= nil then
      error("progress.rules: two rules have the id " .. rule.id, 2)
    end
    if type(rule.when) ~= "table" then
      error("progress.rules: rule " .. rule.id .. ": when is a condition", 2)
    end
    local at = rule.at or "run_end"
    if not MOMENTS[at] then
      error("progress.rules: rule " .. rule.id .. ".at: \"event\", \"floor_end\" or \"run_end\"", 2)
    end
    conditions.compile(rule.when, "rule " .. rule.id .. ".when", tests)
    if rule.requires ~= nil then check_ids(rule.requires, "rule " .. rule.id .. ".requires") end
    self.list[#self.list + 1] = rule
    self.by_id[rule.id] = rule
  end
  for i = 1, #self.list do
    local requires = self.list[i].requires
    if requires ~= nil then
      for j = 1, #requires do
        if self.by_id[requires[j]] == nil then
          error("progress.rules: rule " .. self.list[i].id .. ".requires: no rule " .. requires[j], 2)
        end
      end
    end
  end
  return self
end

local function ready(rule, set)
  local requires = rule.requires
  if requires == nil then return true end
  for i = 1, #requires do
    if set[requires[i]] ~= true then return false end
  end
  return true
end

-- rules:check(moment, ctx, set) -> an array of the rules earned now, in list order. Every rule
-- with `at == moment` is tested, plus every "event" rule at "floor_end" and "run_end". Earned
-- ids are written to `set` (the game passes profile.achievements or profile.unlocks). When
-- nothing is new it returns one shared empty table.
function Rules:check(moment, ctx, set)
  if not MOMENTS[moment] then
    error("progress.rules: the moment is \"event\", \"floor_end\" or \"run_end\"", 2)
  end
  if type(set) ~= "table" then
    error("progress.rules: check needs the profile set (a table)", 2)
  end
  local earned = nil
  for i = 1, #self.list do
    local rule = self.list[i]
    if set[rule.id] ~= true then
      local at = rule.at or "run_end"
      if at == moment or (at == "event" and moment ~= "event") then
        if ready(rule, set) and conditions.test(rule.when, ctx, self.tests) then
          set[rule.id] = true
          if earned == nil then earned = {} end
          earned[#earned + 1] = rule
        end
      end
    end
  end
  return earned or EMPTY
end

-- rules:is_earned(id, set) -> true when the profile set holds the id. An id that is not in this
-- list is an error (the set belongs to this list).
function Rules:is_earned(id, set)
  if self.by_id[id] == nil then error("progress.rules: no rule " .. tostring(id), 2) end
  return set ~= nil and set[id] == true
end

return M
