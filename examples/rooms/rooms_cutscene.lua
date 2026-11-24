-- A state that plays one engine.cutscene script: the endings and the Progress > Endings replay.
-- It is opaque (the script draws its own background) and autopause = false, so a dead battery
-- during an ending does not open the pause menu over it. enter(previous, script, on_finish)
-- builds the cutscene with the game's audio; when it ends, on_finish(skipped) is called once and
-- the caller decides what comes next.
local engine = require("engine")
local profile = require("rooms_profile")

local M = { autopause = false }

function M:enter(previous, script, on_finish)
  assert(type(script) == "table", "rooms_cutscene: enter needs a cutscene script")
  self.previous = previous
  self.script = script
  self.on_finish = on_finish
  self.finished = false
  local audio = previous and previous.audio or profile.audio
  self.audio = audio
  self.cutscene = engine.cutscene.new(script, {
    audio = audio,
    on_finish = function(cs, skipped) self:finish(skipped) end,
  })
end

-- The cutscene calls this once; on_finish may pop this state and push another one.
function M:finish(skipped)
  if self.finished then return end
  self.finished = true
  local on_finish = self.on_finish
  self.on_finish = nil
  if on_finish then on_finish(skipped and true or false) end
end

function M:input(input)
  local cs = self.cutscene
  if cs then cs:input(input) end
end

function M:update(dt)
  local cs, audio = self.cutscene, self.audio
  if cs then cs:update(dt) end
  if audio and audio.update then audio:update(dt) end
end

function M:draw()
  if self.cutscene then self.cutscene:draw() end
end

function M:exit()
  self.previous = nil
  self.script = nil
  self.on_finish = nil
  self.audio = nil
  self.cutscene = nil
  self.finished = false
end

return M
