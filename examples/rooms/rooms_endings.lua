-- The game's endings as data for engine.cutscene. Every script is a placeholder (coloured
-- rectangles and short English text) until the owner defines what the endings look like; the
-- names and the order come from the world-building drafts. The one-line hint in each script is
-- the only thing taken from those drafts: the rest is deliberately generic so it is easy to
-- replace. M.pick(run) is where the rules for choosing an ending will go.
local M = {}

-- A placeholder scene: a background, two coloured rectangles, one move, one pan, two short
-- dialogue lines, the ending title and a PLACEHOLDER line, then a fade out. 12 steps.
local function placeholder(id, name, hint, background, first, second)
  return {
    id = id,
    background = background,
    steps = {
      { "fade", to = 1, time = 0 },
      { "show", id = "back", rect = { 320, 180 }, color = background, layer = -2, parallax = 0 },
      { "show", id = "shape", rect = { 120, 70 }, color = first, x = 100, y = 55, layer = 0,
        alpha = 0 },
      { "show", id = "spark", rect = { 16, 16 }, color = second, x = 152, y = 82, layer = 1,
        parallax = 1.5 },
      { "fade", to = 0, time = 0.3, wait = false },
      { "move", id = "shape", y = 45, alpha = 1, time = 0.6, wait = false },
      { "pan", x = 10, y = -4, time = 1.0 },
      { "say", speaker = name, text = hint, speed = 40 },
      { "say", text = "THIS IS A PLACEHOLDER ENDING.", speed = 0 },
      { "text", id = "ending", text = "ENDING: " .. name, x = 0, y = 24, w = 320,
        align = "center", speed = 0 },
      { "text", id = "placeholder", text = "PLACEHOLDER", x = 0, y = 34, w = 320,
        align = "center", speed = 0, color = { 0.7, 0.7, 0.75 } },
      { "fade", to = 1, time = 0.6 },
    },
  }
end

-- Partial endings: the run ends, but the story is not resolved.
M.list = {
  -- A plush shaped like a female of the Blob's kind.
  { id = "plush", kind = "partial", name = "THE PLUSH",
    script = placeholder("plush", "THE PLUSH", "A PLUSH SHAPED LIKE A FEMALE OF YOUR KIND.",
      { 0.18, 0.10, 0.16 }, { 0.95, 0.62, 0.72 }, { 0.98, 0.90, 0.52 }) },
  -- The clone machine melting after the massacre.
  { id = "clone_machine", kind = "partial", name = "THE CLONE MACHINE",
    script = placeholder("clone_machine", "THE CLONE MACHINE", "THE CLONE MACHINE IS MELTING.",
      { 0.06, 0.14, 0.18 }, { 0.35, 0.75, 0.68 }, { 0.85, 0.95, 0.70 }) },
  -- Lab evidence that a female of the Blob's kind is alive (unlocks longer runs).
  { id = "lab_evidence", kind = "partial", name = "LAB EVIDENCE",
    script = placeholder("lab_evidence", "LAB EVIDENCE", "A FEMALE OF YOUR KIND IS ALIVE SOMEWHERE.",
      { 0.10, 0.12, 0.16 }, { 0.65, 0.72, 0.82 }, { 0.30, 0.90, 0.55 }) },
  -- The cryo scientist found asleep.
  { id = "cryo_scientist", kind = "partial", name = "THE CRYO SCIENTIST",
    script = placeholder("cryo_scientist", "THE CRYO SCIENTIST", "A SCIENTIST SLEEPS IN THE POD.",
      { 0.08, 0.14, 0.22 }, { 0.45, 0.70, 0.95 }, { 0.85, 0.95, 1.00 }) },
  -- The helpful AI that caused the massacre.
  { id = "helpful_ai", kind = "partial", name = "THE HELPFUL AI",
    script = placeholder("helpful_ai", "THE HELPFUL AI", "THE AI HELPED UNTIL THE MASSACRE.",
      { 0.10, 0.06, 0.18 }, { 0.72, 0.40, 0.95 }, { 0.30, 1.00, 0.85 }) },
  -- The AI and the scientist against each other.
  { id = "ai_vs_scientist", kind = "partial", name = "AI VS SCIENTIST",
    script = placeholder("ai_vs_scientist", "AI VS SCIENTIST", "THE AI AND THE SCIENTIST FIGHT.",
      { 0.18, 0.08, 0.08 }, { 0.95, 0.45, 0.30 }, { 0.40, 0.80, 1.00 }) },
  -- True endings: nature, the AI or humanity takes what is left.
  { id = "true_natural", kind = "true", name = "TRUE NATURAL",
    script = placeholder("true_natural", "TRUE NATURAL", "NATURE TAKES THE WORLD BACK.",
      { 0.06, 0.16, 0.08 }, { 0.30, 0.80, 0.35 }, { 0.95, 0.85, 0.40 }) },
  { id = "true_ai", kind = "true", name = "TRUE AI",
    script = placeholder("true_ai", "TRUE AI", "THE AI INHERITS WHAT IS LEFT.",
      { 0.06, 0.08, 0.18 }, { 0.30, 0.45, 0.95 }, { 0.65, 1.00, 0.95 }) },
  { id = "true_human", kind = "true", name = "TRUE HUMAN",
    script = placeholder("true_human", "TRUE HUMAN", "HUMANS REBUILD FROM THE RUINS.",
      { 0.18, 0.14, 0.08 }, { 0.95, 0.75, 0.40 }, { 0.98, 0.96, 0.85 }) },
  -- The secret ending.
  { id = "secret", kind = "secret", name = "SECRET",
    script = placeholder("secret", "SECRET", "SOMETHING HIDES BENEATH THE LAB.",
      { 0.04, 0.04, 0.04 }, { 0.55, 0.20, 0.65 }, { 0.95, 0.95, 0.95 }) },
}

-- The endings by id, so a save or a script can find one without scanning the list.
local by_id = {}
for _, ending in ipairs(M.list) do by_id[ending.id] = ending end

function M.get(id) return by_id[id] end

-- Which ending a victory plays. The rules are not defined yet, so it is always the first
-- partial ending; the run argument is here so the rules have one place to go.
function M.pick(play)
  return M.get("plush")
end

return M
