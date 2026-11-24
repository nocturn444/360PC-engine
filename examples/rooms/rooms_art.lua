-- The biome art of the rooms example: a sky, two parallax layers, an autotiled wall sheet and
-- the small sprites shared by every biome (the firefly glow and the walking mob). Images are
-- loaded once per biome and kept; the room code builds its tile SpriteBatch when the room is
-- entered. Art lives in art/<biome>/ and art/{fx,enemies}/; tools/art/gen_placeholders.py writes
-- the placeholders. No love at load: only the functions touch love.graphics.
local W, TS = 320, 16

local M = {}

-- Biomes with art on disk. Fixed, so nothing probes the filesystem.
local HAS_ART = {
  forest = true, deep_jungle = true, grotto = true, fungal_cave = true,
  catacombs = true, labs = true, catastrophe = true,
}

local cache = {}

local function load_image(path)
  local image = love.graphics.newImage(path)
  image:setFilter("nearest")
  return image
end

-- The biome's art table { sky, far, mid, tiles, quads }, or nil for a biome without art.
function M.biome(id)
  if not HAS_ART[id] then return nil end
  local art = cache[id]
  if art then return art end
  local prefix = "art/" .. id .. "/"
  local tiles = load_image(prefix .. "tiles.png")
  local tw, th = tiles:getDimensions()
  local quads = {}
  for mask = 0, 15 do
    quads[mask + 1] = love.graphics.newQuad((mask % 4) * TS, math.floor(mask / 4) * TS,
      TS, TS, tw, th)
  end
  art = {
    sky = load_image(prefix .. "sky.png"),
    far = load_image(prefix .. "bg_far.png"),
    mid = load_image(prefix .. "bg_mid.png"),
    tiles = tiles,
    quads = quads,
  }
  cache[id] = art
  return art
end

-- Tiles outside the room count as solid, so the border keeps its wall edges.
local function solid_at(grid, tx, ty)
  if tx < 1 or ty < 1 or tx > grid.width or ty > grid.height then return true end
  return grid:kind(tx, ty) == "solid"
end

-- One quad per solid tile, the variant picked from the open sides (1 up, 2 right, 4 down,
-- 8 left). Call it when the room is entered, never per frame. One-way ledges are not in it.
function M.build_tiles(art, grid)
  local count = 0
  for ty = 1, grid.height do
    for tx = 1, grid.width do
      if grid:kind(tx, ty) == "solid" then count = count + 1 end
    end
  end
  local batch = love.graphics.newSpriteBatch(art.tiles, count > 0 and count or 1)
  for ty = 1, grid.height do
    for tx = 1, grid.width do
      if grid:kind(tx, ty) == "solid" then
        local mask = 0
        if not solid_at(grid, tx, ty - 1) then mask = mask + 1 end
        if not solid_at(grid, tx + 1, ty) then mask = mask + 2 end
        if not solid_at(grid, tx, ty + 1) then mask = mask + 4 end
        if not solid_at(grid, tx - 1, ty) then mask = mask + 8 end
        batch:add(art.quads[mask + 1], (tx - 1) * TS, (ty - 1) * TS)
      end
    end
  end
  return batch
end

-- In screen space, before the camera is attached: the sky fixed, the far layer at 0.25 and the
-- mid layer at 0.5 of the camera's horizontal position, wrapped every 320 px.
function M.draw_background(art, camera_x, camera_y)
  local g = love.graphics
  g.setColor(1, 1, 1, 1)
  g.draw(art.sky, 0, 0)
  local far_x = math.floor(-((camera_x * 0.25) % W))
  local mid_x = math.floor(-((camera_x * 0.5) % W))
  g.draw(art.far, far_x, 0)
  g.draw(art.far, far_x + W, 0)
  g.draw(art.mid, mid_x, 0)
  g.draw(art.mid, mid_x + W, 0)
end

local glow
-- The white soft glow, shared by every biome's fireflies.
function M.glow()
  if not glow then glow = load_image("art/fx/glow.png") end
  return glow
end

local mob
-- The 4 walk frames of the shared mob strip.
function M.mob()
  if mob then return mob end
  local image = load_image("art/enemies/mob_walk.png")
  local iw, ih = image:getDimensions()
  local quads = {}
  for frame = 0, 3 do
    quads[frame + 1] = love.graphics.newQuad(frame * TS, 0, TS, TS, iw, ih)
  end
  mob = { image = image, quads = quads }
  return mob
end

-- Draws a body (x, y, w, h is its room box): centred, bottom aligned, flipped by facing, at
-- twice the size for a boss or miniboss. The caller sets the colour (the hit flash). `shape`
-- picks the look: nil or "walker" is the shared mob sprite; the other types get a simple
-- placeholder silhouette of rectangles in the caller's colour (the owner will draw the real
-- sprites later; no new image files are needed).
function M.draw_enemy(x, y, w, h, facing, boss, shape)
  local g = love.graphics
  local scale = boss and 2 or 1
  if not shape or shape == "walker" then
    local art = M.mob()
    local frame = math.floor(love.timer.getTime() * 6) % 4 + 1
    local sx = (facing or 1) < 0 and -scale or scale
    local ox = (facing or 1) < 0 and TS or 0
    g.draw(art.image, art.quads[frame], x + w / 2 - 8 * scale, y + h - TS * scale,
      0, sx, scale, ox, 0)
    return
  end
  local f = (facing or 1) < 0 and -1 or 1
  local ww, hh = w * scale, h * scale
  local left = math.floor(x + w / 2 - ww / 2 + 0.5)
  local bottom = math.floor(y + h + 0.5)
  local top = bottom - hh
  if shape == "hopper" then
    g.rectangle("fill", left + 2, top + 2, ww - 4, hh - 2)
    g.rectangle("fill", left, bottom - 2, 3, 2)
    g.rectangle("fill", left + ww - 3, bottom - 2, 3, 2)
    g.rectangle("fill", left + ww / 2 - 2, top - 2, 4, 2)
  elseif shape == "charger" then
    g.rectangle("fill", left, top + 3, ww, hh - 3)
    if f > 0 then
      g.rectangle("fill", left + ww - 2, top + 4, 4, 3)
      g.rectangle("fill", left + ww, top + 3, 2, 2)
    else
      g.rectangle("fill", left - 2, top + 4, 4, 3)
      g.rectangle("fill", left - 2, top + 3, 2, 2)
    end
    g.rectangle("fill", left + 1, bottom - 2, 3, 2)
    g.rectangle("fill", left + ww - 4, bottom - 2, 3, 2)
  elseif shape == "shooter" then
    g.rectangle("fill", left + 1, top + 2, ww - 2, hh - 2)
    if f > 0 then g.rectangle("fill", left + ww - 1, top + 4, 5, 3)
    else g.rectangle("fill", left - 4, top + 4, 5, 3) end
    g.rectangle("fill", left + ww / 2 - 2, top - 1, 4, 3)
  elseif shape == "sniper" then
    g.rectangle("fill", left + 2, top, ww - 4, hh)
    if f > 0 then g.rectangle("fill", left + ww - 2, top + 4, 8, 2)
    else g.rectangle("fill", left - 6, top + 4, 8, 2) end
    g.rectangle("fill", left + ww / 2 - 2, top - 2, 4, 2)
  elseif shape == "sprayer" then
    g.rectangle("fill", left, top + 3, ww, hh - 3)
    if f > 0 then
      g.rectangle("fill", left + ww, top + 4, 4, 2)
      g.rectangle("fill", left + ww, top + 7, 4, 2)
    else
      g.rectangle("fill", left - 4, top + 4, 4, 2)
      g.rectangle("fill", left - 4, top + 7, 4, 2)
    end
    g.rectangle("fill", left + ww / 2 - 2, top, 4, 3)
  elseif shape == "bat" then
    g.rectangle("fill", left + ww / 2 - 2, top + 1, 4, hh - 1)
    g.rectangle("fill", left, top + 2, ww / 2 - 2, 3)
    g.rectangle("fill", left + ww / 2 + 2, top + 2, ww / 2 - 2, 3)
    g.rectangle("fill", left + ww / 2 - 3, top, 2, 2)
    g.rectangle("fill", left + ww / 2 + 1, top, 2, 2)
  else -- drone
    g.rectangle("fill", left + 1, top + 3, ww - 2, hh - 3)
    g.rectangle("fill", left - 1, top, ww + 2, 2)
    g.rectangle("fill", left + ww / 2 - 2, top + 5, 4, 2)
  end
end

return M
