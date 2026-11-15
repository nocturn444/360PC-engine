/*
 * 360PC-Engine console runtime (from Love360): controller, files, saving and exit (task 05 phase 4, task 08).
 *
 * Everything from phase 4 lives here so it does not clash with phase 2 (graphics), which works in main.c:
 *   - l360.pad / l360.rumble on XamInputGetState / XamInputSetState, with the same table and the
 *     same values as libXenon (runtime/source/main.c, l_pad): sticks from -32768 to 32767,
 *     triggers from 0 to 255, buttons 0 or 1.
 *   - l360.poll / l360.poll_input: there is no network; poll_input (in main.c) calls l360_sys_poll(), which
 *     reads the controller once per frame and checks for exit.
 *   - Exit: holding Back for 3 s calls quit_to_aurora; a short Back press still goes to the game.
 *     (Back + Start does not: it is the console's screenshot shortcut and the game does not receive it.)
 *   - l360.fetch_start / fetch_step: the music chunks. There is no network here: the file is read
 *     whole from game:\ on a separate thread, and fetch_step returns it when done.
 *   - l360.save_dir / save_read / save_write: game:\save\ (regular files), as the task asks.
 *   - l360.upload: writes game:\<name> (on libXenon it uploaded over TFTP). upload_log is not needed:
 *     xsdk writes the log line by line with NtWriteFile, with no buffer to flush.
 *
 * The sign of the Y axis: XAM delivers the sticks as the 360's HID report, which is the same thing
 * libXenon delivers (libxenon/drivers/usb/usbctrl.c copies the same two signed bytes: up is
 * positive). That is why they are passed through as they are; the one that flips the sign for LOVE is
 * input.lua (line 20: "XInput: arriba positivo; LOVE: abajo positivo"), which is not changed.
 */
#include <dirent.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include "xsdk/kernel.h"
#include "xsdk/thread.h"
#include "xsdk/xam.h"

#include "lauxlib.h"
#include "lua.h"

#include "l360_audio.h"
#include "l360_sys.h"

/* Game folder: the folder of the .xex (main.c uses the same). The save folder is a subfolder of
 * it, named by the game's game.lua through l360.save_set_dir ("save" until then). */
#define GAME_DIR "game:/"
#define SAVE_DIR_DEFAULT "save"

enum {
	PORTS = 4,               /* XAM controllers 0 to 3 */
	EXIT_HOLD_MS = 3000,     /* Back held, to exit */
	NAME_MAX_CHARS = 80,     /* same as libXenon: l360.save_read/save_write */
	SAVE_DIR_NAME_MAX = 32,  /* the save folder's name (l360.save_set_dir) */
};

/* Seconds of the monotonic clock (so as not to depend on l360.time, which main.c keeps). */
static double now_s(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

/* ---------- controller ---------- */

static INPUT_STATE pads[PORTS];   /* last state read by l360_sys_poll */
static int pad_ok[PORTS];         /* 1 = that port has a controller (l360.pad returns the table) */
static int pad_seen[PORTS] = { -1, -1, -1, -1 };   /* to log connections and disconnections once */

/* Reads the four ports. As in libXenon: a passing error keeps the last state (otherwise a USB
 * glitch would cut the rumble and the buttons in the middle of a run); only "no controller
 * connected" (ERROR_DEVICE_NOT_CONNECTED) gives nil in l360.pad. */
static void sample_pads(void)
{
	for (int port = 0; port < PORTS; port++) {
		INPUT_STATE state;
		memset(&state, 0, sizeof state);
		const uint32_t r = XamInputGetState((uint32_t)port, 0, &state);
		if (r == ERROR_SUCCESS) {
			pads[port] = state;
			pad_ok[port] = 1;
		} else if (r == ERROR_DEVICE_NOT_CONNECTED) {
			pad_ok[port] = 0;
		}
		if (pad_seen[port] != pad_ok[port]) {
			if (pad_seen[port] >= 0) {
				char line[80];
				snprintf(line, sizeof(line), "  controller %d: %s", port + 1, pad_ok[port] ? "connected" : "disconnected");
				l360_log(line);
			}
			pad_seen[port] = pad_ok[port];
		}
	}
}

/* pad(port): the same table as libXenon, or nil if that port has no controller. */
static int l_pad(lua_State *L)
{
	const int port = (int)luaL_optinteger(L, 1, 0);
	if (port < 0 || port >= PORTS || !pad_ok[port]) {
		lua_pushnil(L);
		return 1;
	}
	const INPUT_GAMEPAD *g = &pads[port].gamepad;
	const uint16_t buttons = g->buttons;
	lua_newtable(L);
#define PAD_FIELD(name, value) \
	lua_pushinteger(L, (lua_Integer)(value)); \
	lua_setfield(L, -2, name)
	PAD_FIELD("s1_x", g->thumb_lx);
	PAD_FIELD("s1_y", g->thumb_ly);
	PAD_FIELD("s2_x", g->thumb_rx);
	PAD_FIELD("s2_y", g->thumb_ry);
	PAD_FIELD("s1_z", (buttons & INPUT_GAMEPAD_LEFT_THUMB) != 0);
	PAD_FIELD("s2_z", (buttons & INPUT_GAMEPAD_RIGHT_THUMB) != 0);
	PAD_FIELD("lb", (buttons & INPUT_GAMEPAD_LEFT_SHOULDER) != 0);
	PAD_FIELD("rb", (buttons & INPUT_GAMEPAD_RIGHT_SHOULDER) != 0);
	PAD_FIELD("start", (buttons & INPUT_GAMEPAD_START) != 0);
	PAD_FIELD("back", (buttons & INPUT_GAMEPAD_BACK) != 0);
	PAD_FIELD("a", (buttons & INPUT_GAMEPAD_A) != 0);
	PAD_FIELD("b", (buttons & INPUT_GAMEPAD_B) != 0);
	PAD_FIELD("x", (buttons & INPUT_GAMEPAD_X) != 0);
	PAD_FIELD("y", (buttons & INPUT_GAMEPAD_Y) != 0);
	PAD_FIELD("up", (buttons & INPUT_GAMEPAD_DPAD_UP) != 0);
	PAD_FIELD("down", (buttons & INPUT_GAMEPAD_DPAD_DOWN) != 0);
	PAD_FIELD("left", (buttons & INPUT_GAMEPAD_DPAD_LEFT) != 0);
	PAD_FIELD("right", (buttons & INPUT_GAMEPAD_DPAD_RIGHT) != 0);
	PAD_FIELD("lt", g->left_trigger);
	PAD_FIELD("rt", g->right_trigger);
	/* The Guide is handled by XAM and probably does not reach the title; if it does, it is logged. */
	PAD_FIELD("logo", (buttons & INPUT_GAMEPAD_GUIDE) != 0);
#undef PAD_FIELD
	return 1;
}

/* Both motors off: xsdk asks for them to be set to zero before exiting (docs/GUIDE.md). */
static void rumble_stop(void)
{
	const INPUT_VIBRATION off = { 0, 0 };
	for (int port = 0; port < PORTS; port++)
		if (pad_ok[port])
			(void)XamInputSetState((uint32_t)port, 0, &off);
}

static int motor_speed(int v)
{
	if (v < 0)
		return 0;
	if (v > 255)
		return 255;
	return v;
}

static int rumble_failed[PORTS];   /* 1 = already logged that XAM does not accept the rumble on that port */

/* rumble(port, left, right): 0-255; true if there was a controller (as libXenon does, which does not
 * check the result). If XAM does not take it, it is logged once in the log and it carries on: without
 * rumble the run is not lost. */
static int l_rumble(lua_State *L)
{
	const int port = (int)luaL_checkinteger(L, 1);
	const int left = motor_speed((int)luaL_optinteger(L, 2, 0));
	const int right = motor_speed((int)luaL_optinteger(L, 3, 0));
	if (port < 0 || port >= PORTS || !pad_ok[port]) {
		lua_pushboolean(L, 0);
		return 1;
	}
	/* XAM takes each motor's speed from 0 to 65535; Lua sends 0-255, as in libXenon */
	const INPUT_VIBRATION vibration = { (uint16_t)(left * 257), (uint16_t)(right * 257) };
	const uint32_t r = XamInputSetState((uint32_t)port, 0, &vibration);
	if (r != ERROR_SUCCESS && !rumble_failed[port]) {
		rumble_failed[port] = 1;
		char line[120];
		snprintf(line, sizeof(line), "  controller %d: XamInputSetState failed (0x%08X); continuing without rumble",
			 port + 1, (unsigned)r);
		l360_log(line);
	}
	lua_pushboolean(L, 1);
	return 1;
}

/* ---------- exit ---------- */

/* Where to look for Aurora on exit: the path in game:\aurora_launcher.txt (one line), if it is there,
 * and then the usual ones. Same as in runtime/ and in herramientas/lanzador_aurora. */
static const char *const AURORA[] = {
	"usb:\\Apps\\Aurora\\Aurora.xex",
	"usb1:\\Apps\\Aurora\\Aurora.xex",
	"hdd:\\Apps\\Aurora\\Aurora.xex",
	"hdd:\\Aurora\\Aurora.xex",
};

static void launch_if_there(const char *path)
{
	struct stat st;
	char line[360];
	if (stat(path, &st) != 0) {
		snprintf(line, sizeof(line), "exit: %s not found", path);
		l360_log(line);
		return;
	}
	snprintf(line, sizeof(line), "exit: launching %s", path);
	l360_log(line);
	l360_log_flush();                /* the log up to here, before leaving */
	/* if it works, it does not return: the title ends as an exit and XAM opens the other .xex */
	const int r = xsdk_launch(path, NULL, 0);
	snprintf(line, sizeof(line), "exit: could not launch %s (%d)", path, r);
	l360_log(line);
}

/* Leaves Love360 and opens Aurora; if it cannot find it, returns to the dashboard. It is called only
 * when the game read Back held for 3 s: docs/PITFALLS.md of xsdk ("Ending under the Guide") asks to exit
 * with a button that the title reads (XAM does not pass Back with the Guide open), never on its own.
 * Through Xbox Home atexit does not run, so there is no exit work to do here: turn off the rumble and
 * open the next one. */
static void quit_to_aurora(void) __attribute__((noreturn));
static void quit_to_aurora(void)
{
	rumble_stop();
	l360_sys_save_flush();           /* what is left in the save queue, before leaving */
	l360_audio_close();              /* xsdk_audio_close before opening another .xex (phase 3) */
	char path[260] = { 0 };
	FILE *f = fopen("game:/aurora_launcher.txt", "r");
	if (f) {
		if (fgets(path, sizeof(path), f)) {
			path[strcspn(path, "\r\n")] = 0;
			if (path[0])
				launch_if_there(path);
		}
		fclose(f);
	}
	for (size_t i = 0; i < sizeof(AURORA) / sizeof(AURORA[0]); i++)
		launch_if_there(AURORA[i]);
	l360_log("exit: Aurora not found, returning to the dashboard");
	l360_log_flush();
	exit(0);
}

/* Back held for 3 s on any controller exits. A short Back press reaches the game as usual (during
 * those 3 s too, as just another Back). Back + Start does not work: the console takes it for the
 * screenshot and the game never sees it. */
static double exit_since = -1;

static void check_exit(void)
{
	int held = 0;
	for (int i = 0; i < PORTS; i++)
		if (pad_ok[i] && (pads[i].gamepad.buttons & INPUT_GAMEPAD_BACK))
			held = 1;
	if (!held) {
		exit_since = -1;
		return;
	}
	const double now = now_s();
	if (exit_since < 0) {
		exit_since = now;
		return;
	}
	if ((now - exit_since) * 1000 < EXIT_HOLD_MS)
		return;
	exit_since = -1;
	char line[160];
	snprintf(line, sizeof(line), "exit: Back held for %d s, exiting", EXIT_HOLD_MS / 1000);
	l360_log(line);
	quit_to_aurora();
}

/* ---------- files ---------- */

static int fetch_files;
static double fetch_bytes, fetch_ms;

/* Reads a whole file; NULL if it is not there or could not be read. */
static char *read_whole(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
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

/* ---------- list of what is in game:\ (task 12, hitches) ----------
 * On the console, opening a file that was not on the USB stick took up to 872 ms
 * ("resources/sounds/ambientFire3.idx" is not there, just before a 939 ms hitch): the boot looks for the
 * .idx of each sound the first time it plays, and almost none of them exist. Each folder is listed
 * only once (xsdk's opendir/readdir; resources/sounds at startup, the others the first time something
 * is read from them), and what is not in the list is not opened. Names are compared without case,
 * like the USB stick's FAT. If a folder could not be listed in full, everything in it is still opened
 * (something that might exist is never treated as missing). "no_listing" in game:\l360_gfx.txt turns
 * it off. */
enum { LIST_DIRS = 48, LIST_DIR_CHARS = 160 };

typedef struct {
	char dir[LIST_DIR_CHARS];   /* lowercase, no trailing slash; "" = game:\ */
	char **names;               /* lowercase and sorted; NULL if it could not be listed */
	int count;
} dirlist_t;

static dirlist_t lists[LIST_DIRS];
static int list_count, list_off;

static void lower_copy(char *out, size_t n, const char *in, size_t len)
{
	size_t i = 0;
	for (; i < len && i + 1 < n; i++) {
		char c = in[i];
		if (c == '\\')
			c = '/';
		out[i] = (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
	}
	out[i] = 0;
}

static int cmp_names(const void *a, const void *b)
{
	return strcmp(*(char *const *)a, *(char *const *)b);
}

static double now_ms_sys(void) { return now_s() * 1000.0; }

/* Lists game:\<dir> (dir already lowercase) and stores it in lists[]; NULL if there is no room. */
static dirlist_t *list_add(const char *dir)
{
	if (list_count >= LIST_DIRS)
		return NULL;
	const int slot = list_count++;
	snprintf(lists[slot].dir, sizeof(lists[slot].dir), "%s", dir);
	char path[LIST_DIR_CHARS + 32];
	snprintf(path, sizeof(path), dir[0] ? GAME_DIR "%s" : GAME_DIR, dir);
	const double t0 = now_ms_sys();
	char line[300];
	DIR *d = opendir(path);
	if (!d) {
		snprintf(line, sizeof(line), "  [files] could not list %s (errno %d): opening everything there", path, errno);
		l360_log(line);
		return &lists[slot];
	}
	char **names = NULL;
	int count = 0, room = 0, ok = 1;
	for (;;) {
		errno = 0;
		struct dirent *e = readdir(d);
		if (!e) {
			ok = errno == 0;
			break;
		}
		if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
			continue;
		if (count == room) {
			room = room ? room * 2 : 64;
			char **more = realloc(names, (size_t)room * sizeof(*names));
			if (!more) {
				ok = 0;
				break;
			}
			names = more;
		}
		const size_t len = strlen(e->d_name);
		char *name = malloc(len + 1);
		if (!name) {
			ok = 0;
			break;
		}
		lower_copy(name, len + 1, e->d_name, len);
		names[count++] = name;
	}
	const int err = errno;
	closedir(d);
	if (!ok) {
		for (int i = 0; i < count; i++)
			free(names[i]);
		free(names);
		snprintf(line, sizeof(line), "  [files] the listing of %s is incomplete (errno %d): opening everything there",
			 path, err);
		l360_log(line);
		return &lists[slot];
	}
	if (count > 1)
		qsort(names, (size_t)count, sizeof(*names), cmp_names);
	lists[slot].names = names ? names : malloc(sizeof(*names));   /* empty folder: empty list, not "no list" */
	lists[slot].count = count;
	snprintf(line, sizeof(line), "  [files] %s: %d files, listed in %.1f ms", path, count, now_ms_sys() - t0);
	l360_log(line);
	return &lists[slot];
}

void l360_sys_list_off(void)
{
	list_off = 1;
	l360_log("  [files] no_listing: opening each file without checking the folder listing");
}

void l360_sys_list_dir(const char *dir)
{
	char low[LIST_DIR_CHARS];
	lower_copy(low, sizeof(low), dir, strlen(dir));
	if (list_off)
		return;
	for (int i = 0; i < list_count; i++)
		if (!strcmp(lists[i].dir, low))
			return;
	(void)list_add(low);
}

int l360_sys_game_missing(const char *path)
{
	if (list_off || !path)
		return 0;
	while (path[0] == '.' && path[1] == '/')
		path += 2;
	const size_t len = strlen(path);
	if (len == 0 || len >= LIST_DIR_CHARS + 100 || strstr(path, ".."))
		return 0;
	char low[LIST_DIR_CHARS + 100];
	lower_copy(low, sizeof(low), path, len);
	char *slash = strrchr(low, '/');
	const char *name = low;
	char dir[LIST_DIR_CHARS] = "";
	if (slash) {
		if ((size_t)(slash - low) >= sizeof(dir))
			return 0;
		memcpy(dir, low, (size_t)(slash - low));
		dir[slash - low] = 0;
		name = slash + 1;
	}
	if (!name[0])
		return 0;
	dirlist_t *l = NULL;
	for (int i = 0; i < list_count && !l; i++)
		if (!strcmp(lists[i].dir, dir))
			l = &lists[i];
	if (!l)
		l = list_add(dir);
	if (!l || !l->names)
		return 0;
	return bsearch(&name, l->names, (size_t)l->count, sizeof(*l->names), cmp_names) == NULL;
}

/* ---------- music in chunks (l360.fetch_start / l360.fetch_step) ---------- */

/* One download at a time, as in libXenon. The chunk is read on a separate thread (FETCH_HW_THREAD):
 * reading it in fetch_start stalled the main thread, and the boot asks for it after present, so the
 * first frames (SPLASH, chunk 0 of every track) took 60-90 ms (the "rest" of 60-70 ms in the [hitch],
 * task 12), and a USB stall in the middle of the game would be a hitch of almost a second.
 * fetch_step waits at most the ms it is given and returns "pending" if it has not finished.
 * A missing file is reported in fetch_step (nil and the reason), not in fetch_start, as with libXenon.
 * The folder listing (l360_sys_game_missing) is checked in fetch_start, on the main thread: the reader
 * thread does not touch the log, the listing or Lua. If the thread does not start, it is read in
 * fetch_start as before. */
enum { FETCH_HW_THREAD = 3, FETCH_STACK = 32 * 1024 };

static struct {
	int active;
	int id;                 /* the id that is valid now; 0 = no download in progress */
	char name[200];         /* the requested path, for the log */
	char path[460];         /* game:\<path>, for the thread */
	char error[260];        /* the reason, if it could not be read */
	char *data;
	size_t len;
	int failed;
	int pending;            /* 1 while the thread reads it (under fetch_mu) */
	double ms;              /* how long the read took, for readstats */
} fetch;

static int fetch_last_id;
static int fetch_thread_state;          /* 0 not started, 1 running, -1 did not start: it is read right away */
static HANDLE fetch_thread;
static pthread_mutex_t fetch_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t fetch_cv = PTHREAD_COND_INITIALIZER;

static uint32_t fetch_worker(void *context)
{
	(void)context;
	char path[sizeof(fetch.path)];
	for (;;) {
		pthread_mutex_lock(&fetch_mu);
		while (fetch.pending != 1)
			pthread_cond_wait(&fetch_cv, &fetch_mu);
		memcpy(path, fetch.path, sizeof(path));
		fetch.pending = 2;               /* reading: fetch_start does not request it again */
		pthread_mutex_unlock(&fetch_mu);

		const double t0 = now_s();
		size_t n = 0;
		char *data = read_whole(path, &n);
		const double ms = (now_s() - t0) * 1000;

		pthread_mutex_lock(&fetch_mu);
		fetch.data = data;
		fetch.len = data ? n : 0;
		fetch.failed = data == NULL;
		fetch.ms = ms;
		fetch.pending = 0;
		pthread_mutex_unlock(&fetch_mu);
	}
	return 0;
}

static int fetch_thread_start(void)
{
	if (fetch_thread_state)
		return fetch_thread_state > 0;
	const NTSTATUS st = xsdk_thread_create_on(&fetch_thread, FETCH_STACK, fetch_worker, NULL, FETCH_HW_THREAD);
	fetch_thread_state = NT_SUCCESS(st) ? 1 : -1;
	if (fetch_thread_state < 0) {
		char line[120];
		snprintf(line, sizeof(line), "  [music] the reader thread did not start (0x%08X): reading synchronously",
			 (unsigned)st);
		l360_log(line);
	}
	return fetch_thread_state > 0;
}

static int l_fetch_start(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	if (fetch.active) {
		lua_pushnil(L);
		lua_pushstring(L, "a download is already running");
		return 2;
	}
	pthread_mutex_lock(&fetch_mu);       /* the thread is idle (pending 0): the lock is for tidiness */
	free(fetch.data);
	memset(&fetch, 0, sizeof fetch);
	pthread_mutex_unlock(&fetch_mu);
	snprintf(fetch.name, sizeof(fetch.name), "%s", path);
	snprintf(fetch.path, sizeof(fetch.path), GAME_DIR "%s", path);
	snprintf(fetch.error, sizeof(fetch.error), GAME_DIR "%.200s: not found", path);
	if (l360_sys_game_missing(path)) {
		fetch.failed = 1;
	} else if (fetch_thread_start()) {
		pthread_mutex_lock(&fetch_mu);
		fetch.pending = 1;
		pthread_cond_signal(&fetch_cv);
		pthread_mutex_unlock(&fetch_mu);
	} else {
		const double t0 = now_s();
		size_t n = 0;
		fetch.data = read_whole(fetch.path, &n);
		fetch.len = fetch.data ? n : 0;
		fetch.failed = fetch.data == NULL;
		fetch.ms = (now_s() - t0) * 1000;
	}
	fetch.id = ++fetch_last_id;
	fetch.active = 1;
	lua_pushnumber(L, (lua_Number)fetch.id);
	return 1;
}

/* fetch_step(id, ms): "pending", the data, or nil and the reason. Waits at most ms (0 to 1000)
 * for the thread to finish reading. */
static int l_fetch_step(lua_State *L)
{
	const lua_Number id = luaL_checknumber(L, 1);
	lua_Number wait_ms = luaL_optnumber(L, 2, 0);
	if (!fetch.active || id != (lua_Number)fetch.id) {
		lua_pushnil(L);
		lua_pushstring(L, "invalid download id");
		return 2;
	}
	if (wait_ms < 0)
		wait_ms = 0;
	if (wait_ms > 1000)
		wait_ms = 1000;
	const double until = now_s() + wait_ms / 1000.0;
	for (;;) {
		pthread_mutex_lock(&fetch_mu);
		const int pending = fetch.pending;
		pthread_mutex_unlock(&fetch_mu);
		if (!pending)
			break;
		if (now_s() >= until) {
			lua_pushstring(L, "pending");
			return 1;
		}
		const struct timespec one_ms = { 0, 1000 * 1000 };
		nanosleep(&one_ms, NULL);
	}
	fetch.active = 0;               /* the id is no longer valid, as in libXenon */
	fetch.id = 0;
	char line[460];
	if (fetch.failed) {
		snprintf(line, sizeof(line), "  not found: %.120s (background load: %.200s)", fetch.name, fetch.error);
		l360_log(line);
		lua_pushnil(L);
		lua_pushstring(L, fetch.error);
		return 2;
	}
	fetch_files++;
	fetch_bytes += (double)fetch.len;
	fetch_ms += fetch.ms;
	snprintf(line, sizeof(line), "  read %s: %u KB, %.1f ms (from disk, on another thread)", fetch.name,
		 (unsigned)(fetch.len / 1024), fetch.ms);
	l360_log(line);
	lua_pushlstring(L, fetch.data, fetch.len);
	free(fetch.data);
	fetch.data = NULL;
	fetch.len = 0;
	return 1;
}

void l360_sys_readstats(int *files, double *bytes, double *ms)
{
	if (files)
		*files = fetch_files;
	if (bytes)
		*bytes = fetch_bytes;
	if (ms)
		*ms = fetch_ms;
}

/* ---------- saving (game:\save\, regular files) ---------- */

/* Save folder: game:\save\. It is created the first time it is used, if it is missing (game: is the
 * .xex folder). What used to fall into "game:\l360save_*" because there was no guard_dir is now
 * kept in its own folder; save.lua does not change (it already uses the two slots). */
static char save_dir_path[48] = GAME_DIR SAVE_DIR_DEFAULT "/";   /* ends in '/' */
static int save_dir_used;                /* 1 once the folder was used: its name can no longer change */

static const char *save_dir(void)
{
	if (!save_dir_used) {
		char bare[sizeof(save_dir_path)];
		snprintf(bare, sizeof(bare), "%s", save_dir_path);
		bare[strlen(bare) - 1] = 0;          /* without the final '/' */
		struct stat st;
		if (stat(bare, &st) != 0)
			mkdir(bare, 0777);   /* the first time; if it fails, save_write returns false */
		save_dir_used = 1;
	}
	return save_dir_path;
}

/* 1 if name can be the save folder: flat (letters, digits, _ and -), 1 to SAVE_DIR_NAME_MAX
 * characters, and not a folder the runtime uses for something else. */
static int save_dir_name_ok(const char *name)
{
	const size_t len = strlen(name);
	if (len < 1 || len > SAVE_DIR_NAME_MAX)
		return 0;
	for (const char *p = name; *p; p++)
		if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9')
		      || *p == '_' || *p == '-'))
			return 0;
	char low[SAVE_DIR_NAME_MAX + 1];
	lower_copy(low, sizeof(low), name, len);
	return strcmp(low, "l360") != 0 && strcmp(low, "shaders") != 0;
}

/* save_set_dir(name): the save folder becomes game:\<name>\ (game.lua's save_dir; boot.lua calls
 * it before anything is saved). true if it was taken; false for a bad name or when the folder was
 * already used under another name. */
static int l_save_set_dir(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);
	char want[sizeof(save_dir_path)];
	int ok = save_dir_name_ok(name);
	if (ok) {
		snprintf(want, sizeof(want), GAME_DIR "%.32s/", name);
		if (strcmp(want, save_dir_path) != 0) {
			if (save_dir_used)
				ok = 0;
			else
				memcpy(save_dir_path, want, sizeof(save_dir_path));
		}
	}
	if (!ok) {
		char line[200];
		snprintf(line, sizeof(line), "  [ERROR] [save] save folder \"%.80s\" not accepted: keeping %s", name,
			 save_dir_path);
		l360_log(line);
	}
	lua_pushboolean(L, ok);
	return 1;
}

/* Flat name (letters, digits, _ . -) of up to 80 characters -> full path; -1 if it is not valid. */
static int save_path(char *out, size_t n, const char *name)
{
	if (!name || !*name || strlen(name) > NAME_MAX_CHARS)
		return -1;
	for (const char *p = name; *p; p++)
		if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9')
		      || *p == '_' || *p == '.' || *p == '-'))
			return -1;
	snprintf(out, n, "%s%s", save_dir(), name);
	return 0;
}

static int l_save_dir(lua_State *L)
{
	lua_pushstring(L, save_dir());
	return 1;
}

/* ---------- saving on a separate thread (task 12, hitches) ----------
 * The game saves the run in the middle of play (save_run), and writing to the USB stick stalled the frame.
 * l360.save_write copies the data, puts it in a queue and returns true right away; a dedicated thread
 * (SAVE_HW_THREAD, away from thread 0 that runs Lua) writes them in order. What Lua sees does not change:
 *  - save_read of a file still in the queue returns what was sent to be written.
 *  - If a file is in the queue twice before it starts, only the last one is written.
 *  - save.lua's two slots (.a and .b, alternating) still make sure that a power cut in the middle of
 *    a write leaves the other one intact: the thread writes one slot at a time, in order.
 *  - A write error is logged from the main thread (l360_sys_poll), not from the writer thread,
 *    which does not touch the log or Lua.
 *  - Before leaving for Aurora it waits for the queue to empty (SAVE_FLUSH_MS at most).
 *  - If the thread does not start or there is no memory for the copy, it is written as before, right away.
 * "direct_save" in game:\l360_gfx.txt turns it off (everything as before). */
enum {
	SAVE_HW_THREAD = 3,               /* core 1, with the audio mixer (2); not core 0 (Lua) */
	SAVE_STACK = 64 * 1024,
	SAVE_QUEUE_MAX = 16 * 1024 * 1024,   /* above this in the queue, save_write waits (it never drops data) */
	SAVE_FLUSH_MS = 5000,
};

typedef struct save_job {
	struct save_job *next;
	char path[200];
	char *data;
	size_t len;
	double queued_at;                 /* now_s() when queued */
} save_job_t;

static pthread_mutex_t save_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t save_cv = PTHREAD_COND_INITIALIZER;       /* there is work */
static pthread_cond_t save_done_cv = PTHREAD_COND_INITIALIZER;  /* one finished */
static save_job_t *save_head, *save_tail;   /* not started, in order */
static save_job_t *save_busy;               /* the one being written (save_read reads it) */
static size_t save_queued_bytes;
static int save_thread_state;               /* 0 not started, 1 running, -1 did not start: direct */
static int save_direct;                     /* "direct_save" in l360_gfx.txt */
static HANDLE save_thread;
/* What the thread leaves for the main thread to log (under save_mu) */
static char save_note[8][300];
static int save_notes;

static int write_file(const char *path, const char *data, size_t len)
{
	int ok = 0;
	FILE *f = fopen(path, "wb");
	if (f) {
		ok = fwrite(data, 1, len, f) == len;
		if (fclose(f))          /* here too it has to close properly: FAT is written on close */
			ok = 0;
	}
	return ok;
}

static uint32_t save_worker(void *context)
{
	(void)context;
	for (;;) {
		pthread_mutex_lock(&save_mu);
		while (!save_head)
			pthread_cond_wait(&save_cv, &save_mu);
		save_job_t *job = save_head;
		save_head = job->next;
		if (!save_head)
			save_tail = NULL;
		save_busy = job;
		pthread_mutex_unlock(&save_mu);

		const double t0 = now_s();
		const int ok = write_file(job->path, job->data, job->len);
		const double t1 = now_s();

		pthread_mutex_lock(&save_mu);
		save_busy = NULL;
		save_queued_bytes -= job->len;
		if (save_notes < (int)(sizeof(save_note) / sizeof(save_note[0]))) {
			snprintf(save_note[save_notes++], sizeof(save_note[0]),
				 ok ? "  [save] wrote %s: %u KB, %.0f ms (queued %.0f ms)"
				    : "  [ERROR] [save] could not write %s (%u KB, %.0f ms, queued %.0f ms)",
				 job->path, (unsigned)(job->len / 1024), (t1 - t0) * 1000, (t0 - job->queued_at) * 1000);
		}
		pthread_cond_broadcast(&save_done_cv);
		pthread_mutex_unlock(&save_mu);
		free(job->data);
		free(job);
	}
	return 0;
}

static int save_thread_start(void)
{
	if (save_thread_state)
		return save_thread_state > 0;
	const NTSTATUS st = xsdk_thread_create_on(&save_thread, SAVE_STACK, save_worker, NULL, SAVE_HW_THREAD);
	save_thread_state = NT_SUCCESS(st) ? 1 : -1;
	char line[120];
	if (save_thread_state > 0)
		snprintf(line, sizeof(line), "  [save] writing on a separate thread (hardware thread %d)", SAVE_HW_THREAD);
	else
		snprintf(line, sizeof(line), "  [save] the writer thread did not start (0x%08X): writing synchronously",
			 (unsigned)st);
	l360_log(line);
	return save_thread_state > 0;
}

/* Queues a copy of data for path. 0 if it could not (no thread or no memory): the caller writes it. */
static int save_enqueue(const char *path, const char *data, size_t len)
{
	if (save_direct || !save_thread_start())
		return 0;
	char *copy = malloc(len ? len : 1);
	save_job_t *job = copy ? calloc(1, sizeof(*job)) : NULL;
	if (!job) {
		free(copy);
		l360_log("  [save] out of memory for the copy: writing synchronously");
		return 0;
	}
	memcpy(copy, data, len);
	snprintf(job->path, sizeof(job->path), "%s", path);
	job->data = copy;
	job->len = len;
	job->queued_at = now_s();
	pthread_mutex_lock(&save_mu);
	while (save_queued_bytes > SAVE_QUEUE_MAX)
		pthread_cond_wait(&save_done_cv, &save_mu);
	/* same file, not started yet: its data is replaced (only the last one is written) */
	for (save_job_t *j = save_head; j; j = j->next) {
		if (!strcmp(j->path, path)) {
			save_queued_bytes -= j->len;
			save_queued_bytes += len;
			free(j->data);
			j->data = copy;
			j->len = len;
			pthread_mutex_unlock(&save_mu);
			free(job);
			return 1;
		}
	}
	save_queued_bytes += len;
	if (save_tail)
		save_tail->next = job;
	else
		save_head = job;
	save_tail = job;
	pthread_cond_signal(&save_cv);
	pthread_mutex_unlock(&save_mu);
	return 1;
}

/* If path is in the queue (or being written), it pushes it to Lua and returns 1: the last one sent wins. */
static int save_push_queued(lua_State *L, const char *path)
{
	if (save_thread_state <= 0)
		return 0;
	int found = 0;
	pthread_mutex_lock(&save_mu);
	const save_job_t *last = NULL;
	if (save_busy && !strcmp(save_busy->path, path))
		last = save_busy;
	for (const save_job_t *j = save_head; j; j = j->next)
		if (!strcmp(j->path, path))
			last = j;
	if (last) {
		lua_pushlstring(L, last->data, last->len);
		found = 1;
	}
	pthread_mutex_unlock(&save_mu);
	return found;
}

/* What the writer thread left, for the log (from the main thread, once per frame). */
static void save_log_notes(void)
{
	if (save_thread_state <= 0)
		return;
	char notes[8][300];
	int n;
	pthread_mutex_lock(&save_mu);
	n = save_notes;
	memcpy(notes, save_note, sizeof(notes[0]) * (size_t)n);
	save_notes = 0;
	pthread_mutex_unlock(&save_mu);
	for (int i = 0; i < n; i++)
		l360_log(notes[i]);
}

void l360_sys_save_flush(void)
{
	if (save_thread_state <= 0)
		return;
	const double until = now_s() + SAVE_FLUSH_MS / 1000.0;
	for (;;) {
		pthread_mutex_lock(&save_mu);
		const int left = save_head != NULL || save_busy != NULL;
		pthread_mutex_unlock(&save_mu);
		if (!left || now_s() > until)
			break;
		const struct timespec ten_ms = { 0, 10 * 1000 * 1000 };
		nanosleep(&ten_ms, NULL);
	}
	save_log_notes();
	pthread_mutex_lock(&save_mu);
	const int left = save_head != NULL || save_busy != NULL;
	pthread_mutex_unlock(&save_mu);
	if (left)
		l360_log("  [ERROR] [save] exited with unfinished queued writes");
}

void l360_sys_save_direct(void)
{
	save_direct = 1;
	l360_log("  [save] direct_save: writing synchronously, without a separate thread");
}

static int l_save_read(lua_State *L)
{
	char path[200];
	size_t len = 0;
	if (save_path(path, sizeof(path), luaL_checkstring(L, 1))) {
		lua_pushnil(L);
		return 1;
	}
	if (save_push_queued(L, path))
		return 1;
	char *buf = read_whole(path, &len);
	if (!buf) {
		lua_pushnil(L);
		return 1;
	}
	lua_pushlstring(L, buf, len);
	free(buf);
	return 1;
}

static int l_save_write(lua_State *L)
{
	size_t len;
	const char *name = luaL_checkstring(L, 1);
	const char *data = luaL_checklstring(L, 2, &len);
	char path[200];
	int ok = 0;
	if (!save_path(path, sizeof(path), name)) {
		ok = save_enqueue(path, data, len);
		if (!ok) {
			const double t0 = now_s();
			ok = write_file(path, data, len);
			char line[300];
			snprintf(line, sizeof(line), "  [save] wrote synchronously %s: %u KB, %.0f ms%s", path,
				 (unsigned)(len / 1024), (now_s() - t0) * 1000, ok ? "" : " (FAILED)");
			l360_log(line);
		}
	}
	lua_pushboolean(L, ok);
	return 1;
}

/* ---------- the game folder, for love.filesystem ---------- */

/* GAME_DIR<path> without "./" at the start or '/' at the end; -1 for a path that leaves the folder. */
static int game_path(char *out, size_t n, const char *path)
{
	while (path[0] == '.' && path[1] == '/')
		path += 2;
	size_t len = strlen(path);
	while (len > 0 && (path[len - 1] == '/' || path[len - 1] == '\\'))
		len--;
	if (len > 400 || strstr(path, "..") || strchr(path, ':') || path[0] == '/' || path[0] == '\\')
		return -1;
	snprintf(out, n, GAME_DIR "%.*s", (int)len, path);
	return 0;
}

/* filetype(path): "file" and its size, "directory", or nil if it is not in the game folder. */
static int l_filetype(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	char full[460];
	struct stat st;
	if (game_path(full, sizeof(full), path) || l360_sys_game_missing(path) || stat(full, &st) != 0) {
		lua_pushnil(L);
		return 1;
	}
	if (S_ISDIR(st.st_mode)) {
		lua_pushstring(L, "directory");
		return 1;
	}
	lua_pushstring(L, "file");
	lua_pushnumber(L, (lua_Number)st.st_size);
	return 2;
}

/* listdir(path): the names in that folder of the game ("" is the game folder itself), as the disk
 * has them, or nil if it could not be listed. */
static int l_listdir(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	char full[460];
	DIR *d = game_path(full, sizeof(full), path) ? NULL : opendir(full);
	if (!d) {
		lua_pushnil(L);
		return 1;
	}
	lua_newtable(L);
	int n = 0;
	for (struct dirent *e; (e = readdir(d)) != NULL;) {
		if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
			continue;
		lua_pushstring(L, e->d_name);
		lua_rawseti(L, -2, ++n);
	}
	closedir(d);
	return 1;
}

/* quit(): love.event.quit. Leaves like Back held 3 s does; it does not return. */
static int l_quit(lua_State *L)
{
	(void)L;
	l360_log("exit: asked by the game (love.event.quit)");
	quit_to_aurora();
}

/* ---------- log and files in game:\ ---------- */

/* upload(name, data): on libXenon it uploaded to the PC over TFTP; here it writes game:\<name>. */
static int l_upload(lua_State *L)
{
	size_t len;
	const char *name = luaL_checkstring(L, 1);
	const char *data = luaL_checklstring(L, 2, &len);
	char path[400];
	int ok = 0;
	snprintf(path, sizeof(path), "game:/%s", name);
	FILE *f = fopen(path, "wb");
	if (f) {
		ok = fwrite(data, 1, len, f) == len;
		if (fclose(f))
			ok = 0;
	}
	if (!ok) {
		char line[460];
		snprintf(line, sizeof(line), "  [ERROR] could not write %s", path);
		l360_log(line);
	}
	lua_pushboolean(L, ok);
	return 1;
}

/* xsdk's log (game:\<name of the .xex>.log, default.log on the console) is written line by line
 * with NtWriteFile: when l360.upload_log() returns, it is already on disk, with no buffer to flush
 * and no PC to upload it to. The function is kept because boot.lua calls it. */
static int l_upload_log(lua_State *L)
{
	(void)L;
	return 0;
}

/* ---------- network ---------- */

/* poll(): on libXenon it services the network; here there is no network to service (the log can go
 * through xsdk's net_log.txt, which needs nothing from the game). */
static int l_poll(lua_State *L)
{
	(void)L;
	return 0;
}

/* ---------- what main.c calls ---------- */

void l360_sys_poll(void)
{
	save_log_notes();
	sample_pads();
	check_exit();
}

void l360_sys_register(lua_State *L)
{
	lua_pushcfunction(L, l_pad);         lua_setfield(L, -2, "pad");
	lua_pushcfunction(L, l_rumble);      lua_setfield(L, -2, "rumble");
	lua_pushcfunction(L, l_poll);        lua_setfield(L, -2, "poll");
	lua_pushcfunction(L, l_fetch_start); lua_setfield(L, -2, "fetch_start");
	lua_pushcfunction(L, l_fetch_step);  lua_setfield(L, -2, "fetch_step");
	lua_pushcfunction(L, l_upload);      lua_setfield(L, -2, "upload");
	lua_pushcfunction(L, l_upload_log);  lua_setfield(L, -2, "upload_log");
	lua_pushcfunction(L, l_filetype);    lua_setfield(L, -2, "filetype");
	lua_pushcfunction(L, l_listdir);     lua_setfield(L, -2, "listdir");
	lua_pushcfunction(L, l_quit);        lua_setfield(L, -2, "quit");
	lua_pushcfunction(L, l_save_set_dir); lua_setfield(L, -2, "save_set_dir");
	lua_pushcfunction(L, l_save_dir);    lua_setfield(L, -2, "save_dir");
	lua_pushcfunction(L, l_save_read);   lua_setfield(L, -2, "save_read");
	lua_pushcfunction(L, l_save_write);  lua_setfield(L, -2, "save_write");
}
