/* PC check of runtime/l360_particles.c, the simulation behind love.graphics.newParticleSystem
 * (it has no Lua and no GPU in it). From the repository root:
 *   gcc -std=gnu17 -Wall -Wextra -Werror -Iruntime tests/pc/particles_test.c runtime/l360_particles.c -lm -o /tmp/particles_test && /tmp/particles_test
 * must end with "OK:". */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "l360_particles.h"

static int checks;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { printf("FAILED (line %d): ", __LINE__); printf(__VA_ARGS__); printf("\n"); exit(1); } } while (0)
#define NEAR(a, b, eps) (fabsf((a) - (b)) <= (eps))

/* The list holds exactly `count` particles, all in the packed start of the pool, linked both ways */
static void check_list(const l360_ps *ps, const char *when)
{
    uint32_t n = 0;
    const l360_particle *prev = NULL;
    for (const l360_particle *p = ps->head; p; prev = p, p = p->next) {
        CHECK(p >= ps->mem && p < ps->free, "%s: a listed particle is outside the live part of the pool", when);
        CHECK(p->prev == prev, "%s: prev does not match", when);
        CHECK(++n <= ps->count, "%s: the list is longer than count", when);
    }
    CHECK(n == ps->count && ps->count <= ps->max, "%s: %u listed, count %u, max %u", when, n, ps->count, ps->max);
    CHECK((uint32_t)(ps->free - ps->mem) == ps->count, "%s: the pool is not packed", when);
    CHECK(ps->count == 0 ? !ps->head : ps->tail == prev, "%s: tail", when);
}

int main(void)
{
    l360_ps ps;
    l360_ps_init(&ps);
    CHECK(l360_ps_set_buffer_size(&ps, 0) != 0, "a pool of 0 particles is refused");
    CHECK(l360_ps_set_buffer_size(&ps, 64) == 0, "pool of 64");
    const l360_particle *pool = ps.mem;

    /* emit: capped by the pool; lifetime: all gone once it has passed */
    ps.life_min = 0.5f; ps.life_max = 1.0f;
    l360_ps_emit(&ps, 10);
    CHECK(ps.count == 10, "emit(10): %u", ps.count);
    l360_ps_emit(&ps, 1000);
    CHECK(ps.count == 64, "emit past the pool: %u", ps.count);
    check_list(&ps, "full");
    for (const l360_particle *p = ps.head; p; p = p->next)
        CHECK(p->lifetime >= 0.5f && p->lifetime < 1.0f, "lifetime in range: %f", p->lifetime);
    l360_ps_update(&ps, 0.49f);
    CHECK(ps.count == 64, "nothing dies before the shortest lifetime: %u", ps.count);
    l360_ps_update(&ps, 0.26f);
    CHECK(ps.count > 0 && ps.count < 64, "some die between the two lifetimes: %u", ps.count);
    check_list(&ps, "after some died");
    l360_ps_update(&ps, 0.26f);
    CHECK(ps.count == 0, "all dead after the longest lifetime: %u", ps.count);
    check_list(&ps, "empty");

    /* emission rate: 30 a second; the pool caps it; the pool never moves */
    ps.life_min = ps.life_max = 10;
    l360_ps_set_emission_rate(&ps, 30);
    for (int i = 0; i < 60; i++) l360_ps_update(&ps, 1.0f / 60);
    CHECK(ps.count >= 29 && ps.count <= 30, "30 a second for a second: %u", ps.count);
    for (int i = 0; i < 300; i++) { l360_ps_update(&ps, 1.0f / 60); CHECK(ps.count <= 64, "over the pool"); }
    CHECK(ps.count == 64 && ps.mem == pool, "the pool is full and was not reallocated: %u", ps.count);
    l360_ps_emit(&ps, 10);
    CHECK(ps.count == 64, "emit into a full pool: %u", ps.count);

    /* stop, pause, start, reset */
    l360_ps_pause(&ps);
    l360_ps_emit(&ps, 1);
    CHECK(!ps.active && ps.count == 64, "paused");
    l360_ps_reset(&ps);
    CHECK(ps.count == 0, "reset");
    l360_ps_update(&ps, 1);
    CHECK(ps.count == 0, "a paused system emits nothing: %u", ps.count);
    l360_ps_start(&ps);

    /* emitter lifetime: emits for half a second, then stops by itself */
    ps.lifetime = ps.life = 0.5f;
    for (int i = 0; i < 120; i++) l360_ps_update(&ps, 1.0f / 60);
    CHECK(!ps.active && ps.count >= 14 && ps.count <= 16, "emitter lifetime 0.5 s at 30/s: %u", ps.count);
    ps.lifetime = ps.life = -1;
    l360_ps_set_emission_rate(&ps, 0);
    l360_ps_start(&ps);
    l360_ps_reset(&ps);

    /* movement: speed along the direction, linear acceleration, damping */
    ps.speed_min = ps.speed_max = 100;
    ps.direction = 0; ps.spread = 0;
    ps.x = ps.prev_x = 10; ps.y = ps.prev_y = 20;
    l360_ps_emit(&ps, 1);
    for (int i = 0; i < 100; i++) l360_ps_update(&ps, 0.01f);
    CHECK(NEAR(ps.head->x, 110, 0.05f) && NEAR(ps.head->y, 20, 0.001f), "100 px/s for 1 s: %f %f", ps.head->x, ps.head->y);
    l360_ps_reset(&ps);
    ps.speed_min = ps.speed_max = 0;
    ps.accel_min[1] = ps.accel_max[1] = 200;
    l360_ps_emit(&ps, 1);
    for (int i = 0; i < 100; i++) l360_ps_update(&ps, 0.01f);
    CHECK(NEAR(ps.head->vy, 200, 0.05f) && NEAR(ps.head->y, 20 + 101, 0.1f), "gravity 200 px/s2 for 1 s: %f %f", ps.head->vy, ps.head->y);
    l360_ps_reset(&ps);
    ps.accel_min[1] = ps.accel_max[1] = 0;
    ps.speed_min = ps.speed_max = 100;
    ps.damping_min = ps.damping_max = 5;
    l360_ps_emit(&ps, 1);
    for (int i = 0; i < 100; i++) l360_ps_update(&ps, 0.01f);
    CHECK(ps.head->vx > 0 && ps.head->vx < 2, "damping slows it down: %f", ps.head->vx);
    l360_ps_reset(&ps);
    ps.damping_min = ps.damping_max = 0;

    /* spread: directions within +-spread/2; sizes, colours and quads follow the particle's life */
    ps.spread = 1.0f;
    ps.direction = 2.0f;
    l360_ps_emit(&ps, 64);
    for (const l360_particle *p = ps.head; p; p = p->next) {
        float a = atan2f(p->vy, p->vx);
        CHECK(a >= 1.5f - 0.001f && a <= 2.5f + 0.001f, "direction within the spread: %f", a);
    }
    l360_ps_reset(&ps);
    ps.speed_min = ps.speed_max = 0;
    ps.sizes[0] = 1; ps.sizes[1] = 3; ps.sizes[2] = 0; ps.nsizes = 3;
    ps.colors[1][0] = 0; ps.colors[1][1] = 0.5f; ps.colors[1][2] = 1; ps.colors[1][3] = 0; ps.ncolors = 2;
    ps.nquads = 4;
    ps.spin_start = ps.spin_end = 2;
    l360_ps_emit(&ps, 1);
    CHECK(ps.head->size == 1 && ps.head->color[3] == 1 && ps.head->quad == 0, "a new particle has the first size and colour");
    l360_ps_update(&ps, 2.5f);           /* a quarter of its 10 s */
    CHECK(NEAR(ps.head->size, 2, 0.001f), "size halfway to the second: %f", ps.head->size);
    CHECK(NEAR(ps.head->color[0], 0.75f, 0.001f) && NEAR(ps.head->color[3], 0.75f, 0.001f), "colour a quarter of the way: %f", ps.head->color[0]);
    CHECK(ps.head->quad == 1 && NEAR(ps.head->angle, 5, 0.001f), "second quad of 4, spun 5 rad: %d %f", ps.head->quad, ps.head->angle);
    l360_ps_update(&ps, 7.4f);
    CHECK(ps.head->size < 0.1f && ps.head->color[3] < 0.02f && ps.head->quad == 3, "near its end: last size, colour and quad");
    l360_ps_reset(&ps);
    ps.nsizes = ps.ncolors = 1; ps.nquads = 0; ps.spin_start = ps.spin_end = 0;

    /* emission areas: every particle inside (or on the border of) its area */
    static const int areas[] = {L360_PS_AREA_UNIFORM, L360_PS_AREA_ELLIPSE, L360_PS_AREA_BORDER_ELLIPSE,
                                L360_PS_AREA_BORDER_RECTANGLE, L360_PS_AREA_NORMAL};
    ps.area_x = 30; ps.area_y = 10;
    for (int k = 0; k < 5; k++) {
        ps.area = areas[k];
        l360_ps_emit(&ps, 64);
        float far = 0;
        for (const l360_particle *p = ps.head; p; p = p->next) {
            float dx = fabsf(p->x - 10), dy = fabsf(p->y - 20);
            if (dx > far) far = dx;
            if (areas[k] == L360_PS_AREA_NORMAL) continue;
            CHECK(dx <= 30.001f && dy <= 10.001f, "area %d: inside the box: %f %f", areas[k], dx, dy);
            if (areas[k] == L360_PS_AREA_BORDER_RECTANGLE)
                CHECK(NEAR(dx, 30, 0.001f) || NEAR(dy, 10, 0.001f), "on the rectangle's border: %f %f", dx, dy);
            if (areas[k] == L360_PS_AREA_BORDER_ELLIPSE)
                CHECK(NEAR(dx * dx / 900 + dy * dy / 100, 1, 0.001f), "on the ellipse's border: %f %f", dx, dy);
        }
        CHECK(far > 10, "area %d: the particles are spread out: %f", areas[k], far);
        l360_ps_reset(&ps);
    }
    ps.area = L360_PS_AREA_NONE;

    /* the three insert modes with particles dying all the time: the list stays whole, the pool is
     * never exceeded */
    ps.life_min = 0.05f; ps.life_max = 0.6f;
    l360_ps_set_emission_rate(&ps, 500);
    for (int mode = L360_PS_TOP; mode <= L360_PS_RANDOM; mode++) {
        ps.insert_mode = mode;
        uint32_t most = 0;
        for (int i = 0; i < 400; i++) {
            if (i % 7 == 0) l360_ps_emit(&ps, 5);
            l360_ps_update(&ps, i % 3 ? 0.016f : 0.033f);
            check_list(&ps, "churn");
            if (ps.count > most) most = ps.count;
        }
        CHECK(most == 64, "insert mode %d: the pool filled up: %u", mode, most);
        if (mode == L360_PS_TOP)
            for (const l360_particle *p = ps.head; p && p->next; p = p->next)
                CHECK(p->lifetime - p->life >= p->next->lifetime - p->next->life - 0.0001f, "top: oldest first");
        l360_ps_reset(&ps);
    }

    /* clone: the same settings, its own empty pool; setBufferSize: a new empty pool */
    l360_ps copy;
    l360_ps_emit(&ps, 5);
    CHECK(l360_ps_clone(&copy, &ps) == 0, "clone");
    CHECK(copy.max == 64 && copy.count == 0 && copy.mem != ps.mem && copy.rate == 500 && copy.rng != ps.rng, "the clone is empty and separate");
    l360_ps_emit(&copy, 3);
    CHECK(copy.count == 3 && ps.count == 5, "the clone has its own particles");
    check_list(&copy, "clone");
    CHECK(l360_ps_set_buffer_size(&ps, 8) == 0 && ps.max == 8 && ps.count == 0, "setBufferSize empties the system");
    l360_ps_emit(&ps, 100);
    CHECK(ps.count == 8, "the new pool caps emit: %u", ps.count);
    l360_ps_free(&ps);
    l360_ps_free(&copy);
    l360_ps_update(&ps, 1);
    l360_ps_emit(&ps, 1);
    CHECK(ps.count == 0, "a freed system does nothing");

    printf("OK: %d checks\n", checks);
    return 0;
}
