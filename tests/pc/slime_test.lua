-- examples/slime: boots on the console's boot (tests/pc/boot_pc.lua) and runs on the engine
-- tests' fake love: the slime falls and rests on the floor, moves, jumps, squashes, and is drawn
-- as one pixel grid.
-- Usage, from the repository root: luajit -joff tests/pc/slime_test.lua   (must end with "OK:")
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./examples/slime/?.lua;" .. package.path
local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print("FAILED: " .. what); os.exit(1) end
end
local function read(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local d = f:read("*a"); f:close(); return d
end

-- 1. Files and config
for _, name in ipairs({ "game.lua", "conf.lua", "main.lua", "slime_play.lua", "README.md" }) do
  check(read("examples/slime/" .. name), "examples/slime/" .. name .. " exists")
end
local Config = dofile("runtime/lua/config.lua")
local cfg, err = Config.load(read("examples/slime/game.lua"), "examples/slime/game.lua")
check(cfg and cfg.title_id and cfg.identity == "slime_demo", "game.lua is valid: " .. tostring(err))

-- 2. On the console's boot, without a GPU
local p = assert(io.popen("luajit -joff tests/pc/boot_pc.lua examples/slime 2>&1"))
local out = p:read("*a"); p:close()
local last = out:match("([^\n]*)\n*$")
check(last:sub(1, 3) == "OK:", "boot_pc.lua examples/slime ends with OK: " .. last)
check(not out:find("ERROR", 1, true), "and logs no error")

-- 3. On the fake love
local F = require("fake_love")
F.install({ width = 1280, height = 720 })
assert(loadfile("examples/slime/main.lua"))()
love.load()
local engine = require("engine")
local play = engine.states:top()
check(play == require("slime_play"), "the slime's state is entered")
local slime = play.slime
local function frames(n, dt) for _ = 1, n do love.update(dt or 1 / 60); love.draw() end end
frames(90)
local x0, y0 = slime:center()
check(slime:on_ground(), "it falls and rests on the floor")
F.keys.right = true; frames(30); F.keys.right = nil
local x1 = slime:center()
check(x1 > x0 + 10 and play.facing == 1, "right moves it right (" .. (x1 - x0) .. " px)")
frames(60)
local _, rest = slime:center()
F.keys.space = true; love.update(1 / 60); F.keys.space = nil
local top = rest
for _ = 1, 30 do love.update(1 / 60); local _, y = slime:center(); if y < top then top = y end end
local jump = rest - top
check(jump > 30, "jump lifts it (" .. jump .. " px)")
frames(90)
local area = slime:area()
F.keys.down = true; frames(30)
check(slime.inflate < 1 and slime:area() < area * 0.85, "holding down squashes it")
local _, low = slime:center()
F.keys.down = nil; frames(1)
top = low
for _ = 1, 40 do love.update(1 / 60); local _, y = slime:center(); if y < top then top = y end end
check(rest - top > jump * 1.3, "letting go after a squash jumps higher (" .. (rest - top) .. " px against " .. jump .. ")")
local pad = F.add_pad(); love.joystickadded(pad)
frames(60)
local before = slime:center()
pad.axes.leftx = -1; frames(15, 1 / 30); pad.axes.leftx = 0   -- the console's 30 FPS
check(slime:center() < before - 10 and play.facing == -1, "the stick moves it at 30 FPS")
-- the tuning overlay: Tab opens it, ] raises the selected number, Page Down picks the next
local tuner = play.tuner
check(not tuner.open and #tuner.fields == 11, "the tuner has the body's and the controls' numbers, closed")
F.keys.tab = true; love.update(1 / 60); F.keys.tab = nil; love.update(1 / 60)
check(tuner.open, "Tab opens it")
local before_k = slime.stiffness
F.keys["["] = true; love.update(1 / 60); F.keys["["] = nil; love.update(1 / 60)
check(math.abs(slime.stiffness - (before_k - 0.05)) < 1e-9, "[ lowers the stiffness one step")
F.keys.pagedown = true; love.update(1 / 60); F.keys.pagedown = nil; love.update(1 / 60)
check(tuner.selected == 2, "Page Down picks the next number")
F.reset_calls(); love.draw()
check(#F.find("rectangle") > 50, "the overlay is drawn with the built-in font")
F.keys.tab = true; love.update(1 / 60); F.keys.tab = nil; love.update(1 / 60)
check(not tuner.open, "Tab closes it")
F.reset_calls(); love.draw()
check(play.pixels.count > 150, "the slime is drawn as a pixel grid (" .. play.pixels.count .. " cells)")
F.keys.escape = true; love.update(1 / 60)
check(F.quit == true, "quit leaves the game")

print(string.format("OK: %d checks; the slime boots, moves, jumps and squashes", checks))
