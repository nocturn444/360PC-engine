-- examples/perf_platformer: what the test runs. Data only; change it and start the game again.
return {
  seed = 360018,                          -- the level's seed (a number, or a 7-character seed code)
  rooms = 12,                             -- rooms in the generated level
  min_width = 4,                          -- the level is at least this many screens wide

  enemy_counts = { 0, 50, 100, 200 },     -- cycled with RB / E
  particle_counts = { 500, 1000, 2000 },  -- cycled with LB / P
  start_enemies = 2,                      -- which of each list the game starts with
  start_particles = 1,

  benchmark = false,                      -- true: the benchmark starts by itself at boot
  bench_seconds = 10,                     -- measured seconds per (enemies, particles) pair
  bench_warmup = 2,                       -- seconds left out after each change
  bench_quit = false,                     -- true: leave the game when the benchmark ends
  results_file = "perf_results.md",       -- written in the save folder

  overlay_interval = 0.25,                -- seconds between refreshes of the overlay's numbers
}
