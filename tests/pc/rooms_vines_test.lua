-- examples/rooms vines (rooms_vines): the `up` input action, a `vine` placement in the tall
-- room, building the room's list from the template (or from a live props set), grabbing with
-- up / down, climbing at the prop's speed, swinging with left / right under the maximum angle,
-- jump releasing with the pendulum's horizontal speed, down at the bottom end releasing, and
-- nothing allocated per frame while on a vine.
-- Usage, from the repository root: luajit -joff tests/pc/rooms_vines_test.lua   (must end with "OK:")
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./examples/rooms/?.lua;" .. package.path
local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print("FAILED: " .. what); os.exit(1) end
end
local function near(a, b, what, eps)
  checks = checks + 1
  if math.abs(a - b) > (eps or 1e-6) then
    print(string.format("FAILED: %s (got %s, expected %s)", what, tostring(a), tostring(b)))
    os.exit(1)
  end
end
local function read(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local d = f:read("*a"); f:close(); return d
end

local V = require("rooms_vines")
local softbody = require("engine.modules.softbody")
local data = require("rooms_data")
local props = require("rooms_props")
local DT, JUMP = 1 / 60, 260

-- The action exists, and the tall room places a vine
local main = read("examples/rooms/main.lua")
check(main:find("up = { keys = { \"up\", \"w\" }, buttons = { \"dpup\" }, axes = { \"lefty-\" } }", 1, true),
  "main.lua has the up action (keys, d-pad and left stick up)")
local tall
for _, t in ipairs(data.templates()) do if t.id == "tall" then tall = t end end
check(tall and tall.props and tall.props[1] and tall.props[1].type == "vine", "the tall room places a vine")
check(props.types:get("vine").flags.climbable, "the vine type is climbable")

-- Building from the template: the prop's tiles become pixels, with the type's defaults
local vine = { type = "vine", tx = 10, ty = 2, h = 10 }
local self = { slime = softbody.new({ x = 152, y = 168 }) }
V.build(self, { props = { vine } }, data.tile_size)
check(#self.vines == 1, "one vine from the template")
local v = self.vines[1]
near(v.top_x, 152, "top x: the centre of tile 10")
near(v.top_y, 16, "top y: tile 2")
near(v.bottom_y, 176, "bottom y: 10 tiles down")
near(v.speed, 60, "the default climbing speed")
check(v.swing == true, "swing is on by default")

-- A live props set, when the play state has one, wins over the template (and keeps its fields)
local fake_set = { count = function() return 2 end, at = function(_, i)
  if i == 1 then return { type = "spike", x = 0, y = 0, w = 16, h = 16, fields = {} } end
  return { type = "vine", x = 32, y = 48, w = 16, h = 64, fields = { speed = 120, swing = false } }
end }
local with_set = { slime = softbody.new({ x = 40, y = 80 }), props = fake_set }
V.build(with_set, { props = { vine } }, data.tile_size)
check(#with_set.vines == 1 and with_set.vines[1].x == 32 and with_set.vines[1].speed == 120
  and with_set.vines[1].swing == false, "the live props set is used when it exists")

-- An input stand-in: the fields the vine update reads
local Input = {}
Input.__index = Input
function Input.new() return setmetatable({ down_ = {}, pressed_ = {}, axis_ = {} }, Input) end
function Input:down(name) return self.down_[name] == true end
function Input:pressed(name) return self.pressed_[name] == true end
function Input:axis(name) return self.axis_[name] or 0 end
function Input:clear() for k in pairs(self.pressed_) do self.pressed_[k] = nil end end
local function frame(s, input, jump)
  V.update(s, DT, input, jump or JUMP)
  s.slime:step(DT)
  input:clear()
end
local function grab_at(cx, cy)
  local s = { slime = softbody.new({ x = cx, y = cy }) }
  V.build(s, { props = { vine } }, data.tile_size)
  local input = Input.new()
  input.pressed_.up = true
  frame(s, input)
  return s, input
end

-- Grab and climb: up moves the slime up along the vine at the prop's speed
local s, input = grab_at(152, 168)
check(s.vine and s.vine.top_x == 152, "up on a vine grabs it")
near(s.slime.gravity, 0, "gravity is cancelled while it holds")
local x0, y0 = s.slime:center()
near(s.vine_len, 152, "the grab point is the distance from the top", 0.01)
input.down_.up = true
for _ = 1, 30 do frame(s, input) end
local x1, y1 = s.slime:center()
near(y0 - y1, 30, "climbing up 30 steps at 60 px/s", 0.2)
near(x1, v.top_x, "it climbs along the vine", 0.01)
for _ = 1, 150 do frame(s, input) end
near(s.vine_len, V.tuning.min_length, "the top of the vine stops it", 0.01)

-- Swinging: left / right pump the pendulum, and the angle never passes the maximum
s, input = grab_at(152, 92)
input.down_.up = false
input.axis_.move_x = 1
local max_seen = 0
for _ = 1, 180 do
  frame(s, input)
  if math.abs(s.vine_angle) > max_seen then max_seen = math.abs(s.vine_angle) end
end
check(max_seen > 0.5, "holding right builds up the swing (" .. max_seen .. ")")
check(max_seen <= V.tuning.max_angle + 1e-9, "the swing stays under the maximum angle (" .. max_seen .. ")")
input.axis_.move_x = -1
for _ = 1, 180 do
  frame(s, input)
  check(math.abs(s.vine_angle) <= V.tuning.max_angle + 1e-9, "and under it the other way")
end

-- Jump: it lets go with the pendulum's tangential speed plus the normal jump
s, input = grab_at(152, 92)
input.down_.up = false
input.axis_.move_x = 1
for _ = 1, 8 do frame(s, input) end
input.pressed_.jump = true
frame(s, input)
check(s.vine == nil, "jump lets go")
near(s.slime.gravity, 600, "gravity comes back")
local vx, vy = s.slime:velocity()
check(vx > 20, "it keeps the pendulum's horizontal speed (" .. vx .. ")")
check(vy < -100, "and gets the jump upwards (" .. vy .. ")")

-- Down at the bottom end lets go too
s, input = grab_at(152, 176)
input.down_.up = false
input.down_.down, input.pressed_.down = true, true
frame(s, input)
check(s.vine == nil, "down at the bottom end lets go")

-- Drawing: a 3 px line from the top, back to the normal width afterwards
local F = require("fake_love")
F.install()
s = grab_at(152, 92)
F.reset_calls()
V.draw(s, love.graphics)
local lines = F.find("line")
local widths = F.find("setLineWidth")
check(#lines == 1 and lines[1][2] == v.top_x and lines[1][3] == v.top_y, "it draws the vine from its top")
check(widths[1] and widths[1][2] == V.tuning.width and widths[#widths][2] == 1,
  "3 px wide, then the line width is put back")

-- Nothing allocated per frame while it hangs
s, input = grab_at(152, 92)
input.down_.up = false
frame(s, input)
collectgarbage(); collectgarbage("stop")
local before = collectgarbage("count")
for _ = 1, 200 do
  V.update(s, DT, input, JUMP)
  s.slime:step(DT)
end
local grown = collectgarbage("count") - before
collectgarbage("restart")
check(grown < 1, "update and step allocate nothing on a vine (" .. grown .. " KB)")

print(string.format("OK: %d checks; rooms vines grab, climb, swing and let go", checks))
