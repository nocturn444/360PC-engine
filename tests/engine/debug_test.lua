-- engine.debug on the fake love: off by default, the game.lua flag, the menu on the state
-- machine, seed entry with the controller's directions, granting modifiers from a registry,
-- and the hitbox overlay with rectangles from a function and from a combat world.
local T = ...
local F = require("fake_love")
F.install({ width = 320, height = 180 })
for _, m in ipairs({ "engine", "engine.init", "engine.ui", "engine.debug" }) do package.loaded[m] = nil end
local engine = require("engine")
local Debug = engine.debug
local rng = engine.rng
T.check(Debug == require("engine.debug"), "engine.debug is loaded on first use")

-- the flag of game.lua: off without a file, off unless it is exactly true
T.check(Debug.flag() == false, "no game.lua: off")
love.filesystem.read = function(name) return name == "game.lua" and 'return { name = "x", debug = true }' or nil end
T.check(Debug.flag() == true, "debug = true in game.lua turns it on")
love.filesystem.read = function() return 'return { name = "x", debug = os ~= nil }' end
T.check(Debug.flag() == false, "game.lua runs without globals")
love.filesystem.read = function() return 'return { name = "x" }' end
T.check(Debug.flag() == false, "no flag: off")
l360 = { game = { debug = true } }
T.check(Debug.flag() == true, "on the console the flag comes from l360.game")
l360 = nil
local Config = dofile("runtime/lua/config.lua")
T.check(Config.load('return { name = "x", debug = true }').debug == true, "config.lua accepts debug")
T.check(Config.load('return { name = "x", debug = false }').debug == nil, "false is the same as absent")
T.check(Config.load('return { name = "x", debug = 1 }') == nil, "and rejects other values")

local globals = {}
for k in pairs(_G) do globals[k] = true end

local input = engine.input.new({ actions = { debug = { keys = { "f1" } }, cheat = { keys = { "f2" } } } })
local states = engine.state.new()
local game = { name = "game" }
states:push(game)
local function step(keys)
  for k in pairs(F.keys) do F.keys[k] = nil end
  for _, k in ipairs(keys or {}) do F.keys[k] = true end
  input:poll(); input:step()
  return states:input(input)
end
local function tap(key) step({ key }); step() end

local mods = engine.modifiers.new()
mods:defineAll({ { id = "thorns", name = "Thorns" }, { id = "dash", name = "Dash" }, { id = "armor" } })
local seed, entered, granted = 360, nil, {}
local rects = { { 10, 20, 30, 40, "body" }, { x = 1, y = 2, w = 3, h = 4, kind = "solid" } }
local function make(enabled)
  local d = Debug.new({ enabled = enabled, states = states, input = input, enable_action = "cheat",
    seed = function() return seed end,
    on_seed = function(n, code) entered = { n, code }; seed = n end,
    modifiers = mods, grant = function(id, def) granted[#granted + 1] = { id, def } end,
    hitboxes = function(emit) emit("hit", 5, 6, 7, 8); return rects end })
  function game:input(i) d:input(i) end
  return d
end

---------------------------------------------------------------------------
-- Off by default
---------------------------------------------------------------------------
local dbg = make(nil)
T.check(dbg.enabled == false, "off by default")
tap("f1")
T.check(states:depth() == 1 and dbg.menu == nil, "the debug action does nothing while off")
dbg.show_hitboxes = true
F.reset_calls()
T.check(dbg:drawHitboxes() == 0 and #F.calls == 0, "no overlay while off")
dbg:draw()
T.check(#F.calls == 0, "no seed text while off")
T.check(dbg:open() == nil and dbg:grantModifier("dash") == false and dbg:submitSeed("1") == nil,
  "nothing can be opened, granted or entered while off")
tap("f2")
T.check(dbg.enabled == true, "enable_action turns it on")
tap("f2")
T.check(dbg.enabled == false, "and off again")

---------------------------------------------------------------------------
-- Seed code, menu
---------------------------------------------------------------------------
dbg = make(true)
local code, number = dbg:seedCode()
T.check(code == rng.seed_to_code(360) and number == 360, "the seed code of the run: " .. tostring(code))
F.reset_calls(); dbg:draw()
local texts = F.find("print")
T.check(#texts == 1 and texts[1][2] == "seed " .. code, "draw shows the seed code")
seed = "daily"
T.check(dbg:seedCode() == rng.seed_to_code("daily"), "a string seed shows the code of its number")
seed = 360

tap("f1")
T.check(states:depth() == 2 and states:top() == dbg.menu and dbg.menu.transparent, "the action opens the menu over the game")
T.check(dbg.menu:get("seed").text == "seed " .. code, "the menu shows the seed")
local list = dbg.menu:get("modifiers")
T.check(#list.items == 3 and list.items[1].id == "armor" and list.items[2].id == "dash" and list.labels[3] == "Thorns",
  "the registry's modifiers, sorted by id, shown by name")
tap("escape")
T.check(states:depth() == 1 and dbg.menu == nil, "back closes it")

-- grant a modifier: focus the list, go down one, accept
tap("f1")
dbg.menu:focus("modifiers")
tap("down"); tap("return")
T.check(#granted == 1 and granted[1][1] == "dash" and granted[1][2] == mods:get("dash"), "accept on the list grants that modifier")
T.check(dbg.menu:get("message").text == "granted dash", "and says so")
T.check(states:top() == dbg.menu, "the menu stays open to grant more")

-- hitbox toggle
dbg.menu:focus("hitboxes"); tap("return")
T.check(dbg.show_hitboxes == true, "the toggle switches the overlay on")

---------------------------------------------------------------------------
-- Seed entry with directions only
---------------------------------------------------------------------------
dbg.menu:focus("enter_seed"); tap("return")
T.check(states:depth() == 3 and states:top() == dbg.entry, "the seed entry is pushed over the menu")
T.check(dbg:entryCode() == code, "it starts on the current code: " .. dbg:entryCode())
T.check(#dbg.columns[1].items == 4 and #dbg.columns[2].items == 32, "the first character only goes up to 3")
T.check(dbg.entry.focused == dbg.columns[1], "the first column has the focus")
tap("down")                                      -- 0 -> 1
tap("right"); tap("up")                          -- second column: 0 -> Z (wraps)
for _ = 1, 5 do tap("right") end
T.check(dbg.entry.focused == dbg.columns[7], "right moves along the columns")
tap("down")
local want = "1Z" .. code:sub(3, 6) .. rng.seed_to_code(rng.code_to_seed(code:sub(7, 7)) + 1):sub(7, 7)
T.check(dbg:entryCode() == want, "up and down change a character: " .. dbg:entryCode() .. " / " .. want)
tap("return")
T.check(entered and entered[1] == rng.code_to_seed(want) and entered[2] == want, "accept gives the game the seed")
T.check(states:depth() == 1 and dbg.menu == nil and dbg.entry == nil, "and closes both screens")
T.check(dbg:seedCode() == want, "the overlay shows the new seed")

tap("f1"); dbg.menu:focus("enter_seed"); tap("return"); tap("escape")
T.check(states:top() == dbg.menu and dbg.entry == nil, "back cancels the entry and returns to the menu")
dbg:close()
T.check(states:depth() == 1, "close")
local n, err = dbg:submitSeed("UUUU")
T.check(n == nil and type(err) == "string", "a code that is not valid is refused: " .. tostring(err))
T.check(dbg:submitSeed("c1s") == rng.code_to_seed("C1S") and entered[2] == "0000C1S", "typed codes are read like rng.code_to_seed")

---------------------------------------------------------------------------
-- Hitbox overlay
---------------------------------------------------------------------------
F.reset_calls()
love.graphics.setColor(0.5, 0.5, 0.5, 1)
T.check(dbg:drawHitboxes() == 3, "one rectangle by emit and two from the returned list")
local lines = {}
for _, c in ipairs(F.find("rectangle")) do if c[2] == "line" then lines[#lines + 1] = c end end
T.check(#lines == 3 and lines[1][3] == 5 and lines[1][6] == 8 and lines[2][3] == 10 and lines[3][5] == 3, "drawn where the game said")
T.check(lines[1].color[1] == Debug.colors.hit[1] and lines[2].color[3] == Debug.colors.body[3], "coloured by kind")
T.check(love.graphics.getColor() == 0.5, "the colour is put back")
dbg.show_hitboxes = false
T.check(dbg:drawHitboxes() == 0, "switched off: nothing")

-- a combat world, through boxes(): no require of the module in engine/debug.lua
local src = assert(io.open("engine/debug.lua")):read("*a")
T.check(not src:find("require%([^)]*modules"), "engine/debug.lua requires no genre module")
local combat = require("engine.modules.combat")
local world = combat.world.new()
local f = world:fighter({ body = { x = 100, y = 50, w = 16, h = 16, facing = 1, vx = 0, vy = 0 }, team = "a" })
f:hurtbox({ w = 16, h = 16 })
local bite = f:hitbox({ ox = 16, w = 8, h = 8 })
local d2 = Debug.new({ enabled = true, states = states, input = input, show_hitboxes = true })
d2:addHitboxes(Debug.boxes(world))
T.check(d2:drawHitboxes() == 1, "a combat world: the hurtbox, and no inactive hitbox")
bite:activate(1)
F.reset_calls()
T.check(d2:drawHitboxes() == 2, "and the active hitbox")
lines = {}
for _, c in ipairs(F.find("rectangle")) do if c[2] == "line" then lines[#lines + 1] = c end end
T.check(lines[2][3] == 116 and lines[2][4] == 50 and lines[2][5] == 8, "at the box's rectangle in the world")

-- a plain list of modifiers instead of a registry
local d3 = Debug.new({ enabled = true, states = states, input = input,
  modifiers = { "a", { id = "b", name = "Bee" } }, grant = function(id) granted[#granted + 1] = { id } end })
d3:open()
T.check(d3.menu:get("modifiers").labels[2] == "Bee" and d3.menu:get("enter_seed") == nil and d3.menu:get("hitboxes") == nil,
  "the menu only has what the game provided")
d3:close()

T.no_new_globals(globals)
