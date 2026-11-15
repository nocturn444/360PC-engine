-- engine.anim: animations with anim8 (lib/anim8, v2.3.1). anim8 itself is in M.anim8; this
-- adds building a named set of animations from data. See docs/ENGINE.md.
local prefix = (...):gsub("anim$", "")

local function find()
  for _, name in ipairs({ "lib.anim8.anim8", "anim8.anim8", "anim8", prefix .. "anim8" }) do
    local ok, lib = pcall(require, name)
    if ok and type(lib) == "table" and lib.newGrid then return lib end
  end
  error("engine.anim: anim8 not found (copy lib/anim8/ into the game folder)", 3)
end

local anim8 = find()
local M = { anim8 = anim8, newGrid = anim8.newGrid, newAnimation = anim8.newAnimation }

-- A grid of frame_w x frame_h frames over an image (the other arguments as in anim8.newGrid).
function M.grid(image, frame_w, frame_h, left, top, border)
  return anim8.newGrid(frame_w, frame_h, image:getWidth(), image:getHeight(), left, top, border)
end

-- Animations from data: defs[name] = { frames = { "1-4", 1 }, duration = 0.1, loop = true }
--   frames    the arguments of anim8's grid(...): column and row pairs
--   duration  seconds per frame, or anim8's table of durations
--   loop      false: stops on the last frame. A function: called as anim8's onLoop.
-- Returns { name = Animation }. Each sprite needs its own copy: animation:clone().
function M.set(grid, defs)
  local out = {}
  for name, d in pairs(defs) do
    local on_loop = d.loop
    if on_loop == false then on_loop = "pauseAtEnd" elseif type(on_loop) ~= "function" then on_loop = nil end
    out[name] = anim8.newAnimation(grid(unpack(d.frames)), d.duration or 0.1, on_loop)
  end
  return out
end

return M
