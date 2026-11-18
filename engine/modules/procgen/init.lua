-- engine.modules.procgen: maps made of hand-made rooms joined procedurally. Room templates as
-- plain data (no file format: the level loader, objective 11, produces them), a room graph on
-- a grid of map cells, locks and keys from ability tags, validation by breadth-first search,
-- minimap data, a stable layout hash, and a generator that can be spread over frames.
-- A genre module: nothing in engine/ requires it and it knows nothing about a game. The only
-- platformer-specific part (reach.lua) reads a tile grid through the platformer grid
-- interface and takes the jump's reach from a function the game injects.
-- Reference: engine/modules/procgen/README.md.
--
--   local procgen = require("engine.modules.procgen")
--   local map, err = procgen.generate({ templates = rooms, rng = run:get("level"), rooms = 16,
--     abilities = { "dash", "double_jump" } })
--   -- or, a few operations per frame:
--   local gen = procgen.generator.new(opts)
--   function loading:update(dt) if gen:step(4) then use(gen.map or error(gen.error)) end end
local prefix = (...):gsub("%.init$", "") .. "."

local generator = require(prefix .. "generator")
local map = require(prefix .. "map")

return {
  templates = require(prefix .. "templates"),
  generator = generator,
  graph = require(prefix .. "graph"),
  map = map,
  reach = require(prefix .. "reach"),
  seeds = require(prefix .. "seeds"),
  roomtypes = require(prefix .. "roomtypes"),
  floors = require(prefix .. "floors"),
  biomes = require(prefix .. "biomes"),
  generate = generator.generate,
  hash = map.hash,
}
