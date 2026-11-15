-- level_spec with a rule of the game's that some seeds cannot meet (for the validator's tests).
local base = require("level_spec")
return {
  templates = function() return base.templates end,
  abilities = base.abilities,
  rooms = base.rooms,
  attempts = 2,
  stream = false,
  check = function(map)
    if #map.doors % 2 == 1 then return false, "odd number of doors" end
    return true
  end,
}
