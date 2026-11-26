-- examples/rooms: every template machine (and shop offer and casino machine) stands on solid floor, also once the room's up/down
-- doors are opened (the play state opens columns 9..11 of the cell in the first or last row).
-- Usage, from the repository root: luajit -joff tests/pc/rooms_machine_floor_test.lua   (must end with "OK:")
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./examples/rooms/?.lua;" .. package.path
local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print("FAILED: " .. what); os.exit(1) end
end

local CW = 20   -- cell width in tiles, as in rooms_play.lua
local data = require("rooms_data")
local machines = 0
for _, t in ipairs(data.templates()) do
  local mt = t.machine
  if mt or t.offers or t.casino then
    if mt then machines = machines + 1 end
    local rows = {}
    for i, row in ipairs(t.rows) do rows[i] = row end
    -- open every up/down door exactly like build_rows in rooms_play.lua
    for _, exit in ipairs(t.exits) do
      if exit.side == "up" or exit.side == "down" then
        local r = exit.side == "up" and 1 or #rows
        for k = 9, 11 do
          local x = (exit.offset or 0) * CW + k
          rows[r] = rows[r]:sub(1, x - 1) .. "." .. rows[r]:sub(x + 1)
        end
      end
    end
    if mt then
      local below = rows[mt.ty + 1] and rows[mt.ty + 1]:sub(mt.tx, mt.tx)
      check(below == "#" or below == "=",
        t.id .. ": machine at " .. mt.tx .. "," .. mt.ty .. " stands on floor (got '" .. tostring(below) .. "')")
    end
    -- the shop's offers and the casino's machines too
    local spots = {}
    for _, o in ipairs(t.offers or {}) do spots[#spots + 1] = o end
    for _, o in ipairs(t.casino or {}) do spots[#spots + 1] = o end
    for _, o in ipairs(spots) do
      local under = rows[o.ty + 1] and rows[o.ty + 1]:sub(o.tx, o.tx)
      check(under == "#" or under == "=",
        t.id .. ": spot at " .. o.tx .. "," .. o.ty .. " stands on floor (got '" .. tostring(under) .. "')")
    end
  end
end
check(machines >= 4, "the shop variants have machines (" .. machines .. ")")
print("OK: " .. checks .. " checks")
