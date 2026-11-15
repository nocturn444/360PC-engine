/*
 * 360PC-Engine - love.graphics on xsdk's GPU (from Love360).
 *
 * Copy of runtime/source/l360_gfx.c (libXenon) with a different layer underneath: the vertex
 * transform, batches, the shader program and register tables, and the Lua types are the same.
 * What changes is how it talks to the GPU (xsdk_gpu_*, xsdk_present_*, xsdk_texture_*).
 *
 * As in LOVE 11: each draw is transformed on the CPU with the transform stack (so the shader gets
 * positions in screen pixels) and sent as a pair of triangles with their constants.
 *
 * Steps 2a to 2d: screen, color shapes, images, text, canvases (resolve to their texture), and the
 * game's shaders (docs/SHADERS.md).
 *
 * Types (userdata with a metatable):
 *   Image / Canvas  xsdk texture + size in LOVE units (dpiscale applied)
 *   Quad            a crop of a texture
 *   Shader          a registered program (the game's shader) or the default one, and its uniform values
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

/* 1 from step 2b: images (stb_image) and text (stb_truetype atlas) as xsdk textures.
 * With 0 (step 2a) newImage only reads the PNG size and fonts do not build their atlas: images and
 * text count as "skipped" and only the color shapes are visible. */
#define L360_TEXTURAS 1

/* 1 from step 2d: each draw uses the program the game asked for.
 * With 0 everything is drawn with l360_default.psu/.vsu (step 2b: testing textures only);
 * newShader answers the same in both cases, so Lua does the same thing. */
#define L360_SHADERS 1

/* Test switches, no recompile needed: words in game:\l360_gfx.txt (one or more):
 *   no_canvas      setCanvas does nothing and drawing a canvas does nothing either: everything goes straight to the screen
 *   no_shaders     everything with l360_default.psu/.vsu (like L360_SHADERS 0)
 *   no_literals   does not load the literals of the XNA shaders (like before the fix)
 *   no_batching       one draw per submit, without joining the ones that share state
 * The xost shaders (tools/shaders/build_shaders.py) and the XNA ones go together in game:\shaders\: each .psu/.vsu
 * is recognized by its header (L3X1 = xost). The shaders_xost switch is no longer needed. */
static int opt_no_canvas, opt_no_shaders, opt_no_batching;
/* for the log, every 300 frames */
static long st_canvas_resolves, st_screen_resolves, st_last_draws, st_last_submits, st_last_verts;

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

/* ---------- device ---------- */

enum {
    BEGIN_TIMEOUT_MS = 5000,     /* the first opening of the Guide held a frame for 2.7 s (xsdk) */
    FENCE_TIMEOUT_MS = 1000,
};

static int W, H;
static float proj[16];
static int gpu_ok;               /* 0 if the GPU hung: draws are discarded */
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

/* xsdk texture and its filter (libXenon stored it in the surface) */
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

/* Same layout as the libXenon vbf: position, uv and color in stream 0 */
static const XsdkVertexElement layout[] = {
    {.usage = XSDK_USAGE_POSITION, .format = XSDK_VERTEX_FLOAT4, .offset_bytes = 0},
    {.usage = XSDK_USAGE_TEXCOORD, .format = XSDK_VERTEX_FLOAT2, .offset_bytes = 16},
    {.usage = XSDK_USAGE_COLOR,    .format = XSDK_VERTEX_FLOAT4, .offset_bytes = 24},
};
static const uint32_t layout_stride[] = {sizeof(vertex_t)};

/* One GPU memory block with two halves: a frame writes one while the GPU may be reading the other
 * (each half's fence says when the GPU is done with it). */
#define VB_VERTS 120000
#define VB_BYTES (VB_VERTS * (uint32_t)sizeof(vertex_t))
static volatile uint32_t *vb_mem;
static uint32_t vb_addr[2];
static uint32_t vb_fence[2];
static int vb_pending[2];
static vertex_t *vb_base;
static int vb_cur, vb_index;

/* GPU memory is written with xsdk's memcpy (32-bit stores) or with volatile stores, never with
 * plain stores (xsdk's docs/PITFALLS.md). Through a volatile pointer: with a fixed size
 * (6 vertices of emit_quad) GCC could replace the call with its own 64-bit stores. */
static void *(*volatile gpu_memcpy)(void *, const void *, size_t) = memcpy;

l360_gfx_stats_t l360_gfx_stats;

/* ---------- LOVE state ---------- */

typedef struct { float a, b, c, d, e, f; } mat_t;   /* x' = a x + c y + e ; y' = b x + d y + f */
#define STACK_MAX 128
static mat_t mstack[STACK_MAX];
static int msp;
static float color[4] = {1, 1, 1, 1};
static float line_width = 1.0f;
static float clear_color[4] = {0, 0, 0, 1};
static int default_linear = 1;

/* ---------- shaders ---------- */

/* Programs: a pixel shader and the vertex shader linked to it, plus where each uniform goes.
 * progs[0] is the default one (texture times colour). The others are the game's: newShader(name,
 * meta) registers them from the table of shaders/<name>.meta.lua, which tools/shaders writes when
 * it compiles the game's GLSL (docs/SHADERS.md). No C changes per game. Registers, the same as in
 * tools/shaders/glsl2hlsl.py:
 *   pixel:  c6 = love_ScreenSize, c7 = 0, c8... = uniforms; s0 = the texture drawn, s1-s3 = Images
 *   vertex: c0-c3 = projection, c4 = love_ScreenSize, c5... = uniforms */
enum {
    PS_SCREEN_REG = 6, PS_BASE = 8, PS_MAX = 32,
    VS_BASE = 5, VS_MAX = 16,
    SAMPLER_MAX = 3, PROG_MAX = 64, UNI_MAX = 96,
};
#define DEFAULT_PS "l360_default.psu"
#define DEFAULT_VS "l360_default.vsu"

typedef struct {
    char name[32];
    int comps, rows, count;      /* floats per register, registers per element, elements */
    int ps, vs;                  /* first register as an index into shader_ud.ps / .vs; -1 = not in that stage */
    int sampler;                 /* 1-3: an Image uniform in that slot; 0 = not an Image */
} uni_t;

typedef struct {
    char name[32];
    XsdkShader *ps, *vs;         /* NULL in a game program: it did not load (drawn with the default) */
    uni_t *uni;
    int nuni;
    int ps_regs, vs_regs;        /* registers to upload from PS_BASE / VS_BASE */
    int samplers;                /* highest Image slot in use */
} prog_t;
static prog_t progs[PROG_MAX];
static int nprogs = 1;

typedef struct {
    int prog;                    /* index into progs; 0 = default */
    float ps[PS_MAX][4];
    float vs[VS_MAX][4];
    surf_t *tex[SAMPLER_MAX + 1];   /* [1..3]: what was sent to each Image uniform */
} shader_ud;

static shader_ud *cur_shader;

/* ---------- textures ---------- */

#define TEX_IMAGE  1
#define TEX_CANVAS 2
typedef struct {
    int kind;
    surf_t *s;                  /* NULL: no texture yet (step 2a) */
    float w, h, dpi;
    char path[64];
} tex_ud;

typedef struct { float x, y, w, h, sw, sh; } quad_ud;

static tex_ud *cur_canvas;      /* active canvas, or NULL = screen */

/* ---------- utilities ---------- */

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

/* XNA shader literals: the fixed HLSL numbers (0.5, 2.0...) are not in the microcode, they are in
 * the container's definition table (word 5 of the header) and must be loaded into the constants
 * every time the shader is set. libXenon does it in Xe_pUploadShaderConstants; xsdk_shader_load
 * does not (it only knows the xost ones, which have xsdk_built_shader_set_literals). Without this
 * the shaders read garbage. */
#define LIT_MAX 64               /* xost ones come one register at a time: consecutive ones are merged */
typedef struct { uint32_t first, count; const float *v; } lit_t;   /* count in groups of 4 floats */
typedef struct {
    XsdkShader sh;               /* first: the XsdkShader * in the tables also points here */
    int pixel;
    int nlit;
    lit_t lit[LIT_MAX];
    uint32_t vmin;               /* the lowest vertex constant that a literal overwrites */
    uint32_t bools[8], bool_mask;
    uint32_t loops[32], loop_mask;
    float hi[4 * 4];             /* pixel c252-c255 (XNA puts the literals at the very top) */
    int has_hi;
} shader_t;

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint32_t be16(const uint8_t *p) { return (uint32_t)p[0] << 8 | p[1]; }

static void parse_literals(shader_t *s, const uint8_t *c, uint32_t n, const char *name)
{
    s->vmin = 0xFFFFFFFFu;
    s->hi[12] = s->hi[13] = 0.5f;                /* c255 as xsdk leaves it if the shader does not use it */
    if (n < 0x24)
        return;
    uint32_t off = be32(c + 0x14), base = be32(c + 4);
    if (!off || off > n)
        return;
    uint32_t p = off + 20;                       /* 16 bytes and the size, as in libXenon */
    for (;;) {                                   /* floats: start, float count, offset */
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
        /* the pixel ones from c252 go separately, in put_hi_constants */
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
    for (;;) {                                   /* ints: booleans and loop counters */
        if (p + 4 > n) return;
        uint32_t start = be16(c + p), count = be16(c + p + 2);
        p += 4;
        if (!count) break;
        if (start < 0x2300 || count * 4 > n - p) return;
        uint32_t idx = (start - 0x2300) / 4;     /* 0-7: boolean words; 8-39: loops */
        for (uint32_t k = 0; k < count; k++) {
            uint32_t i = idx + k, w = be32(c + p + k * 4);
            if (i < 8) { s->bools[i] = w; s->bool_mask |= 1u << i; }
            else if (i < 40) { s->loops[i - 8] = w; s->loop_mask |= 1u << (i - 8); }
        }
        p += count * 4 + 4;
    }
}

static int opt_no_literals;

/* Pixel c252-c255: xsdk_gpu_set_pixel_constants does not work (assert), because xsdk uses c255 for
 * the gl_FragCoord of the xost shaders. Love360 does not use those shaders or the band passes, so
 * the group is written with its own packet, like xsdk's set_floats (src/gpu_constants.c): NOPs
 * until the values start at 16 bytes, the type-0 header and the 16 floats. xsdk puts c255 back
 * when XAM draws (Guide), and then frame_state makes it be written again. */
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

/* The xost ones (tools/shaders/build_shaders.py): "L3X1", the number of literals, and for each
 * literal its register and 4 floats, then the xost container. xost puts each literal in a register
 * the shader does not use (the HLSL register(cN) stay where they say, as in D3D9), so they go
 * through apply_literals like the XNA ones; never in c252-c255. Returns the header size, or 0. */
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

/* game:\shaders\<name>: either the XNA one (10_compilar_todo.bat) or the xost one (build_shaders.py,
 * starts with L3X1), whichever the installer left. The container stays in memory: xsdk reads the
 * shader's tables from it for as long as it exists. */
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

/* Pixel shaders: one per file (l360_love.psu is shared by the shaders with only a vertex stage) */
#define PS_CACHE (PROG_MAX + 2)
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

/* Vertex shader linked to a pixel shader. HLSL: the vertex shader outputs go to the pixel shader
 * inputs by semantic, as in D3D9 (libXenon did not link: it worked because they were in the same
 * order). xsdk_shader_link rewrites the vertex shader's microcode for that pixel shader, so a .vsu
 * that several .psu files use (l360_love.vsu) is loaded once for each of them. */
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

/* 32-bit texture from the RGBA of stb_image. XSDK_FORMAT_A8R8G8B8 takes 0xAARRGGBB words in CPU
 * order (texture.h); xsdk does the Xenos tiling, which libXenon did by hand. */
static surf_t *upload_rgba(const unsigned char *rgba, int w, int h)
{
    surf_t *s = calloc(1, sizeof(*s));
    NTSTATUS st = xsdk_texture_create(&s->t, XSDK_FORMAT_A8R8G8B8, (uint32_t)w, (uint32_t)h, 1, true);
    enum { BAND = 32 };          /* rows per call: each xsdk_texture_upload_rows ends in a sync */
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

/* ---------- draw emission ---------- */

static XsdkShader *bound_ps, *bound_vs;
static surf_t *bound_tex;
static int bound_linear;
static int need_state = 1;       /* after a resolve: target, blend, shaders and texture again */
static int guide_open;           /* the Guide (or a XAM dialog) is open: nothing is drawn, only present */
static int need_vconst = 1;      /* c0-c4 (projection and screen): the text screen overwrites them */

/* What a resolve undoes (xsdk's docs/GUIDE.md): the target, the blend, the shaders and slot 0.
 * The constants stay. No cull or Z: xsdk_gpu_set_target leaves them off. */
static void frame_state(void)
{
    xsdk_gpu_set_target((uint32_t)W, (uint32_t)H);
    xsdk_gpu_set_blend(&blend_alpha);
    bound_ps = bound_vs = NULL;
    bound_tex = NULL;
    need_vconst = 1;              /* with the Guide open, XAM draws between frames and overwrites constants */
    need_state = 0;
}

static void flush(void);

void l360_gfx_forget_state(void)
{
    flush();
    need_state = 1;
    need_vconst = 1;
}

/* Before writing to this frame's half of the vertex buffer: the GPU must have finished the frame
 * that used it (two frames back). */
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

/* Batches: consecutive triangles that share texture (and filter), shaders and constants go in one
 * draw. The vertices are already in screen pixels with their color, so joining them does not change
 * what is seen or the order: it only reduces how often the state is set up and xsdk_gpu_draw is
 * called. The pending batch is drawn (flush) before anything that changes outside state: a resolve
 * (setCanvas, present), a send (changes the constants the batch has not uploaded yet), and the text
 * screen. "no_batching" in l360_gfx.txt draws each submit separately, as before. */
static struct {
    int n;                       /* vertices in the batch; 0 = no batch */
    int first;                   /* first vertex in the current half of the buffer */
    surf_t *tex;
    int linear;
    shader_ud *sh;
    prog_t *p;
    XsdkShader *ps, *vs;
} pend;

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

    /* constants in groups of 4 floats (xsdk); pixel 252-255 belong to xsdk and the table does not reach them */
    float screen[4] = {(float)W, (float)H, 0, 0};
    if (need_vconst) {
        float vc[5 * 4];
        memcpy(vc, proj, sizeof(proj));
        memcpy(vc + 16, screen, sizeof(screen));
        xsdk_gpu_set_vertex_constants(0, vc, 5);
        need_vconst = 0;
        lits_dirty = 1;
    }
    if (p != &progs[0]) {
        /* the game's uniforms: c6 = screen size, c7 = 0 and the shader's own from c8 */
        float pc[2 + PS_MAX][4];
        memcpy(pc[0], screen, sizeof(screen));
        memset(pc[1], 0, sizeof(pc[1]));
        memcpy(pc[2], sh->ps, (size_t)p->ps_regs * sizeof(pc[0]));
        xsdk_gpu_set_pixel_constants(PS_SCREEN_REG, pc[0], 2 + (uint32_t)p->ps_regs);
        if (p->vs_regs > 0)
            xsdk_gpu_set_vertex_constants(VS_BASE, sh->vs[0], (uint32_t)p->vs_regs);
        for (int i = 1; i <= p->samplers; i++) {
            surf_t *x = sh->tex[i] ? sh->tex[i] : white_tex;
            xsdk_gpu_set_texture((uint32_t)i, &x->t, x->linear ? &samp_linear : &samp_point);
        }
        lits_dirty = 1;
    }
    /* the literals go after the game's constants, as in libXenon (they are uploaded when drawing):
     * if they share a register the shader does not declare, the literal wins */
    if (lits_dirty && !opt_no_literals) {
        apply_literals(vs);
        apply_literals(ps);
        if (((const shader_t *)vs)->vmin < 5)
            need_vconst = 1;             /* floor c0-c4: the next draw puts them back */
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

/* Adds triangles (already in screen pixels) with the current shader: to the pending batch if they
 * share the state, otherwise to a new one. */
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
    if (sh && !sh->prog)
        sh = NULL;                   /* a shader that was not built draws as no shader */
    prog_t *p = &progs[sh ? sh->prog : 0];
    XsdkShader *ps = p->ps, *vs = p->vs;
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
    l360_gfx_stats.submits++;
    l360_gfx_stats.verts += nverts;
    if (opt_no_batching)
        flush();                  /* as before batching: each submit is drawn right away */
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

/* local quad (x0,y0)-(x1,y1) with uv, transformed by m */
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

/* local transform of love.graphics.draw: T(x,y) R(r) S(sx,sy) K(kx,ky) T(-ox,-oy) */
static void local_transform(mat_t *out, float x, float y, float r, float sx, float sy,
                            float ox, float oy, float kx, float ky)
{
    float c = cosf(r), s = sinf(r);
    /* same as love::Matrix4::setTransformation */
    out->a = c * sx - ky * s * sy;
    out->b = s * sx + ky * c * sy;
    out->c = kx * c * sx - s * sy;
    out->d = kx * s * sx + c * sy;
    out->e = x - ox * out->a - oy * out->c;
    out->f = y - ox * out->b - oy * out->d;
}

/* Vertices of one text, line, shape or SpriteBatch chunk before they are copied to the GPU's
 * memory. A multiple of 6 (quads) and of 3 (fans). */
#define SCRATCH_VERTS 3060
static vertex_t scratch[SCRATCH_VERTS];

/* ---------- metatables ---------- */

#define MT_TEX    "L360.Tex"
#define MT_QUAD   "L360.Quad"
#define MT_SHADER "L360.Shader"
#define MT_BATCH  "L360.SpriteBatch"

static void (*missing_cb)(const char *);
void l360_gfx_set_missing_cb(void (*cb)(const char *)) { missing_cb = cb; }

static int nop(lua_State *L) { (void)L; return 0; }

/* __index: known method, or nop (and it is logged as missing) */
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

static const uni_t *find_uniform(const prog_t *p, const char *name)
{
    for (int i = 0; i < p->nuni; i++)
        if (!strcmp(p->uni[i].name, name))
            return &p->uni[i];
    return NULL;
}

/* One register from the value at idx: a number or a boolean (first component), or a table, from
 * its element `first`. */
static void read_row(lua_State *L, int idx, float *dst, int comps, int first)
{
    int t = lua_type(L, idx);
    if (t == LUA_TNUMBER) {
        dst[0] = (float)lua_tonumber(L, idx);
    } else if (t == LUA_TBOOLEAN) {
        dst[0] = lua_toboolean(L, idx) ? 1.0f : 0.0f;
    } else if (t == LUA_TTABLE) {
        for (int i = 0; i < comps; i++) {
            lua_rawgeti(L, idx, first + i);
            dst[i] = lua_isboolean(L, -1) ? (float)lua_toboolean(L, -1) : (float)lua_tonumber(L, -1);
            lua_pop(L, 1);
        }
    }
}

/* shader:send(name, value, ...), one value per array element, as in LOVE:
 *   float, int, bool  a number or a boolean
 *   vecN              a table of N numbers
 *   matN              a table of N rows (tables of N numbers) or of N*N numbers; in rows, or in
 *                     columns if "column" comes before the first matrix
 *   Image             an Image or a Canvas
 * A uniform that is not in the shader's metadata is logged once as [missing]. */
static int shader_send(lua_State *L)
{
    shader_ud *sh = luaL_checkudata(L, 1, MT_SHADER);
    const char *name = luaL_checkstring(L, 2);
    l360_gfx_stats.sends++;
    if (!sh->prog)
        return 0;                 /* not built: boot.lua already logged it */
    const prog_t *p = &progs[sh->prog];
    const uni_t *u = find_uniform(p, name);
    if (!u) {
        if (missing_cb) {
            char msg[96];
            snprintf(msg, sizeof(msg), "shader %s: uniform %.40s", p->name, name);
            missing_cb(msg);
        }
        return 0;
    }
    flush();                      /* the pending batch uploads the constants from now, not the new ones */
    if (u->sampler) {
        tex_ud *t = to_tex(L, 3);
        sh->tex[u->sampler] = t ? t->s : NULL;
        return 0;
    }
    if (u->ps < 0 && u->vs < 0)
        return 0;                 /* declared and not used by the shader */
    float v[PS_MAX][4];
    memset(v, 0, sizeof(v));
    int arg = 3, top = lua_gettop(L), column = 0, regs = 0;
    if (u->rows > 1 && lua_type(L, arg) == LUA_TSTRING)
        column = !strcmp(lua_tostring(L, arg++), "column");
    for (int e = 0; e < u->count && arg <= top; e++, arg++, regs += u->rows) {
        float (*dst)[4] = &v[e * u->rows];
        if (u->rows == 1) {
            read_row(L, arg, dst[0], u->comps, 1);
        } else if (lua_istable(L, arg)) {
            float m[4][4];
            memset(m, 0, sizeof(m));
            lua_rawgeti(L, arg, 1);
            int nested = lua_istable(L, -1);
            lua_pop(L, 1);
            for (int r = 0; r < u->rows; r++) {
                if (nested) {
                    lua_rawgeti(L, arg, r + 1);
                    read_row(L, lua_gettop(L), m[r], u->comps, 1);
                    lua_pop(L, 1);
                } else {
                    read_row(L, arg, m[r], u->comps, r * u->comps + 1);
                }
            }
            for (int r = 0; r < u->rows; r++)
                for (int c = 0; c < u->comps; c++)
                    dst[r][c] = column ? m[c][r] : m[r][c];
        }
    }
    if (u->ps >= 0)
        memcpy(sh->ps[u->ps], v, (size_t)regs * sizeof(v[0]));
    if (u->vs >= 0)
        memcpy(sh->vs[u->vs], v, (size_t)regs * sizeof(v[0]));
    return 0;
}

static int shader_hasUniform(lua_State *L)
{
    shader_ud *sh = luaL_checkudata(L, 1, MT_SHADER);
    lua_pushboolean(L, sh->prog && find_uniform(&progs[sh->prog], luaL_checkstring(L, 2)) != NULL);
    return 1;
}

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

/* ---------- love.graphics functions ---------- */


/* ---------- fonts and text (stb_truetype) ---------- */

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
    float ascent, descent, linegap;   /* in font units */
    float upm_scale;                  /* scale from units to 1 px of em */
    surf_t *atlas;                    /* NULL without textures (step 2a) */
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

/* Advance of a character at this size: from the atlas table (Latin-1), otherwise from the font.
 * Control characters take no room. */
static float glyph_adv(font_data *fd, int cp, float size)
{
    if (cp < 32) return 0;
    if (cp < 256 && fd->g[cp].ok) return fd->g[cp].adv * (size / RASTER_PX);
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
    /* atlas with ASCII and Latin-1, rasterized at RASTER_PX */
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

static float font_height(const font_ud *f)
{
    return floorf((f->fd->ascent - f->fd->descent + f->fd->linegap) * px_scale(f->fd, f->size) + 0.5f);
}

/* The text of print, printf, getWidth and getWrap: one buffer for the whole program (no heap use
 * per call), with the colours of a coloured text ({color, "str", ...}) and the lines it was split
 * into. Longer texts are cut. */
#define PRINT_MAX 4096
#define PRINT_RUNS 32
#define PRINT_LINES 256
typedef struct { int start, end, spaces; float width; } line_t;
static struct {
    char buf[PRINT_MAX];
    int len, nruns, nlines;
    struct { int start; float col[4]; } run[PRINT_RUNS];
    line_t line[PRINT_LINES];
    float width;                 /* of the widest line */
} pr;

static void pr_append(const char *s, size_t n, const float *col)
{
    if (!s || pr.nruns == PRINT_RUNS) return;
    if (n > (size_t)(PRINT_MAX - 1 - pr.len)) n = (size_t)(PRINT_MAX - 1 - pr.len);
    pr.run[pr.nruns].start = pr.len;
    memcpy(pr.run[pr.nruns].col, col, 4 * sizeof(float));
    pr.nruns++;
    memcpy(pr.buf + pr.len, s, n);
    pr.len += (int)n;
    pr.buf[pr.len] = 0;
}

/* A string, a number or a coloured text table at idx */
static void pr_read(lua_State *L, int idx)
{
    float col[4] = {1, 1, 1, 1};
    size_t n;
    pr.len = pr.nruns = 0;
    pr.buf[0] = 0;
    if (lua_istable(L, idx)) {
        int len = (int)lua_objlen(L, idx);
        for (int i = 1; i <= len; i++) {
            lua_rawgeti(L, idx, i);
            if (lua_istable(L, -1)) {
                for (int k = 0; k < 4; k++) {
                    lua_rawgeti(L, -1, k + 1);
                    col[k] = lua_isnumber(L, -1) ? (float)lua_tonumber(L, -1) : 1.0f;
                    lua_pop(L, 1);
                }
            } else if (lua_isstring(L, -1)) {
                const char *s = lua_tolstring(L, -1, &n);
                pr_append(s, n, col);
            }
            lua_pop(L, 1);
        }
    } else if (lua_isstring(L, idx)) {
        const char *s = lua_tolstring(L, idx, &n);
        pr_append(s, n, col);
    }
}

static void pr_line(int start, int end, float w)
{
    if (pr.nlines == PRINT_LINES) return;
    int spaces = 0;
    for (int i = start; i < end; i++) spaces += pr.buf[i] == ' ';
    pr.line[pr.nlines++] = (line_t){start, end, spaces, w};
    if (w > pr.width) pr.width = w;
}

/* Splits the text into lines, as LOVE does: at each \n, and (with limit >= 0) before the character
 * that would go past the limit, back at the last space of the line if it has one. */
static void pr_wrap(const font_ud *f, float limit)
{
    const unsigned char *s = (const unsigned char *)pr.buf;
    int i = 0;
    pr.nlines = 0;
    pr.width = 0;
    for (;;) {
        int start = i, space = -1;
        float w = 0, w_space = 0;
        while (i < pr.len && s[i] != '\n') {
            const unsigned char *p = s + i;
            int cp = utf8_next(&p);
            float adv = glyph_adv(f->fd, cp, f->size);
            if (limit >= 0 && w + adv > limit && cp != ' ' && i > start) {
                if (space >= 0) {
                    pr_line(start, space, w_space);
                    i = space + 1;
                } else {
                    pr_line(start, i, w);
                }
                start = i;
                space = -1;
                w = 0;
                continue;
            }
            if (cp == ' ') { space = i; w_space = w; }
            w += adv;
            i = (int)(p - s);
        }
        pr_line(start, i, w);
        if (i >= pr.len) break;
        i++;                     /* the \n */
    }
}

enum { ALIGN_LEFT, ALIGN_CENTER, ALIGN_RIGHT, ALIGN_JUSTIFY };

static int font_getWidth(lua_State *L)
{
    font_ud *f = to_font(L, 1);
    pr_read(L, 2);
    pr_wrap(f, -1);
    lua_pushnumber(L, pr.width);
    return 1;
}
static int font_getHeight(lua_State *L) { lua_pushnumber(L, font_height(to_font(L, 1))); return 1; }
static int font_getAscent(lua_State *L) { font_ud *f = to_font(L, 1); lua_pushnumber(L, f->fd->ascent * px_scale(f->fd, f->size)); return 1; }
static int font_getDescent(lua_State *L) { font_ud *f = to_font(L, 1); lua_pushnumber(L, f->fd->descent * px_scale(f->fd, f->size)); return 1; }
static int font_getLineHeight(lua_State *L) { lua_pushnumber(L, to_font(L, 1)->line_height); return 1; }
static int font_setLineHeight(lua_State *L) { to_font(L, 1)->line_height = (float)luaL_checknumber(L, 2); return 0; }
static int font_hasGlyphs(lua_State *L) { lua_pushboolean(L, 1); return 1; }
/* font:getWrap(text, limit): the width of the widest line and the lines */
static int font_getWrap(lua_State *L)
{
    font_ud *f = to_font(L, 1);
    pr_read(L, 2);
    pr_wrap(f, (float)luaL_optnumber(L, 3, -1));
    lua_pushnumber(L, pr.width);
    lua_createtable(L, pr.nlines, 0);
    for (int i = 0; i < pr.nlines; i++) {
        lua_pushlstring(L, pr.buf + pr.line[i].start, (size_t)(pr.line[i].end - pr.line[i].start));
        lua_rawseti(L, -2, i + 1);
    }
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

/* newText(font, text) */
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

static void draw_text(text_ud *t, const mat_t *m)
{
    font_data *fd = t->font.fd;
    if (!fd->atlas) {                   /* without textures (step 2a) */
        l360_gfx_stats.skipped++;
        return;
    }
    float k = t->font.size / RASTER_PX;              /* from rasterized px to font px */
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
            if (gl->x1 > gl->x0 && nv + 6 <= SCRATCH_VERTS) {
                float x0 = pen + gl->x0 * k, x1 = pen + gl->x1 * k;
                float y0 = base + gl->y0 * k, y1 = base + gl->y1 * k;
                vertex_t *v = scratch + nv;
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
    if (nv) submit(fd->atlas, scratch, nv);
}

/* Draws the lines of pr with their alignment inside `limit` */
static void pr_draw(const font_ud *f, const mat_t *m, float limit, int align)
{
    font_data *fd = f->fd;
    if (!fd->atlas) {                   /* without textures (step 2a) */
        l360_gfx_stats.skipped++;
        return;
    }
    float k = f->size / RASTER_PX;
    float base = fd->ascent * px_scale(fd, f->size);
    float step = floorf(font_height(f) * f->line_height + 0.5f);
    float saved[4];
    memcpy(saved, color, sizeof(saved));
    int nv = 0, run = 0, applied = -1;
    for (int li = 0; li < pr.nlines; li++) {
        const line_t *ln = &pr.line[li];
        float pen = 0, extra = 0;
        if (align == ALIGN_CENTER) pen = floorf((limit - ln->width) / 2);
        else if (align == ALIGN_RIGHT) pen = floorf(limit - ln->width);
        else if (align == ALIGN_JUSTIFY && ln->spaces && ln->width < limit) extra = (limit - ln->width) / ln->spaces;
        float y = base + li * step;
        const unsigned char *p = (const unsigned char *)pr.buf + ln->start;
        const unsigned char *end = (const unsigned char *)pr.buf + ln->end;
        while (p < end) {
            int at = (int)(p - (const unsigned char *)pr.buf);
            while (run + 1 < pr.nruns && pr.run[run + 1].start <= at) run++;
            if (run != applied) {
                for (int c = 0; c < 4; c++) color[c] = saved[c] * pr.run[run].col[c];
                applied = run;
            }
            int cp = utf8_next(&p);
            glyph_t *gl = (cp >= 32 && cp < 256) ? &fd->g[cp] : NULL;
            if (!gl || !gl->ok) { pen += glyph_adv(fd, cp, f->size); continue; }
            if (gl->x1 > gl->x0) {
                if (nv + 6 > SCRATCH_VERTS) { submit(fd->atlas, scratch, nv); nv = 0; }
                float x0 = pen + gl->x0 * k, x1 = pen + gl->x1 * k;
                float y0 = y + gl->y0 * k, y1 = y + gl->y1 * k;
                vertex_t *v = scratch + nv;
                set_vert(&v[0], m, x0, y0, gl->u0, gl->v0);
                set_vert(&v[1], m, x1, y0, gl->u1, gl->v0);
                set_vert(&v[2], m, x0, y1, gl->u0, gl->v1);
                v[3] = v[1];
                set_vert(&v[4], m, x1, y1, gl->u1, gl->v1);
                v[5] = v[2];
                nv += 6;
            }
            pen += gl->adv * k;
            if (cp == ' ') pen += extra;
        }
    }
    memcpy(color, saved, sizeof(saved));
    if (nv) submit(fd->atlas, scratch, nv);
}

static int g_newImage(lua_State *L)
{
    /* newImage(path, png_bytes, dpiscale) - the Lua side already read the file */
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
    /* step 2a: only the size (big-endian width and height from the IHDR header, bytes 16 to 23) */
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
    /* texture the size of the screen, tiled (a resolve only writes tiled textures) */
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

static int meta_int(lua_State *L, int t, const char *key, int def)
{
    lua_getfield(L, t, key);
    int v = lua_isnumber(L, -1) ? (int)lua_tointeger(L, -1) : def;
    lua_pop(L, 1);
    return v;
}

/* A .psu/.vsu file name in the metadata: a plain name, inside shaders\ */
static int meta_file(lua_State *L, int t, const char *key, char *dst, size_t size)
{
    lua_getfield(L, t, key);
    const char *v = lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : "";
    int ok = v[0] && strlen(v) < size && !strpbrk(v, "/\\:") && !strstr(v, "..");
    snprintf(dst, size, "%s", ok ? v : "");
    lua_pop(L, 1);
    return ok;
}

/* The uniforms of the metadata table at t: { name = { comps, rows, count, ps, vs, sampler } }.
 * ps and vs are register numbers (c8..., c5...). 0 if something is out of range. */
static int read_uniforms(lua_State *L, int t, prog_t *p)
{
    int ok = 1;
    lua_getfield(L, t, "uniforms");
    if (lua_istable(L, -1)) {
        int ut = lua_gettop(L);
        lua_pushnil(L);
        while (lua_next(L, ut)) {
            if (ok) {
                uni_t u;
                memset(&u, 0, sizeof(u));
                int e = lua_gettop(L);
                ok = lua_type(L, -2) == LUA_TSTRING && lua_istable(L, -1) && p->nuni < UNI_MAX
                     && strlen(lua_tostring(L, -2)) < sizeof(u.name);
                if (ok) {
                    snprintf(u.name, sizeof(u.name), "%s", lua_tostring(L, -2));
                    u.comps = meta_int(L, e, "comps", 0);
                    u.rows = meta_int(L, e, "rows", 0);
                    u.count = meta_int(L, e, "count", 1);
                    u.ps = meta_int(L, e, "ps", -1);
                    u.vs = meta_int(L, e, "vs", -1);
                    u.sampler = meta_int(L, e, "sampler", 0);
                    if (u.sampler) {
                        ok = u.sampler >= 1 && u.sampler <= SAMPLER_MAX;
                        if (ok && u.sampler > p->samplers) p->samplers = u.sampler;
                    } else {
                        int regs = u.rows * u.count;
                        ok = u.comps >= 1 && u.comps <= 4 && u.rows >= 1 && u.rows <= 4 && u.count >= 1
                             && u.count <= PS_MAX
                             && (u.ps < 0 || (u.ps >= PS_BASE && u.ps - PS_BASE + regs <= p->ps_regs))
                             && (u.vs < 0 || (u.vs >= VS_BASE && u.vs - VS_BASE + regs <= p->vs_regs));
                        if (u.ps >= 0) u.ps -= PS_BASE;
                        if (u.vs >= 0) u.vs -= VS_BASE;
                    }
                }
                uni_t *grown = ok ? realloc(p->uni, (size_t)(p->nuni + 1) * sizeof(uni_t)) : NULL;
                if (grown) {
                    p->uni = grown;
                    p->uni[p->nuni++] = u;
                } else {
                    ok = 0;
                }
            }
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);
    return ok;
}

/* The program called `name`; the first time, registered from its metadata table (stack index t).
 * 0 (the default program) if it cannot be used: the reason is logged, once. */
static int prog_for(lua_State *L, int t, const char *name)
{
    for (int i = 1; i < nprogs; i++)
        if (!strcmp(progs[i].name, name))
            return progs[i].ps ? i : 0;
    if (nprogs == PROG_MAX || strlen(name) >= sizeof(progs[0].name)) {
        gfx_log(" [shader] %.40s: cannot be registered (at most %d shaders, names under 32 characters)",
                name, PROG_MAX - 1);
        return 0;
    }
    prog_t *p = &progs[nprogs];
    memset(p, 0, sizeof(*p));
    snprintf(p->name, sizeof(p->name), "%s", name);
    char ps[32], vs[32];
    p->ps_regs = meta_int(L, t, "ps_regs", 0);
    p->vs_regs = meta_int(L, t, "vs_regs", 0);
    int ok = meta_int(L, t, "version", 0) == 1;
    ok = meta_file(L, t, "ps", ps, sizeof(ps)) && ok;
    ok = meta_file(L, t, "vs", vs, sizeof(vs)) && ok;
    ok = ok && p->ps_regs >= 0 && p->ps_regs <= PS_MAX && p->vs_regs >= 0 && p->vs_regs <= VS_MAX;
    ok = ok && read_uniforms(L, t, p);
    nprogs++;                    /* it stays registered if it fails: one attempt and one log line */
    if (!ok) {
        gfx_log(" [shader] %s: bad metadata (shaders\\%s.meta.lua; build the shaders again)", name, name);
        return 0;
    }
    p->ps = load_ps(ps);
    p->vs = vs_for(vs, p->ps);
    if (!p->ps || !p->vs) {
        gfx_log(" [shader] %s: not loaded, drawn with the default one", name);
        p->ps = p->vs = NULL;
        return 0;
    }
    gfx_log(" [shader] %s: %s + %s, %d uniforms (%d pixel and %d vertex registers, %d images)", name, ps, vs,
            p->nuni, p->ps_regs, p->vs_regs, p->samplers);
    return nprogs - 1;
}

/* newShader(name, meta): meta is the table of shaders/<name>.meta.lua, or nil if the shader was
 * not built (boot.lua logs that). Returns the Shader and whether its program is in use. */
static int g_newShader(lua_State *L)
{
    const char *name = luaL_optstring(L, 1, "");
    shader_ud *sh = lua_newuserdata(L, sizeof(shader_ud));
    memset(sh, 0, sizeof(*sh));
    if (lua_istable(L, 2))
        sh->prog = prog_for(L, 2, name);
    luaL_getmetatable(L, MT_SHADER);
    lua_setmetatable(L, -2);
    lua_pushboolean(L, sh->prog != 0);
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

/* The arguments x, y (at xy) and r, sx, sy, ox, oy, kx, ky (at rest) as a local transform */
static void arg_local(lua_State *L, int xy, int rest, mat_t *lt)
{
    float sx = num_or(L, rest + 1, 1);
    local_transform(lt, num_or(L, xy, 0), num_or(L, xy + 1, 0), num_or(L, rest, 0),
                    sx, num_or(L, rest + 2, sx),
                    num_or(L, rest + 3, 0), num_or(L, rest + 4, 0), num_or(L, rest + 5, 0), num_or(L, rest + 6, 0));
}

/* ---------- SpriteBatch ---------- */

/* The sprites keep their vertices ready (position in the batch's own space, uv and colour): add
 * and set do the work once, and drawing the batch only moves them by the current transform and
 * copies them to the vertex buffer in chunks, which the batching joins into a single GPU draw.
 * The buffer grows when it is full, as in LOVE 11. */
typedef struct {
    tex_ud *tex;                 /* kept alive by the userdata's environment table */
    vertex_t *v;                 /* 6 per sprite */
    int count, cap;
    float col[4];
} batch_ud;

static batch_ud *to_batch(lua_State *L, int i) { return luaL_checkudata(L, i, MT_BATCH); }

static void batch_set_tex(lua_State *L, batch_ud *b, int idx)
{
    tex_ud *t = to_tex(L, idx);
    if (!t) luaL_argerror(L, idx, "Image or Canvas expected");
    lua_createtable(L, 1, 0);
    lua_pushvalue(L, idx);
    lua_rawseti(L, -2, 1);
    lua_setfenv(L, 1);
    b->tex = t;
}

/* newSpriteBatch(image, maxsprites, usage) */
static int g_newSpriteBatch(lua_State *L)
{
    if (!to_tex(L, 1)) luaL_argerror(L, 1, "Image or Canvas expected");
    int cap = (int)luaL_optnumber(L, 2, 1000);
    if (cap < 1) cap = 1;
    batch_ud *b = lua_newuserdata(L, sizeof(batch_ud));
    memset(b, 0, sizeof(*b));
    b->col[0] = b->col[1] = b->col[2] = b->col[3] = 1;
    luaL_getmetatable(L, MT_BATCH);
    lua_setmetatable(L, -2);
    lua_insert(L, 1);            /* the batch first, the image second */
    batch_set_tex(L, b, 2);
    b->v = malloc((size_t)cap * 6 * sizeof(vertex_t));
    if (!b->v) return luaL_error(L, "newSpriteBatch: no memory for %d sprites", cap);
    b->cap = cap;
    lua_settop(L, 1);
    return 1;
}

static int batch_gc(lua_State *L)
{
    batch_ud *b = to_batch(L, 1);
    free(b->v);
    b->v = NULL;
    b->count = b->cap = 0;
    return 0;
}

/* ([quad], x, y, r, sx, sy, ox, oy, kx, ky) from argument a: the 6 vertices of a sprite */
static void batch_sprite(lua_State *L, batch_ud *b, vertex_t *v, int a)
{
    quad_ud *q = luaL_testudata(L, a, MT_QUAD);
    float w = b->tex->w, h = b->tex->h, u0 = 0, v0 = 0, u1 = 1, v1 = 1;
    if (q) {
        a++;
        w = q->w; h = q->h;
        u0 = q->x / q->sw; v0 = q->y / q->sh;
        u1 = (q->x + q->w) / q->sw; v1 = (q->y + q->h) / q->sh;
    }
    mat_t lt;
    arg_local(L, a, a + 2, &lt);
    const float px[4] = {0, w, 0, w}, py[4] = {0, 0, h, h};
    const float pu[4] = {u0, u1, u0, u1}, pv[4] = {v0, v0, v1, v1};
    static const int order[6] = {0, 1, 2, 1, 3, 2};
    for (int i = 0; i < 6; i++) {
        int c = order[i];
        xf(&lt, px[c], py[c], &v[i].x, &v[i].y);
        v[i].z = 0; v[i].w = 1;
        v[i].u = pu[c]; v[i].v = pv[c];
        v[i].r = b->col[0]; v[i].g = b->col[1]; v[i].b = b->col[2]; v[i].a = b->col[3];
    }
}

static int batch_add(lua_State *L)
{
    batch_ud *b = to_batch(L, 1);
    if (b->count == b->cap) {
        int cap = b->cap * 2;
        vertex_t *v = realloc(b->v, (size_t)cap * 6 * sizeof(vertex_t));
        if (!v) return luaL_error(L, "SpriteBatch:add: no memory for %d sprites", cap);
        b->v = v;
        b->cap = cap;
    }
    batch_sprite(L, b, b->v + b->count * 6, 2);
    lua_pushinteger(L, ++b->count);
    return 1;
}
static int batch_set(lua_State *L)
{
    batch_ud *b = to_batch(L, 1);
    int id = (int)luaL_checkinteger(L, 2);
    if (id < 1 || id > b->count) return luaL_error(L, "SpriteBatch:set: no sprite %d (the batch has %d)", id, b->count);
    batch_sprite(L, b, b->v + (id - 1) * 6, 3);
    return 0;
}
static int batch_clear(lua_State *L) { to_batch(L, 1)->count = 0; return 0; }
static int batch_getCount(lua_State *L) { lua_pushinteger(L, to_batch(L, 1)->count); return 1; }
static int batch_getBufferSize(lua_State *L) { lua_pushinteger(L, to_batch(L, 1)->cap); return 1; }
/* setColor(r, g, b, a): the colour of the sprites added or set from now on; setColor(): white */
static int batch_setColor(lua_State *L) { read_color(L, 2, to_batch(L, 1)->col); return 0; }
static int batch_getColor(lua_State *L)
{
    batch_ud *b = to_batch(L, 1);
    for (int i = 0; i < 4; i++) lua_pushnumber(L, b->col[i]);
    return 4;
}
static int batch_setTexture(lua_State *L) { batch_set_tex(L, to_batch(L, 1), 2); return 0; }
static int batch_getTexture(lua_State *L)
{
    to_batch(L, 1);
    lua_getfenv(L, 1);
    lua_rawgeti(L, -1, 1);
    return 1;
}
static int batch_type(lua_State *L) { lua_pushliteral(L, "SpriteBatch"); return 1; }
static int batch_typeOf(lua_State *L)
{
    const char *n = luaL_checkstring(L, 2);
    lua_pushboolean(L, !strcmp(n, "SpriteBatch") || !strcmp(n, "Drawable") || !strcmp(n, "Object"));
    return 1;
}

/* Sprites that end up wholly outside the screen (or the canvas, which has its size) are left out,
 * so a batch with a whole map costs what the visible part costs. Not with a game shader active:
 * its vertex stage may move them. */
static void draw_batch(const batch_ud *b, const mat_t *m)
{
    surf_t *s = b->tex->s;
    if (!s || (b->tex->kind == TEX_CANVAS && opt_no_canvas)) {
        l360_gfx_stats.skipped++;
        return;
    }
    const shader_ud *sh = (L360_SHADERS && !opt_no_shaders) ? cur_shader : NULL;
    const int cull = !sh || !sh->prog;
    const int tinted = color[0] != 1 || color[1] != 1 || color[2] != 1 || color[3] != 1;
    const float w = (float)W, h = (float)H;
    const vertex_t *src = b->v;
    int n = 0;
    for (int i = 0; i < b->count; i++, src += 6) {
        /* the corners are vertices 0, 1, 2 and 4; 3 and 5 repeat 1 and 2 */
        float x0, y0, x1, y1, x2, y2, x3, y3;
        xf(m, src[0].x, src[0].y, &x0, &y0);
        xf(m, src[1].x, src[1].y, &x1, &y1);
        xf(m, src[2].x, src[2].y, &x2, &y2);
        xf(m, src[4].x, src[4].y, &x3, &y3);
        if (cull && ((x0 < 0 && x1 < 0 && x2 < 0 && x3 < 0) || (x0 > w && x1 > w && x2 > w && x3 > w) ||
                     (y0 < 0 && y1 < 0 && y2 < 0 && y3 < 0) || (y0 > h && y1 > h && y2 > h && y3 > h)))
            continue;
        if (n == SCRATCH_VERTS) {
            submit(s, scratch, n);
            n = 0;
        }
        vertex_t *v = scratch + n;
        memcpy(v, src, 6 * sizeof(vertex_t));
        v[0].x = x0; v[0].y = y0;
        v[1].x = v[3].x = x1; v[1].y = v[3].y = y1;
        v[2].x = v[5].x = x2; v[2].y = v[5].y = y2;
        v[4].x = x3; v[4].y = y3;
        if (tinted)
            for (int k = 0; k < 6; k++) {
                v[k].r *= color[0]; v[k].g *= color[1]; v[k].b *= color[2]; v[k].a *= color[3];
            }
        n += 6;
    }
    if (n) submit(s, scratch, n);
}

/* draw(drawable, [quad], x, y, r, sx, sy, ox, oy, kx, ky) */
static int g_draw(lua_State *L)
{
    tex_ud *t = to_tex(L, 1);
    text_ud *tx = t ? NULL : luaL_testudata(L, 1, MT_TEXT);
    batch_ud *sb = (t || tx) ? NULL : luaL_testudata(L, 1, MT_BATCH);
    if ((!t && !tx && !sb) || (t && !t->s) || (t && t->kind == TEX_CANVAS && opt_no_canvas)) {
        l360_gfx_stats.skipped++;        /* Video and others: not yet; textures from step 2b */
        return 0;
    }
    int a = 2;
    quad_ud *q = sb ? NULL : luaL_testudata(L, 2, MT_QUAD);
    if (q) a = 3;
    mat_t lt, m;
    arg_local(L, a, a + 2, &lt);
    mat_mul(&m, &mstack[msp], &lt);
    if (sb) {
        draw_batch(sb, &m);
    } else if (tx) {
        draw_text(tx, &m);
    } else if (q) {
        emit_quad(t->s, &m, 0, 0, q->w, q->h,
                  q->x / q->sw, q->y / q->sh, (q->x + q->w) / q->sw, (q->y + q->h) / q->sh);
    } else {
        emit_quad(t->s, &m, 0, 0, t->w, t->h, 0, 0, 1, 1);
    }
    return 0;
}

/* print(font, text, x, y, r, sx, sy, ox, oy, kx, ky): boot.lua adds the current font */
static int g_print(lua_State *L)
{
    font_ud *f = to_font(L, 1);
    if (!f) {
        l360_gfx_stats.skipped++;        /* no TTF: the font only measures */
        return 0;
    }
    mat_t lt, m;
    arg_local(L, 3, 5, &lt);
    mat_mul(&m, &mstack[msp], &lt);
    pr_read(L, 2);
    pr_wrap(f, -1);
    pr_draw(f, &m, 0, ALIGN_LEFT);
    return 0;
}

/* printf(font, text, x, y, limit, align, r, sx, sy, ox, oy, kx, ky) */
static int g_printf(lua_State *L)
{
    static const char *const aligns[] = {"left", "center", "right", "justify", NULL};
    font_ud *f = to_font(L, 1);
    if (!f) {
        l360_gfx_stats.skipped++;
        return 0;
    }
    float limit = (float)luaL_checknumber(L, 5);
    int align = luaL_checkoption(L, 6, "left", aligns);
    mat_t lt, m;
    arg_local(L, 3, 7, &lt);
    mat_mul(&m, &mstack[msp], &lt);
    pr_read(L, 2);
    pr_wrap(f, limit < 0 ? 0 : limit);
    pr_draw(f, &m, limit, align);
    return 0;
}

/* ---------- lines and shapes ---------- */

/* Shapes are drawn without the game's shader, like rectangle and polygon since Love360. */

#define LINE_PTS 510             /* 6 vertices per segment in scratch */
static float line_pts[LINE_PTS * 2], line_off[LINE_PTS * 2];

/* Numbers from argument `first` on, or from the table there: how many were read (at most max) */
static int read_numbers(lua_State *L, int first, float *dst, int max)
{
    int n = 0;
    if (lua_istable(L, first)) {
        int len = (int)lua_objlen(L, first);
        for (int i = 1; i <= len && n < max; i++) {
            lua_rawgeti(L, first, i);
            dst[n++] = (float)lua_tonumber(L, -1);
            lua_pop(L, 1);
        }
    } else {
        int top = lua_gettop(L);
        for (int i = first; i <= top && n < max; i++) dst[n++] = (float)lua_tonumber(L, i);
    }
    return n;
}

/* A line of the current width through the np points of line_pts (changed here), closed or not,
 * with miter joins: each point is moved to both sides along the bisector of its two segments, so
 * the segments share their corners and nothing is drawn twice (it matters with alpha). Very sharp
 * corners are cut short. */
static void emit_polyline(const mat_t *m, int np, int closed)
{
    float *p = line_pts, *o = line_off;
    int n = 0;
    for (int i = 0; i < np; i++) {               /* drop repeated points */
        if (n && p[i * 2] == p[n * 2 - 2] && p[i * 2 + 1] == p[n * 2 - 1]) continue;
        p[n * 2] = p[i * 2]; p[n * 2 + 1] = p[i * 2 + 1];
        n++;
    }
    if (closed && n > 2 && p[0] == p[n * 2 - 2] && p[1] == p[n * 2 - 1]) n--;
    if (n < 2) return;
    if (n == 2) closed = 0;
    const float hw = line_width * 0.5f;
    for (int i = 0; i < n; i++) {
        int a = i - 1, b = i + 1;
        if (a < 0) a = closed ? n - 1 : i;
        if (b >= n) b = closed ? 0 : i;
        /* normals of the segment that arrives and of the one that leaves */
        float ax = p[i * 2] - p[a * 2], ay = p[i * 2 + 1] - p[a * 2 + 1];
        float bx = p[b * 2] - p[i * 2], by = p[b * 2 + 1] - p[i * 2 + 1];
        float al = sqrtf(ax * ax + ay * ay), bl = sqrtf(bx * bx + by * by);
        if (al < 1e-12f) { ax = bx; ay = by; al = bl; }
        if (bl < 1e-12f) { bx = ax; by = ay; bl = al; }
        float n1x = -ay / al, n1y = ax / al, n2x = -by / bl, n2y = bx / bl;
        float mx = n1x + n2x, my = n1y + n2y, ml = sqrtf(mx * mx + my * my);
        if (ml < 1e-4f) {                        /* it turns back on itself */
            o[i * 2] = n1x * hw; o[i * 2 + 1] = n1y * hw;
            continue;
        }
        mx /= ml; my /= ml;
        float d = mx * n1x + my * n1y;
        if (d < 0.25f) d = 0.25f;
        o[i * 2] = mx * hw / d; o[i * 2 + 1] = my * hw / d;
    }
    int segs = closed ? n : n - 1, k = 0;
    for (int i = 0; i < segs; i++) {
        int j = i + 1 == n ? 0 : i + 1;
        vertex_t *v = scratch + k;
        set_vert(&v[0], m, p[i * 2] + o[i * 2], p[i * 2 + 1] + o[i * 2 + 1], 0, 0);
        set_vert(&v[1], m, p[j * 2] + o[j * 2], p[j * 2 + 1] + o[j * 2 + 1], 0, 0);
        set_vert(&v[2], m, p[i * 2] - o[i * 2], p[i * 2 + 1] - o[i * 2 + 1], 0, 0);
        v[3] = v[1];
        set_vert(&v[4], m, p[j * 2] - o[j * 2], p[j * 2 + 1] - o[j * 2 + 1], 0, 0);
        v[5] = v[2];
        k += 6;
    }
    shader_ud *saved = cur_shader;
    cur_shader = NULL;
    submit(NULL, scratch, k);
    cur_shader = saved;
}

/* line(x1, y1, x2, y2, ...) | line({x1, y1, ...}); a line that ends where it starts is closed */
static int g_line(lua_State *L)
{
    int np = read_numbers(L, 1, line_pts, LINE_PTS * 2) / 2;
    int closed = np >= 3 && line_pts[0] == line_pts[np * 2 - 2] && line_pts[1] == line_pts[np * 2 - 1];
    emit_polyline(&mstack[msp], np, closed);
    return 0;
}

/* The ellipse with radii rx, ry around (x, y), in `segs` segments (0 = as many as LOVE picks) */
static void draw_ellipse(const char *mode, float x, float y, float rx, float ry, int segs)
{
    if (segs <= 0) {
        segs = (int)sqrtf((fabsf(rx) + fabsf(ry)) * 0.5f * 20.0f);
        if (segs < 8) segs = 8;
    }
    if (segs < 3) segs = 3;
    if (segs > LINE_PTS) segs = LINE_PTS;
    const mat_t *m = &mstack[msp];
    const float step = 6.28318530718f / (float)segs;
    for (int i = 0; i < segs; i++) {
        line_pts[i * 2] = x + cosf(step * i) * rx;
        line_pts[i * 2 + 1] = y + sinf(step * i) * ry;
    }
    if (mode[0] != 'f') {
        emit_polyline(m, segs, 1);
        return;
    }
    int k = 0;
    for (int i = 0; i < segs; i++) {             /* fan from the centre */
        int j = i + 1 == segs ? 0 : i + 1;
        set_vert(&scratch[k++], m, x, y, 0, 0);
        set_vert(&scratch[k++], m, line_pts[i * 2], line_pts[i * 2 + 1], 0, 0);
        set_vert(&scratch[k++], m, line_pts[j * 2], line_pts[j * 2 + 1], 0, 0);
    }
    shader_ud *saved = cur_shader;
    cur_shader = NULL;
    submit(NULL, scratch, k);
    cur_shader = saved;
}

/* circle(mode, x, y, radius, segments) */
static int g_circle(lua_State *L)
{
    float r = num_or(L, 4, 0);
    draw_ellipse(luaL_checkstring(L, 1), num_or(L, 2, 0), num_or(L, 3, 0), r, r, (int)num_or(L, 5, 0));
    return 0;
}
/* ellipse(mode, x, y, radiusx, radiusy, segments) */
static int g_ellipse(lua_State *L)
{
    draw_ellipse(luaL_checkstring(L, 1), num_or(L, 2, 0), num_or(L, 3, 0), num_or(L, 4, 0), num_or(L, 5, 0),
                 (int)num_or(L, 6, 0));
    return 0;
}

static float point_size = 1.0f;
static int g_setPointSize(lua_State *L) { point_size = num_or(L, 1, 1); return 0; }
static int g_getPointSize(lua_State *L) { lua_pushnumber(L, point_size); return 1; }

/* points(x, y, ...) | points({x, y, ...}) | points({{x, y, r, g, b, a}, ...}): squares of the
 * point size in screen pixels (the transform moves them, it does not scale them) */
static int g_points(lua_State *L)
{
    static const mat_t ident = {1, 0, 0, 1, 0, 0};
    const mat_t *m = &mstack[msp];
    const float h = point_size * 0.5f;
    int coloured = 0, np, k = 0;
    if (lua_istable(L, 1)) {
        lua_rawgeti(L, 1, 1);
        coloured = lua_istable(L, -1);
        lua_pop(L, 1);
    }
    np = coloured ? (int)lua_objlen(L, 1) : read_numbers(L, 1, line_pts, LINE_PTS * 2) / 2;
    if (np > LINE_PTS) np = LINE_PTS;
    float saved[4];
    memcpy(saved, color, sizeof(saved));
    for (int i = 0; i < np; i++) {
        float x, y;
        if (coloured) {
            float c[6] = {0, 0, 1, 1, 1, 1};
            lua_rawgeti(L, 1, i + 1);
            if (lua_istable(L, -1))
                for (int j = 0; j < 6; j++) {
                    lua_rawgeti(L, -1, j + 1);
                    if (lua_isnumber(L, -1)) c[j] = (float)lua_tonumber(L, -1);
                    lua_pop(L, 1);
                }
            lua_pop(L, 1);
            for (int j = 0; j < 4; j++) color[j] = saved[j] * c[2 + j];
            xf(m, c[0], c[1], &x, &y);
        } else {
            xf(m, line_pts[i * 2], line_pts[i * 2 + 1], &x, &y);
        }
        vertex_t *v = scratch + k;
        set_vert(&v[0], &ident, x - h, y - h, 0, 0);
        set_vert(&v[1], &ident, x + h, y - h, 0, 0);
        set_vert(&v[2], &ident, x - h, y + h, 0, 0);
        v[3] = v[1];
        set_vert(&v[4], &ident, x + h, y + h, 0, 0);
        v[5] = v[2];
        k += 6;
    }
    memcpy(color, saved, sizeof(saved));
    if (k) {
        shader_ud *sh = cur_shader;
        cur_shader = NULL;
        submit(NULL, scratch, k);
        cur_shader = sh;
    }
    return 0;
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
        const float pts[8] = {x, y, x + w, y, x + w, y + h, x, y + h};
        memcpy(line_pts, pts, sizeof(pts));
        emit_polyline(&mstack[msp], 4, 1);
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
            for (int i = 1; i + 1 < np; i++) {       /* fan from the first vertex */
                set_vert(&v[k++], m, pts[0], pts[1], 0, 0);
                set_vert(&v[k++], m, pts[i * 2], pts[i * 2 + 1], 0, 0);
                set_vert(&v[k++], m, pts[i * 2 + 2], pts[i * 2 + 3], 0, 0);
            }
            submit(NULL, v, k);
        }
    } else {
        memcpy(line_pts, pts, (size_t)np * 2 * sizeof(float));
        emit_polyline(m, np, 1);
    }
    cur_shader = saved;
    return 0;
}

/* EDRAM clear color in ARGB: a resolve copies and then clears, so it applies to the next frame
 * (like Xe_SetClearColor + Xe_Resolve) */
static uint32_t clear_argb(void)
{
    uint32_t c[4];
    for (int i = 0; i < 4; i++) {
        float v = clear_color[i] < 0 ? 0 : clear_color[i] > 1 ? 1 : clear_color[i];
        c[i] = (uint32_t)(v * 255.0f + 0.5f);
    }
    return c[3] << 24 | c[0] << 16 | c[1] << 8 | c[2];
}

/* Ends the canvas: what was drawn in the EDRAM goes to its texture and the EDRAM is left clean (like
 * Xe_ResolveInto). The resolve undoes target, blend, shaders and slot 0: frame_state puts them back
 * before the next draw. */
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

/* present: ends the frame. xsdk_present_begin waits until a screen buffer is free (the frame is
 * built before, while the previous one is shown), the resolve copies the EDRAM there and clears it,
 * and present_end shows it at the next vblank once the GPU has finished. */
static int g_present(lua_State *L)
{
    (void)L;
    flush();                     /* pending work counts as a draw, not a present */
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
    /* Guide: XAM draws each frame under it and leaves the GPU as it likes (xsdk rebuilds it).
     * While it is open, presenting continues (otherwise the Guide would not be seen) but nothing is drawn. */
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
        gfx_log("[gfx] frame %ld: %ld draws/frame (%ld submits, %ld vertices), resolves canvas %ld screen %ld, %ld skipped",
                l360_gfx_stats.frames, (l360_gfx_stats.draws - st_last_draws) / 300,
                (l360_gfx_stats.submits - st_last_submits) / 300, (l360_gfx_stats.verts - st_last_verts) / 300,
                st_canvas_resolves, st_screen_resolves, l360_gfx_stats.skipped);
        st_last_draws = l360_gfx_stats.draws;
        st_last_submits = l360_gfx_stats.submits;
        st_last_verts = l360_gfx_stats.verts;
        st_canvas_resolves = st_screen_resolves = 0;
    }
    /* next frame: the other half of the vertex buffer */
    vb_index ^= 1;
    vb_base = (vertex_t *)(uintptr_t)(vb_mem + vb_index * (VB_BYTES / 4));
    vb_cur = 0;
    msp = 0;
    g_origin(L);
    l360_gfx_stats.present_end_at = now_ms();
    return 0;
}

/* sync: before drawing the frame, waits for the GPU to finish with its half of the vertex buffer
 * (the one used two frames ago; libXenon waited for the whole previous frame) */
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
    {"newSpriteBatch", g_newSpriteBatch}, {"print", g_print}, {"printf", g_printf},
    {"line", g_line}, {"circle", g_circle}, {"ellipse", g_ellipse}, {"points", g_points},
    {"setPointSize", g_setPointSize}, {"getPointSize", g_getPointSize},
    {"setCanvas", g_setCanvas}, {"present", g_present}, {"sync", g_sync},
    {"getDimensions", g_getDimensions}, {"getPixelDimensions", g_getDimensions},
    {"getWidth", g_getWidth}, {"getHeight", g_getHeight},
    {"setDefaultFilter", g_setDefaultFilter}, {"getStats", g_getStats},
    {NULL, NULL}};

/* ---------- startup ---------- */

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
    opt_no_shaders = strstr(buf, "no_shaders") != NULL;
    opt_no_literals = strstr(buf, "no_literals") != NULL;
    opt_no_batching = strstr(buf, "no_batching") != NULL;
    gfx_log("[gfx] l360_gfx.txt: no_canvas=%d no_shaders=%d no_literals=%d no_batching=%d",
            opt_no_canvas, opt_no_shaders, opt_no_literals, opt_no_batching);
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
    (void)xsdk_system_ui_open();     /* the first call starts listening to XAM */

    /* The default program. The game's are registered by newShader, from their metadata. */
    snprintf(progs[0].name, sizeof(progs[0].name), "default");
    progs[0].ps = load_ps(DEFAULT_PS);
    progs[0].vs = vs_for(DEFAULT_VS, progs[0].ps);
    if (!progs[0].ps || !progs[0].vs) {
        gfx_log("[ERROR] without shaders\\" DEFAULT_PS " and " DEFAULT_VS " there are no graphics "
                "(copy the output of tools/shaders/build_shaders.py to shaders\\)");
        return -1;
    }

    gfx_log("shaders: %d loaded (%d from xost), %d missing, %d failed to load, %d with literals", shaders_loaded,
            shaders_xost, shaders_missing, shaders_bad, shaders_lits);

    XsdkSampler sampler = {
        .mag_filter = XSDK_FILTER_LINEAR, .min_filter = XSDK_FILTER_LINEAR, .mip_filter = XSDK_FILTER_POINT,
        .address_u = XSDK_ADDRESS_CLAMP, .address_v = XSDK_ADDRESS_CLAMP, .address_w = XSDK_ADDRESS_CLAMP};
    xsdk_texture_sampler_state(&samp_linear, &sampler);
    sampler.mag_filter = sampler.min_filter = XSDK_FILTER_POINT;
    xsdk_texture_sampler_state(&samp_point, &sampler);
    /* as in libXenon: color SRCALPHA / INVSRCALPHA, alpha ONE / INVSRCALPHA */
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
        {"send", shader_send}, {"sendColor", shader_send}, {"hasUniform", shader_hasUniform}, {NULL, NULL}};
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
    static const luaL_Reg batch_m[] = {
        {"add", batch_add}, {"set", batch_set}, {"clear", batch_clear}, {"flush", nop},
        {"getCount", batch_getCount}, {"getBufferSize", batch_getBufferSize},
        {"setColor", batch_setColor}, {"getColor", batch_getColor},
        {"setTexture", batch_setTexture}, {"getTexture", batch_getTexture},
        {"type", batch_type}, {"typeOf", batch_typeOf}, {NULL, NULL}};
    make_mt(L, MT_BATCH, batch_m);
    luaL_getmetatable(L, MT_BATCH);
    lua_pushcfunction(L, batch_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);
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
