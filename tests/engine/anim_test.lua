-- anim8 (lib/anim8, unchanged) on the fake love, the engine.anim wrapper, and a static check of
-- what anim8 and engine/ call in love against the console's subset (tools/api_subset_data.lua).
local T = ...
local F = require("fake_love")
F.install({ image_w = 64, image_h = 32 })
local anim = require("engine.anim")
local anim8 = anim.anim8
T.check(anim8._VERSION == "anim8 v2.3.1", "lib/anim8 is v2.3.1")

local img = love.graphics.newImage("sheet.png")
local grid = anim.grid(img, 16, 16)
local set = anim.set(grid, {
  walk = { frames = { "1-4", 1 }, duration = 0.1 },
  die = { frames = { "1-3", 2 }, duration = 0.1, loop = false },
})
T.check(#set.walk.frames == 4 and #set.die.frames == 3, "frames from data")
local x, y, w, h = set.walk.frames[3]:getViewport()
T.check(x == 32 and y == 0 and w == 16 and h == 16, "the third frame's quad")
set.walk:update(0.25)
T.check(set.walk.position == 3, "0.25 s at 0.1 s a frame is the third frame")
set.walk:update(0.2)
T.check(set.walk.position == 1, "it loops")
set.die:update(1)
T.check(set.die.position == 3 and set.die.status == "paused", "loop = false stops on the last frame")
local copy = set.walk:clone()
copy:update(0.1)
T.check(copy.position == 2 and set.walk.position == 1, "clone gives an independent animation")
F.reset_calls()
set.walk:draw(img, 10, 20)
copy:flipH():draw(img, 10, 20)
local d = F.find("draw")
T.check(#d == 2 and d[1][2] == img and d[1][3] == set.walk.frames[1] and d[1][4] == 10, "draw passes image, quad and position")
T.check(d[2][7] == -1 and d[2][9] == 16, "a flipped animation draws with a negative scale")

-- Static check against the subset
package.path = "tools/?.lua;" .. package.path
local data = require("api_subset_data")
local function status(e) return type(e) == "table" and e[1] or e end
local ALIASES = { g = "love.graphics", gfx = "love.graphics", kb = "love.keyboard", ms = "love.mouse",
  js = "love.joystick" }
local function scan(path, found)
  local f = assert(io.open(path, "rb"))
  local src = f:read("*a"); f:close()
  T.check(not src:find("%f[%w]goto%f[%W]") and not src:find("require%(?%s*[\"']ffi[\"']"), path .. ": no goto, no FFI")
  src = src:gsub("%-%-[^\n]*", "")
  for mod, fn in src:gmatch("love%.(%l+)%.([%a_]+)") do found["love." .. mod .. "." .. fn] = true end
  for alias, fn in src:gmatch("%f[%w_]([%l]+)%.([%a_]+)%(") do
    if ALIASES[alias] then found[ALIASES[alias] .. "." .. fn] = true end
  end
end
local function classify(found)
  local by = { full = {}, partial = {}, stub = {}, missing = {} }
  for name in pairs(found) do
    local mod, fn = name:match("^(.*)%.([%a_]+)$")
    local st = data.modules[mod] and status(data.modules[mod][fn]) or "missing"
    by[st][#by[st] + 1] = name
  end
  for _, list in pairs(by) do table.sort(list) end
  return by
end

local found = {}
scan("lib/anim8/anim8.lua", found)
local by = classify(found)
T.check(#by.missing == 0 and #by.stub == 0, "anim8 calls nothing missing or stubbed: " .. table.concat(by.missing, " ") .. table.concat(by.stub, " "))
T.check(table.concat(by.full, " ") == "love.graphics.newQuad" and table.concat(by.partial, " ") == "love.graphics.draw",
  "anim8 uses love.graphics.newQuad and love.graphics.draw only")
T.check(status(data.types.Quad.getViewport) == "full", "and Quad:getViewport")

found = {}
for _, m in ipairs({ "init", "state", "timestep", "input", "camera", "pixel", "layers", "anim", "level" }) do
  scan("engine/" .. m .. ".lua", found)
end
by = classify(found)
T.check(#by.missing == 0, "engine/ calls nothing missing on the console: " .. table.concat(by.missing, " "))
-- stubs on the console by design: there is no keyboard or mouse there
T.check(table.concat(by.stub, " ") == "love.keyboard.isDown love.mouse.getPosition love.mouse.isDown",
  "engine/ only touches the keyboard and mouse stubs: " .. table.concat(by.stub, " "))
for _, m in ipairs({ "isGamepad", "isGamepadDown", "getGamepadAxis" }) do
  T.check(status(data.types.Joystick[m]) == "full", "Joystick:" .. m .. " is in the subset")
end
T.check(status(data.types.Canvas.setFilter) == "partial" and status(data.types.Image.getWidth) == "full",
  "Canvas:setFilter and Image:getWidth are in the subset")
if os.getenv("ENGINE_TEST_VERBOSE") then
  print("     engine/ full: " .. table.concat(by.full, " "))
  print("     engine/ partial: " .. table.concat(by.partial, " "))
end
