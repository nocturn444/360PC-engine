#ifndef L360_PARTICLES_H
#define L360_PARTICLES_H
/* The simulation behind love.graphics.newParticleSystem: a port of LOVE 11's ParticleSystem
 * (emit, update, the particle list) with no Lua and no GPU in it, so that tests/pc/particles_test.c
 * can build it on PC. l360_gfx.c has the Lua methods and draws the particles.
 *
 * The particles live in one pool allocated by l360_ps_set_buffer_size: emit and update never
 * allocate. Random numbers come from a xorshift32 kept in each system (integer state, seeded from
 * a counter: the same calls in the same order give the same particles); it is not love.math's
 * generator and love.math.setRandomSeed does not reach it. */
#include <stdint.h>

#define L360_PS_SIZES  8
#define L360_PS_COLORS 8
#define L360_PS_QUADS  64

enum { L360_PS_TOP, L360_PS_BOTTOM, L360_PS_RANDOM };
enum { L360_PS_AREA_NONE, L360_PS_AREA_UNIFORM, L360_PS_AREA_NORMAL, L360_PS_AREA_ELLIPSE,
       L360_PS_AREA_BORDER_ELLIPSE, L360_PS_AREA_BORDER_RECTANGLE };

typedef struct l360_particle {
    struct l360_particle *prev, *next;
    float lifetime, life;
    float x, y, ox, oy;              /* position, and where the emitter was when it was emitted */
    float vx, vy;
    float ax, ay;                    /* linear acceleration */
    float radial, tangential, damping;
    float size, size_offset, size_interval;
    float rotation, angle, spin_start, spin_end;
    float color[4];
    int quad;
} l360_particle;

typedef struct { float x, y, w, h, sw, sh; } l360_ps_quad;

typedef struct {
    l360_particle *mem, *free, *head, *tail;
    uint32_t max, count;
    uint32_t rng;
    int active, insert_mode;
    float rate, emit_counter;
    float x, y, prev_x, prev_y;
    int area, area_relative;
    float area_x, area_y, area_angle;
    float lifetime, life;            /* of the emitter; -1 = forever */
    float life_min, life_max;
    float direction, spread;
    float speed_min, speed_max;
    float accel_min[2], accel_max[2];
    float radial_min, radial_max, tangential_min, tangential_max;
    float damping_min, damping_max;
    float sizes[L360_PS_SIZES]; int nsizes; float size_variation;
    float colors[L360_PS_COLORS][4]; int ncolors;
    float rotation_min, rotation_max;
    float spin_start, spin_end, spin_variation;
    float offset_x, offset_y; int default_offset;
    int relative_rotation;
    l360_ps_quad quads[L360_PS_QUADS]; int nquads;
} l360_ps;

/* LOVE's defaults, a new seed and no pool yet */
void l360_ps_init(l360_ps *ps);
/* Frees the pool and allocates one of `size` particles; the live particles are lost (as in LOVE).
 * 0 on success, -1 if size is 0 or there is no memory (the old pool is kept then). */
int  l360_ps_set_buffer_size(l360_ps *ps, uint32_t size);
void l360_ps_free(l360_ps *ps);
/* dst (already initialized or not) becomes a copy of src's settings with its own empty pool */
int  l360_ps_clone(l360_ps *dst, const l360_ps *src);
void l360_ps_emit(l360_ps *ps, uint32_t n);
void l360_ps_update(l360_ps *ps, float dt);
void l360_ps_start(l360_ps *ps);
void l360_ps_stop(l360_ps *ps);
void l360_ps_pause(l360_ps *ps);
void l360_ps_reset(l360_ps *ps);
void l360_ps_set_emission_rate(l360_ps *ps, float rate);
#endif
