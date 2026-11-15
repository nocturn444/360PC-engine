-- A game-provided spec for tools/seed_validator.lua and tests/console/level_hash_check.lua
-- (engine/modules/procgen/README.md): the same templates as tests/console/procgen_check.lua.
local function ex(...)
  local t = {}
  for i, s in ipairs({ ... }) do t[i] = { side = s } end
  return t
end

return {
  templates = {
    { id = "start", type = "start", exits = ex("left", "right", "down") },
    { id = "cross", weight = 3, exits = ex("left", "right", "up", "down") },
    { id = "hall", weight = 3, exits = ex("left", "right") },
    { id = "shaft", weight = 2, exits = ex("up", "down") },
    { id = "big", w = 2, h = 2, exits = { { side = "left", offset = 1 }, { side = "right" },
      { side = "up", offset = 1 }, { side = "down" } } },
    { id = "corner_a", weight = 2, exits = ex("left", "down") },
    { id = "corner_b", weight = 2, exits = ex("right", "up") },
    { id = "shop", type = "shop", exits = ex("left", "right") },
    { id = "item_l", item = true, exits = ex("left") },
    { id = "item_r", item = true, exits = ex("right") },
    { id = "item_u", item = true, exits = ex("up") },
    { id = "boss_l", type = "boss", exits = ex("left") },
    { id = "boss_u", type = "boss", exits = ex("up") },
  },
  abilities = { "dash", "double_jump", "swim" },
  rooms = 16,
}
