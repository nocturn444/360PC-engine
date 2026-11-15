/*
 * 360PC-Engine console runtime: a LOVE game as a .xex opened from Aurora (from Love360, task 05).
 *
 * The game is the folder of the .xex (game:\): game.lua, conf.lua, main.lua and its assets. The
 * runtime's own Lua layer is in game:\l360\ (runtime/lua/ in the repository).
 *
 * LuaJIT 2.1 (interpreter) + the l360 table that l360/boot.lua sees.
 * Phase 1: time, log, files and real memory. Phase 2 (task 07): l360.gfx is
 * l360_gfx.c on xsdk's GPU, with the shaders in game:\shaders\; if it does not start (the shaders
 * are missing), the Lua stub from phase 1 (l360_gfx_stub.lua) keeps the text screen. There is no
 * sound. The controller, chunked files, saving and exit are in l360_sys.c (phase 4).
 *
 * Files: everything is read from game:\ (the .xex folder). The log is game:\<name of the
 * .xex>.log (xsdk writes it: default.log on the console) and it is also shown on screen, like the
 * text console of libXenon. Holding Back for 3 s exits and opens Aurora (or returns to the
 * dashboard if it cannot find it): a single Back press is used by the game.
 */
#include <malloc.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/times.h>
#include <time.h>

#include "xsdk/gpu.h"
#include "xsdk/kernel.h"
#include "xsdk/log.h"
#include "xsdk/present.h"
#include "xsdk/splash.h"
#include "xsdk/text.h"
#include "xsdk/thread.h"

#include "lauxlib.h"
#include "lua.h"
#include "luajit.h"
#include "lualib.h"

#include "l360_audio.h"
#include "l360_gfx.h"
#include "l360_sys.h"

/* Game folder: the folder of the .xex. RUNTIME_DIR, inside it, has the runtime's own .lua files
 * (runtime/lua/ in the repository); l360_sys.c reserves the same name. */
#define GAME_DIR "game:/"
#define RUNTIME_DIR "l360/"

enum {
	SPLASH_MS = 2000,
	BUFFERS = 2,
	SWAP_INTERVAL = 1,
	BEGIN_TIMEOUT_MS = 5000,
	CON_LINES = 32,          /* lines of the log on screen */
	CON_COLS = 120,
	CON_REDRAW_MS = 100,     /* during loading, redraw at most every 100 ms */
};
static const uint32_t CLEAR_ARGB = 0xFF101828;
static const uint32_t TEXT_ARGB = 0xFFFFFFFF;
static const uint32_t STATUS_ARGB = 0xFFB0C4DE;

static struct timespec t_start;

static double now_s(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)(t.tv_sec - t_start.tv_sec) + (double)(t.tv_nsec - t_start.tv_nsec) / 1e9;
}

/* times(): newlib's clock() uses it (LuaJIT's os.clock) and xsdk does not provide it (its docs/GUIDE.md,
 * "Porting"). It lives in this file and not in a separate one: an .o placed before main.c in the link
 * makes elf2xex fail with "section .init overlaps the PE headers". */
clock_t times(struct tms *buf)
{
	const clock_t ticks = (clock_t)(now_s() * CLOCKS_PER_SEC);
	if (buf) {
		buf->tms_utime = ticks;
		buf->tms_stime = buf->tms_cutime = buf->tms_cstime = 0;
	}
	return ticks;
}

/* ---------- text screen (the log on screen) ---------- */

static int screen_on;                    /* 1 if the GPU and the screen opened */
static int gfx_ok;                       /* 1 if l360_gfx.c started (if not, the Lua stub) */
static int gfx_active;                   /* from start_render on, the screen belongs to the game (l360_gfx.c) */
static uint32_t screen_w, screen_h;
static char con[CON_LINES][CON_COLS];
static int con_next, con_count;
static char con_status[CON_COLS];
static double con_drawn_at = -1;

static void screen_open(void)
{
	NTSTATUS status = xsdk_gpu_open();
	if (!NT_SUCCESS(status)) {
		xsdk_log_write("runtime: xsdk_gpu_open failed: 0x%08X", (unsigned)status);
		return;
	}
	status = xsdk_present_open(XSDK_DISPLAY_720P, BUFFERS, SWAP_INTERVAL, &screen_w, &screen_h);
	if (!NT_SUCCESS(status)) {
		xsdk_log_write("runtime: xsdk_present_open failed: 0x%08X", (unsigned)status);
		return;
	}
	status = xsdk_text_open();
	if (!NT_SUCCESS(status)) {
		xsdk_log_write("runtime: xsdk_text_open failed: 0x%08X", (unsigned)status);
		return;
	}
	xsdk_log_write("runtime: screen is %ux%u", (unsigned)screen_w, (unsigned)screen_h);
	screen_on = 1;
}

static void screen_draw(void)
{
	if (!screen_on)
		return;
	uint32_t address;
	const NTSTATUS status = xsdk_present_begin(&address, BEGIN_TIMEOUT_MS);
	if (!NT_SUCCESS(status)) {
		xsdk_log_write("runtime: xsdk_present_begin failed: 0x%08X (stopping drawing)", (unsigned)status);
		screen_on = 0;
		return;
	}
	xsdk_gpu_set_target(screen_w, screen_h);
	int first = con_count < CON_LINES ? 0 : con_next;
	for (int i = 0; i < con_count; i++)
		xsdk_text_draw(32, 24 + i * XSDK_TEXT_CELL_HEIGHT, 1, TEXT_ARGB, con[(first + i) % CON_LINES]);
	if (con_status[0])
		xsdk_text_draw(32, (int32_t)screen_h - 24 - XSDK_TEXT_CELL_HEIGHT, 1, STATUS_ARGB, con_status);
	xsdk_gpu_resolve(address, screen_w, screen_h, CLEAR_ARGB);
	xsdk_present_end();
	con_drawn_at = now_s();
	/* the text changed target, shaders, stream 0, slot 0 and constants: l360_gfx.c sets them again */
	if (gfx_ok)
		l360_gfx_forget_state();
}

/* redraws if CON_REDRAW_MS have passed since the last time (for loading, which has no frames) */
static void screen_maybe_draw(void)
{
	/* not during the game: it would cut the frame being built */
	if (gfx_active)
		return;
	if (con_drawn_at < 0 || now_s() - con_drawn_at >= CON_REDRAW_MS / 1000.0)
		screen_draw();
}

/* copies a screen line, cut to what fits (CON_COLS - 1 characters) */
static void copy_line(char *dst, const char *s)
{
	size_t n = strlen(s);
	if (n >= CON_COLS)
		n = CON_COLS - 1;
	memcpy(dst, s, n);
	dst[n] = 0;
}

static void set_status(const char *s)
{
	copy_line(con_status, s);
}

/* adds text to the screen, one line per '\n' (xsdk_text_draw would wrap lines on its own and
 * write over the following ones, as happened with the Lua errors) */
static void con_add(const char *s)
{
	for (;;) {
		const char *nl = strchr(s, '\n');
		size_t n = nl ? (size_t)(nl - s) : strlen(s);
		if (n >= CON_COLS)
			n = CON_COLS - 1;
		memcpy(con[con_next], s, n);
		con[con_next][n] = 0;
		con_next = (con_next + 1) % CON_LINES;
		if (con_count < CON_LINES)
			con_count++;
		if (!nl)
			break;
		s = nl + 1;
	}
}

/* ---------- log ---------- */

/* ---------- short log (task 12, published version) ----------
 * Each log line is written to the USB stick. In the published version (built with
 * -DL360_PUBLICADO=ON, which defines L360_REGISTRO_CORTO) only these go to the .log: errors, what is
 * missing, the summaries every 300 frames ([memory], [audio], [gfx] frame, [hitches]) and the [hitch]
 * lines. Up to start_render the startup lines also go (not the ones for each file read), to know what
 * it started with. The text screen still shows everything. In game:\l360_gfx.txt, "registro_completo"
 * or "registro_corto" choose something other than the built-in setting. */
#ifdef L360_REGISTRO_CORTO
static int log_short = 1;
#else
static int log_short;
#endif

static int log_keep(const char *s)
{
	static const char *const KEEP[] = { "ERROR", "[missing", "[hitch", "[memory]", "[audio] voices", "[gfx] frame" };
	if (!log_short)
		return 1;
	for (size_t i = 0; i < sizeof(KEEP) / sizeof(KEEP[0]); i++)
		if (strstr(s, KEEP[i]))
			return 1;
	return 0;
}

/* ---------- log on a separate thread (task 12) ----------
 * On the console the USB stick sometimes stalls for about 0.9 s, and each log line was written
 * (NtWriteFile) from the main thread, so the game waited (the ~900 ms hitches in the #48 log almost
 * all came right after a written line). Now the lines go to an in-memory queue and their own thread
 * (LOG_HW_THREAD) writes them with xsdk_log_write, which already takes care of threads on its own.
 * The main thread never waits: if the queue is full, the line is lost and the count is noted later.
 * Before the thread starts (or if it does not start), it is written as before.
 * l360_log_flush() waits until it is empty (called on the exit to Aurora). */
enum {
	LOG_SLOTS = 256,                 /* lineas en cola: 128 KB */
	LOG_LINE_CHARS = 512,            /* same as a line of xsdk_log_write */
	LOG_HW_THREAD = 3,               /* core 1, with audio and saving; never core 0 (Lua) */
	LOG_STACK = 32 * 1024,
	LOG_FLUSH_MS = 3000,
};
static char log_ring[LOG_SLOTS][LOG_LINE_CHARS];
static unsigned log_head, log_tail;       /* the thread writes log_head; the main thread fills log_tail */
static int log_writing;                   /* 1 while the thread writes a line outside the lock */
static unsigned long log_dropped;         /* lines lost while the queue was full (under log_mu) */
static int log_thread_on;
static HANDLE log_thread;
static pthread_mutex_t log_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t log_cv = PTHREAD_COND_INITIALIZER;

static uint32_t log_worker(void *context)
{
	(void)context;
	char line[LOG_LINE_CHARS];
	for (;;) {
		pthread_mutex_lock(&log_mu);
		while (log_head == log_tail)
			pthread_cond_wait(&log_cv, &log_mu);
		memcpy(line, log_ring[log_head % LOG_SLOTS], sizeof(line));
		log_head++;
		const unsigned long dropped = log_dropped;
		log_dropped = 0;
		log_writing = 1;
		pthread_mutex_unlock(&log_mu);
		if (dropped)
			xsdk_log_write("[log] %lu lines lost (queue full)", dropped);
		xsdk_log_write("%s", line);
		pthread_mutex_lock(&log_mu);
		log_writing = 0;
		pthread_mutex_unlock(&log_mu);
	}
	return 0;
}

static void log_thread_start(void)
{
	const NTSTATUS st = xsdk_thread_create_on(&log_thread, LOG_STACK, log_worker, NULL, LOG_HW_THREAD);
	log_thread_on = NT_SUCCESS(st);
	if (!log_thread_on)
		xsdk_log_write("runtime: the log thread did not start (0x%08X): writing from the main thread",
			       (unsigned)st);
}

static void log_out(const char *s)
{
	if (!log_thread_on) {
		xsdk_log_write("%s", s);
		return;
	}
	pthread_mutex_lock(&log_mu);
	if (log_tail - log_head >= LOG_SLOTS) {
		log_dropped++;
	} else {
		snprintf(log_ring[log_tail % LOG_SLOTS], LOG_LINE_CHARS, "%s", s);
		log_tail++;
		pthread_cond_signal(&log_cv);
	}
	pthread_mutex_unlock(&log_mu);
}

void l360_log_flush(void)
{
	if (!log_thread_on)
		return;
	const double until = now_s() + LOG_FLUSH_MS / 1000.0;
	for (;;) {
		pthread_mutex_lock(&log_mu);
		const int left = log_head != log_tail || log_writing;
		pthread_mutex_unlock(&log_mu);
		if (!left || now_s() > until)
			return;
		const struct timespec ten_ms = { 0, 10 * 1000 * 1000 };
		nanosleep(&ten_ms, NULL);
	}
}

static void logline(const char *s)
{
	if (!gfx_active || log_keep(s))
		log_out(s);
	con_add(s);
	screen_maybe_draw();
}

/* to the log, without going through the screen (file reads: there are hundreds) */
static void logline_quiet(const char *s)
{
	if (log_keep(s))
		log_out(s);
}

/* Used by l360_sys.c (controller, exit, chunked files and saving) to write to the log shown
 * on screen, without touching this part. */
void l360_log(const char *s)
{
	logline(s);
}

/* ---------- files ---------- */

static int files_read;
static double bytes_read, read_ms;

/* Reads all of GAME_DIR<path>; NULL if it is not there. */
static char *read_game_file(const char *path, size_t *len)
{
	char name[320];
	if (l360_sys_game_missing(path))    /* not in its folder's listing: not even opened */
		return NULL;
	snprintf(name, sizeof(name), GAME_DIR "%s", path);
	FILE *f = fopen(name, "rb");
	if (!f)
		return NULL;
	char *buf = NULL;
	long n = -1;
	if (fseek(f, 0, SEEK_END) == 0)
		n = ftell(f);
	if (n >= 0 && fseek(f, 0, SEEK_SET) == 0)
		buf = malloc(n > 0 ? (size_t)n : 1);
	if (buf && fread(buf, 1, (size_t)n, f) != (size_t)n) {
		free(buf);
		buf = NULL;
	}
	fclose(f);
	if (buf)
		*len = (size_t)n;
	return buf;
}

/* ---------- functions for Lua ---------- */

static int l_time(lua_State *L)
{
	lua_pushnumber(L, now_s());
	return 1;
}

static int l_log(lua_State *L)
{
	logline(luaL_checkstring(L, 1));
	return 0;
}

/* read(path): contents of game:\<path>, or nil */
static int l_read(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	double t0 = now_s();
	size_t n = 0;
	const int listed_missing = l360_sys_game_missing(path);
	char *buf = listed_missing ? NULL : read_game_file(path, &n);
	double ms = (now_s() - t0) * 1000;
	read_ms += ms;
	char line[360];
	snprintf(line, sizeof(line), "  %s %s: %u KB, %.1f ms%s", buf ? "read" : "not found", path, (unsigned)(n / 1024), ms,
		 listed_missing ? " (per the listing)" : "");
	logline_quiet(line);
	set_status(line + 2);
	screen_maybe_draw();
	if (!buf) {
		lua_pushnil(L);
		return 1;
	}
	files_read++;
	bytes_read += (double)n;
	lua_pushlstring(L, buf, n);
	free(buf);
	return 1;
}

static int l_readstats(lua_State *L)
{
	int fetch_files = 0;
	double fetch_bytes = 0, fetch_ms = 0;
	l360_sys_readstats(&fetch_files, &fetch_bytes, &fetch_ms);   /* what l360.fetch_* downloaded */
	lua_newtable(L);
	lua_pushnumber(L, files_read + fetch_files);
	lua_setfield(L, -2, "files");
	lua_pushnumber(L, bytes_read + fetch_bytes);
	lua_setfield(L, -2, "bytes");
	lua_pushnumber(L, read_ms + fetch_ms);
	lua_setfield(L, -2, "ms");
	return 1;
}

/* heap(): KB in use and KB requested from the system by malloc (newlib) */
static int l_heap(lua_State *L)
{
	struct mallinfo mi = mallinfo();
	lua_pushnumber(L, mi.uordblks / 1024.0);
	lua_pushnumber(L, mi.arena / 1024.0);
	return 2;
}

/* ---------- game state (log and screen) ---------- */

static char crash_ctx[128];

static int frames;

/* ---------- hitches: slow frames, broken into pieces ----------
 * The boot loop (runtime/lua/boot.lua) does per frame: poll_input, love.update, gfx.sync,
 * love.draw, present, the music and wait_frame. With the marks of poll_input and wait_frame, plus
 * those of sync and present in l360_gfx.c, every frame that takes more than TIRON_MS to reach
 * wait_frame goes to the log with: update, GPU wait, draw, present and the rest; Lua memory at the
 * start and at the end; how many garbage collections finished in the frame (an object with __gc that
 * is created again each time); how much texture data was uploaded; and the draws. */
#define TIRON_MS 40.0
#define TIRON_MAX_POR_300 30            /* so as not to fill the log if everything is slow */

static double ms_now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec * 1000.0 + (double)t.tv_nsec / 1e6;
}

static double lua_kb(lua_State *L) { return lua_gc(L, LUA_GCCOUNT, 0) + lua_gc(L, LUA_GCCOUNTB, 0) / 1024.0; }

static long gc_cycles;
static void gc_sentinel_new(lua_State *L);
static int gc_sentinel(lua_State *L)
{
	gc_cycles++;
	gc_sentinel_new(L);
	return 0;
}
static void gc_sentinel_new(lua_State *L)
{
	lua_newuserdata(L, 1);
	if (luaL_newmetatable(L, "l360.gc_sentinel")) {
		lua_pushcfunction(L, gc_sentinel);
		lua_setfield(L, -2, "__gc");
	}
	lua_setmetatable(L, -2);
	lua_pop(L, 1);                   /* no references: the next collection picks it up */
}

static struct {
	int started;
	double at, kb;
	long cycles, draws, tex_bytes;
	unsigned long image_ms;
} fr;
static long tirones, tirones_logged, tirones_omitted, tiron_frames;
static double tiron_worst;
static int opt_gc_paso;                  /* "gc_paso" in game:\l360_gfx.txt (see wait_frame) */
static long gc_steps;

static void frame_begin(lua_State *L)
{
	if (!fr.started) {
		fr.started = 1;
		gc_sentinel_new(L);
	}
	fr.at = ms_now();
	fr.kb = lua_kb(L);
	fr.cycles = gc_cycles;
	fr.draws = l360_gfx_stats.draws;
	fr.tex_bytes = l360_gfx_stats.texture_bytes;
	fr.image_ms = l360_gfx_stats.image_ms;
}

static void frame_end(lua_State *L)
{
	if (!fr.started)
		return;
	double end = ms_now(), total = end - fr.at;
	const l360_gfx_stats_t *g = &l360_gfx_stats;
	tiron_frames++;
	if (total > TIRON_MS) {
		tirones++;
		if (total > tiron_worst) tiron_worst = total;
		if (tirones_logged < TIRON_MAX_POR_300) {
			tirones_logged++;
			/* the l360_gfx.c marks belong to this frame only if they were set after poll_input */
			int ok = g->sync_at >= fr.at && g->sync_end_at >= g->sync_at && g->present_at >= g->sync_end_at &&
				 g->present_end_at >= g->present_at && end >= g->present_end_at;
			char parts[160];
			if (ok)
				snprintf(parts, sizeof(parts), "update %.0f, GPU %.0f, draw %.0f, present %.0f, rest %.0f",
					 g->sync_at - fr.at, g->sync_end_at - g->sync_at, g->present_at - g->sync_end_at,
					 g->present_end_at - g->present_at, end - g->present_end_at);
			else
				snprintf(parts, sizeof(parts), "no l360_gfx timestamps");
			char line[400];
			snprintf(line, sizeof(line),
				 "[hitch] frame %d, %.0f ms (%s); Lua %.1f -> %.1f MB, %ld collections; textures +%ld KB"
				 " in %lu ms; %ld draws; %.60s",
				 frames, total, parts, fr.kb / 1024, lua_kb(L) / 1024, gc_cycles - fr.cycles,
				 (g->texture_bytes - fr.tex_bytes) / 1024, g->image_ms - fr.image_ms, g->draws - fr.draws,
				 crash_ctx[0] ? crash_ctx : "-");
			logline(line);
		} else {
			tirones_omitted++;
		}
	}
	if (tiron_frames % 300 == 0) {
		char line[200];
		snprintf(line, sizeof(line), "[hitches] last 300 frames: %ld over %.0f ms (worst %.0f ms, %ld not logged),"
			 " %ld collections in total%s", tirones, TIRON_MS, tiron_worst, tirones_omitted, gc_cycles,
			 opt_gc_paso ? ", gc_paso" : "");
		logline(line);
		if (opt_gc_paso) {
			snprintf(line, sizeof(line), "[hitches] gc_paso: %ld steps in the spare time", gc_steps);
			logline(line);
			gc_steps = 0;
		}
		tirones = tirones_logged = tirones_omitted = 0;
		tiron_worst = 0;
	}
}

/* poll_input(): once per frame. The controller, saving and exit (Back held for 3 s) are in
 * l360_sys.c, phase 4. It is the first thing in the frame: the hitch measurement starts there. */
static int l_poll_input(lua_State *L)
{
	frame_begin(L);
	l360_sys_poll();
	l360_audio_update();             /* frees the audio buffers Lua released that are no longer playing */
	return 0;
}

/* wait_frame(until): waits until that instant (seconds of l360.time). Draws the text screen
 * (xsdk_present_begin waits for the vblank) and sleeps for what is left. */
static int l_wait_frame(lua_State *L)
{
	double until = luaL_checknumber(L, 1);
	frames++;
	frame_end(L);
	char status[200];
	snprintf(status, sizeof(status), "frame %d, %d s, state %.60s.  Hold Back 3 s: exit", frames, (int)now_s(),
		 crash_ctx[0] ? crash_ctx : "-");
	set_status(status);
	if (!gfx_active)
		screen_draw();
	/* gc_paso (test): small collector steps in the spare time of the frame, leaving 3 ms, so that
	 * collection does not all land in one frame. It stops when a collection finishes. */
	while (opt_gc_paso && (until - now_s()) * 1000 > 3) {
		gc_steps++;
		if (lua_gc(L, LUA_GCSTEP, 0))
			break;
	}
	for (;;) {
		double left_ms = (until - now_s()) * 1000;
		if (left_ms <= 0)
			break;
		/* xsdk sleeps up to 1 ms longer than requested (docs/PITFALLS.md of xsdk) */
		if (left_ms > 2)
			xsdk_thread_sleep((uint32_t)(left_ms - 1));
	}
	return 0;
}

static int l_set_context(lua_State *L)
{
	snprintf(crash_ctx, sizeof(crash_ctx), "%s", luaL_checkstring(L, 1));
	return 0;
}

static int l_start_render(lua_State *L)
{
	(void)L;
	if (gfx_ok) {
		logline("start_render: drawing the game (l360_gfx.c); the log continues in the .log file");
		gfx_active = 1;
	} else {
		logline("start_render: no graphics (l360_gfx.c did not start), keeping the text screen");
	}
	return 0;
}

/* ---------- startup ---------- */

/* After an error or the end of the boot: leaves the log on screen until Back is held for 3 s
 * (a single Back press is used by the game). */
static void wait_back_forever(void) __attribute__((noreturn));
static void wait_back_forever(void)
{
	gfx_active = 0;                  /* back to the text screen with the log */
	char status[200];
	snprintf(status, sizeof(status), "Hold Back 3 s: exit (log at %.120s)",
		 xsdk_log_path() ? xsdk_log_path() : "?");
	set_status(status);
	for (;;) {
		l360_sys_poll();
		screen_draw();
		if (!screen_on)
			xsdk_thread_sleep(30);
	}
}

/* ---------- graphics ---------- */

static int l_gfxstats(lua_State *L)
{
	lua_newtable(L);
#define F(k) lua_pushnumber(L, (double)l360_gfx_stats.k); lua_setfield(L, -2, #k);
	F(draws) F(sends) F(skipped) F(dropped) F(frames) F(missing_images) F(texture_bytes) F(image_ms) F(gpu_wait_ms)
#undef F
	return 1;
}

/* LOVE functions the game uses that l360_gfx.c does not have: one line for each, only once */
static void missing_cb(const char *what)
{
	static char seen[4096];
	if (strstr(seen, what))
		return;
	if (strlen(seen) + strlen(what) + 2 < sizeof(seen)) {
		strcat(seen, what);
		strcat(seen, ";");
	}
	char line[128];
	snprintf(line, sizeof(line), "  [missing] %.100s", what);
	logline(line);
}

/* Runs GAME_DIR<path>; 0 if it worked, -1 (and the error to the log) if not. */
static int run_game_lua(lua_State *L, const char *path)
{
	char line[1024];
	size_t n = 0;
	char *code = read_game_file(path, &n);
	if (!code) {
		snprintf(line, sizeof(line), "[ERROR] not found: " GAME_DIR "%s", path);
		logline(line);
		return -1;
	}
	snprintf(line, sizeof(line), "@%s", strrchr(path, '/') ? strrchr(path, '/') + 1 : path);
	int rc = luaL_loadbuffer(L, code, n, line);
	free(code);
	if (rc == 0)
		rc = lua_pcall(L, 0, 0, 0);
	if (rc) {
		snprintf(line, sizeof(line), "[ERROR Lua] %s: %s", path, lua_tostring(L, -1));
		logline(line);
		return -1;
	}
	return 0;
}

int main(void)
{
	clock_gettime(CLOCK_MONOTONIC, &t_start);
	xsdk_log_write("runtime: 360PC-Engine on xsdk");
	const NTSTATUS splash = xsdk_splash_show(SPLASH_MS);
	if (!NT_SUCCESS(splash))
		xsdk_log_write("runtime: xsdk_splash_show failed: 0x%08X", (unsigned)splash);
	screen_open();
	log_thread_start();              /* from here on, the log is written by another thread */
	logline("360PC-Engine on xsdk");
	if (screen_on) {
		gfx_ok = l360_gfx_init(screen_w, screen_h, logline) == 0;
		if (gfx_ok)
			l360_gfx_set_missing_cb(missing_cb);
		else
			logline("[ERROR] graphics did not start: continuing with the text screen (l360.gfx stub)");
	}
	/* sound (phase 3): without it the game stays silent (boot.lua warns that l360.audio is missing) */
	const int audio = l360_audio_init();
	if (audio == 0) {
		atexit(l360_audio_close);
		logline("sound: xsdk_audio_open and the mixer thread are running");
	} else {
		char line[96];
		snprintf(line, sizeof(line), "[ERROR] sound did not start (0x%08X): continuing without sound", (unsigned)audio);
		logline(line);
	}

	/* gc_paso: the same switch list as l360_gfx.c (game:\l360_gfx.txt) */
	FILE *opts = fopen("game:/l360_gfx.txt", "rb");
	if (opts) {
		char buf[256] = { 0 };
		size_t n = fread(buf, 1, sizeof(buf) - 1, opts);
		fclose(opts);
		buf[n] = 0;
		opt_gc_paso = strstr(buf, "gc_paso") != NULL;
		if (opt_gc_paso)
			logline("gc_paso: Lua collector steps in the spare time of each frame");
		if (strstr(buf, "sin_lista"))
			l360_sys_list_off();
		if (strstr(buf, "guardado_directo"))
			l360_sys_save_direct();
		if (strstr(buf, "registro_completo"))
			log_short = 0;
		else if (strstr(buf, "registro_corto"))
			log_short = 1;
	}
	if (log_short)
		logline("short log: from start_render on, only errors, missing items, summaries and [hitch]"
			" (registro_completo in l360_gfx.txt for everything)");
	lua_State *L = luaL_newstate();
	if (!L) {
		logline("[ERROR] luaL_newstate returned NULL (out of memory?)");
		wait_back_forever();
	}
	luaL_openlibs(L);
	luaJIT_setmode(L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);

	lua_newtable(L);
	lua_pushcfunction(L, l_time);         lua_setfield(L, -2, "time");
	lua_pushcfunction(L, l_log);          lua_setfield(L, -2, "log");
	lua_pushcfunction(L, l_read);         lua_setfield(L, -2, "read");
	lua_pushcfunction(L, l_readstats);    lua_setfield(L, -2, "readstats");
	lua_pushcfunction(L, l_heap);         lua_setfield(L, -2, "heap");
	lua_pushcfunction(L, l_wait_frame);   lua_setfield(L, -2, "wait_frame");
	lua_pushcfunction(L, l_poll_input);   lua_setfield(L, -2, "poll_input");
	lua_pushcfunction(L, l_set_context);  lua_setfield(L, -2, "set_context");
	lua_pushcfunction(L, l_start_render); lua_setfield(L, -2, "start_render");
	l360_sys_register(L);                 /* controller, poll, fetch_*, upload and saving (phase 4) */
	if (audio == 0) {
		l360_audio_register(L);           lua_setfield(L, -2, "audio");
	}
	lua_pushstring(L, "xbox360-luajit");  lua_setfield(L, -2, "platform");
	lua_pushstring(L, RUNTIME_DIR);       lua_setfield(L, -2, "runtime_dir");
	lua_pushnumber(L, gfx_ok ? l360_gfx_width() : 1280);  lua_setfield(L, -2, "width");
	lua_pushnumber(L, gfx_ok ? l360_gfx_height() : 720);  lua_setfield(L, -2, "height");
	if (gfx_ok) {
		lua_pushcfunction(L, l_gfxstats); lua_setfield(L, -2, "gfxstats");
		l360_gfx_register(L);             lua_setfield(L, -2, "gfx");
	}
	lua_setglobal(L, "l360");

	/* Interpreter number test (tests/console/xsdk_numeros.lua), only if it was copied */
	FILE *pf = fopen(GAME_DIR RUNTIME_DIR "xsdk_numeros.lua", "rb");
	if (pf) {
		fclose(pf);
		logline("Number test (" RUNTIME_DIR "xsdk_numeros.lua):");
		run_game_lua(L, RUNTIME_DIR "xsdk_numeros.lua");
	}

	/* l360.gfx and l360.gfxstats: if l360_gfx.c did not start, the Lua stub from phase 1; then the boot */
	if (!gfx_ok && run_game_lua(L, RUNTIME_DIR "l360_gfx_stub.lua"))
		wait_back_forever();
	logline("Loading the game...");
	if (!run_game_lua(L, RUNTIME_DIR "boot.lua"))
		logline(RUNTIME_DIR "boot.lua finished");
	char line[200];
	snprintf(line, sizeof(line), "Files read: %d (%d KB) in %d ms", files_read, (int)(bytes_read / 1024),
		 (int)read_ms);
	logline(line);
	wait_back_forever();
	return 0;
}
