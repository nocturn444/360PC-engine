local T = ...
local F = require("fake_love")
F.install()
local Layers = require("engine.layers")
local img = love.graphics.newImage("x.png")
local q1, q2 = love.graphics.newQuad(0, 0, 16, 16, 32, 16), love.graphics.newQuad(16, 0, 16, 16, 32, 16)
local function order(set) return table.concat(set:getOrder(), ",") end

local set = Layers.new({ "body", "outfit", "held", "effect" })
set:set("held", { image = img, quad = q2, ox = 6, oy = -2 })
set:set("glow", { image = img })
set:set("body", { image = img, quad = q1 })
set:set("effect", { image = img, tint = { 1, 0.5, 0.25, 0.5 } })
set:set("shadow", { image = img })
T.check(order(set) == "body,held,effect,glow,shadow", "the order list first, then the others as added")
set:set("outfit", { image = img, quad = q2 })
T.check(order(set) == "body,outfit,held,effect,glow,shadow" and set:count() == 6, "a late layer still goes to its place")
set:set("held", { image = img, quad = q1 })
T.check(order(set) == "body,outfit,held,effect,glow,shadow" and set:get("held").quad == q1 and set:get("held").ox == 0,
  "replacing keeps the place and takes the new definition")
T.check(set:remove("glow") and not set:remove("glow") and not set:has("glow"), "remove")
set:set("glow", { image = img })
T.check(order(set) == "body,outfit,held,effect,glow,shadow", "a layer added again goes back to its place")
set:remove("glow"); set:remove("shadow")

-- drawing: order, offsets, tint, visibility
set:setOffset("held", 6, -2)
set:setVisible("outfit", false)
love.graphics.setColor(1, 1, 0.5, 1)
F.reset_calls()
set:draw(100, 50, 0, -1, 1, 8, 16)
local d = F.find("draw")
T.check(#d == 3, "hidden layers are not drawn")
T.check(d[1][3] == q1 and d[2][3] == q1 and d[3][3] == 100, "body, held, effect, in that order")
T.check(d[1][4] == 100 and d[1][5] == 50 and d[1][7] == -1 and d[1][9] == 8 and d[1][10] == 16, "position, flip and origin")
T.check(d[2][9] == 2 and d[2][10] == 18, "a layer's offset moves its origin, so it follows the flip")
T.check(d[3].color[1] == 1 and d[3].color[2] == 0.5 and d[3].color[3] == 0.125 and d[3].color[4] == 0.5,
  "the tint multiplies the current colour")
local r, g, b, a = love.graphics.getColor()
T.check(r == 1 and g == 1 and b == 0.5 and a == 1, "the colour is restored")
set:setTint("effect", 1, 1, 1, 1); set:setQuad("body", q2)
T.check(set:get("effect").g == 1 and set:get("body").quad == q2, "setTint, setQuad")
T.check(not pcall(set.setVisible, set, "nope", true), "an unknown layer is an error")

-- animations and custom draws
local log = {}
local anim = { update = function(self, dt) log[#log + 1] = "update " .. dt end,
  draw = function(self, image, x, y, r2, sx, sy, ox, oy) log[#log + 1] = "draw " .. x .. " " .. ox end }
set:setAnim("outfit", anim)
set:set("custom", { draw = function(layer, x, y) log[#log + 1] = "custom " .. layer.name .. " " .. y end })
set:update(0.25)
set:setVisible("outfit", true)
set:draw(7, 9)
T.check(table.concat(log, "; ") == "update 0.25; draw 7 0; custom custom 9", "anim layers update and draw; custom draw")

-- drawing allocates nothing
love.graphics.draw = function() end
anim.update, anim.draw, set:get("custom").draw = function() end, function() end, function() end
collectgarbage(); collectgarbage("stop")
local before = collectgarbage("count")
for _ = 1, 200 do set:update(0.016); set:draw(1, 2, 0, 1, 1, 0, 0) end
local grown = collectgarbage("count") - before
collectgarbage("restart")
T.check(grown == 0, "update and draw allocate nothing (" .. grown .. " KB)")
