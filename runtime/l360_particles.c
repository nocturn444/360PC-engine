/*
 * 360PC-Engine - the particle simulation of love.graphics.newParticleSystem.
 *
 * Adapted from LOVE 11.5's src/modules/graphics/ParticleSystem.cpp, rewritten in C: the same
 * steps in the same order, so a system set up the same way behaves as on PC. This is an altered
 * version, not the original software. What differs: the random generator (see l360_particles.h;
 * the particles are alike, not the same ones), fixed limits for sizes, colours and quads, and no
 * drawing here. LOVE's notice:
 *
 * Copyright (c) 2006-2023 LOVE Development Team
 *
 * This software is provided 'as-is', without any express or implied
 * warranty.  In no event will the authors be held liable for any damages
 * arising from the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, subject to the following restrictions:
 *
 * 1. The origin of this software must not be misrepresented; you must not
 *    claim that you wrote the original software. If you use this software
 *    in a product, an acknowledgment in the product documentation would be
 *    appreciated but is not required.
 * 2. Altered source versions must be plainly marked as such, and must not be
 *    misrepresented as being the original software.
 * 3. This notice may not be removed or altered from any source distribution.
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "l360_particles.h"

#define PS_PI 3.14159265358979323846f

static uint32_t seed_counter;

static uint32_t rnd_u32(l360_ps *ps)
{
    uint32_t x = ps->rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return ps->rng = x;
}

/* [0, 1) from the top 24 bits: exact in a float */
static float rnd01(l360_ps *ps) { return (float)(rnd_u32(ps) >> 8) * (1.0f / 16777216.0f); }
static float rnd(l360_ps *ps, float min, float max) { return min + rnd01(ps) * (max - min); }

static float rnd_normal(l360_ps *ps, float stddev)
{
    float r = sqrtf(-2.0f * logf(1.0f - rnd01(ps)));
    return r * cosf(2.0f * PS_PI * rnd01(ps)) * stddev;
}

static void seed(l360_ps *ps)
{
    /* a different, never zero, state for each system, in creation order */
    ps->rng = (++seed_counter * 0x9E3779B9u) ^ 0x2545F491u;
    if (!ps->rng)
        ps->rng = 0x9E3779B9u;
    rnd_u32(ps);
}

void l360_ps_init(l360_ps *ps)
{
    memset(ps, 0, sizeof(*ps));
    ps->active = 1;
    ps->insert_mode = L360_PS_TOP;
    ps->lifetime = -1;
    ps->sizes[0] = 1;
    ps->nsizes = 1;
    ps->colors[0][0] = ps->colors[0][1] = ps->colors[0][2] = ps->colors[0][3] = 1;
    ps->ncolors = 1;
    ps->default_offset = 1;
    seed(ps);
}

void l360_ps_reset(l360_ps *ps)
{
    ps->free = ps->mem;
    ps->head = ps->tail = NULL;
    ps->count = 0;
    ps->life = ps->lifetime;
    ps->emit_counter = 0;
}

int l360_ps_set_buffer_size(l360_ps *ps, uint32_t size)
{
    if (size == 0 || size > 0x7FFFFFFFu / sizeof(l360_particle))
        return -1;
    l360_particle *mem = malloc((size_t)size * sizeof(l360_particle));
    if (!mem)
        return -1;
    free(ps->mem);
    ps->mem = mem;
    ps->max = size;
    l360_ps_reset(ps);
    return 0;
}

void l360_ps_free(l360_ps *ps)
{
    free(ps->mem);
    ps->mem = ps->free = ps->head = ps->tail = NULL;
    ps->max = ps->count = 0;
}

int l360_ps_clone(l360_ps *dst, const l360_ps *src)
{
    *dst = *src;
    dst->mem = NULL;
    dst->max = 0;
    seed(dst);
    if (l360_ps_set_buffer_size(dst, src->max) != 0) {
        l360_ps_free(dst);
        return -1;
    }
    return 0;
}

void l360_ps_start(l360_ps *ps) { ps->active = 1; }
void l360_ps_pause(l360_ps *ps) { ps->active = 0; }
void l360_ps_stop(l360_ps *ps)
{
    ps->active = 0;
    ps->life = ps->lifetime;
    ps->emit_counter = 0;
}

void l360_ps_set_emission_rate(l360_ps *ps, float rate)
{
    ps->rate = rate;
    /* as LOVE: no burst when the rate goes up a lot */
    if (rate > 0 && ps->emit_counter > 1.0f / rate)
        ps->emit_counter = 1.0f / rate;
}

static float variation(l360_ps *ps, float inner, float outer, float var)
{
    float low = inner - (outer / 2.0f) * var;
    float high = inner + (outer / 2.0f) * var;
    float r = rnd01(ps);
    return low * (1 - r) + high * r;
}

static void init_particle(l360_ps *ps, l360_particle *p, float t)
{
    /* between the emitter's previous and current position */
    float px = ps->prev_x + (ps->x - ps->prev_x) * t;
    float py = ps->prev_y + (ps->y - ps->prev_y) * t;

    p->life = ps->life_min == ps->life_max ? ps->life_min : rnd(ps, ps->life_min, ps->life_max);
    p->lifetime = p->life;
    p->x = px;
    p->y = py;

    float dir = rnd(ps, ps->direction - ps->spread / 2.0f, ps->direction + ps->spread / 2.0f);

    if (ps->area != L360_PS_AREA_NONE) {
        const float c = cosf(ps->area_angle), s = sinf(ps->area_angle);
        const float ax = ps->area_x, ay = ps->area_y;
        float dx = 0, dy = 0, rx, ry;
        switch (ps->area) {
        case L360_PS_AREA_UNIFORM:
            dx = rnd(ps, -ax, ax);
            dy = rnd(ps, -ay, ay);
            break;
        case L360_PS_AREA_NORMAL:
            dx = rnd_normal(ps, ax);
            dy = rnd_normal(ps, ay);
            break;
        case L360_PS_AREA_ELLIPSE:
            rx = rnd(ps, -1, 1);
            ry = rnd(ps, -1, 1);
            dx = ax * (rx * sqrtf(1 - 0.5f * ry * ry));
            dy = ay * (ry * sqrtf(1 - 0.5f * rx * rx));
            break;
        case L360_PS_AREA_BORDER_ELLIPSE:
            rx = rnd(ps, 0, PS_PI * 2);
            dx = cosf(rx) * ax;
            dy = sinf(rx) * ay;
            break;
        case L360_PS_AREA_BORDER_RECTANGLE:
            rx = rnd(ps, (ax + ay) * -2, (ax + ay) * 2);
            ry = ay * 2;
            if (rx < -ry)     { dx = rx + ry + ax; dy = -ay; }
            else if (rx < 0)  { dx = -ax;          dy = rx + ay; }
            else if (rx < ry) { dx = ax;           dy = rx - ay; }
            else              { dx = rx - ry - ax; dy = ay; }
            break;
        }
        p->x += c * dx - s * dy;
        p->y += c * dy + s * dx;
    }
    if (ps->area_relative)
        dir += atan2f(p->y - py, p->x - px);

    p->ox = px;
    p->oy = py;

    float speed = rnd(ps, ps->speed_min, ps->speed_max);
    p->vx = cosf(dir) * speed;
    p->vy = sinf(dir) * speed;
    p->ax = rnd(ps, ps->accel_min[0], ps->accel_max[0]);
    p->ay = rnd(ps, ps->accel_min[1], ps->accel_max[1]);
    p->radial = rnd(ps, ps->radial_min, ps->radial_max);
    p->tangential = rnd(ps, ps->tangential_min, ps->tangential_max);
    p->damping = rnd(ps, ps->damping_min, ps->damping_max);

    p->size_offset = rnd(ps, 0, ps->size_variation);     /* time offset of the size change */
    p->size_interval = (1.0f - rnd(ps, 0, ps->size_variation)) - p->size_offset;
    p->size = ps->sizes[0];

    p->spin_start = variation(ps, ps->spin_start, ps->spin_end, ps->spin_variation);
    p->spin_end = variation(ps, ps->spin_end, ps->spin_start, ps->spin_variation);
    p->rotation = rnd(ps, ps->rotation_min, ps->rotation_max);
    p->angle = p->rotation;
    if (ps->relative_rotation)
        p->angle += atan2f(p->vy, p->vx);

    memcpy(p->color, ps->colors[0], sizeof(p->color));
    p->quad = 0;
}

static void insert_top(l360_ps *ps, l360_particle *p)
{
    if (!ps->head) {
        ps->head = p;
        p->prev = NULL;
    } else {
        ps->tail->next = p;
        p->prev = ps->tail;
    }
    p->next = NULL;
    ps->tail = p;
}

static void insert_bottom(l360_ps *ps, l360_particle *p)
{
    if (!ps->tail) {
        ps->tail = p;
        p->next = NULL;
    } else {
        ps->head->prev = p;
        p->next = ps->head;
    }
    p->prev = NULL;
    ps->head = p;
}

static void insert_random(l360_ps *ps, l360_particle *p)
{
    uint32_t pos = rnd_u32(ps) % (ps->count + 1);
    if (pos == ps->count) {          /* before the head */
        l360_particle *a = ps->head;
        if (a) a->prev = p; else ps->tail = p;
        p->prev = NULL;
        p->next = a;
        ps->head = p;
        return;
    }
    l360_particle *a = ps->mem + pos, *b = a->next;   /* after a random live particle */
    a->next = p;
    if (b) b->prev = p; else ps->tail = p;
    p->prev = a;
    p->next = b;
}

static void add_particle(l360_ps *ps, float t)
{
    if (ps->count == ps->max)
        return;
    l360_particle *p = ps->free++;
    init_particle(ps, p, t);
    switch (ps->insert_mode) {
    case L360_PS_BOTTOM: insert_bottom(ps, p); break;
    case L360_PS_RANDOM: insert_random(ps, p); break;
    default:             insert_top(ps, p); break;
    }
    ps->count++;
}

/* The live particles stay packed at the start of the pool: the last one in memory moves into the
 * slot that is freed. Returns the particle after p in the list. */
static l360_particle *remove_particle(l360_ps *ps, l360_particle *p)
{
    l360_particle *last = --ps->free, *next = NULL;
    if (p->prev) p->prev->next = p->next; else ps->head = p->next;
    if (p->next) { p->next->prev = p->prev; next = p->next; } else ps->tail = p->prev;
    if (p != last) {
        *p = *last;
        if (next == last) next = p;
        if (p->prev) p->prev->next = p; else ps->head = p;
        if (p->next) p->next->prev = p; else ps->tail = p;
    }
    ps->count--;
    return next;
}

void l360_ps_emit(l360_ps *ps, uint32_t n)
{
    if (!ps->active || !ps->mem)
        return;
    if (n > ps->max - ps->count)
        n = ps->max - ps->count;
    while (n--)
        add_particle(ps, 1.0f);
}

void l360_ps_update(l360_ps *ps, float dt)
{
    if (!ps->mem || dt == 0.0f)
        return;

    const int nsizes = ps->nsizes, ncolors = ps->ncolors, nquads = ps->nquads;
    l360_particle *p = ps->head;
    while (p) {
        p->life -= dt;
        if (p->life <= 0) {
            p = remove_particle(ps, p);
            continue;
        }
        /* radial: away from where it was emitted; tangential: at a right angle to that */
        float rx = p->x - p->ox, ry = p->y - p->oy;
        float len = sqrtf(rx * rx + ry * ry);
        if (len > 0) { rx /= len; ry /= len; }
        float tx = -ry * p->tangential, ty = rx * p->tangential;
        rx *= p->radial;
        ry *= p->radial;

        p->vx += (rx + tx + p->ax) * dt;
        p->vy += (ry + ty + p->ay) * dt;
        float damp = 1.0f / (1.0f + p->damping * dt);
        p->vx *= damp;
        p->vy *= damp;
        p->x += p->vx * dt;
        p->y += p->vy * dt;

        const float t = 1.0f - p->life / p->lifetime;

        p->rotation += (p->spin_start * (1.0f - t) + p->spin_end * t) * dt;
        p->angle = p->rotation;
        if (ps->relative_rotation)
            p->angle += atan2f(p->vy, p->vx);

        /* size and colour: t goes through the list in equal steps */
        float s = (p->size_offset + t * p->size_interval) * (float)(nsizes - 1);
        int i = (int)s;
        if (i < 0) i = 0;
        if (i > nsizes - 1) i = nsizes - 1;
        int k = (i == nsizes - 1) ? i : i + 1;
        s -= (float)i;
        p->size = ps->sizes[i] * (1.0f - s) + ps->sizes[k] * s;

        s = t * (float)(ncolors - 1);
        i = (int)s;
        if (i < 0) i = 0;
        if (i > ncolors - 1) i = ncolors - 1;
        k = (i == ncolors - 1) ? i : i + 1;
        s -= (float)i;
        for (int c = 0; c < 4; c++)
            p->color[c] = ps->colors[i][c] * (1.0f - s) + ps->colors[k][c] * s;

        if (nquads > 0) {
            s = t * (float)nquads;
            i = s > 0.0f ? (int)s : 0;
            p->quad = i < nquads ? i : nquads - 1;
        }
        p = p->next;
    }

    if (ps->active) {
        if (ps->rate > 0) {
            float rate = 1.0f / ps->rate;        /* time between two particles */
            ps->emit_counter += dt;
            float total = ps->emit_counter - rate;
            while (ps->emit_counter > rate) {
                add_particle(ps, 1.0f - (ps->emit_counter - rate) / total);
                ps->emit_counter -= rate;
            }
        }
        ps->life -= dt;
        if (ps->lifetime != -1 && ps->life < 0)
            l360_ps_stop(ps);
    }
    ps->prev_x = ps->x;
    ps->prev_y = ps->y;
}
