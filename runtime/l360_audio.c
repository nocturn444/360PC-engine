/*
 * Love360 sobre xsdk - sonido (tarea 09, fase 3 de docs/tareas/05_port_xsdk.md).
 *
 * Copia de runtime/source/l360_audio.c (el de libXenon) con otra salida: la misma API l360.audio
 * (docs/audio.md), el mismo mezclador, el mismo ADPCM y el mismo reparto de memoria entre hilos.
 *
 * Salida: el driver de audio del kernel por xsdk (include/xsdk/audio.h). Un hilo propio, el
 * "feeder", en el hilo de hardware AUDIO_HW_THREAD (nucleo 1, lejos del hilo 0 que corre Lua y
 * dibuja), espera en xsdk_audio_next_frame a que el kernel se lleve un frame, mezcla el siguiente
 * y lo encola con xsdk_audio_queue_frame. Un frame de xsdk son 256 muestras por canal a 48 kHz,
 * 6 canales en float big-endian, un canal despues del otro: el mezclador hace bloques de 256
 * frames (CHUNK) en enteros como antes y al final escribe izquierdo y derecho como float
 * (muestra de 16 bits / 32768) y silencio en los otros 4. xsdk deja 8 frames en cola (43 ms).
 *
 * Reparto de memoria entre los dos hilos, sin locks (igual que en libXenon):
 *  - buffers (abuf_t): PCM nativo (big-endian) o IMA ADPCM mono tal como viene del WAV. Los
 *    crea y libera solo el hilo principal. Un buffer ADPCM se crea vacio con su tamano final
 *    (newstream) y crece con append: el hilo principal copia los bloques, lwsync, y recien
 *    despues publica `avail`. El hilo de audio lee `avail`, lwsync, y despues los bloques.
 *    Si Lua recolecta uno que todavia suena, queda en `pending` y se libera en
 *    l360_audio_update cuando ninguna voz lo usa.
 *  - voces (voice_t): `state` pasa de 0 a 1 solo en el hilo principal (play) y de 1 a 0 solo
 *    en el hilo de audio (termino o stop_req). Mientras state es 0, todos los campos son del
 *    hilo principal; mientras es 1, pos y frac son del hilo de audio y el resto del principal.
 *    Los campos son palabras de 32 bits alineadas (escrituras atomicas en PPC) y el orden se
 *    asegura con lwsync.
 *  - ADPCM: el hilo de audio decodifica de a un bloque entero en `dec` de la voz (lo reserva
 *    el hilo principal en play, con state 0). Si la voz llega a lo que todavia no se cargo,
 *    sigue avanzando en silencio y suma a `starved`.
 *  - El hilo de audio no llama a malloc, printf ni Lua (docs/PITFALLS.md de xsdk: nada de
 *    mutex que se pueda liberar mientras otro hilo lo espera).
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>

#include "xsdk/audio.h"
#include "xsdk/kernel.h"
#include "xsdk/thread.h"

#include "lua.h"
#include "lauxlib.h"
#include "l360_audio.h"

#define OUT_RATE     XSDK_AUDIO_RATE_HZ
#define CHUNK        XSDK_AUDIO_FRAME_SAMPLES  /* frames por bloque = un frame de xsdk (5,3 ms) */
#define MAX_VOICES   32                     /* potencia de 2: el id lleva la ranura en 5 bits */
#define VOICE_BITS   5
#define AUDIO_HW_THREAD 2                   /* nucleo 1; el kernel llama a xsdk en el hilo 4 */
#define FEEDER_STACK (64 * 1024)
#define FEED_WAIT_MS 100                    /* si no se libera un lugar en este tiempo, otra vuelta */
#define CLOSE_WAIT_MS 200                   /* al salir: lo que se espera al feeder, no mas */
#define GAIN_ONE     1024                   /* volumen en Q10 */

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#ifdef __powerpc__
#define lwsync() __asm__ volatile("lwsync" ::: "memory")
#else
#define lwsync() __sync_synchronize()       /* prueba en la PC (pruebas/audio_xsdk_pc) */
#endif

typedef struct abuf {
    int16_t *pcm;               /* PCM intercalado, orden de bytes nativo; NULL si es ADPCM */
    uint8_t *adpcm;             /* ADPCM: bloques como en el chunk data del WAV; NULL si es PCM */
    uint32_t frames;            /* total; en ADPCM, el final aunque todavia no este cargado */
    volatile uint32_t avail;    /* frames que ya se pueden leer (PCM: todos) */
    uint32_t block_align;       /* ADPCM: bytes por bloque */
    uint32_t spb;               /* ADPCM: frames por bloque */
    uint32_t blocks, loaded;    /* ADPCM: bloques en total y ya cargados (hilo principal) */
    int channels, rate;
    struct abuf *next;          /* en `pending` despues de recolectado */
} abuf_t;

typedef struct {
    volatile int state;         /* 0 libre, 1 asignada (ver arriba) */
    volatile int stop_req;      /* principal: pide terminar */
    volatile int paused;        /* principal */
    volatile int loop;          /* principal */
    volatile int gain;          /* principal, Q10 (0..GAIN_ONE) */
    volatile uint32_t step;     /* principal: frames de origen por frame de salida, 16.16 */
    volatile uint32_t seek_frame, seek_seq;  /* principal: seek_frame, lwsync, seek_seq++ */
    uint32_t seek_done;         /* audio */
    volatile uint32_t pos;      /* audio (principal solo con state 0) */
    uint32_t frac;              /* audio */
    abuf_t *buf;                /* principal, se cambia solo con state 0 */
    uint32_t gen;               /* principal: generacion, invalida ids viejos */
    int16_t *dec;               /* ADPCM: bloque decodificado; principal lo reserva con state 0 */
    uint32_t dec_cap;           /* principal: muestras que entran en dec */
    uint32_t dec_base;          /* audio: primer frame del bloque que esta en dec */
    int dec_ok;                 /* audio (principal lo pone en 0 con state 0) */
} voice_t;

static voice_t voices[MAX_VOICES];
static abuf_t *pending;
static volatile int master_gain = GAIN_ONE;
static volatile int quit, running, opened;
static HANDLE feeder;
static int next_slot;

/* estadisticas: las escribe el hilo de audio */
static volatile uint32_t st_chunks, st_mix_us_max, st_active, st_starved;

static int32_t acc[CHUNK * 2];

/* ---------- hilo de audio ---------- */

static inline int clamp16(int32_t v)
{
    return v > 32767 ? 32767 : v < -32768 ? -32768 : v;
}

/* ---------- IMA ADPCM (el estandar de IMA, igual que el decodificador de ffmpeg) ---------- */

static const int16_t ima_step[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
};
static const int8_t ima_index[16] = { -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8 };

static inline int ima_nibble(int nib, int *pred, int *idx)
{
    int step = ima_step[*idx];
    int diff = ((2 * (nib & 7) + 1) * step) >> 3;
    int p = (nib & 8) ? *pred - diff : *pred + diff;
    p = clamp16(p);
    int i = *idx + ima_index[nib];
    *idx = i < 0 ? 0 : i > 88 ? 88 : i;
    *pred = p;
    return p;
}

/* Decodifica un bloque IMA ADPCM mono de un WAV (formato 0x11): 4 bytes de encabezado
 * (predictor de 16 bits little-endian, indice, reservado) y despues dos muestras por byte,
 * primero el nibble bajo. Escribe 1 + 2 * (bytes - 4) muestras. Devuelve cuantas. */
uint32_t l360_adpcm_decode_mono(const uint8_t *blk, uint32_t bytes, int16_t *outp)
{
    if (bytes < 4) return 0;
    int pred = (int16_t)(blk[0] | (blk[1] << 8));
    int idx = blk[2] > 88 ? 88 : blk[2];
    uint32_t i, n = 0;
    outp[n++] = (int16_t)pred;
    for (i = 4; i < bytes; i++) {
        outp[n++] = (int16_t)ima_nibble(blk[i] & 15, &pred, &idx);
        outp[n++] = (int16_t)ima_nibble(blk[i] >> 4, &pred, &idx);
    }
    return n;
}

static inline int adpcm_head(const abuf_t *b, uint32_t frame)
{
    const uint8_t *p = b->adpcm + (frame / b->spb) * b->block_align;
    return (int16_t)(p[0] | (p[1] << 8));
}

/* Como el lazo PCM de mix_voice, pero leyendo de bloques ADPCM decodificados. */
static int mix_adpcm(voice_t *v, abuf_t *b, int g)
{
    uint32_t n = b->frames, avail = b->avail;
    lwsync();                               /* leer los bloques despues de ver avail */
    uint32_t step = v->step, pos = v->pos, frac = v->frac, spb = b->spb, base = v->dec_base;
    int loop = v->loop, done = 0, ok = v->dec_ok, starved = 0;
    const int16_t *d = v->dec;
    int32_t *a = acc;
    int i;
    for (i = 0; i < CHUNK; i++) {
        if (pos >= n) {
            if (!loop) { done = 1; break; }
            pos %= n;
        }
        int s0, s1;
        if (pos >= avail) {
            s0 = s1 = 0;                    /* todavia no se cargo: silencio, pero avanza */
            starved = 1;
        } else {
            if (!ok || pos - base >= spb) {
                base = pos - pos % spb;
                l360_adpcm_decode_mono(b->adpcm + (base / spb) * b->block_align, b->block_align, v->dec);
                ok = 1;
            }
            s0 = d[pos - base];
            uint32_t nx = pos + 1 < n ? pos + 1 : (loop ? 0 : pos);
            if (nx >= avail) s1 = s0;
            else if (nx - base < spb) s1 = d[nx - base];
            else s1 = adpcm_head(b, nx);    /* primera muestra del bloque siguiente */
        }
        int f = frac >> 2;
        int l = s0 + (((s1 - s0) * f) >> 14);
        a[2 * i] += l * g;
        a[2 * i + 1] += l * g;
        frac += step;
        pos += frac >> 16;
        frac &= 0xffff;
    }
    v->pos = pos;
    v->frac = frac;
    v->dec_base = base;
    v->dec_ok = ok;
    if (starved) st_starved++;
    return done;
}

/* Mezcla una voz en acc. Devuelve 1 si la voz termino. */
static int mix_voice(voice_t *v, int master)
{
    abuf_t *b = v->buf;
    uint32_t n = b->frames;
    if (v->seek_seq != v->seek_done) {
        uint32_t s = v->seek_seq;
        lwsync();
        v->pos = v->seek_frame < n ? v->seek_frame : 0;
        v->frac = 0;
        v->seek_done = s;
    }
    if (v->paused)
        return 0;
    int g = (v->gain * master) >> 10;
    if (b->adpcm)
        return mix_adpcm(v, b, g);
    uint32_t step = v->step, pos = v->pos, frac = v->frac;
    int loop = v->loop, done = 0;
    const int16_t *p = b->pcm;
    int32_t *a = acc;
    int i;
    for (i = 0; i < CHUNK; i++) {
        if (pos >= n) {
            if (!loop) { done = 1; break; }
            pos %= n;
        }
        uint32_t nx = pos + 1 < n ? pos + 1 : (loop ? 0 : pos);
        int f = frac >> 2;                  /* 14 bits: (s1 - s0) * f entra en 32 bits */
        int l, r;
        if (b->channels == 1) {
            int s0 = p[pos], s1 = p[nx];
            l = r = s0 + (((s1 - s0) * f) >> 14);
        } else {
            int l0 = p[2 * pos], l1 = p[2 * nx], r0 = p[2 * pos + 1], r1 = p[2 * nx + 1];
            l = l0 + (((l1 - l0) * f) >> 14);
            r = r0 + (((r1 - r0) * f) >> 14);
        }
        a[2 * i] += l * g;                  /* 2^15 * 2^10 * 32 voces < 2^31 */
        a[2 * i + 1] += r * g;
        frac += step;
        pos += frac >> 16;
        frac &= 0xffff;
    }
    v->pos = pos;
    v->frac = frac;
    return done;
}

static void mix_chunk(void)
{
    int i, active = 0, master = master_gain;
    memset(acc, 0, sizeof(acc));
    for (i = 0; i < MAX_VOICES; i++) {
        voice_t *v = &voices[i];
        if (!v->state) continue;
        lwsync();                           /* ver los campos que escribio play() */
        if (v->stop_req || mix_voice(v, master)) {
            lwsync();                       /* terminar de leer el buffer antes de soltarlo */
            v->state = 0;
            continue;
        }
        active++;
    }
    st_active = active;
}

/* El bloque mezclado al frame de xsdk: izquierdo y derecho como float (la muestra de 16 bits que
 * escribia libXenon, / 32768) y silencio en centro, LFE y traseros. Se escriben los 6 canales
 * siempre: xsdk reusa los lugares de la cola. */
static void write_frame(float *frame)
{
    volatile float *o = frame;
    const float k = 1.0f / 32768.0f;
    int i, c;
    for (i = 0; i < CHUNK; i++) {
        o[XSDK_AUDIO_FRONT_LEFT * CHUNK + i] = (float)clamp16(acc[2 * i] >> 10) * k;
        o[XSDK_AUDIO_FRONT_RIGHT * CHUNK + i] = (float)clamp16(acc[2 * i + 1] >> 10) * k;
    }
    for (c = XSDK_AUDIO_CENTER; c < XSDK_AUDIO_CHANNELS; c++)
        for (i = 0; i < CHUNK; i++)
            o[c * CHUNK + i] = 0.0f;
}

static uint64_t now_us(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000u + (uint64_t)t.tv_nsec / 1000u;
}

/* El feeder: cada vez que el kernel se lleva un frame, xsdk lo despierta con un lugar libre. Termina
 * cuando l360_audio_close cierra el cliente (next_frame devuelve STATUS_INVALID_HANDLE). */
static uint32_t feed(void *context)
{
    (void)context;
    while (!quit) {
        float *frame;
        NTSTATUS st = xsdk_audio_next_frame(FEED_WAIT_MS, &frame);
        if (st == STATUS_IO_TIMEOUT)
            continue;
        if (st != STATUS_SUCCESS)
            break;
        uint64_t t0 = now_us();
        mix_chunk();
        write_frame(frame);
        xsdk_audio_queue_frame();
        uint32_t us = (uint32_t)(now_us() - t0);
        if (us > st_mix_us_max) st_mix_us_max = us;
        st_chunks++;
    }
    running = 0;
    return 0;
}

/* ---------- control desde el hilo principal ---------- */

int l360_audio_init(void)
{
    if (opened) return 0;
    NTSTATUS st = xsdk_audio_open(0);
    if (!NT_SUCCESS(st)) return (int)st;
    opened = 1;
    quit = 0;
    running = 1;
    lwsync();
    st = xsdk_thread_create_on(&feeder, FEEDER_STACK, feed, NULL, AUDIO_HW_THREAD);
    if (!NT_SUCCESS(st)) {
        running = 0;
        feeder = 0;
        xsdk_audio_close();
        opened = 0;
        return (int)st;
    }
    return 0;
}

/* Al salir: cierra el cliente (despierta al feeder) y lo espera un rato corto. No libera las voces:
 * el proceso termina enseguida. */
void l360_audio_close(void)
{
    if (!opened) return;
    quit = 1;
    lwsync();
    xsdk_audio_close();
    opened = 0;
    if (feeder) {
        const int64_t timeout = -(int64_t)CLOSE_WAIT_MS * 10000;   /* relativo, en 100 ns */
        (void)NtWaitForSingleObjectEx(feeder, USER_MODE, 0, &timeout);
        (void)NtClose(feeder);
        feeder = 0;
    }
}

static int buf_in_use(const abuf_t *b)
{
    int i;
    for (i = 0; i < MAX_VOICES; i++)
        if (voices[i].buf == b && voices[i].state)
            return 1;
    return 0;
}

static void buf_release(abuf_t *b)
{
    b->next = pending;
    pending = b;
    l360_audio_update();
}

void l360_audio_update(void)
{
    abuf_t **pp = &pending;
    while (*pp) {
        abuf_t *b = *pp;
        if (buf_in_use(b)) { pp = &b->next; continue; }
        *pp = b->next;
        free(b->pcm);
        free(b->adpcm);
        free(b);
    }
}

static abuf_t *buf_alloc(uint32_t frames, int channels, int rate)
{
    abuf_t *b = malloc(sizeof(*b));
    if (!b) return NULL;
    memset(b, 0, sizeof(*b));
    b->pcm = malloc((size_t)frames * channels * 2);
    if (!b->pcm) { free(b); return NULL; }
    b->frames = b->avail = frames;
    b->channels = channels;
    b->rate = rate;
    return b;
}

static uint32_t buf_bytes(const abuf_t *b)
{
    return b->adpcm ? b->blocks * b->block_align : b->frames * b->channels * 2;
}

static int to_gain(double vol)
{
    if (!(vol > 0)) return 0;               /* tambien NaN */
    if (vol >= 1) return GAIN_ONE;
    return (int)(vol * GAIN_ONE + 0.5);
}

/* double de Lua -> uint32_t sin comportamiento indefinido: NaN y negativos dan 0, lo enorme satura */
static uint32_t to_u32(double d)
{
    if (!(d > 0)) return 0;
    return d < 4294967295.0 ? (uint32_t)d : 0xffffffffu;
}

static uint32_t to_step(const abuf_t *b, double pitch)
{
    if (!(pitch > 0)) pitch = 1;
    if (pitch > 16) pitch = 16;
    double s = (double)b->rate * pitch / OUT_RATE * 65536.0 + 0.5;
    return s < 1 ? 1 : (uint32_t)s;
}

/* id = gen << VOICE_BITS | ranura; NULL si el id es viejo */
static voice_t *voice_of(lua_State *L, int idx)
{
    lua_Number id = luaL_checknumber(L, idx);
    if (!(id >= 0 && id < 4294967296.0)) return NULL;  /* tambien NaN e infinito */
    uint32_t u = (uint32_t)id;
    voice_t *v = &voices[u & (MAX_VOICES - 1)];
    return v->gen == (u >> VOICE_BITS) ? v : NULL;
}

static int voice_playing(const voice_t *v)
{
    return v && v->state && !v->stop_req;
}

/* Asigna una voz y la pone a sonar. Devuelve el id o -1 si no hay voces libres. */
static double voice_start(abuf_t *b, double vol, double pitch, int loop, uint32_t start)
{
    int k;
    for (k = 0; k < MAX_VOICES; k++) {
        int i = (next_slot + k) & (MAX_VOICES - 1);
        voice_t *v = &voices[i];
        if (v->state) continue;
        if (b->adpcm && v->dec_cap < b->spb) {      /* con state 0 la ranura es del hilo principal */
            int16_t *d = realloc(v->dec, (size_t)b->spb * sizeof(int16_t));
            if (!d) return -1;
            v->dec = d;
            v->dec_cap = b->spb;
        }
        v->dec_ok = 0;
        next_slot = i + 1;
        v->gen = (v->gen + 1) & 0x3ffffff;
        if (!v->gen) v->gen = 1;
        v->buf = b;
        v->stop_req = 0;
        v->paused = 0;
        v->loop = loop;
        v->gain = to_gain(vol);
        v->step = to_step(b, pitch);
        v->pos = start < b->frames ? start : 0;
        v->frac = 0;
        v->seek_done = v->seek_seq;
        lwsync();
        v->state = 1;
        return (double)(((uint32_t)v->gen << VOICE_BITS) | (uint32_t)i);
    }
    return -1;
}

/* ---------- Lua: buffers ---------- */

#define BUF_MT "l360.audio.buffer"

static abuf_t *check_buf(lua_State *L, int idx)
{
    abuf_t **ud = luaL_checkudata(L, idx, BUF_MT);
    if (!*ud) luaL_error(L, "audio buffer already freed");
    return *ud;
}

/* newbuffer(pcm, canales, frecuencia [, desde [, bytes]]): PCM de 16 bits little-endian */
static int l_newbuffer(lua_State *L)
{
    size_t len;
    const unsigned char *s = (const unsigned char *)luaL_checklstring(L, 1, &len);
    int ch = luaL_checkint(L, 2);
    int rate = luaL_checkint(L, 3);
    lua_Number fromn = luaL_optnumber(L, 4, 0);
    luaL_argcheck(L, ch == 1 || ch == 2, 2, "channels must be 1 or 2");
    luaL_argcheck(L, rate >= 4000 && rate <= 96000, 3, "sample rate out of range");
    luaL_argcheck(L, fromn >= 0 && fromn <= len, 4, "offset out of range");  /* tambien NaN */
    size_t from = (size_t)fromn;
    size_t bytes = to_u32(luaL_optnumber(L, 5, (lua_Number)(len - from)));
    if (bytes > len - from) bytes = len - from;
    uint32_t frames = (uint32_t)(bytes / (2 * ch));
    luaL_argcheck(L, frames > 0, 1, "no samples");
    abuf_t *b = buf_alloc(frames, ch, rate);
    if (!b) return luaL_error(L, "out of memory for the audio buffer (%d KB)", (int)(bytes / 1024));
    const unsigned char *p = s + from;
    uint32_t i, n = frames * ch;
    for (i = 0; i < n; i++)
        b->pcm[i] = (int16_t)(p[2 * i] | (p[2 * i + 1] << 8));
    abuf_t **ud = lua_newuserdata(L, sizeof(*ud));
    *ud = b;
    luaL_getmetatable(L, BUF_MT);
    lua_setmetatable(L, -2);
    return 1;
}

/* newstream(canales, frecuencia, block_align, frames_totales): buffer IMA ADPCM vacio que crece
 * con append. Por ahora solo mono. Reserva de una vez el tamano final (comprimido). */
static int l_newstream(lua_State *L)
{
    int ch = luaL_checkint(L, 1);
    int rate = luaL_checkint(L, 2);
    int ba = luaL_checkint(L, 3);
    uint32_t frames = to_u32(luaL_checknumber(L, 4));
    luaL_argcheck(L, ch == 1, 1, "only mono ADPCM for now");
    luaL_argcheck(L, rate >= 4000 && rate <= 96000, 2, "sample rate out of range");
    luaL_argcheck(L, ba >= 8 && ba <= 8192, 3, "block_align out of range");
    luaL_argcheck(L, frames > 0 && frames <= 96000u * 3600, 4, "frames out of range");
    uint32_t spb = 1 + 2 * (uint32_t)(ba - 4);
    uint32_t blocks = (frames + spb - 1) / spb;
    abuf_t *b = malloc(sizeof(*b));
    if (!b) return luaL_error(L, "out of memory for the audio buffer");
    memset(b, 0, sizeof(*b));
    b->adpcm = calloc(blocks, ba);
    if (!b->adpcm) {
        free(b);
        return luaL_error(L, "out of memory for the audio buffer (%d KB)", (int)((uint64_t)blocks * ba / 1024));
    }
    b->frames = frames;
    b->block_align = ba;
    b->spb = spb;
    b->blocks = blocks;
    b->channels = 1;
    b->rate = rate;
    abuf_t **ud = lua_newuserdata(L, sizeof(*ud));
    *ud = b;
    luaL_getmetatable(L, BUF_MT);
    lua_setmetatable(L, -2);
    return 1;
}

static uint32_t buf_avail(const abuf_t *b)
{
    if (!b->adpcm) return b->frames;
    uint64_t f = (uint64_t)b->loaded * b->spb;
    return f < b->frames ? (uint32_t)f : b->frames;
}

/* buf:append(datos [, desde [, bytes]]): agrega bloques ADPCM enteros (lo de adentro del chunk
 * data). Solo el ultimo bloque del buffer puede venir incompleto. Devuelve los frames cargados. */
static int l_buf_append(lua_State *L)
{
    abuf_t *b = check_buf(L, 1);
    size_t len;
    const char *s = luaL_checklstring(L, 2, &len);
    lua_Number fromn = luaL_optnumber(L, 3, 0);
    if (!b->adpcm) return luaL_error(L, "append: the buffer is not ADPCM");
    luaL_argcheck(L, fromn >= 0 && fromn <= len, 3, "offset out of range");  /* tambien NaN */
    size_t from = (size_t)fromn;
    size_t bytes = to_u32(luaL_optnumber(L, 4, (lua_Number)(len - from)));
    if (bytes > len - from) bytes = len - from;
    size_t ba = b->block_align;
    size_t whole = bytes / ba, rest = bytes % ba;
    size_t room = b->blocks - b->loaded;
    if (whole > room || (whole == room && rest))
        return luaL_error(L, "append: more data than the buffer size");
    if (rest && b->loaded + whole + 1 != b->blocks)
        return luaL_error(L, "append: incomplete ADPCM block that is not the last one");
    if (rest && rest < 4)
        return luaL_error(L, "append: ADPCM block without a header");
    memcpy(b->adpcm + (size_t)b->loaded * ba, s + from, bytes);   /* lo que falta del ultimo queda en 0 */
    b->loaded += whole + (rest ? 1 : 0);
    lwsync();                               /* los bloques antes que avail */
    b->avail = buf_avail(b);
    lua_pushnumber(L, b->avail);
    return 1;
}

static int l_buf_available(lua_State *L) { lua_pushnumber(L, check_buf(L, 1)->avail); return 1; }
static int l_buf_complete(lua_State *L)
{
    abuf_t *b = check_buf(L, 1);
    lua_pushboolean(L, b->avail >= b->frames);
    return 1;
}

static int l_buf_gc(lua_State *L)
{
    abuf_t **ud = luaL_checkudata(L, 1, BUF_MT);
    if (*ud) { buf_release(*ud); *ud = NULL; }
    return 0;
}
static int l_buf_frames(lua_State *L)   { lua_pushnumber(L, check_buf(L, 1)->frames); return 1; }
static int l_buf_channels(lua_State *L) { lua_pushinteger(L, check_buf(L, 1)->channels); return 1; }
static int l_buf_rate(lua_State *L)     { lua_pushinteger(L, check_buf(L, 1)->rate); return 1; }
static int l_buf_duration(lua_State *L)
{
    abuf_t *b = check_buf(L, 1);
    lua_pushnumber(L, (double)b->frames / b->rate);
    return 1;
}

/* ---------- Lua: voces ---------- */

/* play(buffer [, volumen [, pitch [, loop [, desde_frame]]]]) -> id o nil */
static int l_play(lua_State *L)
{
    abuf_t *b = check_buf(L, 1);
    if (!running) { lua_pushnil(L); return 1; }     /* sin hilo nadie mezcla ni suelta la voz */
    double id = voice_start(b, luaL_optnumber(L, 2, 1), luaL_optnumber(L, 3, 1),
                            lua_toboolean(L, 4), to_u32(luaL_optnumber(L, 5, 0)));
    if (id < 0) lua_pushnil(L); else lua_pushnumber(L, id);
    return 1;
}

static int l_stop(lua_State *L)
{
    voice_t *v = voice_of(L, 1);
    if (v && v->state) v->stop_req = 1;
    return 0;
}

static int l_pause(lua_State *L)
{
    voice_t *v = voice_of(L, 1);
    if (v) v->paused = lua_isnoneornil(L, 2) ? 1 : lua_toboolean(L, 2);
    return 0;
}

/* set(id, volumen, pitch, loop): nil deja el valor como estaba */
static int l_set(lua_State *L)
{
    voice_t *v = voice_of(L, 1);
    if (!voice_playing(v)) return 0;        /* con state 0 el buffer puede estar liberado */
    if (!lua_isnoneornil(L, 2)) v->gain = to_gain(lua_tonumber(L, 2));
    if (!lua_isnoneornil(L, 3)) v->step = to_step(v->buf, lua_tonumber(L, 3));
    if (!lua_isnoneornil(L, 4)) v->loop = lua_toboolean(L, 4);
    return 0;
}

static int l_seek(lua_State *L)
{
    voice_t *v = voice_of(L, 1);
    lua_Number f = luaL_checknumber(L, 2);
    if (!v) return 0;
    v->seek_frame = to_u32(f);
    lwsync();
    v->seek_seq = v->seek_seq + 1;
    return 0;
}

static int l_tell(lua_State *L)
{
    voice_t *v = voice_of(L, 1);
    if (!voice_playing(v)) { lua_pushnil(L); return 1; }
    uint32_t pos = v->seek_seq != v->seek_done ? v->seek_frame : v->pos;
    lua_pushnumber(L, pos);
    return 1;
}

static int l_state(lua_State *L)
{
    voice_t *v = voice_of(L, 1);
    lua_pushstring(L, !voice_playing(v) ? "stopped" : v->paused ? "paused" : "playing");
    return 1;
}

static int l_master(lua_State *L)
{
    if (!lua_isnoneornil(L, 1)) master_gain = to_gain(luaL_checknumber(L, 1));
    lua_pushnumber(L, (double)master_gain / GAIN_ONE);
    return 1;
}

/* beep([frecuencia [, ms [, volumen]]]) -> id o nil: seno en un buffer propio, para probar */
static int l_beep(lua_State *L)
{
    double freq = luaL_optnumber(L, 1, 880);
    int ms = luaL_optint(L, 2, 250);
    double vol = luaL_optnumber(L, 3, 0.5);
    if (ms < 10) ms = 10;
    if (ms > 5000) ms = 5000;
    uint32_t i, n = (uint32_t)OUT_RATE * ms / 1000, fade = OUT_RATE / 200;  /* 5 ms sin clic */
    abuf_t *b = buf_alloc(n, 1, OUT_RATE);
    if (!b) { lua_pushnil(L); return 1; }
    for (i = 0; i < n; i++) {
        double env = i < fade ? (double)i / fade : (n - i < fade ? (double)(n - i) / fade : 1);
        b->pcm[i] = (int16_t)(sin(2 * M_PI * freq * i / OUT_RATE) * env * 30000);
    }
    double id = voice_start(b, vol, 1, 0, 0);
    buf_release(b);                         /* se libera solo cuando termine de sonar */
    if (id < 0) lua_pushnil(L); else lua_pushnumber(L, id);
    return 1;
}

static int l_stats(lua_State *L)
{
    int i, used = 0, kb = 0, npend = 0;
    abuf_t *b;
    XsdkAudioStats xs;
    memset(&xs, 0, sizeof(xs));
    if (opened) xsdk_audio_stats(&xs);
    for (i = 0; i < MAX_VOICES; i++) used += voices[i].state != 0;
    for (b = pending; b; b = b->next) { npend++; kb += buf_bytes(b) / 1024; }
    lua_newtable(L);
#define F(k, x) lua_pushnumber(L, (double)(x)); lua_setfield(L, -2, k);
    /* underruns = silent de xsdk: frames que el kernel toco en silencio porque no habia uno en
     * cola (cortes que se oyen). queued_bytes ya no existe: fewest_queued dice cuanto falto. */
    F("voices", used) F("mixed", st_active) F("chunks", st_chunks) F("underruns", xs.silent)
    F("mix_us_max", st_mix_us_max) F("pending_buffers", npend) F("pending_kb", kb) F("starved", st_starved)
    F("played", xs.played) F("silent", xs.silent) F("fewest_queued", xs.fewest_queued)
    F("longest_wait_us", xs.longest_wait_us)
#undef F
    lua_pushboolean(L, running); lua_setfield(L, -2, "running");
    return 1;
}

void l360_audio_register(lua_State *L)
{
    static const luaL_Reg buf_methods[] = {
        {"frames", l_buf_frames}, {"channels", l_buf_channels}, {"rate", l_buf_rate},
        {"duration", l_buf_duration}, {"append", l_buf_append}, {"available", l_buf_available},
        {"complete", l_buf_complete}, {NULL, NULL}
    };
    static const luaL_Reg fns[] = {
        {"newbuffer", l_newbuffer}, {"newstream", l_newstream}, {"play", l_play}, {"stop", l_stop}, {"pause", l_pause},
        {"set", l_set}, {"seek", l_seek}, {"tell", l_tell}, {"state", l_state},
        {"master", l_master}, {"beep", l_beep}, {"stats", l_stats}, {NULL, NULL}
    };
    luaL_newmetatable(L, BUF_MT);
    lua_pushcfunction(L, l_buf_gc);
    lua_setfield(L, -2, "__gc");
    lua_newtable(L);
    luaL_register(L, NULL, buf_methods);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);

    lua_newtable(L);
    luaL_register(L, NULL, fns);
    lua_pushnumber(L, OUT_RATE);   lua_setfield(L, -2, "rate");
    lua_pushnumber(L, MAX_VOICES); lua_setfield(L, -2, "max_voices");
}
