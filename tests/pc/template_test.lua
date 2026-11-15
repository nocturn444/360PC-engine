-- template/: the new-game skeleton boots on the console's boot (tests/pc/boot_pc.lua) and runs
-- on the engine tests' fake love: its example state moves with the input actions.
-- Usage, from the repository root: luajit -joff tests/pc/template_test.lua   (must end with "OK:")
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./template/?.lua;" .. package.path
local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print("FAILED: " .. what); os.exit(1) end
end
local function read(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local d = f:read("*a"); f:close(); return d
end

-- 1. The files a new game starts from
for _, name in ipairs({ "game.lua", "conf.lua", "main.lua", "states/play.lua", ".gitignore", "README.md" }) do
  check(read("template/" .. name), "template/" .. name .. " exists")
end
local Config = dofile("runtime/lua/config.lua")
local cfg, err = Config.load(read("template/game.lua"), "template/game.lua")
check(cfg and cfg.title_id and cfg.identity == "new_game", "template/game.lua is valid and has a Title ID: " .. tostring(err))
check(cfg.debug == nil, "debug mode is off in the template")

-- 2. On the console's boot, without a GPU
local p = assert(io.popen("luajit -joff tests/pc/boot_pc.lua template 2>&1"))
local out = p:read("*a"); p:close()
local last = out:match("([^\n]*)\n*$")
check(last:sub(1, 3) == "OK:", "boot_pc.lua template ends with OK: " .. last)
check(not out:find("ERROR", 1, true), "and logs no error")

-- 3. On the fake love: engine.state, engine.timestep and engine.input drive the example state
local F = require("fake_love")
F.install({ width = 1280, height = 720 })
assert(loadfile("template/main.lua"))()
love.load()
local engine = require("engine")
local play = engine.states:top()
check(play == engine.states:get("play") and play == require("states.play"), "the example state is entered")
check(engine.time.rate == 60 and engine.screen.width == 320, "fixed timestep at 60 Hz, 320x180 game pixels")
local x0, y0 = play.x, play.y
F.keys.right = true
for _ = 1, 30 do love.update(1 / 60); love.draw() end
F.keys.right = nil
check(math.abs(play.x - (x0 + 45)) < 1e-6 and play.y == y0, "half a second to the right moves 45 pixels: " .. play.x)
check(engine.time.tick == 30, "one logic step per 1/60 s")
local pad = F.add_pad()
love.joystickadded(pad)
pad.axes.lefty = -1
for _ = 1, 6 do love.update(1 / 30) end                 -- the console's frame rate: two steps a frame
check(math.abs(play.y - (y0 - 18)) < 1e-6, "the stick moves it too, the same distance at 30 FPS: " .. play.y)
pad.axes.lefty = 0
pad.buttons.a = true; love.update(1 / 60); pad.buttons.a = nil; love.update(1 / 60)
check(play.bright == true, "the action toggles the colour")
F.reset_calls(); love.draw()
check(#F.find("rectangle") >= 2, "the state draws")
F.keys.escape = true; love.update(1 / 60)
check(F.quit == true, "quit leaves the game")

print(string.format("OK: %d checks; template boots and runs", checks))
