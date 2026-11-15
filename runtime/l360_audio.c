/*
 * Love360 on xsdk - sound (task 09, phase 3 of docs/tareas/05_port_xsdk.md).
 *
 * Copy of runtime/source/l360_audio.c (the libXenon one) with a different output: the same l360.audio API
 * (docs/audio.md), the same mixer, the same ADPCM and the same memory sharing between threads.
 *
 * Output: the kernel audio driver through xsdk (include/xsdk/audio.h). A dedicated thread, the
 * "feeder", on hardware thread AUDIO_HW_THREAD (core 1, away from thread 0 which runs Lua and
 * draws), waits in xsdk_audio_next_frame for the kernel to take a frame, mixes the next one
 * and queues it with xsdk_audio_queue_frame. An xsdk frame is 256 samples per channel at 48 kHz,
 * 6 channels in big-endian float, one channel after another: the mixer makes blocks of 256
 * frames (CHUNK) in integers as before and at the end writes left and right as float
 * (16-bit sample / 32768) and silence on the other 4. xsdk leaves 8 frames queued (43 ms).
 *
 * Memory sharing between the two threads, without locks (same as in libXenon):
 *  - buffers (abuf_t): native PCM (big-endian) or mono IMA ADPCM as it comes from the WAV. Only
 *    the main thread creates and frees them. An ADPCM buffer is created empty with its final size
 *    (newstream) and grows with append: the main thread copies the blocks, lwsync, and only
 *    afterwards publishes `avail`. The audio thread reads `avail`, lwsync, and then the blocks.
 *    If Lua collects one that is still playing, it stays in `pending` and is freed in
 *    l360_audio_update when no voice uses it.
 *  - voices (voice_t): `state` goes from 0 to 1 only in the main thread (play) and from 1 to 0 only
 *    in the audio thread (finished or stop_req). While state is 0, all fields belong to the
 *    main thread; while it is 1, pos and frac belong to the audio thread and the rest to the main one.
 *    The fields are aligned 32-bit words (atomic writes on PPC) and the order is
 *    ensured with lwsync.
 *  - ADPCM: the audio thread decodes one whole block at a time into the voice's `dec` (reserved
 *    by the main thread in play, with state 0). If the voice reaches what has not been loaded yet,
 *    it keeps advancing in silence and adds to `starved`.
 *  - The audio thread does not call malloc, printf or Lua (xsdk docs/PITFALLS.md: no
 *    mutex that can be freed while another thread waits for it).
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
#define CHUNK        XSDK_AUDIO_FRAME_SAMPLES  /* frames per block = one xsdk frame (5.3 ms) */
#define MAX_VOICES   32                     /* power of 2: the id carries the slot in 5 bits */
#define VOICE_BITS   5
#define AUDIO_HW_THREAD 2                   /* core 1; the kernel calls xsdk on thread 4 */
#define FEEDER_STACK (64 * 1024)
#define FEED_WAIT_MS 100                    /* if a slot is not freed within this time, another round */
#define CLOSE_WAIT_MS 200                   /* on exit: how long the feeder is waited for, no more */
#define GAIN_ONE     1024                   /* volume in Q10 */

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#ifdef __powerpc__
#define lwsync() __asm__ volatile("lwsync" ::: "memory")
#else
#define lwsync() __sync_synchronize()       /* test on the PC (pruebas/audio_xsdk_pc) */
#endif

typedef struct abuf {
    int16_t *pcm;               /* interleaved PCM, native byte order; NULL if ADPCM */
    uint8_t *adpcm;             /* ADPCM: blocks as in the WAV data chunk; NULL if PCM */
    uint32_t frames;            /* total; in ADPCM, the end even if not loaded yet */
    volatile uint32_t avail;    /* frames that can already be read (PCM: all) */
    uint32_t block_align;       /* ADPCM: bytes per block */
    uint32_t spb;               /* ADPCM: frames per block */
    uint32_t blocks, loaded;    /* ADPCM: total blocks and already loaded ones (main thread) */
    int channels, rate;
    struct abuf *next;          /* in `pending` after being collected */
} abuf_t;

typedef struct {
    volatile int state;         /* 0 free, 1 assigned (see above) */
    volatile int stop_req;      /* main: requests termination */
    volatile int paused;        /* main */
    volatile int loop;          /* main */
    volatile int gain;          /* main, Q10 (0..GAIN_ONE) */
    volatile uint32_t step;     /* main: source frames per output frame, 16.16 */
    volatile uint32_t seek_frame, seek_seq;  /* main: seek_frame, lwsync, seek_seq++ */
    uint32_t seek_done;         /* audio */
    volatile uint32_t pos;      /* audio (main only with state 0) */
    uint32_t frac;              /* audio */
    abuf_t *buf;                /* main, changed only with state 0 */
    uint32_t gen;               /* main: generation, invalidates old ids */
    int16_t *dec;               /* ADPCM: decoded block; main reserves it with state 0 */
    uint32_t dec_cap;           /* main: samples that fit in dec */
    uint32_t dec_base;          /* audio: first frame of the block in dec */
    int dec_ok;                 /* audio (main sets it to 0 with state 0) */
} voice_t;

static voice_t voices[MAX_VOICES];
static abuf_t *pending;
static volatile int master_gain = GAIN_ONE;
static volatile int quit, running, opened;
static HANDLE feeder;
static int next_slot;

/* stats: written by the audio thread */
static volatile uint32_t st_chunks, st_mix_us_max, st_active, st_starved;

static int32_t acc[CHUNK * 2];

/* ---------- audio thread ---------- */

static inline int clamp16(int32_t v)
{
    return v > 32767 ? 32767 : v < -32768 ? -32768 : v;
}

/* ---------- IMA ADPCM (the IMA standard, same as the ffmpeg decoder) ---------- */

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

/* Decodes a mono IMA ADPCM block from a WAV (format 0x11): 4 header bytes
 * (16-bit little-endian predictor, index, reserved) and then two samples per byte,
 * low nibble first. Writes 1 + 2 * (bytes - 4) samples. Returns how many. */
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

/* Like the PCM loop of mix_voice, but reading from decoded ADPCM blocks. */
static int mix_adpcm(voice_t *v, abuf_t *b, int g)
{
    uint32_t n = b->frames, avail = b->avail;
    lwsync();                               /* read the blocks after seeing avail */
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
            s0 = s1 = 0;                    /* not loaded yet: silence, but it still advances */
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
            else s1 = adpcm_head(b, nx);    /* first sample of the next block */
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

/* Mixes a voice into acc. Returns 1 if the voice finished. */
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
        int f = frac >> 2;                  /* 14 bits: (s1 - s0) * f fits in 32 bits */
        int l, r;
        if (b->channels == 1) {
            int s0 = p[pos], s1 = p[nx];
            l = r = s0 + (((s1 - s0) * f) >> 14);
        } else {
            int l0 = p[2 * pos], l1 = p[2 * nx], r0 = p[2 * pos + 1], r1 = p[2 * nx + 1];
            l = l0 + (((l1 - l0) * f) >> 14);
            r = r0 + (((r1 - r0) * f) >> 14);
        }
        a[2 * i] += l * g;                  /* 2^15 * 2^10 * 32 voices < 2^31 */
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
        lwsync();                           /* see the fields written by play() */
        if (v->stop_req || mix_voice(v, master)) {
            lwsync();                       /* finish reading the buffer before releasing it */
            v->state = 0;
            continue;
        }
        active++;
    }
    st_active = active;
}

/* The mixed block to the xsdk frame: left and right as float (the 16-bit sample that
 * libXenon wrote, / 32768) and silence on center, LFE and rears. The 6 channels are always
 * written: xsdk reuses the queue slots. */
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

/* The feeder: each time the kernel takes a frame, xsdk wakes it with a free slot. It ends
 * when l360_audio_close closes the client (next_frame returns STATUS_INVALID_HANDLE). */
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

/* ---------- control from the main thread ---------- */

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

/* On exit: closes the client (wakes the feeder) and waits for it briefly. Does not free the voices:
 * the process exits right away. */
void l360_audio_close(void)
{
    if (!opened) return;
    quit = 1;
    lwsync();
    xsdk_audio_close();
    opened = 0;
    if (feeder) {
        const int64_t timeout = -(int64_t)CLOSE_WAIT_MS * 10000;   /* relative, in 100 ns */
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
    if (!(vol > 0)) return 0;               /* also NaN */
    if (vol >= 1) return GAIN_ONE;
    return (int)(vol * GAIN_ONE + 0.5);
}

/* Lua double -> uint32_t without undefined behaviour: NaN and negatives give 0, huge values saturate */
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

/* id = gen << VOICE_BITS | slot; NULL if the id is old */
static voice_t *voice_of(lua_State *L, int idx)
{
    lua_Number id = luaL_checknumber(L, idx);
    if (!(id >= 0 && id < 4294967296.0)) return NULL;  /* also NaN and infinity */
    uint32_t u = (uint32_t)id;
    voice_t *v = &voices[u & (MAX_VOICES - 1)];
    return v->gen == (u >> VOICE_BITS) ? v : NULL;
}

static int voice_playing(const voice_t *v)
{
    return v && v->state && !v->stop_req;
}

/* Allocates a voice and starts it playing. Returns the id or -1 if there are no free voices. */
static double voice_start(abuf_t *b, double vol, double pitch, int loop, uint32_t start)
{
    int k;
    for (k = 0; k < MAX_VOICES; k++) {
        int i = (next_slot + k) & (MAX_VOICES - 1);
        voice_t *v = &voices[i];
        if (v->state) continue;
        if (b->adpcm && v->dec_cap < b->spb) {      /* with state 0 the slot belongs to the main thread */
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

/* newbuffer(pcm, channels, rate [, from [, bytes]]): 16-bit little-endian PCM */
static int l_newbuffer(lua_State *L)
{
    size_t len;
    const unsigned char *s = (const unsigned char *)luaL_checklstring(L, 1, &len);
    int ch = luaL_checkint(L, 2);
    int rate = luaL_checkint(L, 3);
    lua_Number fromn = luaL_optnumber(L, 4, 0);
    luaL_argcheck(L, ch == 1 || ch == 2, 2, "channels must be 1 or 2");
    luaL_argcheck(L, rate >= 4000 && rate <= 96000, 3, "sample rate out of range");
    luaL_argcheck(L, fromn >= 0 && fromn <= len, 4, "offset out of range");  /* also NaN */
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

/* newstream(channels, rate, block_align, total_frames): empty IMA ADPCM buffer that grows
 * with append. Only mono for now. Reserves the final size (compressed) all at once. */
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

/* buf:append(data [, from [, bytes]]): appends whole ADPCM blocks (the contents of the data
 * chunk). Only the last block of the buffer may come incomplete. Returns the loaded frames. */
static int l_buf_append(lua_State *L)
{
    abuf_t *b = check_buf(L, 1);
    size_t len;
    const char *s = luaL_checklstring(L, 2, &len);
    lua_Number fromn = luaL_optnumber(L, 3, 0);
    if (!b->adpcm) return luaL_error(L, "append: the buffer is not ADPCM");
    luaL_argcheck(L, fromn >= 0 && fromn <= len, 3, "offset out of range");  /* also NaN */
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
    memcpy(b->adpcm + (size_t)b->loaded * ba, s + from, bytes);   /* what is missing from the last one stays 0 */
    b->loaded += whole + (rest ? 1 : 0);
    lwsync();                               /* the blocks before avail */
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

/* ---------- Lua: voices ---------- */

/* play(buffer [, volume [, pitch [, loop [, from_frame]]]]) -> id or nil */
static int l_play(lua_State *L)
{
    abuf_t *b = check_buf(L, 1);
    if (!running) { lua_pushnil(L); return 1; }     /* without a thread nothing mixes or releases the voice */
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

/* set(id, volume, pitch, loop): nil leaves the value as it was */
static int l_set(lua_State *L)
{
    voice_t *v = voice_of(L, 1);
    if (!voice_playing(v)) return 0;        /* with state 0 the buffer may be freed */
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

/* beep([frequency [, ms [, volume]]]) -> id or nil: sine in its own buffer, for testing */
static int l_beep(lua_State *L)
{
    double freq = luaL_optnumber(L, 1, 880);
    int ms = luaL_optint(L, 2, 250);
    double vol = luaL_optnumber(L, 3, 0.5);
    if (ms < 10) ms = 10;
    if (ms > 5000) ms = 5000;
    uint32_t i, n = (uint32_t)OUT_RATE * ms / 1000, fade = OUT_RATE / 200;  /* 5 ms without a click */
    abuf_t *b = buf_alloc(n, 1, OUT_RATE);
    if (!b) { lua_pushnil(L); return 1; }
    for (i = 0; i < n; i++) {
        double env = i < fade ? (double)i / fade : (n - i < fade ? (double)(n - i) / fade : 1);
        b->pcm[i] = (int16_t)(sin(2 * M_PI * freq * i / OUT_RATE) * env * 30000);
    }
    double id = voice_start(b, vol, 1, 0, 0);
    buf_release(b);                         /* freed only when it finishes playing */
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
    /* underruns = xsdk silent: frames the kernel played in silence because there was none
     * queued (audible cutouts). queued_bytes no longer exists: fewest_queued says how much was missing. */
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
