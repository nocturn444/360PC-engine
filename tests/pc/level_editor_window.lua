-- The level editor's window on the fake love (tests/engine/fake_love.lua), driven by mouse and
-- key events. Run by tests/pc/level_editor_test.lua; returns the number of checks.
local check, M = ...
local n = 0
local function ok(cond, what) n = n + 1; check(cond, what) end

local F = require("fake_love")
F.install({ width = 1280, height = 720 })
local keys = F.keys
love.keyboard.isDown = function(...)
  for i = 1, select("#", ...) do if keys[select(i, ...)] then return true end end
  return false
end
love.graphics.setLineWidth = function() end
love.graphics.circle = function(...) end
love.keyboard.setTextInput = function() end
love.keyboard.setKeyRepeat = function() end

local dir = os.getenv("TMPDIR") or "/tmp"
local path = dir .. "/360pc_level_editor_test.lvl"
os.remove(path); os.remove(path .. ".bak")

local E = assert(loadfile("tools/level_editor/main.lua"))()
love.load({ path, "--cell", "10x6", "--tile", "16" })
ok(E.data and #E.data.rooms == 1 and E.room().type == "start" and E.room().tiles_w == 10, "a new level with a start room")
love.draw()
ok(#E.buttons > 10, "the panels have buttons")

-- the centre of a tile on the screen
local function at(tx, ty)
  local ts, z = E.data.tile_size, E.zoom
  return E.ox + (tx - 0.5) * ts * z, E.oy + (ty - 0.5) * ts * z
end
local function click(tx, ty, button)
  local x, y = at(tx, ty)
  F.mouse_x, F.mouse_y = x, y
  love.mousepressed(x, y, button or 1)
  love.mousereleased(x, y, button or 1)
end
local function drag(x1, y1, x2, y2)
  local ax, ay = at(x1, y1)
  local bx, by = at(x2, y2)
  love.mousepressed(ax, ay, 1)
  love.mousemoved(bx, by)
  love.mousereleased(bx, by, 1)
end

-- paint a stroke: every tile between the two ends
drag(2, 4, 8, 4)
local row = M.rows(E.room())[4]
ok(row == "########.#" or row:sub(2, 8) == "#######", "a stroke paints a line without gaps (" .. row .. ")")
ok(E.dirty, "the level is marked changed")
-- right click erases
click(5, 4, 2)
ok(M.get(E.room(), 5, 4) == M.EMPTY, "right click erases")
-- one-way with a rectangle
love.keypressed("2")
ok(E.tool == "one_way", "2 picks one-way")
keys.lshift = true
drag(3, 2, 4, 3)
keys.lshift = nil
ok(M.get(E.room(), 3, 2) == M.ONE_WAY and M.get(E.room(), 4, 3) == M.ONE_WAY, "Shift+drag fills a rectangle")
-- undo / redo
keys.lctrl = true
love.keypressed("z")
keys.lctrl = nil
ok(M.get(E.room(), 3, 2) == M.EMPTY, "Ctrl+Z")
keys.lctrl = true
love.keypressed("y")
keys.lctrl = nil
ok(M.get(E.room(), 3, 2) == M.ONE_WAY, "Ctrl+Y")

-- doors, item, entity
love.keypressed("4")
click(1, 3)
click(10, 3)
ok(#E.room().exits == 2 and E.selected and E.selected.kind == "exit", "two doors, the last one selected")
love.keypressed("return")
ok(E.prompt ~= nil, "Enter asks for the door's abilities")
love.textinput("dash")
love.keypressed("return")
ok(E.room().exits[2].requires[1] == "dash" and not E.prompt, "the door requires dash")
love.keypressed("5")
click(6, 5)
ok(E.room().item and E.room().item.tx == 6, "the item")
love.keypressed("6")
click(3, 5)
local ent = E.room().entities[1]
ok(ent and ent.name == "Enemy", "an entity")
local ex, ey = at(3, 5)
love.mousepressed(ex, ey, 1)
local bx, by = at(7, 5)
love.mousemoved(bx, by)
love.mousereleased(bx, by, 1)
ok(ent.tx == 7, "dragged to another tile")
love.keypressed("n")
love.textinput("Spawn")
love.keypressed("return")
ok(ent.name == "Spawn" and E.entity_name == "Spawn", "N renames the selected entity")

-- the checks see the level
love.draw()
ok(type(E.problems) == "table", "checks ran")

-- rooms: new, rename by prompt, resize from the panel, switch
keys.lctrl = true
love.keypressed("n")
keys.lctrl = nil
ok(#E.data.rooms == 2 and E.room_i == 2, "Ctrl+N adds a room after this one and shows it")
E.room_action("rename")
E.prompt.text = ""
love.textinput("Hall")
love.keypressed("return")
ok(E.room().id == "Hall", "renamed")
love.draw()
local plus
for _, b in ipairs(E.buttons) do if b.id == "Width+" then plus = b end end
love.mousepressed(plus.x + 2, plus.y + 2, 1)
ok(E.room().w == 2 and E.room().tiles_w == 20, "the panel's + widens the room by one cell")
love.keypressed("pageup")
ok(E.room_i == 1, "PgUp shows the previous room")
love.keypressed("delete")
love.keypressed("delete")
ok(#E.data.rooms == 1 and E.data.rooms[1].id == "Hall", "Delete twice deletes the room")
keys.lctrl = true
love.keypressed("z")
keys.lctrl = nil
ok(#E.data.rooms == 2 and E.data.rooms[1].id == "Start", "and Ctrl+Z brings it back")
E.show_room(1)

-- save, and the file opens again
keys.lctrl = true
love.keypressed("s")
keys.lctrl = nil
ok(not E.dirty, "Ctrl+S saved")
local f = assert(io.open(path, "rb"))
local text = f:read("*a")
f:close()
local back = assert(M.from_text(text))
ok(#back.rooms == 2 and back.rooms[1].entities[1].name == "Spawn" and back.rooms[1].exits[2].requires[1] == "dash",
  "the saved file has the rooms, the entity and the door's requires")
ok(require("engine.level").from_text(text), "engine.level reads it")

-- play test: the body starts at the Spawn entity and falls onto the floor
love.keypressed("p")
ok(E.play ~= nil, "P starts the play test")
local y0 = E.play.body.y
for _ = 1, 120 do love.update(1 / 60) end
ok(E.play.body.y > y0 and E.play.body.on_ground, "the body falls and lands")
keys.right = true
local x0 = E.play.body.x
for _ = 1, 30 do love.update(1 / 60) end
keys.right = nil
ok(E.play.body.x > x0, "and walks right with the arrow")
love.draw()
love.keypressed("escape")
ok(E.play == nil, "Esc stops it")

-- quitting with unsaved changes asks once
click(5, 2)
ok(E.dirty and love.quit() == true and love.quit() == nil, "close with changes is held once")
os.remove(path); os.remove(path .. ".bak")

-- tileset paths are relative to the game folder: found from a level inside it
local game = dir .. "/360pc_editor_game"
os.execute('mkdir -p "' .. game .. '/levels"')
local gf = assert(io.open(game .. "/game.lua", "wb")); gf:write("return {}\n"); gf:close()
ok(E.find_root(game .. "/levels/world.lvl") == game, "the root is the folder with game.lua")
ok(E.find_root(dir .. "/nowhere/x.lvl") == dir .. "/nowhere", "else the file's folder")
os.remove(game .. "/game.lua"); os.remove(game .. "/levels"); os.remove(game)
return n
