/*
 * Love360 - love.graphics sobre la GPU de xsdk (tarea 07), para la logica de Balatro.
 *
 * Copia de runtime/source/l360_gfx.c (libXenon) con otra capa de abajo: la transformacion de
 * vertices, los lotes, la tabla de programas y registros de shader y los tipos de Lua son los
 * mismos. Cambia como se habla con la GPU (xsdk_gpu_*, xsdk_present_*, xsdk_texture_*).
 *
 * Como LOVE 11: cada dibujo se transforma en la CPU con la pila de transformaciones
 * (asi el shader recibe posiciones en pixeles de pantalla, que es lo que espera
 * Balatro) y se manda como un par de triangulos con sus constantes.
 *
 * Pasos 2a a 2d: pantalla, figuras de color, imagenes, texto, canvas (resolve a su textura) y los
 * shaders del juego (dissolve, background, CRT y los efectos de carta).
 *
 * Tipos (userdata con metatabla):
 *   Image / Canvas  textura de xsdk + tamano en unidades de LOVE (dpiscale aplicado)
 *   Quad            recorte de una textura
 *   Shader          programa traducido (dissolve, background, CRT) o el de defecto
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>

#include "xsdk/gpu.h"
#include "xsdk/kernel.h"
#include "xsdk/present.h"
#include "xsdk/shader.h"
#include "xsdk/texture.h"
#include "xsdk/xam.h"

#include "lua.h"
#include "lauxlib.h"

/* 1 desde el paso 2b: imagenes (stb_image) y texto (atlas de stb_truetype) como texturas de xsdk.
 * Con 0 (paso 2a) newImage solo lee el tamano del PNG y las fuentes no arman su atlas: imagenes y
 * texto se cuentan como "skipped" y solo se ven las figuras de color. */
#define L360_TEXTURAS 1

/* 1 desde el paso 2d: cada dibujo usa el programa que pidio el juego (dissolve, background, CRT,
 * efectos de carta). Con 0 todo se dibuja con default.psu/.vsu (paso 2b: probar solo texturas);
 * newShader responde igual en los dos casos, para que Lua haga lo mismo. */
#define L360_SHADERS 1

/* Interruptores de prueba sin recompilar: palabras en game:\l360_gfx.txt (una o varias):
 *   no_canvas      setCanvas no hace nada y dibujar un canvas tampoco: todo va directo a la pantalla
 *   canvas_default  el canvas se dibuja con default.psu en lugar del shader que pida el juego (CRT)
 *   no_shaders     todo con default.psu/.vsu (como L360_SHADERS 0)
 *   no_literals   no carga los literales de los shaders de XNA (como antes de arreglarlo)
 *   no_batching       un draw por cada submit, sin juntar los que comparten estado
 * Los shaders de xost (compilar_xost.py) y los de XNA van juntos en game:\shaders\: cada .psu/.vsu
 * se reconoce por su cabecera (L3X1 = xost). El interruptor shaders_xost ya no hace falta. */
static int opt_no_canvas, opt_canvas_default, opt_no_shaders, opt_no_batching;
/* para el registro cada 300 frames */
static long st_canvas_resolves, st_screen_resolves, st_last_draws, st_last_submits;

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#pragma GCC diagnostic ignored "-Wsign-compare"
#pragma GCC diagnostic ignored "-Wunused-parameter"
#pragma GCC diagnostic ignored "-Wimplicit-fallthrough"
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STBI_NO_THREAD_LOCALS
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define STBTT_STATIC
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
#pragma GCC diagnostic pop

#include "l360_gfx.h"

/* ---------- dispositivo ---------- */

enum {
    BEGIN_TIMEOUT_MS = 5000,     /* la primera apertura de la Guia retuvo un frame 2,7 s (xsdk) */
    FENCE_TIMEOUT_MS = 1000,
};

static int W, H;
static float proj[16];
static int gpu_ok;               /* 0 si la GPU se colgo: los dibujos se descartan */
static void (*log_cb)(const char *);

static void gfx_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void gfx_log(const char *fmt, ...)
{
    char line[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    if (log_cb) log_cb(line);
}

static double now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1000.0 + (double)t.tv_nsec / 1e6;
}

/* Textura de xsdk y su filtro (libXenon lo guardaba en la superficie) */
typedef struct {
    XsdkTexture t;
    int linear;
} surf_t;
static surf_t *white_tex;
static XsdkSamplerState samp_linear, samp_point;
static XsdkBlendState blend_alpha;

typedef struct {
    float x, y, z, w;
    float u, v;
    float r, g, b, a;
} vertex_t;                                     /* 40 bytes = 10 dwords */

/* La misma disposicion que el vbf de libXenon: posicion, uv y color en el stream 0 */
static const XsdkVertexElement layout[] = {
    {.usage = XSDK_USAGE_POSITION, .format = XSDK_VERTEX_FLOAT4, .offset_bytes = 0},
    {.usage = XSDK_USAGE_TEXCOORD, .format = XSDK_VERTEX_FLOAT2, .offset_bytes = 16},
    {.usage = XSDK_USAGE_COLOR,    .format = XSDK_VERTEX_FLOAT4, .offset_bytes = 24},
};
static const uint32_t layout_stride[] = {sizeof(vertex_t)};

/* Un solo bloque de memoria de GPU con dos mitades: un frame escribe una mientras la GPU puede
 * estar leyendo la otra (el fence de cada mitad dice cuando la GPU termino con ella). */
#define VB_VERTS 120000
#define VB_BYTES (VB_VERTS * (uint32_t)sizeof(vertex_t))
static volatile uint32_t *vb_mem;
static uint32_t vb_addr[2];
static uint32_t vb_fence[2];
static int vb_pending[2];
static vertex_t *vb_base;
static int vb_cur, vb_index;

/* La memoria de GPU se escribe con el memcpy de xsdk (stores de 32 bits) o con stores volatile,
 * nunca con stores comunes (docs/PITFALLS.md de xsdk). Por puntero volatile: con un tamano fijo
 * (6 vertices de emit_quad) GCC podria cambiar la llamada por stores propios de 64 bits. */
static void *(*volatile gpu_memcpy)(void *, const void *, size_t) = memcpy;

l360_gfx_stats_t l360_gfx_stats;

/* ---------- estado de LOVE ---------- */

typedef struct { float a, b, c, d, e, f; } mat_t;   /* x' = a x + c y + e ; y' = b x + d y + f */
#define STACK_MAX 128
static mat_t mstack[STACK_MAX];
static int msp;
static float color[4] = {1, 1, 1, 1};
static float line_width = 1.0f;
static float clear_color[4] = {0, 0, 0, 1};
static int default_linear = 1;

/* ---------- shaders ---------- */

/* Shaders traducidos con glsl2hlsl.py (y sus vertices). El nombre es el del .fs de Balatro. */
#define N_GEN 16
static const char *gen_names[N_GEN] = {
    "booster", "debuff", "foil", "holo", "hologram", "negative", "negative_shine", "played",
    "polychrome", "voucher", "flame", "splash", "flash", "gold_seal", "vortex", "skew"};
enum { PROG_DEFAULT, PROG_DISSOLVE, PROG_BACKGROUND, PROG_CRT, PROG_GEN, PROG_COUNT = PROG_GEN + N_GEN };

/* name "" = el uniform que se llama como el shader (foil, holo, ...) */
typedef struct { const char *name; int vs; int reg; int comp; int n; } umap_t;

static const umap_t map_edition[] = {
    {"dissolve", 0, 0, 0, 1}, {"time", 0, 0, 1, 1}, {"shadow", 0, 0, 2, 1},
    {"texture_details", 0, 1, 0, 4}, {"image_details", 0, 2, 0, 2},
    {"burn_colour_1", 0, 3, 0, 4}, {"burn_colour_2", 0, 4, 0, 4}, {"", 0, 5, 0, 2},
    {"mouse_screen_pos", 1, 5, 0, 2}, {"hovering", 1, 5, 2, 1}, {"screen_scale", 1, 5, 3, 1},
    {NULL, 0, 0, 0, 0}};
static const umap_t map_flame[] = {
    {"time", 0, 0, 0, 1}, {"amount", 0, 0, 1, 1}, {"id", 0, 0, 2, 1},
    {"texture_details", 0, 1, 0, 4}, {"image_details", 0, 2, 0, 2},
    {"colour_1", 0, 3, 0, 4}, {"colour_2", 0, 4, 0, 4},
    {NULL, 0, 0, 0, 0}};
static const umap_t map_splash[] = {
    {"time", 0, 0, 0, 1}, {"vort_speed", 0, 0, 1, 1}, {"mid_flash", 0, 0, 2, 1}, {"vort_offset", 0, 0, 3, 1},
    {"colour_1", 0, 1, 0, 4}, {"colour_2", 0, 2, 0, 4},
    {NULL, 0, 0, 0, 0}};
static const umap_t map_flash[] = {
    {"time", 0, 0, 0, 1}, {"mid_flash", 0, 0, 1, 1}, {NULL, 0, 0, 0, 0}};
static const umap_t map_gold_seal[] = {
    {"gold_seal", 0, 0, 0, 4}, {NULL, 0, 0, 0, 0}};
static const umap_t map_vortex[] = {
    {"vortex_amt", 1, 5, 0, 1}, {NULL, 0, 0, 0, 0}};
static const umap_t map_skew[] = {
    {"mouse_screen_pos", 1, 5, 0, 2}, {"hovering", 1, 5, 2, 1}, {"screen_scale", 1, 5, 3, 1},
    {NULL, 0, 0, 0, 0}};

static const umap_t map_dissolve[] = {
    {"dissolve", 0, 0, 0, 1}, {"time", 0, 0, 1, 1}, {"shadow", 0, 0, 2, 1},
    {"texture_details", 0, 1, 0, 4}, {"image_details", 0, 2, 0, 2},
    {"burn_colour_1", 0, 3, 0, 4}, {"burn_colour_2", 0, 4, 0, 4},
    {"mouse_screen_pos", 1, 5, 0, 2}, {"hovering", 1, 5, 2, 1}, {"screen_scale", 1, 5, 3, 1},
    {NULL, 0, 0, 0, 0}};
static const umap_t map_background[] = {
    {"time", 0, 0, 0, 1}, {"spin_time", 0, 0, 1, 1}, {"contrast", 0, 0, 2, 1}, {"spin_amount", 0, 0, 3, 1},
    {"colour_1", 0, 1, 0, 4}, {"colour_2", 0, 2, 0, 4}, {"colour_3", 0, 3, 0, 4},
    {NULL, 0, 0, 0, 0}};
static const umap_t map_crt[] = {
    {"time", 0, 0, 0, 1}, {"feather_fac", 0, 0, 1, 1}, {"noise_fac", 0, 0, 2, 1}, {"bloom_fac", 0, 0, 3, 1},
    {"distortion_fac", 0, 1, 0, 2}, {"scale_fac", 0, 1, 2, 2},
    {"crt_intensity", 0, 2, 0, 1}, {"glitch_intensity", 0, 2, 1, 1}, {"scanlines", 0, 2, 2, 1},
    {"mouse_screen_pos", 1, 5, 0, 2}, {"hovering", 1, 5, 2, 1}, {"screen_scale", 1, 5, 3, 1},
    {NULL, 0, 0, 0, 0}};

typedef struct {
    XsdkShader *ps, *ps_alt, *vs, *vs_alt;  /* ps_alt: dissolve con quemado; vs_alt: su .vsu enlazado a el */
    const umap_t *map;
    int ps_screen_reg;                      /* registro PS con love_ScreenSize, -1 = ninguno */
    int ps_regs;                            /* cuantos registros PS subir */
} prog_t;
static prog_t progs[PROG_COUNT];

typedef struct {
    int prog;
    float ps[8][4];
    float vs[8][4];
    char name[32];
} shader_ud;

static shader_ud *cur_shader;

/* ---------- texturas ---------- */

#define TEX_IMAGE  1
#define TEX_CANVAS 2
typedef struct {
    int kind;
    surf_t *s;                  /* NULL: todavia sin textura (paso 2a) */
    float w, h, dpi;
    char path[64];
} tex_ud;

typedef struct { float x, y, w, h, sw, sh; } quad_ud;

static tex_ud *cur_canvas;      /* canvas activo o NULL = pantalla */

/* ---------- utilidades ---------- */

static void build_ortho(void)
{
    float m[16] = {
        2.0f / W, 0, 0, -1,
        0, -2.0f / H, 0, 1,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
    memcpy(proj, m, sizeof(m));
}

static int shaders_loaded, shaders_missing, shaders_bad, shaders_lits, shaders_xost;

/* Literales de los shaders de XNA: los numeros fijos del HLSL (0.5, 2.0...) no van en el
 * microcodigo, van en la tabla de definiciones del contenedor (palabra 5 de la cabecera) y hay que
 * cargarlos en las constantes cada vez que se pone el shader. libXenon lo hace en
 * Xe_pUploadShaderConstants; xsdk_shader_load no (solo conoce las de xost, que tienen
 * xsdk_built_shader_set_literals). Sin esto, dissolve, el CRT y los efectos leen basura. */
#define LIT_MAX 64               /* los de xost vienen de a un registro: se juntan los seguidos */
typedef struct { uint32_t first, count; const float *v; } lit_t;   /* count en grupos de 4 floats */
typedef struct {
    XsdkShader sh;               /* primero: el XsdkShader * de las tablas apunta tambien aca */
    int pixel;
    int nlit;
    lit_t lit[LIT_MAX];
    uint32_t vmin;               /* la constante de vertice mas baja que pisa un literal */
    uint32_t bools[8], bool_mask;
    uint32_t loops[32], loop_mask;
    float hi[4 * 4];             /* c252-c255 de pixel (XNA pone los literales arriba de todo) */
    int has_hi;
} shader_t;

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint32_t be16(const uint8_t *p) { return (uint32_t)p[0] << 8 | p[1]; }

static void parse_literals(shader_t *s, const uint8_t *c, uint32_t n, const char *name)
{
    s->vmin = 0xFFFFFFFFu;
    s->hi[12] = s->hi[13] = 0.5f;                /* c255 como lo deja xsdk si el shader no la usa */
    if (n < 0x24)
        return;
    uint32_t off = be32(c + 0x14), base = be32(c + 4);
    if (!off || off > n)
        return;
    uint32_t p = off + 20;                       /* 16 bytes y el tamano, como libXenon */
    for (;;) {                                   /* floats: inicio, cantidad de floats, offset */
        if (p + 4 > n) return;
        uint32_t start = be16(c + p), count = be16(c + p + 2);
        p += 4;
        if (!count) break;
        if (p + 4 > n) return;
        uint32_t at = base + be32(c + p);
        p += 4;
        if (at > n || count * 4 > n - at || at % 4) {
            gfx_log(" [shader] %s: literal outside the file, skipping it", name);
            continue;
        }
        uint32_t reg = start;
        if (s->pixel) {
            if (reg < 256) {
                gfx_log(" [shader] %s: pixel literal at c%u (expected 256 or higher)", name, (unsigned)reg);
            } else {
                reg -= 256;
            }
        }
        uint32_t groups = (count + 3) / 4;
        if (reg + groups > XSDK_FLOAT_CONSTANTS) {
            gfx_log(" [shader] %s: literals c%u..c%u out of range", name, (unsigned)reg, (unsigned)(reg + groups - 1));
            continue;
        }
        /* las de pixel desde c252 van aparte, en put_hi_constants */
        if (s->pixel && reg + groups > XSDK_PIXEL_CONSTANTS) {
            uint32_t from = reg > XSDK_PIXEL_CONSTANTS ? reg : XSDK_PIXEL_CONSTANTS;
            for (uint32_t r = from; r < reg + groups; r++)
                for (uint32_t k = 0; k < 4; k++)
                    if ((r - reg) * 4 + k < count)
                        memcpy(&s->hi[(r - XSDK_PIXEL_CONSTANTS) * 4 + k], c + at + ((r - reg) * 4 + k) * 4, 4);
            s->has_hi = 1;
            if (reg >= XSDK_PIXEL_CONSTANTS)
                continue;
            count = (XSDK_PIXEL_CONSTANTS - reg) * 4;
            groups = XSDK_PIXEL_CONSTANTS - reg;
        }
        if (s->nlit == LIT_MAX) {
            gfx_log(" [shader] %s: more than %d literal groups", name, LIT_MAX);
            continue;
        }
        float *v = calloc(groups * 4, sizeof(float));
        memcpy(v, c + at, (count < groups * 4 ? count : groups * 4) * 4);
        s->lit[s->nlit++] = (lit_t){reg, groups, v};
        if (!s->pixel && reg < s->vmin) s->vmin = reg;
    }
    for (;;) {                                   /* enteros: booleanos y contadores de bucles */
        if (p + 4 > n) return;
        uint32_t start = be16(c + p), count = be16(c + p + 2);
        p += 4;
        if (!count) break;
        if (start < 0x2300 || count * 4 > n - p) return;
        uint32_t idx = (start - 0x2300) / 4;     /* 0-7: palabras de booleanos; 8-39: bucles */
        for (uint32_t k = 0; k < count; k++) {
            uint32_t i = idx + k, w = be32(c + p + k * 4);
            if (i < 8) { s->bools[i] = w; s->bool_mask |= 1u << i; }
            else if (i < 40) { s->loops[i - 8] = w; s->loop_mask |= 1u << (i - 8); }
        }
        p += count * 4 + 4;
    }
}

static int opt_no_literals;

/* c252-c255 de pixel: xsdk_gpu_set_pixel_constants no llega (assert), porque xsdk usa c255 para el
 * gl_FragCoord de los shaders de xost. Love360 no usa esos shaders ni los pases en bandas, asi que
 * el grupo se escribe con un paquete propio, como set_floats de xsdk (src/gpu_constants.c): NOPs
 * hasta que los valores empiecen en 16 bytes, la cabecera tipo 0 y los 16 floats. xsdk vuelve a
 * poner c255 cuando XAM dibuja (Guia) y ahi frame_state hace que se escriba de nuevo. */
#define PS_CONST_252 (0x4400u + 252u * 4u)
static void put_hi_constants(const float *v)
{
    volatile uint32_t *pk = xsdk_gpu_reserve(3 + 1 + 16);
    uint32_t before = (3u - ((uint32_t)(uintptr_t)pk >> 2)) & 3u, i = 0;
    for (; i < before; i++)
        pk[i] = 0x80000000u;
    pk[i++] = (16u - 1u) << 16 | PS_CONST_252;
    for (uint32_t k = 0; k < 16; k++) {
        uint32_t w;
        memcpy(&w, &v[k], 4);
        pk[i++] = w;
    }
    for (uint32_t k = before; k < 3; k++)
        pk[i++] = 0x80000000u;
}

static void apply_literals(const XsdkShader *x)
{
    const shader_t *s = (const shader_t *)x;
    for (int i = 0; i < s->nlit; i++) {
        if (s->pixel)
            xsdk_gpu_set_pixel_constants(s->lit[i].first, s->lit[i].v, s->lit[i].count);
        else
            xsdk_gpu_set_vertex_constants(s->lit[i].first, s->lit[i].v, s->lit[i].count);
    }
    if (s->has_hi)
        put_hi_constants(s->hi);
    for (uint32_t w = 0; w < 8; w++)
        if (s->bool_mask & (1u << w))
            xsdk_gpu_set_bool_constants(w, &s->bools[w], 1);
    for (uint32_t l = 0; l < 32; l++)
        if (s->loop_mask & (1u << l))
            xsdk_gpu_set_loop_constants(l, &s->loops[l], 1);
}

/* Los de xost (herramientas/pc/compilar_xost.py): "L3X1", cantidad de literales y por literal el
 * registro y 4 floats, despues el contenedor de xost. xost pone cada literal en un registro que el
 * shader no usa (los register(cN) del HLSL quedan donde dicen, como en D3D9), asi que van con
 * apply_literals igual que los de XNA; nunca en c252-c255. Devuelve el tamano de la cabecera o 0. */
static uint32_t parse_xost(shader_t *s, const uint8_t *c, uint32_t n, const char *name)
{
    s->vmin = 0xFFFFFFFFu;
    if (n < 8 || memcmp(c, "L3X1", 4)) {
        gfx_log(" [shader] shaders\\%s: does not start with L3X1", name);
        return 0;
    }
    uint32_t count = be32(c + 4);
    if (count > (n - 8) / 20) {
        gfx_log(" [shader] shaders\\%s (xost): truncated header", name);
        return 0;
    }
    uint32_t hdr = 8 + count * 20;
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *e = c + 8 + i * 20;
        uint32_t reg = be32(e);
        uint32_t lim = s->pixel ? XSDK_PIXEL_CONSTANTS : XSDK_FLOAT_CONSTANTS;
        if (reg >= lim) {
            gfx_log(" [shader] shaders\\%s (xost): literal at c%u, out of range", name, (unsigned)reg);
            return 0;
        }
        lit_t *last = s->nlit ? &s->lit[s->nlit - 1] : NULL;
        float *v;
        if (last && last->first + last->count == reg) {
            v = realloc((void *)last->v, (last->count + 1) * 4 * sizeof(float));
            last->v = v;
            v += last->count * 4;
            last->count++;
        } else {
            if (s->nlit == LIT_MAX) {
                gfx_log(" [shader] shaders\\%s (xost): more than %d literal groups", name, LIT_MAX);
                return 0;
            }
            v = malloc(4 * sizeof(float));
            s->lit[s->nlit++] = (lit_t){reg, 1, v};
        }
        for (int k = 0; k < 4; k++) {
            uint32_t w = be32(e + 4 + k * 4);
            memcpy(&v[k], &w, 4);
        }
        if (!s->pixel && reg < s->vmin) s->vmin = reg;
    }
    return hdr;
}

/* game:\shaders\<name>: el de XNA (10_compilar_todo.bat) o el de xost (compilar_xost.py, empieza con
 * L3X1), el que haya dejado el instalador. El contenedor queda en memoria: xsdk lee de el las tablas
 * del shader mientras exista. */
static XsdkShader *load_shader(const char *name, int vertex)
{
    char path[96];
    snprintf(path, sizeof(path), "game:/shaders/%s", name);
    FILE *f = fopen(path, "rb");
    if (!f) {
        gfx_log(" [missing shader] shaders\\%s", name);
        shaders_missing++;
        return NULL;
    }
    uint32_t *code = NULL;
    long n = -1;
    if (fseek(f, 0, SEEK_END) == 0)
        n = ftell(f);
    if (n > 0 && fseek(f, 0, SEEK_SET) == 0)
        code = malloc((size_t)n);
    if (code && fread(code, 1, (size_t)n, f) != (size_t)n) {
        free(code);
        code = NULL;
    }
    fclose(f);
    if (!code) {
        gfx_log(" [shader] could not read shaders\\%s", name);
        shaders_bad++;
        return NULL;
    }
    shader_t *s = calloc(1, sizeof(*s));
    XsdkShader *sh = &s->sh;
    s->pixel = !vertex;
    uint32_t hdr = 0;
    const int xost = n >= 4 && !memcmp(code, "L3X1", 4);
    if (xost && !(hdr = parse_xost(s, (const uint8_t *)code, (uint32_t)n, name))) {
        for (int i = 0; i < s->nlit; i++)
            free((void *)s->lit[i].v);
        free(s);
        free(code);
        shaders_bad++;
        return NULL;
    }
    NTSTATUS st = xsdk_shader_load(sh, code + hdr / 4, (uint32_t)n - hdr);
    if (NT_SUCCESS(st) && vertex)
        st = xsdk_shader_set_vertex_layout(sh, layout, sizeof(layout) / sizeof(layout[0]), layout_stride);
    if (!NT_SUCCESS(st)) {
        gfx_log(" [shader] shaders\\%s%s does not load: 0x%08X", name, xost ? " (xost)" : "", (unsigned)st);
        if (sh->microcode) xsdk_shader_free(sh);
        for (int i = 0; i < s->nlit; i++)
            free((void *)s->lit[i].v);
        free(s);
        free(code);
        shaders_bad++;
        return NULL;
    }
    if (xost)
        shaders_xost++;
    else
        parse_literals(s, (const uint8_t *)code, (uint32_t)n, name);
    if (s->nlit || s->bool_mask || s->loop_mask || s->has_hi)
        shaders_lits++;
    shaders_loaded++;
    return sh;
}

/* Pixel shaders: uno por archivo (love.psu lo usan vortex y skew) */
#define PS_CACHE 32
static struct { char name[32]; XsdkShader *sh; } ps_cache[PS_CACHE];

static XsdkShader *load_ps(const char *name)
{
    int i;
    for (i = 0; i < PS_CACHE && ps_cache[i].name[0]; i++)
        if (!strcmp(ps_cache[i].name, name)) return ps_cache[i].sh;
    XsdkShader *sh = load_shader(name, 0);
    if (i < PS_CACHE) {
        snprintf(ps_cache[i].name, sizeof(ps_cache[i].name), "%s", name);
        ps_cache[i].sh = sh;
    }
    return sh;
}

/* Vertex shader enlazado a un pixel shader. HLSL: las salidas del vertex shader van a las entradas
 * del pixel shader por semantica, como en D3D9 (libXenon no enlazaba: andaba porque estaban en el
 * mismo orden). xsdk_shader_link cambia el microcodigo del vertex shader para ese pixel shader, asi
 * que un .vsu que usan varios .psu (card.vsu con las 10 ediciones) se carga una vez por cada uno. */
static XsdkShader *vs_for(const char *name, XsdkShader *ps)
{
    if (!ps)
        return NULL;
    XsdkShader *vs = load_shader(name, 1);
    if (!vs)
        return NULL;
    NTSTATUS st = xsdk_shader_link(vs, ps);
    if (!NT_SUCCESS(st))
        gfx_log(" [shader] %s does not link with its .psu: 0x%08X (continuing unlinked)", name, (unsigned)st);
    return vs;
}

/* Textura de 32 bits desde el RGBA de stb_image. XSDK_FORMAT_A8R8G8B8 toma palabras 0xAARRGGBB en
 * el orden de la CPU (texture.h); xsdk hace el mosaico de Xenos, que libXenon hacia a mano. */
static surf_t *upload_rgba(const unsigned char *rgba, int w, int h)
{
    surf_t *s = calloc(1, sizeof(*s));
    NTSTATUS st = xsdk_texture_create(&s->t, XSDK_FORMAT_A8R8G8B8, (uint32_t)w, (uint32_t)h, 1, true);
    enum { BAND = 32 };          /* filas por llamada: cada xsdk_texture_upload_rows termina en un sync */
    uint32_t *band = NT_SUCCESS(st) ? malloc((size_t)w * 4 * BAND) : NULL;
    if (!band) {
        gfx_log(" [texture] %dx%d could not be created: 0x%08X", w, h, (unsigned)st);
        if (NT_SUCCESS(st)) xsdk_texture_free(&s->t);
        free(s);
        return NULL;
    }
    for (int y0 = 0; y0 < h; y0 += BAND) {
        int rows = h - y0 < BAND ? h - y0 : BAND;
        const unsigned char *src = rgba + (size_t)y0 * w * 4;
        for (int i = 0; i < rows * w; i++)
            band[i] = (uint32_t)src[i * 4 + 3] << 24 | (uint32_t)src[i * 4 + 0] << 16 |
                      (uint32_t)src[i * 4 + 1] << 8 | src[i * 4 + 2];
        xsdk_texture_upload_rows(&s->t, 0, (uint32_t)y0, (uint32_t)rows, band, (uint32_t)w * 4);
    }
    free(band);
    xsdk_gpu_invalidate(s->t.address, s->t.size_bytes);
    s->linear = default_linear;
    return s;
}

/* ---------- emision de dibujos ---------- */

static XsdkShader *bound_ps, *bound_vs;
static surf_t *bound_tex;
static int bound_linear;
static int need_state = 1;       /* despues de un resolve: target, blend, shaders y textura de nuevo */
static int guide_open;           /* la Guia (o un dialogo de XAM) abierta: no se dibuja, solo present */
static int need_vconst = 1;      /* c0-c4 (proyeccion y pantalla): la pantalla de texto los pisa */

/* Lo que un resolve deshace (docs/GUIDE.md de xsdk): el target, el blend, los shaders y el slot 0.
 * Las constantes quedan. Sin cull ni Z: xsdk_gpu_set_target los deja apagados. */
static void frame_state(void)
{
    xsdk_gpu_set_target((uint32_t)W, (uint32_t)H);
    xsdk_gpu_set_blend(&blend_alpha);
    bound_ps = bound_vs = NULL;
    bound_tex = NULL;
    need_vconst = 1;              /* con la Guia abierta XAM dibuja entre frames y pisa constantes */
    need_state = 0;
}

static void flush(void);

void l360_gfx_forget_state(void)
{
    flush();
    need_state = 1;
    need_vconst = 1;
}

/* Antes de escribir en la mitad del buffer de vertices de este frame: la GPU tiene que haber
 * terminado el frame que la uso (dos frames atras). */
static void wait_vb(void)
{
    if (!vb_pending[vb_index])
        return;
    double t = now_ms();
    NTSTATUS st = xsdk_gpu_wait(vb_fence[vb_index], FENCE_TIMEOUT_MS);
    l360_gfx_stats.gpu_wait_ms += (unsigned long)(now_ms() - t);
    vb_pending[vb_index] = 0;
    if (!NT_SUCCESS(st)) {
        gfx_log("[gfx] xsdk_gpu_wait failed: 0x%08X (the GPU hung, stopping drawing)", (unsigned)st);
        gpu_ok = 0;
    }
}

/* Lotes: los triangulos seguidos que comparten textura (y filtro), shaders y constantes van en un
 * solo draw. Los vertices ya estan en pixeles de pantalla y con su color, asi que juntar no cambia lo
 * que se ve ni el orden: solo cuantas veces se arma el estado y se llama a xsdk_gpu_draw. El lote
 * pendiente se dibuja (flush) antes de lo que cambia el estado de afuera: un resolve (setCanvas,
 * present), un send (cambia las constantes que el lote todavia no subio) y la pantalla de texto.
 * "no_batching" en l360_gfx.txt dibuja cada submit por separado, como antes. */
static struct {
    int n;                       /* vertices en el lote; 0 = no hay lote */
    int first;                   /* primer vertice en la mitad actual del buffer */
    surf_t *tex;
    int linear;
    shader_ud *sh;
    prog_t *p;
    XsdkShader *ps, *vs;
} pend;
static long st_submits;          /* para el registro: submits contra draws de verdad */

static void flush(void)
{
    if (!pend.n)
        return;
    int nverts = pend.n;
    pend.n = 0;
    if (!gpu_ok)
        return;
    if (need_state)
        frame_state();
    uint32_t bytes = (uint32_t)nverts * sizeof(vertex_t);
    uint32_t addr = vb_addr[vb_index] + (uint32_t)pend.first * sizeof(vertex_t);
    xsdk_gpu_invalidate(addr, bytes);

    shader_ud *sh = pend.sh;
    prog_t *p = pend.p;
    XsdkShader *ps = pend.ps, *vs = pend.vs;
    int lits_dirty = 0;
    if (ps != bound_ps || vs != bound_vs) {
        xsdk_gpu_set_shaders(vs, ps);
        bound_ps = ps;
        bound_vs = vs;
        lits_dirty = 1;
    }

    /* constantes de a 4 floats (xsdk); las de pixel 252-255 son de xsdk y la tabla no llega */
    float screen[4] = {(float)W, (float)H, 0, 0};
    if (need_vconst) {
        float vc[5 * 4];
        memcpy(vc, proj, sizeof(proj));
        memcpy(vc + 16, screen, sizeof(screen));
        xsdk_gpu_set_vertex_constants(0, vc, 5);
        need_vconst = 0;
        lits_dirty = 1;
    }
    if (sh && sh->prog != PROG_DEFAULT) {
        xsdk_gpu_set_vertex_constants(5, sh->vs[5], 1);
        if (p->ps_regs > 0)
            xsdk_gpu_set_pixel_constants(0, sh->ps[0], (uint32_t)p->ps_regs);
        if (p->ps_screen_reg >= 0)
            xsdk_gpu_set_pixel_constants((uint32_t)p->ps_screen_reg, screen, 1);
        lits_dirty = 1;
    }
    /* los literales van despues de las constantes del juego, como en libXenon (las sube al dibujar):
     * si comparten un registro que el shader no declara, gana el literal */
    if (lits_dirty && !opt_no_literals) {
        apply_literals(vs);
        apply_literals(ps);
        if (((const shader_t *)vs)->vmin < 5)
            need_vconst = 1;             /* piso c0-c4: el proximo draw las vuelve a poner */
    }
    surf_t *t = pend.tex;
    if (t != bound_tex || pend.linear != bound_linear) {
        xsdk_gpu_set_texture(0, &t->t, pend.linear ? &samp_linear : &samp_point);
        bound_tex = t;
        bound_linear = pend.linear;
    }
    xsdk_gpu_set_vertices(0, addr, bytes);
    xsdk_gpu_draw(XSDK_PRIMITIVE_TRIANGLE_LIST, (uint32_t)nverts);
    l360_gfx_stats.draws++;
}

/* Agrega triangulos (ya en pixeles de pantalla) con el shader actual: al lote pendiente si comparten
 * el estado, si no en uno nuevo. */
static void submit(surf_t *tex, vertex_t *v, int nverts)
{
    if (vb_cur + nverts > VB_VERTS || !gpu_ok) {
        l360_gfx_stats.dropped++;
        return;
    }
    wait_vb();
    if (!gpu_ok || guide_open)
        return;

    shader_ud *sh = (L360_SHADERS && !opt_no_shaders) ? cur_shader : NULL;
    prog_t *p = &progs[sh ? sh->prog : PROG_DEFAULT];
    XsdkShader *ps = p->ps, *vs = p->vs;
    if (sh && sh->prog == PROG_DISSOLVE && sh->ps[0][0] > 0.0001f && p->ps_alt && p->vs_alt) {
        ps = p->ps_alt;
        vs = p->vs_alt;
    }
    if (!ps || !vs) {
        p = &progs[PROG_DEFAULT];
        ps = p->ps;
        vs = p->vs;
    }
    surf_t *t = tex ? tex : white_tex;
    if (!(pend.n && !opt_no_batching && pend.first + pend.n == vb_cur && pend.tex == t && pend.linear == t->linear
          && pend.sh == sh && pend.ps == ps && pend.vs == vs)) {
        flush();
        pend.first = vb_cur;
        pend.tex = t;
        pend.linear = t->linear;
        pend.sh = sh;
        pend.p = p;
        pend.ps = ps;
        pend.vs = vs;
    }
    gpu_memcpy(vb_base + vb_cur, v, (uint32_t)nverts * sizeof(vertex_t));
    vb_cur += nverts;
    pend.n += nverts;
    st_submits++;
    if (opt_no_batching)
        flush();                  /* como antes de los lotes: cada submit se dibuja en el momento */
}

static inline void xf(const mat_t *m, float x, float y, float *ox, float *oy)
{
    *ox = m->a * x + m->c * y + m->e;
    *oy = m->b * x + m->d * y + m->f;
}

static inline void set_vert(vertex_t *v, const mat_t *m, float x, float y, float u, float t)
{
    xf(m, x, y, &v->x, &v->y);
    v->z = 0; v->w = 1;
    v->u = u; v->v = t;
    v->r = color[0]; v->g = color[1]; v->b = color[2]; v->a = color[3];
}

/* quad local (x0,y0)-(x1,y1) con uv, transformado por m */
static void emit_quad(surf_t *tex, const mat_t *m,
                      float x0, float y0, float x1, float y1,
                      float u0, float v0, float u1, float v1)
{
    vertex_t v[6];
    set_vert(&v[0], m, x0, y0, u0, v0);
    set_vert(&v[1], m, x1, y0, u1, v0);
    set_vert(&v[2], m, x0, y1, u0, v1);
    v[3] = v[1];
    set_vert(&v[4], m, x1, y1, u1, v1);
    v[5] = v[2];
    submit(tex, v, 6);
}

static void mat_mul(mat_t *r, const mat_t *m, const mat_t *n)   /* r = m * n */
{
    mat_t t;
    t.a = m->a * n->a + m->c * n->b;
    t.b = m->b * n->a + m->d * n->b;
    t.c = m->a * n->c + m->c * n->d;
    t.d = m->b * n->c + m->d * n->d;
    t.e = m->a * n->e + m->c * n->f + m->e;
    t.f = m->b * n->e + m->d * n->f + m->f;
    *r = t;
}

/* transformacion local de love.graphics.draw: T(x,y) R(r) S(sx,sy) K(kx,ky) T(-ox,-oy) */
static void local_transform(mat_t *out, float x, float y, float r, float sx, float sy,
                            float ox, float oy, float kx, float ky)
{
    float c = cosf(r), s = sinf(r);
    /* igual que love::Matrix4::setTransformation */
    out->a = c * sx - ky * s * sy;
    out->b = s * sx + ky * c * sy;
    out->c = kx * c * sx - s * sy;
    out->d = kx * s * sx + c * sy;
    out->e = x - ox * out->a - oy * out->c;
    out->f = y - ox * out->b - oy * out->d;
}

/* ---------- metatablas ---------- */

#define MT_TEX    "L360.Tex"
#define MT_QUAD   "L360.Quad"
#define MT_SHADER "L360.Shader"

static void (*missing_cb)(const char *);
void l360_gfx_set_missing_cb(void (*cb)(const char *)) { missing_cb = cb; }

static int nop(lua_State *L) { (void)L; return 0; }

/* __index: metodo conocido, o nop (y se anota que falta) */
static int ud_index(lua_State *L)
{
    lua_getmetatable(L, 1);
    lua_getfield(L, -1, "methods");
    lua_pushvalue(L, 2);
    lua_rawget(L, -2);
    if (!lua_isnil(L, -1))
        return 1;
    lua_getfield(L, -3, "__name");
    if (missing_cb) {
        char msg[96];
        snprintf(msg, sizeof(msg), "%s:%s", lua_tostring(L, -1), lua_tostring(L, 2));
        missing_cb(msg);
    }
    lua_pushcfunction(L, nop);
    return 1;
}

static tex_ud *to_tex(lua_State *L, int i) { return (tex_ud *)luaL_testudata(L, i, MT_TEX); }

static int tex_getWidth(lua_State *L) { lua_pushnumber(L, to_tex(L, 1)->w); return 1; }
static int tex_getHeight(lua_State *L) { lua_pushnumber(L, to_tex(L, 1)->h); return 1; }
static int tex_getDimensions(lua_State *L) { tex_ud *t = to_tex(L, 1); lua_pushnumber(L, t->w); lua_pushnumber(L, t->h); return 2; }
static int tex_getPixelWidth(lua_State *L) { tex_ud *t = to_tex(L, 1); lua_pushnumber(L, t->w * t->dpi); return 1; }
static int tex_getPixelHeight(lua_State *L) { tex_ud *t = to_tex(L, 1); lua_pushnumber(L, t->h * t->dpi); return 1; }
static int tex_getPixelDimensions(lua_State *L) { tex_ud *t = to_tex(L, 1); lua_pushnumber(L, t->w * t->dpi); lua_pushnumber(L, t->h * t->dpi); return 2; }
static int tex_getDPIScale(lua_State *L) { lua_pushnumber(L, to_tex(L, 1)->dpi); return 1; }
static int tex_setFilter(lua_State *L)
{
    tex_ud *t = to_tex(L, 1);
    const char *mode = luaL_optstring(L, 2, "linear");
    if (t && t->s) t->s->linear = strcmp(mode, "nearest") != 0;
    return 0;
}
static int tex_type(lua_State *L) { lua_pushstring(L, to_tex(L, 1)->kind == TEX_CANVAS ? "Canvas" : "Image"); return 1; }
static int tex_typeOf(lua_State *L)
{
    tex_ud *t = to_tex(L, 1);
    const char *n = luaL_checkstring(L, 2);
    int ok = !strcmp(n, "Drawable") || !strcmp(n, "Texture") || !strcmp(n, "Object") ||
             !strcmp(n, t->kind == TEX_CANVAS ? "Canvas" : "Image");
    lua_pushboolean(L, ok);
    return 1;
}

static int quad_getViewport(lua_State *L)
{
    quad_ud *q = luaL_checkudata(L, 1, MT_QUAD);
    lua_pushnumber(L, q->x); lua_pushnumber(L, q->y); lua_pushnumber(L, q->w); lua_pushnumber(L, q->h);
    return 4;
}
static int quad_setViewport(lua_State *L)
{
    quad_ud *q = luaL_checkudata(L, 1, MT_QUAD);
    q->x = luaL_checknumber(L, 2); q->y = luaL_checknumber(L, 3);
    q->w = luaL_checknumber(L, 4); q->h = luaL_checknumber(L, 5);
    if (lua_isnumber(L, 6)) { q->sw = lua_tonumber(L, 6); q->sh = luaL_checknumber(L, 7); }
    return 0;
}
static int quad_getTextureDimensions(lua_State *L)
{
    quad_ud *q = luaL_checkudata(L, 1, MT_QUAD);
    lua_pushnumber(L, q->sw); lua_pushnumber(L, q->sh);
    return 2;
}

/* shader:send(nombre, valor) */
static int shader_send(lua_State *L)
{
    shader_ud *sh = luaL_checkudata(L, 1, MT_SHADER);
    const char *name = luaL_checkstring(L, 2);
    l360_gfx_stats.sends++;
    flush();                      /* el lote pendiente sube las constantes de ahora, no las nuevas */
    const umap_t *m = progs[sh->prog].map;
    if (!m)
        return 0;
    for (; m->name; m++) {
        if (m->name[0] ? strcmp(m->name, name) : strcmp(sh->name, name))
            continue;
        float *dst = (m->vs ? sh->vs[m->reg] : sh->ps[m->reg]) + m->comp;
        int t = lua_type(L, 3);
        if (t == LUA_TNUMBER) {
            dst[0] = (float)lua_tonumber(L, 3);
        } else if (t == LUA_TBOOLEAN) {
            dst[0] = lua_toboolean(L, 3) ? 1.0f : 0.0f;
        } else if (t == LUA_TTABLE) {
            for (int i = 0; i < m->n; i++) {
                lua_rawgeti(L, 3, i + 1);
                dst[i] = (float)lua_tonumber(L, -1);
                lua_pop(L, 1);
            }
        }
        return 0;
    }
    return 0;
}
static int shader_hasUniform(lua_State *L) { lua_pushboolean(L, 1); return 1; }

static void make_mt(lua_State *L, const char *name, const luaL_Reg *methods)
{
    luaL_newmetatable(L, name);
    lua_pushstring(L, name);
    lua_setfield(L, -2, "__name");
    lua_newtable(L);
    for (; methods->name; methods++) {
        lua_pushcfunction(L, methods->func);
        lua_setfield(L, -2, methods->name);
    }
    lua_pushcfunction(L, nop); lua_setfield(L, -2, "release");
    lua_setfield(L, -2, "methods");
    lua_pushcfunction(L, ud_index);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);
}

/* ---------- funciones de love.graphics ---------- */


/* ---------- fuentes y texto (stb_truetype) ---------- */

#define MT_FONT "L360.Font"
#define MT_TEXT "L360.Text"
#define RASTER_PX 64.0f
#define ATLAS_W 1024
#define ATLAS_H 1024

typedef struct { float u0, v0, u1, v1; float x0, y0, x1, y1; float adv; int ok; } glyph_t;

typedef struct font_data {
    char path[64];
    unsigned char *ttf;
    stbtt_fontinfo info;
    float ascent, descent, linegap;   /* en unidades de la fuente */
    float upm_scale;                  /* escala de unidades a 1 px de em */
    surf_t *atlas;                    /* NULL sin texturas (paso 2a) */
    glyph_t g[256];
    struct font_data *next;
} font_data;
static font_data *fonts;

typedef struct { font_data *fd; float size; float line_height; } font_ud;

#define TEXT_MAX_RUNS 16
typedef struct { float col[4]; char *str; } run_t;
typedef struct { font_ud font; int nruns; run_t runs[TEXT_MAX_RUNS]; } text_ud;

static float px_scale(font_data *fd, float size) { return fd->upm_scale * size; }

static int utf8_next(const unsigned char **p)
{
    const unsigned char *s = *p;
    int c = *s++;
    if (c >= 0xF0 && s[0] && s[1] && s[2]) { c = ((c & 7) << 18) | ((s[0] & 63) << 12) | ((s[1] & 63) << 6) | (s[2] & 63); s += 3; }
    else if (c >= 0xE0 && s[0] && s[1]) { c = ((c & 15) << 12) | ((s[0] & 63) << 6) | (s[1] & 63); s += 2; }
    else if (c >= 0xC0 && s[0]) { c = ((c & 31) << 6) | (s[0] & 63); s += 1; }
    *p = s;
    return c;
}

static float glyph_adv(font_data *fd, int cp, float size)
{
    int adv, lsb;
    stbtt_GetCodepointHMetrics(&fd->info, cp, &adv, &lsb);
    return adv * px_scale(fd, size);
}

static float str_width(font_data *fd, const char *s, float size)
{
    float w = 0;
    const unsigned char *p = (const unsigned char *)s;
    while (*p) w += glyph_adv(fd, utf8_next(&p), size);
    return w;
}

static font_data *font_load(const char *path, const char *ttf, size_t len)
{
    for (font_data *f = fonts; f; f = f->next)
        if (!strcmp(f->path, path)) return f;
    font_data *fd = calloc(1, sizeof(font_data));
    snprintf(fd->path, sizeof(fd->path), "%s", path);
    fd->ttf = malloc(len);
    memcpy(fd->ttf, ttf, len);
    if (!stbtt_InitFont(&fd->info, fd->ttf, stbtt_GetFontOffsetForIndex(fd->ttf, 0))) {
        free(fd->ttf); free(fd);
        return NULL;
    }
    int a, d, g;
    stbtt_GetFontVMetrics(&fd->info, &a, &d, &g);
    fd->ascent = a; fd->descent = d; fd->linegap = g;
    fd->upm_scale = stbtt_ScaleForMappingEmToPixels(&fd->info, 1.0f);

#if L360_TEXTURAS
    /* atlas con ASCII y Latin-1, rasterizado a RASTER_PX */
    unsigned char *rgba = calloc(ATLAS_W * ATLAS_H, 4);
    float sc = fd->upm_scale * RASTER_PX;
    int pen_x = 1, pen_y = 1, row_h = 0;
    for (int cp = 32; cp < 256; cp++) {
        glyph_t *gl = &fd->g[cp];
        gl->adv = 0;
        if (cp >= 127 && cp < 160) continue;
        int x0, y0, x1, y1;
        stbtt_GetCodepointBitmapBox(&fd->info, cp, sc, sc, &x0, &y0, &x1, &y1);
        int w = x1 - x0, h = y1 - y0;
        int adv, lsb;
        stbtt_GetCodepointHMetrics(&fd->info, cp, &adv, &lsb);
        gl->adv = adv * sc;
        if (w <= 0 || h <= 0) { gl->ok = 1; gl->x0 = gl->x1 = 0; continue; }
        if (pen_x + w + 1 >= ATLAS_W) { pen_x = 1; pen_y += row_h + 1; row_h = 0; }
        if (pen_y + h + 1 >= ATLAS_H) break;
        unsigned char *bm = malloc(w * h);
        stbtt_MakeCodepointBitmap(&fd->info, bm, w, h, w, sc, sc, cp);
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                unsigned char *px = rgba + ((pen_y + y) * ATLAS_W + pen_x + x) * 4;
                px[0] = px[1] = px[2] = 255;
                px[3] = bm[y * w + x];
            }
        free(bm);
        gl->u0 = (float)pen_x / ATLAS_W; gl->v0 = (float)pen_y / ATLAS_H;
        gl->u1 = (float)(pen_x + w) / ATLAS_W; gl->v1 = (float)(pen_y + h) / ATLAS_H;
        gl->x0 = x0; gl->y0 = y0; gl->x1 = x1; gl->y1 = y1;
        gl->ok = 1;
        pen_x += w + 1;
        if (h > row_h) row_h = h;
    }
    fd->atlas = upload_rgba(rgba, ATLAS_W, ATLAS_H);
    if (fd->atlas) fd->atlas->linear = 1;
    free(rgba);
#endif
    fd->next = fonts;
    fonts = fd;
    return fd;
}

/* newFont(path, ttf_bytes, size) */
static int g_newFont(lua_State *L)
{
    const char *path = luaL_checkstring(L, 1);
    size_t len;
    const char *ttf = luaL_checklstring(L, 2, &len);
    float size = (float)luaL_optnumber(L, 3, 12);
    font_data *fd = font_load(path, ttf, len);
    if (!fd) return 0;
    font_ud *f = lua_newuserdata(L, sizeof(font_ud));
    f->fd = fd;
    f->size = size;
    f->line_height = 1;
    luaL_getmetatable(L, MT_FONT);
    lua_setmetatable(L, -2);
    return 1;
}

static font_ud *to_font(lua_State *L, int i) { return luaL_testudata(L, i, MT_FONT); }

static int font_getWidth(lua_State *L)
{
    font_ud *f = to_font(L, 1);
    lua_pushnumber(L, str_width(f->fd, luaL_optstring(L, 2, ""), f->size));
    return 1;
}
static int font_getHeight(lua_State *L)
{
    font_ud *f = to_font(L, 1);
    lua_pushnumber(L, floorf((f->fd->ascent - f->fd->descent + f->fd->linegap) * px_scale(f->fd, f->size) + 0.5f));
    return 1;
}
static int font_getAscent(lua_State *L) { font_ud *f = to_font(L, 1); lua_pushnumber(L, f->fd->ascent * px_scale(f->fd, f->size)); return 1; }
static int font_getDescent(lua_State *L) { font_ud *f = to_font(L, 1); lua_pushnumber(L, f->fd->descent * px_scale(f->fd, f->size)); return 1; }
static int font_getLineHeight(lua_State *L) { lua_pushnumber(L, to_font(L, 1)->line_height); return 1; }
static int font_setLineHeight(lua_State *L) { to_font(L, 1)->line_height = (float)luaL_checknumber(L, 2); return 0; }
static int font_hasGlyphs(lua_State *L) { lua_pushboolean(L, 1); return 1; }
static int font_getWrap(lua_State *L)
{
    font_ud *f = to_font(L, 1);
    const char *s = lua_isstring(L, 2) ? lua_tostring(L, 2) : "";
    lua_pushnumber(L, str_width(f->fd, s, f->size));
    lua_newtable(L);
    lua_pushstring(L, s);
    lua_rawseti(L, -2, 1);
    return 2;
}

static void text_set(lua_State *L, text_ud *t, int idx)
{
    for (int i = 0; i < t->nruns; i++) free(t->runs[i].str);
    t->nruns = 0;
    float col[4] = {1, 1, 1, 1};
    if (lua_istable(L, idx)) {
        int n = (int)lua_objlen(L, idx);
        for (int i = 1; i <= n && t->nruns < TEXT_MAX_RUNS; i++) {
            lua_rawgeti(L, idx, i);
            if (lua_istable(L, -1)) {
                for (int k = 0; k < 4; k++) {
                    lua_rawgeti(L, -1, k + 1);
                    col[k] = lua_isnumber(L, -1) ? (float)lua_tonumber(L, -1) : 1.0f;
                    lua_pop(L, 1);
                }
            } else if (lua_isstring(L, -1)) {
                run_t *r = &t->runs[t->nruns++];
                memcpy(r->col, col, sizeof(col));
                r->str = strdup(lua_tostring(L, -1));
            }
            lua_pop(L, 1);
        }
    } else if (lua_isstring(L, idx)) {
        run_t *r = &t->runs[t->nruns++];
        memcpy(r->col, col, sizeof(col));
        r->str = strdup(lua_tostring(L, idx));
    }
}

static int text_gc(lua_State *L)
{
    text_ud *t = luaL_checkudata(L, 1, MT_TEXT);
    for (int i = 0; i < t->nruns; i++) free(t->runs[i].str);
    t->nruns = 0;
    return 0;
}

/* newText(font, texto) */
static int g_newText(lua_State *L)
{
    font_ud *f = to_font(L, 1);
    if (!f) return luaL_error(L, "newText: the font is not a Love360 font");
    text_ud *t = lua_newuserdata(L, sizeof(text_ud));
    memset(t, 0, sizeof(*t));
    t->font = *f;
    luaL_getmetatable(L, MT_TEXT);
    lua_setmetatable(L, -2);
    text_set(L, t, 2);
    return 1;
}

static float text_width(text_ud *t)
{
    float w = 0;
    for (int i = 0; i < t->nruns; i++) w += str_width(t->font.fd, t->runs[i].str, t->font.size);
    return w;
}
static float text_height(text_ud *t)
{
    font_data *fd = t->font.fd;
    return floorf((fd->ascent - fd->descent + fd->linegap) * px_scale(fd, t->font.size) + 0.5f);
}
static int textm_getWidth(lua_State *L) { lua_pushnumber(L, text_width(luaL_checkudata(L, 1, MT_TEXT))); return 1; }
static int textm_getHeight(lua_State *L) { lua_pushnumber(L, text_height(luaL_checkudata(L, 1, MT_TEXT))); return 1; }
static int textm_getDimensions(lua_State *L)
{
    text_ud *t = luaL_checkudata(L, 1, MT_TEXT);
    lua_pushnumber(L, text_width(t)); lua_pushnumber(L, text_height(t));
    return 2;
}
static int textm_set(lua_State *L) { text_set(L, luaL_checkudata(L, 1, MT_TEXT), 2); return 0; }
static int textm_clear(lua_State *L) { text_ud *t = luaL_checkudata(L, 1, MT_TEXT); lua_pushnil(L); text_set(L, t, 3); return 0; }

#define TEXT_VERTS 6 * 512
static vertex_t text_verts[TEXT_VERTS];

static void draw_text(text_ud *t, const mat_t *m)
{
    font_data *fd = t->font.fd;
    if (!fd->atlas) {                   /* sin texturas (paso 2a) */
        l360_gfx_stats.skipped++;
        return;
    }
    float k = t->font.size / RASTER_PX;              /* de px de rasterizado a px de la fuente */
    float base = fd->ascent * px_scale(fd, t->font.size);
    float pen = 0;
    int nv = 0;
    float saved[4];
    memcpy(saved, color, sizeof(saved));
    for (int i = 0; i < t->nruns; i++) {
        run_t *r = &t->runs[i];
        for (int c = 0; c < 4; c++) color[c] = saved[c] * r->col[c];
        const unsigned char *p = (const unsigned char *)r->str;
        while (*p) {
            int cp = utf8_next(&p);
            glyph_t *gl = (cp > 0 && cp < 256) ? &fd->g[cp] : NULL;
            if (!gl || !gl->ok) { pen += glyph_adv(fd, cp, t->font.size); continue; }
            if (gl->x1 > gl->x0 && nv + 6 <= TEXT_VERTS) {
                float x0 = pen + gl->x0 * k, x1 = pen + gl->x1 * k;
                float y0 = base + gl->y0 * k, y1 = base + gl->y1 * k;
                vertex_t *v = text_verts + nv;
                set_vert(&v[0], m, x0, y0, gl->u0, gl->v0);
                set_vert(&v[1], m, x1, y0, gl->u1, gl->v0);
                set_vert(&v[2], m, x0, y1, gl->u0, gl->v1);
                v[3] = v[1];
                set_vert(&v[4], m, x1, y1, gl->u1, gl->v1);
                v[5] = v[2];
                nv += 6;
            }
            pen += gl->adv * k;
        }
    }
    memcpy(color, saved, sizeof(saved));
    if (nv) submit(fd->atlas, text_verts, nv);
}

static int g_newImage(lua_State *L)
{
    /* newImage(path, png_bytes, dpiscale) - el Lua ya leyo el archivo */
    const char *path = luaL_checkstring(L, 1);
    size_t len = 0;
    const char *png = lua_tolstring(L, 2, &len);
    float dpi = (float)luaL_optnumber(L, 3, 1);
    int w = 1, h = 1;
    surf_t *s = NULL;
    double t0 = now_ms();
#if L360_TEXTURAS
    int n;
    if (png && len) {
        unsigned char *rgba = stbi_load_from_memory((const unsigned char *)png, (int)len, &w, &h, &n, 4);
        if (rgba) {
            s = upload_rgba(rgba, w, h);
            stbi_image_free(rgba);
        }
    }
#else
    /* paso 2a: solo el tamano (ancho y alto big-endian de la cabecera IHDR, bytes 16 a 23) */
    if (png && len >= 24 && !memcmp(png + 1, "PNG", 3)) {
        const unsigned char *u = (const unsigned char *)png;
        w = (int)((uint32_t)u[16] << 24 | (uint32_t)u[17] << 16 | (uint32_t)u[18] << 8 | u[19]);
        h = (int)((uint32_t)u[20] << 24 | (uint32_t)u[21] << 16 | (uint32_t)u[22] << 8 | u[23]);
        l360_gfx_stats.texture_bytes += (long)w * h * 4;
    } else {
        l360_gfx_stats.missing_images++;
        w = h = 64;
    }
#endif
    l360_gfx_stats.image_ms += (unsigned long)(now_ms() - t0);
#if L360_TEXTURAS
    if (!s) {
        static const unsigned char magenta[4] = {255, 0, 255, 255};
        s = upload_rgba(magenta, 1, 1);
        w = h = 64;
        l360_gfx_stats.missing_images++;
    } else {
        l360_gfx_stats.texture_bytes += (long)w * h * 4;
    }
#endif
    tex_ud *t = lua_newuserdata(L, sizeof(tex_ud));
    memset(t, 0, sizeof(*t));
    t->kind = TEX_IMAGE;
    t->s = s;
    t->dpi = dpi;
    t->w = w / dpi;
    t->h = h / dpi;
    snprintf(t->path, sizeof(t->path), "%s", path);
    luaL_getmetatable(L, MT_TEX);
    lua_setmetatable(L, -2);
    return 1;
}

static int g_newCanvas(lua_State *L)
{
    int w = (int)luaL_optnumber(L, 1, W), h = (int)luaL_optnumber(L, 2, H);
    if (w != W || h != H)
        gfx_log(" [warning] canvas %dx%d differs from the screen (%dx%d)", w, h, W, H);
    /* textura del tamano de la pantalla, tiled (un resolve solo escribe texturas tiled) */
    surf_t *s = calloc(1, sizeof(*s));
    NTSTATUS st = xsdk_texture_create(&s->t, XSDK_FORMAT_A8R8G8B8, (uint32_t)W, (uint32_t)H, 1, true);
    if (!NT_SUCCESS(st)) {
        gfx_log(" [canvas] %dx%d could not be created: 0x%08X", W, H, (unsigned)st);
        free(s);
        s = NULL;
    } else {
        s->linear = 1;
        l360_gfx_stats.texture_bytes += (long)W * H * 4;
    }
    tex_ud *t = lua_newuserdata(L, sizeof(tex_ud));
    memset(t, 0, sizeof(*t));
    t->kind = TEX_CANVAS;
    t->s = s;
    t->dpi = 1;
    t->w = W;
    t->h = H;
    luaL_getmetatable(L, MT_TEX);
    lua_setmetatable(L, -2);
    return 1;
}

static int g_newQuad(lua_State *L)
{
    quad_ud *q = lua_newuserdata(L, sizeof(quad_ud));
    q->x = luaL_checknumber(L, 1); q->y = luaL_checknumber(L, 2);
    q->w = luaL_checknumber(L, 3); q->h = luaL_checknumber(L, 4);
    if (lua_isuserdata(L, 5)) {
        tex_ud *t = to_tex(L, 5);
        q->sw = t ? t->w : 1; q->sh = t ? t->h : 1;
    } else {
        q->sw = luaL_checknumber(L, 5); q->sh = luaL_checknumber(L, 6);
    }
    luaL_getmetatable(L, MT_QUAD);
    lua_setmetatable(L, -2);
    return 1;
}

static int g_newShader(lua_State *L)
{
    /* newShader(nombre_sin_extension) */
    const char *name = luaL_checkstring(L, 1);
    shader_ud *sh = lua_newuserdata(L, sizeof(shader_ud));
    memset(sh, 0, sizeof(*sh));
    snprintf(sh->name, sizeof(sh->name), "%s", name);
    sh->prog = PROG_DEFAULT;
    if (!strcmp(name, "dissolve")) sh->prog = PROG_DISSOLVE;
    else if (!strcmp(name, "background")) sh->prog = PROG_BACKGROUND;
    else if (!strcmp(name, "CRT")) sh->prog = PROG_CRT;
    else {
        for (int i = 0; i < N_GEN; i++)
            if (!strcmp(name, gen_names[i])) { sh->prog = PROG_GEN + i; break; }
    }
    luaL_getmetatable(L, MT_SHADER);
    lua_setmetatable(L, -2);
    /* traducido = el programa existe y sus .psu/.vsu se cargaron */
    lua_pushboolean(L, sh->prog != PROG_DEFAULT && progs[sh->prog].ps && progs[sh->prog].vs);
    return 2;
}

static int g_setShader(lua_State *L)
{
    cur_shader = lua_isnoneornil(L, 1) ? NULL : luaL_checkudata(L, 1, MT_SHADER);
    return 0;
}

static float num_or(lua_State *L, int i, float d) { return lua_isnumber(L, i) ? (float)lua_tonumber(L, i) : d; }

static void read_color(lua_State *L, int i, float *dst)
{
    if (lua_istable(L, i)) {
        for (int k = 0; k < 4; k++) {
            lua_rawgeti(L, i, k + 1);
            dst[k] = lua_isnumber(L, -1) ? (float)lua_tonumber(L, -1) : (k == 3 ? 1.0f : 0.0f);
            lua_pop(L, 1);
        }
    } else {
        dst[0] = num_or(L, i, 1); dst[1] = num_or(L, i + 1, 1);
        dst[2] = num_or(L, i + 2, 1); dst[3] = num_or(L, i + 3, 1);
    }
}

static int g_setColor(lua_State *L) { read_color(L, 1, color); return 0; }
static int g_getColor(lua_State *L)
{
    for (int i = 0; i < 4; i++) lua_pushnumber(L, color[i]);
    return 4;
}
static int g_setLineWidth(lua_State *L) { line_width = num_or(L, 1, 1); return 0; }
static int g_getLineWidth(lua_State *L) { lua_pushnumber(L, line_width); return 1; }

static int g_clear(lua_State *L)
{
    if (lua_gettop(L) >= 1) read_color(L, 1, clear_color);
    return 0;
}

static int g_push(lua_State *L)
{
    if (msp < STACK_MAX - 1) { mstack[msp + 1] = mstack[msp]; msp++; }
    else luaL_error(L, "transform stack full");
    return 0;
}
static int g_pop(lua_State *L)
{
    if (msp > 0) msp--;
    else luaL_error(L, "pop without push");
    return 0;
}
static int g_origin(lua_State *L) { (void)L; mat_t *m = &mstack[msp]; m->a = m->d = 1; m->b = m->c = m->e = m->f = 0; return 0; }
static int g_translate(lua_State *L)
{
    float x = num_or(L, 1, 0), y = num_or(L, 2, 0);
    mat_t *m = &mstack[msp];
    m->e += m->a * x + m->c * y;
    m->f += m->b * x + m->d * y;
    return 0;
}
static int g_scale(lua_State *L)
{
    float sx = num_or(L, 1, 1), sy = lua_isnumber(L, 2) ? (float)lua_tonumber(L, 2) : sx;
    mat_t *m = &mstack[msp];
    m->a *= sx; m->b *= sx;
    m->c *= sy; m->d *= sy;
    return 0;
}
static int g_rotate(lua_State *L)
{
    float r = num_or(L, 1, 0), c = cosf(r), s = sinf(r);
    mat_t *m = &mstack[msp];
    float a = m->a, b = m->b, cc = m->c, d = m->d;
    m->a = a * c + cc * s;
    m->b = b * c + d * s;
    m->c = -a * s + cc * c;
    m->d = -b * s + d * c;
    return 0;
}
static int g_shear(lua_State *L)
{
    float kx = num_or(L, 1, 0), ky = num_or(L, 2, 0);
    mat_t n = {1, ky, kx, 1, 0, 0};
    mat_mul(&mstack[msp], &mstack[msp], &n);
    return 0;
}

/* draw(drawable, [quad], x, y, r, sx, sy, ox, oy, kx, ky) */
static int g_draw(lua_State *L)
{
    tex_ud *t = to_tex(L, 1);
    text_ud *tx = t ? NULL : luaL_testudata(L, 1, MT_TEXT);
    if ((!t && !tx) || (t && !t->s) || (t && t->kind == TEX_CANVAS && opt_no_canvas)) {
        l360_gfx_stats.skipped++;        /* Video y otros: todavia no; texturas desde el paso 2b */
        return 0;
    }
    int a = 2;
    quad_ud *q = luaL_testudata(L, 2, MT_QUAD);
    if (q) a = 3;
    mat_t lt, m;
    local_transform(&lt, num_or(L, a, 0), num_or(L, a + 1, 0), num_or(L, a + 2, 0),
                    num_or(L, a + 3, 1), lua_isnumber(L, a + 4) ? (float)lua_tonumber(L, a + 4) : num_or(L, a + 3, 1),
                    num_or(L, a + 5, 0), num_or(L, a + 6, 0), num_or(L, a + 7, 0), num_or(L, a + 8, 0));
    mat_mul(&m, &mstack[msp], &lt);
    if (tx) {
        draw_text(tx, &m);
    } else if (q) {
        emit_quad(t->s, &m, 0, 0, q->w, q->h,
                  q->x / q->sw, q->y / q->sh, (q->x + q->w) / q->sw, (q->y + q->h) / q->sh);
    } else if (t->kind == TEX_CANVAS && opt_canvas_default) {
        shader_ud *keep = cur_shader;
        cur_shader = NULL;
        emit_quad(t->s, &m, 0, 0, t->w, t->h, 0, 0, 1, 1);
        cur_shader = keep;
    } else {
        emit_quad(t->s, &m, 0, 0, t->w, t->h, 0, 0, 1, 1);
    }
    return 0;
}

static void emit_line(const mat_t *m, float x0, float y0, float x1, float y1)
{
    float dx = x1 - x0, dy = y1 - y0, len = sqrtf(dx * dx + dy * dy);
    if (len < 1e-6f) return;
    float nx = -dy / len * line_width * 0.5f, ny = dx / len * line_width * 0.5f;
    vertex_t v[6];
    set_vert(&v[0], m, x0 + nx, y0 + ny, 0, 0);
    set_vert(&v[1], m, x1 + nx, y1 + ny, 0, 0);
    set_vert(&v[2], m, x0 - nx, y0 - ny, 0, 0);
    v[3] = v[1];
    set_vert(&v[4], m, x1 - nx, y1 - ny, 0, 0);
    v[5] = v[2];
    submit(NULL, v, 6);
}

static int g_rectangle(lua_State *L)
{
    const char *mode = luaL_checkstring(L, 1);
    float x = num_or(L, 2, 0), y = num_or(L, 3, 0), w = num_or(L, 4, 0), h = num_or(L, 5, 0);
    shader_ud *saved = cur_shader;
    cur_shader = NULL;
    if (mode[0] == 'f') {
        emit_quad(NULL, &mstack[msp], x, y, x + w, y + h, 0, 0, 1, 1);
    } else {
        emit_line(&mstack[msp], x, y, x + w, y);
        emit_line(&mstack[msp], x + w, y, x + w, y + h);
        emit_line(&mstack[msp], x + w, y + h, x, y + h);
        emit_line(&mstack[msp], x, y + h, x, y);
    }
    cur_shader = saved;
    return 0;
}

#define POLY_MAX 128
static int g_polygon(lua_State *L)
{
    const char *mode = luaL_checkstring(L, 1);
    float pts[POLY_MAX * 2];
    int n = 0;
    if (lua_istable(L, 2)) {
        int len = (int)lua_objlen(L, 2);
        for (int i = 1; i <= len && n < POLY_MAX * 2; i++) {
            lua_rawgeti(L, 2, i);
            pts[n++] = (float)lua_tonumber(L, -1);
            lua_pop(L, 1);
        }
    } else {
        int top = lua_gettop(L);
        for (int i = 2; i <= top && n < POLY_MAX * 2; i++) pts[n++] = (float)lua_tonumber(L, i);
    }
    int np = n / 2;
    if (np < 2) return 0;
    shader_ud *saved = cur_shader;
    cur_shader = NULL;
    const mat_t *m = &mstack[msp];
    if (mode[0] == 'f') {
        if (np >= 3) {
            static vertex_t v[POLY_MAX * 3];
            int k = 0;
            for (int i = 1; i + 1 < np; i++) {       /* abanico desde el primer vertice */
                set_vert(&v[k++], m, pts[0], pts[1], 0, 0);
                set_vert(&v[k++], m, pts[i * 2], pts[i * 2 + 1], 0, 0);
                set_vert(&v[k++], m, pts[i * 2 + 2], pts[i * 2 + 3], 0, 0);
            }
            submit(NULL, v, k);
        }
    } else {
        for (int i = 0; i + 1 < np; i++)
            emit_line(m, pts[i * 2], pts[i * 2 + 1], pts[i * 2 + 2], pts[i * 2 + 3]);
        emit_line(m, pts[(np - 1) * 2], pts[(np - 1) * 2 + 1], pts[0], pts[1]);
    }
    cur_shader = saved;
    return 0;
}

static int g_skip(lua_State *L) { (void)L; l360_gfx_stats.skipped++; return 0; }

/* color de limpieza de la EDRAM en ARGB: un resolve copia y despues limpia, asi que vale para el
 * frame siguiente (como Xe_SetClearColor + Xe_Resolve) */
static uint32_t clear_argb(void)
{
    uint32_t c[4];
    for (int i = 0; i < 4; i++) {
        float v = clear_color[i] < 0 ? 0 : clear_color[i] > 1 ? 1 : clear_color[i];
        c[i] = (uint32_t)(v * 255.0f + 0.5f);
    }
    return c[3] << 24 | c[0] << 16 | c[1] << 8 | c[2];
}

/* Termina el canvas: lo dibujado en la EDRAM pasa a su textura y la EDRAM queda limpia (como
 * Xe_ResolveInto). El resolve deshace target, blend, shaders y slot 0: frame_state los vuelve a
 * poner antes del proximo draw. */
static void resolve_to_canvas(tex_ud *c)
{
    flush();
    if (!gpu_ok || !c->s)
        return;
    if (need_state)
        frame_state();
    xsdk_gpu_resolve_texture(&c->s->t, clear_argb());
    st_canvas_resolves++;
    need_state = 1;
}

/* setCanvas(canvas) | setCanvas({canvas}) | setCanvas() */
static int g_setCanvas(lua_State *L)
{
    tex_ud *t = NULL;
    if (lua_istable(L, 1)) {
        lua_rawgeti(L, 1, 1);
        t = to_tex(L, -1);
        lua_pop(L, 1);
    } else if (!lua_isnoneornil(L, 1)) {
        t = to_tex(L, 1);
    }
    if (opt_no_canvas)
        t = NULL;
    if (t == cur_canvas)
        return 0;
    if (cur_canvas)
        resolve_to_canvas(cur_canvas);
    cur_canvas = t;
    return 0;
}

static int g_getDimensions(lua_State *L) { lua_pushnumber(L, W); lua_pushnumber(L, H); return 2; }
static int g_getWidth(lua_State *L) { lua_pushnumber(L, W); return 1; }
static int g_getHeight(lua_State *L) { lua_pushnumber(L, H); return 1; }
static int g_setDefaultFilter(lua_State *L) { default_linear = strcmp(luaL_optstring(L, 1, "linear"), "nearest") != 0; return 0; }

/* present: termina el frame. xsdk_present_begin espera que se libere un buffer de pantalla (el
 * frame se arma antes, mientras se ve el anterior), el resolve copia la EDRAM ahi y la limpia, y
 * present_end lo muestra en el proximo vblank en que la GPU haya terminado. */
static int g_present(lua_State *L)
{
    (void)L;
    flush();                     /* lo pendiente cuenta como draw, no como present */
    l360_gfx_stats.present_at = now_ms();
    if (cur_canvas) {
        resolve_to_canvas(cur_canvas);
        cur_canvas = NULL;
    }
    if (gpu_ok) {
        uint32_t address;
        NTSTATUS st = xsdk_present_begin(&address, BEGIN_TIMEOUT_MS);
        if (!NT_SUCCESS(st)) {
            gfx_log("[gfx] xsdk_present_begin failed: 0x%08X (the GPU hung, stopping drawing)", (unsigned)st);
            gpu_ok = 0;
        } else {
            if (need_state)
                frame_state();
            xsdk_gpu_resolve(address, (uint32_t)W, (uint32_t)H, clear_argb());
            st_screen_resolves++;
            xsdk_present_end();
            vb_fence[vb_index] = xsdk_gpu_fence();
            vb_pending[vb_index] = 1;
            need_state = 1;
        }
    }
    l360_gfx_stats.frames++;
    /* Guia: XAM dibuja cada frame debajo de ella y deja la GPU como quiere (xsdk la vuelve a armar).
     * Mientras esta abierta se sigue presentando (si no, la Guia no se ve) pero sin dibujar. */
    int ui = xsdk_system_ui_open();
    if (ui != guide_open) {
        XsdkPresentStats ps;
        xsdk_present_stats(&ps);
        gfx_log("[gfx] Guide %s (frame %ld, %u XAM frames)", ui ? "open: stopping drawing" : "closed: resuming",
                l360_gfx_stats.frames, (unsigned)ps.system_frames);
        guide_open = ui;
        need_state = 1;
    }
    if (l360_gfx_stats.frames % 300 == 0) {
        gfx_log("[gfx] frame %ld: %ld draws/frame (%ld submits), resolves canvas %ld screen %ld, %ld skipped",
                l360_gfx_stats.frames, (l360_gfx_stats.draws - st_last_draws) / 300, (st_submits - st_last_submits) / 300,
                st_canvas_resolves, st_screen_resolves, l360_gfx_stats.skipped);
        st_last_draws = l360_gfx_stats.draws;
        st_last_submits = st_submits;
        st_canvas_resolves = st_screen_resolves = 0;
    }
    /* siguiente frame: la otra mitad del buffer de vertices */
    vb_index ^= 1;
    vb_base = (vertex_t *)(uintptr_t)(vb_mem + vb_index * (VB_BYTES / 4));
    vb_cur = 0;
    msp = 0;
    g_origin(L);
    l360_gfx_stats.present_end_at = now_ms();
    return 0;
}

/* sync: antes de dibujar el frame, espera a que la GPU termine con su mitad del buffer de vertices
 * (la usaba el frame de hace dos; libXenon esperaba el frame anterior entero) */
static int g_sync(lua_State *L)
{
    (void)L;
    l360_gfx_stats.sync_at = now_ms();
    wait_vb();
    l360_gfx_stats.sync_end_at = now_ms();
    return 0;
}

static int g_getStats(lua_State *L)
{
    lua_newtable(L);
    lua_pushnumber(L, l360_gfx_stats.draws); lua_setfield(L, -2, "drawcalls");
    lua_pushnumber(L, l360_gfx_stats.texture_bytes); lua_setfield(L, -2, "texturememory");
    return 1;
}

static const luaL_Reg gfx_funcs[] = {
    {"newImage", g_newImage}, {"newFont", g_newFont}, {"newText", g_newText}, {"newCanvas", g_newCanvas}, {"newQuad", g_newQuad}, {"newShader", g_newShader},
    {"setShader", g_setShader}, {"setColor", g_setColor}, {"getColor", g_getColor},
    {"setLineWidth", g_setLineWidth}, {"getLineWidth", g_getLineWidth}, {"clear", g_clear},
    {"push", g_push}, {"pop", g_pop}, {"origin", g_origin}, {"translate", g_translate},
    {"scale", g_scale}, {"rotate", g_rotate}, {"shear", g_shear},
    {"draw", g_draw}, {"rectangle", g_rectangle}, {"polygon", g_polygon},
    {"print", g_skip}, {"printf", g_skip}, {"line", g_skip}, {"circle", g_skip}, {"ellipse", g_skip}, {"points", g_skip},
    {"setCanvas", g_setCanvas}, {"present", g_present}, {"sync", g_sync},
    {"getDimensions", g_getDimensions}, {"getPixelDimensions", g_getDimensions},
    {"getWidth", g_getWidth}, {"getHeight", g_getHeight},
    {"setDefaultFilter", g_setDefaultFilter}, {"getStats", g_getStats},
    {NULL, NULL}};

/* ---------- inicio ---------- */

static void read_options(void)
{
    char buf[256] = {0};
    FILE *f = fopen("game:/l360_gfx.txt", "rb");
    if (!f) {
        gfx_log("[gfx] no l360_gfx.txt: all defaults");
        return;
    }
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = 0;
    opt_no_canvas = strstr(buf, "no_canvas") != NULL;
    opt_canvas_default = strstr(buf, "canvas_default") != NULL;
    opt_no_shaders = strstr(buf, "no_shaders") != NULL;
    opt_no_literals = strstr(buf, "no_literals") != NULL;
    opt_no_batching = strstr(buf, "no_batching") != NULL;
    gfx_log("[gfx] l360_gfx.txt: no_canvas=%d canvas_default=%d no_shaders=%d no_literals=%d no_batching=%d",
            opt_no_canvas, opt_canvas_default, opt_no_shaders, opt_no_literals, opt_no_batching);
    if (strstr(buf, "shaders_xost"))
        gfx_log("[gfx] shaders_xost is no longer needed: xost shaders are read from shaders\\ by their header");
}

int l360_gfx_init(uint32_t w, uint32_t h, void (*log)(const char *))
{
    log_cb = log;
    W = (int)w;
    H = (int)h;
    build_ortho();
    read_options();
    (void)xsdk_system_ui_open();     /* la primera llamada empieza a escuchar a XAM */

    progs[PROG_DEFAULT].ps = load_ps("default.psu");
    progs[PROG_DEFAULT].vs = vs_for("default.vsu", progs[PROG_DEFAULT].ps);
    progs[PROG_DEFAULT].ps_screen_reg = -1;
    if (!progs[PROG_DEFAULT].ps || !progs[PROG_DEFAULT].vs) {
        gfx_log("[ERROR] without shaders\\default.psu and default.vsu there are no graphics (copy the .psu/.vsu files to Love360\\shaders\\)");
        return -1;
    }
    progs[PROG_DISSOLVE].ps = load_ps("dissolve_fast.psu");
    progs[PROG_DISSOLVE].vs = vs_for("dissolve.vsu", progs[PROG_DISSOLVE].ps);
    progs[PROG_DISSOLVE].ps_alt = load_ps("dissolve_br.psu");
    progs[PROG_DISSOLVE].vs_alt = vs_for("dissolve.vsu", progs[PROG_DISSOLVE].ps_alt);
    progs[PROG_DISSOLVE].map = map_dissolve;
    progs[PROG_DISSOLVE].ps_regs = 5;
    progs[PROG_DISSOLVE].ps_screen_reg = -1;
    progs[PROG_BACKGROUND].ps = load_ps("background.psu");
    progs[PROG_BACKGROUND].vs = vs_for("background.vsu", progs[PROG_BACKGROUND].ps);
    progs[PROG_BACKGROUND].map = map_background;
    progs[PROG_BACKGROUND].ps_regs = 4;
    progs[PROG_BACKGROUND].ps_screen_reg = 4;
    progs[PROG_CRT].ps = load_ps("crt_vanilla.psu");
    progs[PROG_CRT].vs = vs_for("crt.vsu", progs[PROG_CRT].ps);
    progs[PROG_CRT].map = map_crt;
    progs[PROG_CRT].ps_regs = 3;
    progs[PROG_CRT].ps_screen_reg = 3;

    /* shaders generados: comparten los .vsu (card, love, vortex), cada uno enlazado a su .psu */
    for (int i = 0; i < N_GEN; i++) {
        const char *n = gen_names[i];
        prog_t *p = &progs[PROG_GEN + i];
        const char *vs = "love.vsu";
        char ps[48];
        snprintf(ps, sizeof(ps), "%s.psu", n);
        p->ps_regs = 8;
        p->ps_screen_reg = 6;
        if (i < 10) {                       /* familia de las cartas: foil, holo, ... */
            p->map = map_edition;
            vs = "card.vsu";
        } else if (!strcmp(n, "flame")) p->map = map_flame;
        else if (!strcmp(n, "splash")) p->map = map_splash;
        else if (!strcmp(n, "flash")) p->map = map_flash;
        else if (!strcmp(n, "gold_seal")) p->map = map_gold_seal;
        else if (!strcmp(n, "vortex")) { p->map = map_vortex; vs = "vortex.vsu"; snprintf(ps, sizeof(ps), "love.psu"); }
        else if (!strcmp(n, "skew")) { p->map = map_skew; vs = "card.vsu"; snprintf(ps, sizeof(ps), "love.psu"); }
        p->ps = load_ps(ps);
        p->vs = vs_for(vs, p->ps);
    }

    gfx_log("shaders: %d loaded (%d from xost), %d missing, %d failed to load, %d with literals", shaders_loaded,
            shaders_xost, shaders_missing, shaders_bad, shaders_lits);

    XsdkSampler sampler = {
        .mag_filter = XSDK_FILTER_LINEAR, .min_filter = XSDK_FILTER_LINEAR, .mip_filter = XSDK_FILTER_POINT,
        .address_u = XSDK_ADDRESS_CLAMP, .address_v = XSDK_ADDRESS_CLAMP, .address_w = XSDK_ADDRESS_CLAMP};
    xsdk_texture_sampler_state(&samp_linear, &sampler);
    sampler.mag_filter = sampler.min_filter = XSDK_FILTER_POINT;
    xsdk_texture_sampler_state(&samp_point, &sampler);
    /* como libXenon: color SRCALPHA / INVSRCALPHA, alfa ONE / INVSRCALPHA */
    XsdkBlend blend = {
        .color_source = XSDK_BLEND_SRC_ALPHA, .color_dest = XSDK_BLEND_ONE_MINUS_SRC_ALPHA,
        .color_op = XSDK_BLEND_OP_ADD,
        .alpha_source = XSDK_BLEND_ONE, .alpha_dest = XSDK_BLEND_ONE_MINUS_SRC_ALPHA,
        .alpha_op = XSDK_BLEND_OP_ADD, .write_mask = XSDK_WRITE_ALL};
    xsdk_gpu_blend_state(&blend_alpha, &blend);

    static unsigned char white[32 * 32 * 4];
    memset(white, 255, sizeof(white));
    white_tex = upload_rgba(white, 32, 32);
    if (!white_tex)
        return -1;
    white_tex->linear = 0;
    vb_mem = xsdk_gpu_alloc(2 * VB_BYTES);
    if (!vb_mem) {
        gfx_log("[ERROR] xsdk_gpu_alloc of %u KB for the vertices failed", (unsigned)(2 * VB_BYTES / 1024));
        return -1;
    }
    vb_addr[0] = xsdk_gpu_address(vb_mem);
    vb_addr[1] = vb_addr[0] + VB_BYTES;
    vb_index = 0;
    vb_base = (vertex_t *)(uintptr_t)vb_mem;
    vb_cur = 0;
    msp = 0;
    mstack[0].a = mstack[0].d = 1;
    gpu_ok = 1;
    l360_gfx_forget_state();
    return 0;
}

int l360_gfx_width(void) { return W; }
int l360_gfx_height(void) { return H; }

void l360_gfx_register(lua_State *L)
{
    static const luaL_Reg tex_m[] = {
        {"getWidth", tex_getWidth}, {"getHeight", tex_getHeight}, {"getDimensions", tex_getDimensions},
        {"getPixelWidth", tex_getPixelWidth}, {"getPixelHeight", tex_getPixelHeight},
        {"getPixelDimensions", tex_getPixelDimensions}, {"getDPIScale", tex_getDPIScale},
        {"setFilter", tex_setFilter}, {"setWrap", nop}, {"setMipmapFilter", nop},
        {"type", tex_type}, {"typeOf", tex_typeOf}, {NULL, NULL}};
    static const luaL_Reg quad_m[] = {
        {"getViewport", quad_getViewport}, {"setViewport", quad_setViewport},
        {"getTextureDimensions", quad_getTextureDimensions}, {NULL, NULL}};
    static const luaL_Reg shader_m[] = {
        {"send", shader_send}, {"hasUniform", shader_hasUniform}, {NULL, NULL}};
    make_mt(L, MT_TEX, tex_m);
    make_mt(L, MT_QUAD, quad_m);
    make_mt(L, MT_SHADER, shader_m);
    static const luaL_Reg font_m[] = {
        {"getWidth", font_getWidth}, {"getHeight", font_getHeight}, {"getAscent", font_getAscent},
        {"getBaseline", font_getAscent}, {"getDescent", font_getDescent},
        {"getLineHeight", font_getLineHeight}, {"setLineHeight", font_setLineHeight},
        {"hasGlyphs", font_hasGlyphs}, {"getWrap", font_getWrap}, {"setFilter", nop}, {"setFallbacks", nop},
        {NULL, NULL}};
    static const luaL_Reg text_m[] = {
        {"getWidth", textm_getWidth}, {"getHeight", textm_getHeight}, {"getDimensions", textm_getDimensions},
        {"set", textm_set}, {"setf", textm_set}, {"clear", textm_clear}, {NULL, NULL}};
    make_mt(L, MT_FONT, font_m);
    make_mt(L, MT_TEXT, text_m);
    luaL_getmetatable(L, MT_TEXT);
    lua_pushcfunction(L, text_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    lua_newtable(L);
    for (const luaL_Reg *f = gfx_funcs; f->name; f++) {
        lua_pushcfunction(L, f->func);
        lua_setfield(L, -2, f->name);
    }
}
