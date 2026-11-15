local T = ...
local F = require("fake_love")
F.install()
local Camera = require("engine.camera")
local DT = 1 / 60

-- follow, instantly
local cam = Camera.new({ width = 320, height = 180 })
T.check(cam.x == 160 and cam.y == 90, "starts showing 0,0 at the top left")
cam:follow(500, 300); cam:update(DT)
T.check(cam.x == 500 and cam.y == 300, "without lerp the camera is on the target")

-- clamping to a room
cam:setBounds(0, 0, 640, 360)
cam:follow(10, 10); cam:update(DT)
T.check(cam.x == 160 and cam.y == 90, "clamped at the top left")
cam:follow(1000, 1000); cam:update(DT)
T.check(cam.x == 480 and cam.y == 270, "clamped at the bottom right")
local vx, vy, vw, vh = cam:getViewport()
T.check(vx == 320 and vy == 180 and vw == 320 and vh == 180, "the viewport stays inside the room")
cam:setBounds(100, 0, 200, 360)
cam:update(DT)
T.check(cam.x == 200, "a room narrower than the view is centred")
cam.zoom = 2
cam:setBounds(0, 0, 640, 360); cam:follow(0, 0); cam:update(DT)
T.check(cam.x == 80 and cam.y == 45, "the zoom shrinks the view that is clamped")
cam.zoom = 1

-- deadzone
cam = Camera.new({ width = 320, height = 180, deadzone_w = 40, deadzone_h = 20 })
cam:follow(175, 95); cam:update(DT)
T.check(cam.x == 160 and cam.y == 90, "the target moves freely inside the deadzone")
cam:follow(200, 60); cam:update(DT)
T.check(cam.x == 180 and cam.y == 70, "past it, the camera keeps the target at the edge")

-- lerp: approaches, never overshoots, independent of the step size
cam = Camera.new({ width = 320, height = 180, lerp = 8 })
cam:follow(260, 90)
local last = cam.x
for _ = 1, 30 do
  cam:update(DT)
  if cam.x < last or cam.x > 260 then error("FAILED: lerp went backwards or overshot") end
  last = cam.x
end
local half = Camera.new({ width = 320, height = 180, lerp = 8 })
half:follow(260, 90)
for _ = 1, 60 do half:update(DT / 2) end
T.near(cam.x, half.x, "the same place after the same time at 60 and 120 Hz")
T.check(cam.x > 250 and cam.x < 260, "half a second of lerp 8 is nearly there")

-- interpolation and attach
cam = Camera.new({ width = 320, height = 180 })
cam:follow(260, 90); cam:update(DT)
local x = cam:getDrawPosition(0.5)
T.check(x == 210, "the draw position is interpolated between two steps")
F.reset_calls()
cam:attach(); love.graphics.rectangle("fill", 260, 90, 1, 1); cam:detach()
local r = F.find("rectangle")[1]
T.check(r.tx + 260 * r.sx == 160 and r.ty + 90 * r.sy == 90, "attach puts the camera's position at the centre")
T.check(F.stack_depth() == 0, "detach pops")
cam.zoom = 2
F.reset_calls()
cam:attach(); love.graphics.rectangle("fill", 260, 90, 1, 1); cam:detach()
r = F.find("rectangle")[1]
T.check(r.sx == 2 and r.tx + 260 * r.sx == 160, "attach with zoom")

-- world <-> screen
local wx, wy = cam:toWorld(160, 90)
T.check(wx == 260 and wy == 90, "the centre of the screen is the camera's position")
wx, wy = cam:toWorld(0, 0)
T.check(wx == 180 and wy == 45, "toWorld with zoom")
local sx, sy = cam:toScreen(wx, wy)
T.check(sx == 0 and sy == 0, "toScreen undoes toWorld")
cam.zoom = 1

-- snap
cam = Camera.new({ width = 320, height = 180, snap = true })
cam:setPosition(160.4, 90.6)
local ox, oy = cam:getOffset()
T.check(ox == 0 and oy == -1, "snap rounds the offset to whole pixels")

-- shake: bounded, deterministic, ends
local a, b = Camera.new({ width = 320, height = 180 }), Camera.new({ width = 320, height = 180 })
a:shake(4, 0.5); b:shake(4, 0.5)
local moved = false
for _ = 1, 29 do
  a:update(DT); b:update(DT)
  if a.shake_x ~= b.shake_x or math.abs(a.shake_x) > 4 or math.abs(a.shake_y) > 4 then error("FAILED: shake") end
  if a.shake_x ~= 0 then moved = true end
end
T.check(moved and a.x == 160, "shake moves the offset, not the position")
a:update(DT); a:update(DT)
ox, oy = a:getOffset()
T.check(a.shake_x == 0 and a.shake_y == 0 and ox == 0 and oy == 0, "shake ends")

-- transitions between rooms
cam = Camera.new({ width = 320, height = 180, bounds = { 0, 0, 320, 180 } })
cam:follow(330, 90)                       -- the target walked into the room on the right
local done = 0
cam:transition(320, 0, 640, 180, { mode = "slide", duration = 0.5, on_done = function() done = done + 1 end })
T.check(cam:isTransitioning(), "transition starts")
last = cam.x
for i = 1, 29 do
  cam:update(DT)
  if cam.x < last or cam.x > 480 then error("FAILED: slide not monotonic") end
  last = cam.x
end
T.check(cam:isTransitioning() and cam.x > 160 and cam.x < 480 and done == 0, "sliding: between the two rooms")
cam:update(DT); cam:update(DT)
T.check(not cam:isTransitioning() and cam.x == 480 and done == 1, "slide ends at the clamped place in the new room")
cam:follow(0, 90); cam:update(DT)
T.check(cam.x == 480, "and the new bounds hold")

cam:transition(0, 0, 320, 180, { mode = "instant", on_done = function() done = done + 1 end })
T.check(cam.x == 160 and cam.px == 160 and done == 2 and not cam:isTransitioning(), "instant transition")

cam:follow(700, 90)
cam:transition(320, 0, 640, 180, { mode = "fade", duration = 0.4 })
for _ = 1, 11 do cam:update(DT) end
T.check(cam.x == 160 and cam.fade > 0.8 and cam.fade < 1, "fade out: still in the old room")
cam:update(DT); cam:update(DT)
T.check(cam.x == 700 and cam.px == 700 and cam.fade > 0.8, "the cut: in the new room, no interpolation across it")
F.reset_calls()
cam:drawFade(0, 0, 0)
r = F.find("rectangle")[1]
T.check(r and r.color[4] == cam.fade and r[5] == 320, "drawFade covers the view at the fade's opacity")
for _ = 1, 12 do cam:update(DT) end
T.check(not cam:isTransitioning() and cam.fade == 0, "fade ends")
F.reset_calls(); cam:drawFade()
T.check(#F.find("rectangle") == 0, "drawFade draws nothing at 0")

-- update and attach allocate nothing
cam:shake(2, 10)
collectgarbage(); collectgarbage("stop")
local before = collectgarbage("count")
for i = 1, 200 do cam:follow(400 + i, 90); cam:update(DT); cam:getOffset(0.5); cam:toWorld(1, 2) end
local grown = collectgarbage("count") - before
collectgarbage("restart")
T.check(grown == 0, "update allocates nothing (" .. grown .. " KB)")
