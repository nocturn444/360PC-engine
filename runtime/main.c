/*
 * Love360 sobre xsdk: Balatro como un .xex que se abre desde Aurora (tarea 05).
 *
 * LuaJIT 2.1 (interprete) + la tabla l360 que ve love360_boot.lua, igual que en runtime/ (libXenon).
 * Fase 1: tiempo, registro, archivos y memoria de verdad. Fase 2 (tarea 07): l360.gfx es
 * l360_gfx.c sobre la GPU de xsdk, con los shaders de game:\shaders\; si no arranca (faltan los
 * shaders), sigue el stub en Lua de la fase 1 (l360_gfx_stub.lua) con la pantalla de texto. No hay
 * sonido. El mando, los archivos en trozos, el guardado y la salida estan en l360_sys.c (fase 4).
 *
 * Archivos: todo se lee de game:\balatro\ (la carpeta del .xex). El registro es game:\<nombre del
 * .xex>.log (lo escribe xsdk: default.log en la consola) y tambien se ve en pantalla, como la consola
 * de texto de libXenon. Back mantenido 3 s sale y abre Aurora (o vuelve al dashboard si no la
 * encuentra): un toque de Back lo usa Balatro.
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

/* Carpeta del juego: los .lua y resources\ de Balatro, y love360\ con los .lua de Love360 */
#define GAME_DIR "game:/balatro/"

enum {
	SPLASH_MS = 2000,
	BUFFERS = 2,
	SWAP_INTERVAL = 1,
	BEGIN_TIMEOUT_MS = 5000,
	CON_LINES = 32,          /* lineas del registro en pantalla */
	CON_COLS = 120,
	CON_REDRAW_MS = 100,     /* durante la carga, redibujar a lo sumo cada 100 ms */
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

/* times(): el clock() de newlib lo usa (os.clock de LuaJIT) y xsdk no lo trae (su docs/GUIDE.md,
 * "Porting"). Va en este archivo y no en uno aparte: un .o puesto antes de main.c en el enlace hace
 * que elf2xex falle con "section .init overlaps the PE headers". */
clock_t times(struct tms *buf)
{
	const clock_t ticks = (clock_t)(now_s() * CLOCKS_PER_SEC);
	if (buf) {
		buf->tms_utime = ticks;
		buf->tms_stime = buf->tms_cutime = buf->tms_cstime = 0;
	}
	return ticks;
}

/* ---------- pantalla de texto (el registro en pantalla) ---------- */

static int screen_on;                    /* 1 si la GPU y la pantalla abrieron */
static int gfx_ok;                       /* 1 si l360_gfx.c arranco (si no, el stub en Lua) */
static int gfx_active;                   /* desde start_render la pantalla es del juego (l360_gfx.c) */
static uint32_t screen_w, screen_h;
static char con[CON_LINES][CON_COLS];
static int con_next, con_count;
static char con_status[CON_COLS];
static double con_drawn_at = -1;

static void screen_open(void)
{
	NTSTATUS status = xsdk_gpu_open();
	if (!NT_SUCCESS(status)) {
		xsdk_log_write("love360: xsdk_gpu_open failed: 0x%08X", (unsigned)status);
		return;
	}
	status = xsdk_present_open(XSDK_DISPLAY_720P, BUFFERS, SWAP_INTERVAL, &screen_w, &screen_h);
	if (!NT_SUCCESS(status)) {
		xsdk_log_write("love360: xsdk_present_open failed: 0x%08X", (unsigned)status);
		return;
	}
	status = xsdk_text_open();
	if (!NT_SUCCESS(status)) {
		xsdk_log_write("love360: xsdk_text_open failed: 0x%08X", (unsigned)status);
		return;
	}
	xsdk_log_write("love360: screen is %ux%u", (unsigned)screen_w, (unsigned)screen_h);
	screen_on = 1;
}

static void screen_draw(void)
{
	if (!screen_on)
		return;
	uint32_t address;
	const NTSTATUS status = xsdk_present_begin(&address, BEGIN_TIMEOUT_MS);
	if (!NT_SUCCESS(status)) {
		xsdk_log_write("love360: xsdk_present_begin failed: 0x%08X (stopping drawing)", (unsigned)status);
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
	/* el texto cambio target, shaders, stream 0, slot 0 y constantes: l360_gfx.c los vuelve a poner */
	if (gfx_ok)
		l360_gfx_forget_state();
}

/* redibuja si paso CON_REDRAW_MS desde la ultima vez (para la carga, que no tiene frames) */
static void screen_maybe_draw(void)
{
	/* durante el juego no: cortaria el frame que se esta armando */
	if (gfx_active)
		return;
	if (con_drawn_at < 0 || now_s() - con_drawn_at >= CON_REDRAW_MS / 1000.0)
		screen_draw();
}

/* copia una linea de pantalla, cortada a lo que entra (CON_COLS - 1 caracteres) */
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

/* agrega texto a la pantalla, una linea por cada '\n' (xsdk_text_draw saltaria de linea solo y
 * escribiria encima de las siguientes, como pasaba con los errores de Lua) */
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

/* ---------- registro ---------- */

/* ---------- registro corto (tarea 12, version publicada) ----------
 * Cada linea del registro se escribe en el pendrive. En la version publicada (compilada con
 * -DL360_PUBLICADO=ON, que define L360_REGISTRO_CORTO) solo van al .log: los errores, lo que falta,
 * los resumenes de cada 300 frames ([memory], [audio], [gfx] frame, [hitches]) y los [hitch]. Hasta
 * start_render van tambien las lineas de arranque (no las de cada archivo leido), para saber con que
 * se arranco. La pantalla de texto sigue mostrando todo. En game:\l360_gfx.txt, "registro_completo"
 * o "registro_corto" eligen otra cosa que la compilada. */
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

/* ---------- registro en un hilo aparte (tarea 12) ----------
 * En la consola el pendrive se frena cerca de 0,9 s de vez en cuando, y cada linea del registro se
 * escribia (NtWriteFile) desde el hilo principal: el juego esperaba (los tirones de ~900 ms del
 * registro del #48 venian casi todos despues de una linea escrita). Ahora las lineas van a una cola
 * en memoria y un hilo propio (LOG_HW_THREAD) las escribe con xsdk_log_write, que ya se cuida solo
 * entre hilos. El hilo principal nunca espera: si la cola se llena, la linea se pierde y despues se
 * anota cuantas. Antes de que arranque el hilo (y si no arranca) se escribe como antes.
 * l360_log_flush() espera a que se vacie (lo llama la salida a Aurora). */
enum {
	LOG_SLOTS = 256,                 /* lineas en cola: 128 KB */
	LOG_LINE_CHARS = 512,            /* lo mismo que una linea de xsdk_log_write */
	LOG_HW_THREAD = 3,               /* nucleo 1, con el audio y el guardado; nunca el 0 de Lua */
	LOG_STACK = 32 * 1024,
	LOG_FLUSH_MS = 3000,
};
static char log_ring[LOG_SLOTS][LOG_LINE_CHARS];
static unsigned log_head, log_tail;       /* el hilo escribe log_head; el principal llena log_tail */
static int log_writing;                   /* 1 mientras el hilo escribe una linea fuera del lock */
static unsigned long log_dropped;         /* lineas perdidas con la cola llena (bajo log_mu) */
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
		xsdk_log_write("love360: the log thread did not start (0x%08X): writing from the main thread",
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

/* al registro sin pasar por la pantalla (lecturas de archivos: son cientos) */
static void logline_quiet(const char *s)
{
	if (log_keep(s))
		log_out(s);
}

/* Lo usa l360_sys.c (mando, salida, archivos en trozos y guardado) para escribir en el registro
 * que se ve en pantalla, sin tocar esta parte. */
void l360_log(const char *s)
{
	logline(s);
}

/* ---------- archivos ---------- */

static int files_read;
static double bytes_read, read_ms;

/* Lee GAME_DIR<ruta> entero; NULL si no esta. */
static char *read_game_file(const char *path, size_t *len)
{
	char name[320];
	if (l360_sys_game_missing(path))    /* no esta en la lista de su carpeta: ni se abre */
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

/* ---------- funciones para Lua ---------- */

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

/* read(ruta): contenido de game:\balatro\<ruta>, o nil */
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
	l360_sys_readstats(&fetch_files, &fetch_bytes, &fetch_ms);   /* lo que bajo l360.fetch_* */
	lua_newtable(L);
	lua_pushnumber(L, files_read + fetch_files);
	lua_setfield(L, -2, "files");
	lua_pushnumber(L, bytes_read + fetch_bytes);
	lua_setfield(L, -2, "bytes");
	lua_pushnumber(L, read_ms + fetch_ms);
	lua_setfield(L, -2, "ms");
	return 1;
}

/* heap(): KB usados y KB pedidos al sistema por malloc (newlib) */
static int l_heap(lua_State *L)
{
	struct mallinfo mi = mallinfo();
	lua_pushnumber(L, mi.uordblks / 1024.0);
	lua_pushnumber(L, mi.arena / 1024.0);
	return 2;
}

/* ---------- estado del juego (registro y pantalla) ---------- */

static char crash_ctx[128];

static int frames;

/* ---------- tirones: los frames lentos, partidos en pedazos ----------
 * El bucle del boot (runtime/love360_boot.lua) hace por frame: poll_input, love.update, gfx.sync,
 * love.draw, present, la musica y wait_frame. Con las marcas de poll_input y wait_frame, mas las de
 * sync y present de l360_gfx.c, cada frame que tarda mas de TIRON_MS en llegar a wait_frame va al
 * registro con: update, espera de la GPU, draw, present y lo demas; la memoria de Lua al empezar y
 * al terminar; cuantas recolecciones de basura terminaron en el frame (un objeto con __gc que se
 * vuelve a crear en cada una); lo que se subio de texturas; y los draws. */
#define TIRON_MS 40.0
#define TIRON_MAX_POR_300 30            /* para no llenar el registro si todo va lento */

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
	lua_pop(L, 1);                   /* sin referencias: la proxima recoleccion lo junta */
}

static struct {
	int started;
	double at, kb;
	long cycles, draws, tex_bytes;
	unsigned long image_ms;
} fr;
static long tirones, tirones_logged, tirones_omitted, tiron_frames;
static double tiron_worst;
static int opt_gc_paso;                  /* "gc_paso" en game:\l360_gfx.txt (ver wait_frame) */
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
			/* las marcas de l360_gfx.c son de este frame solo si quedaron despues de poll_input */
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

/* poll_input(): una vez por frame. El mando, el guardado y la salida (Back mantenido 3 s) estan en
 * l360_sys.c, fase 4. Es lo primero del frame: ahi empieza la medicion de tirones. */
static int l_poll_input(lua_State *L)
{
	frame_begin(L);
	l360_sys_poll();
	l360_audio_update();             /* libera los buffers de audio que Lua solto y ya no suenan */
	return 0;
}

/* wait_frame(hasta): espera hasta ese instante (segundos de l360.time). Dibuja la pantalla de
 * texto (xsdk_present_begin espera el vblank) y duerme lo que falte. */
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
	/* gc_paso (prueba): pasos chicos del recolector en lo que sobra del frame, dejando 3 ms, para que
	 * la recoleccion no se junte toda en un frame. Se corta al terminar una recoleccion. */
	while (opt_gc_paso && (until - now_s()) * 1000 > 3) {
		gc_steps++;
		if (lua_gc(L, LUA_GCSTEP, 0))
			break;
	}
	for (;;) {
		double left_ms = (until - now_s()) * 1000;
		if (left_ms <= 0)
			break;
		/* xsdk duerme hasta 1 ms mas de lo pedido (docs/PITFALLS.md de xsdk) */
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

/* ---------- arranque ---------- */

/* Despues de un error o del final del boot: deja el registro en pantalla hasta que se apriete
 * Back mantenido 3 s (un toque de Back lo usa Balatro). */
static void wait_back_forever(void) __attribute__((noreturn));
static void wait_back_forever(void)
{
	gfx_active = 0;                  /* vuelve la pantalla de texto con el registro */
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

/* ---------- graficos ---------- */

static int l_gfxstats(lua_State *L)
{
	lua_newtable(L);
#define F(k) lua_pushnumber(L, (double)l360_gfx_stats.k); lua_setfield(L, -2, #k);
	F(draws) F(sends) F(skipped) F(dropped) F(frames) F(missing_images) F(texture_bytes) F(image_ms) F(gpu_wait_ms)
#undef F
	return 1;
}

/* Funciones de LOVE que el juego usa y l360_gfx.c no tiene: una linea por cada una, una sola vez */
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

/* Corre GAME_DIR<ruta>; 0 si anduvo, -1 (y el error al registro) si no. */
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
	xsdk_log_write("love360: Love360 on xsdk (graphics with canvas and shaders, sound, controller, save and exit)");
	const NTSTATUS splash = xsdk_splash_show(SPLASH_MS);
	if (!NT_SUCCESS(splash))
		xsdk_log_write("love360: xsdk_splash_show failed: 0x%08X", (unsigned)splash);
	screen_open();
	log_thread_start();              /* desde aca el registro lo escribe otro hilo */
	logline("Love360 on xsdk - graphics with canvas and shaders, sound, controller, save and exit");
	if (screen_on) {
		gfx_ok = l360_gfx_init(screen_w, screen_h, logline) == 0;
		if (gfx_ok)
			l360_gfx_set_missing_cb(missing_cb);
		else
			logline("[ERROR] graphics did not start: continuing with the text screen (l360.gfx stub)");
	}
	/* sonido (fase 3): sin el, el juego sigue mudo (love360_boot.lua avisa que falta l360.audio) */
	const int audio = l360_audio_init();
	if (audio == 0) {
		atexit(l360_audio_close);
		logline("sound: xsdk_audio_open and the mixer thread are running");
	} else {
		char line[96];
		snprintf(line, sizeof(line), "[ERROR] sound did not start (0x%08X): continuing without sound", (unsigned)audio);
		logline(line);
	}

	/* gc_paso: la misma lista de interruptores de l360_gfx.c (game:\l360_gfx.txt) */
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
	/* Los sonidos se cargan la primera vez que suenan: su carpeta se lista ya, en la carga, para no
	 * buscar en el pendrive (hasta 872 ms cada uno) los .idx que no estan (tarea 12). */
	l360_sys_list_dir("resources/sounds");

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
	l360_sys_register(L);                 /* mando, poll, fetch_*, upload y guardado (fase 4) */
	if (audio == 0) {
		l360_audio_register(L);           lua_setfield(L, -2, "audio");
	}
	lua_pushstring(L, "xbox360-luajit");  lua_setfield(L, -2, "platform");
	lua_pushnumber(L, gfx_ok ? l360_gfx_width() : 1280);  lua_setfield(L, -2, "width");
	lua_pushnumber(L, gfx_ok ? l360_gfx_height() : 720);  lua_setfield(L, -2, "height");
	if (gfx_ok) {
		lua_pushcfunction(L, l_gfxstats); lua_setfield(L, -2, "gfxstats");
		l360_gfx_register(L);             lua_setfield(L, -2, "gfx");
	}
	lua_setglobal(L, "l360");

	/* Prueba de numeros del interprete (pruebas/xsdk_numeros.lua), solo si esta copiada */
	char probe[64];
	snprintf(probe, sizeof(probe), GAME_DIR "love360/xsdk_numeros.lua");
	FILE *pf = fopen(probe, "rb");
	if (pf) {
		fclose(pf);
		logline("Number test (love360/xsdk_numeros.lua):");
		run_game_lua(L, "love360/xsdk_numeros.lua");
	}

	/* l360.gfx y l360.gfxstats: si l360_gfx.c no arranco, el stub en Lua de la fase 1; despues el boot */
	if (!gfx_ok && run_game_lua(L, "love360/l360_gfx_stub.lua"))
		wait_back_forever();
	logline("Loading Balatro...");
	if (!run_game_lua(L, "love360/love360_boot.lua"))
		logline("love360_boot.lua finished");
	char line[200];
	snprintf(line, sizeof(line), "Files read: %d (%d KB) in %d ms", files_read, (int)(bytes_read / 1024),
		 (int)read_ms);
	logline(line);
	wait_back_forever();
	return 0;
}
