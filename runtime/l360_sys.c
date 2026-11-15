/*
 * Love360 sobre xsdk: mando, archivos, guardado y salida (tarea 05 fase 4, tarea 08).
 *
 * Todo lo de la fase 4 vive aca para no chocar con la fase 2 (graficos), que trabaja en main.c:
 *   - l360.pad / l360.rumble sobre XamInputGetState / XamInputSetState, con la misma tabla y los
 *     mismos valores que libXenon (runtime/source/main.c, l_pad): sticks de -32768 a 32767,
 *     gatillos de 0 a 255, botones 0 o 1.
 *   - l360.poll / l360.poll_input: no hay red; poll_input (en main.c) llama a l360_sys_poll(), que
 *     lee el mando una vez por frame y mira la salida.
 *   - Salida: Back mantenido 3 s llama a quit_to_aurora; un toque de Back sigue siendo de Balatro.
 *     (Back + Start no: es el atajo de captura de pantalla de la consola y el juego no lo recibe.)
 *   - l360.fetch_start / fetch_step: los trozos de musica. Aca no hay red: el archivo se lee
 *     entero de game:\balatro\ en un hilo aparte y fetch_step lo devuelve cuando termino.
 *   - l360.save_dir / save_read / save_write: game:\save\ (archivos comunes), como pide la tarea.
 *   - l360.upload: escribe game:\<nombre> (en libXenon subia por TFTP). upload_log no hace falta:
 *     xsdk escribe el registro linea por linea con NtWriteFile, sin buffer que vaciar.
 *
 * El signo del eje Y: XAM entrega los sticks como el reporte HID de la 360, que es lo mismo que
 * entrega libXenon (libxenon/drivers/usb/usbctrl.c copia los mismos dos bytes con signo: arriba
 * positivo). Por eso se pasan tal cual; el que cambia el signo para LOVE es love360_input.lua
 * (linea 20: "XInput: arriba positivo; LOVE: abajo positivo"), que no se toca.
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
#include "l360_importar.h"
#include "l360_sys.h"

/* Carpeta del juego (los .lua y resources\ de Balatro) y carpeta de guardado, las dos en game:
 * (la carpeta del .xex). No se usa game:\guardado\: en el pendrive del dueno es la carpeta de la
 * epoca de libXenon y tiene su partida real. */
#define GAME_DIR "game:/balatro/"
#define SAVE_DIR "game:/save/"
#define SAVE_DIR_NO_SLASH "game:/save"

enum {
	PORTS = 4,               /* mandos 0 a 3 de XAM */
	EXIT_HOLD_MS = 3000,     /* Back mantenido, para salir */
	NAME_MAX_CHARS = 80,     /* igual que libXenon: l360.save_read/save_write */
};

/* Segundos de reloj monotono (para no depender de l360.time, que lo lleva main.c). */
static double now_s(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

/* ---------- mando ---------- */

static INPUT_STATE pads[PORTS];   /* ultimo estado leido por l360_sys_poll */
static int pad_ok[PORTS];         /* 1 = ese puerto tiene mando (l360.pad devuelve la tabla) */
static int pad_seen[PORTS] = { -1, -1, -1, -1 };   /* para anotar conexiones y desconexiones una vez */

/* Lee los cuatro puertos. Igual que libXenon: un error pasajero conserva el ultimo estado (si no,
 * un parpadeo del USB cortaria la vibracion y los botones a mitad de partida); solo "no hay mando
 * conectado" (ERROR_DEVICE_NOT_CONNECTED) da nil en l360.pad. */
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

/* pad(puerto): la misma tabla que libXenon, o nil si ese puerto no tiene mando. */
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
	/* La Guia la maneja XAM y probablemente no llegue al titulo; si llega, se informa. */
	PAD_FIELD("logo", (buttons & INPUT_GAMEPAD_GUIDE) != 0);
#undef PAD_FIELD
	return 1;
}

/* Los dos motores apagados: xsdk pide dejarlos en cero antes de terminar (docs/GUIDE.md). */
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

static int rumble_failed[PORTS];   /* 1 = ya se anoto que XAM no toma la vibracion en ese puerto */

/* rumble(puerto, izquierdo, derecho): 0-255; true si habia mando (como libXenon, que no mira el
 * resultado). Si XAM no lo toma se anota una vez en el registro y se sigue: sin vibracion no se
 * pierde la partida. */
static int l_rumble(lua_State *L)
{
	const int port = (int)luaL_checkinteger(L, 1);
	const int left = motor_speed((int)luaL_optinteger(L, 2, 0));
	const int right = motor_speed((int)luaL_optinteger(L, 3, 0));
	if (port < 0 || port >= PORTS || !pad_ok[port]) {
		lua_pushboolean(L, 0);
		return 1;
	}
	/* XAM toma la velocidad de cada motor de 0 a 65535; Lua manda 0-255 como en libXenon */
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

/* ---------- salida ---------- */

/* Donde buscar Aurora al salir: la ruta de game:\lanzador_aurora.txt (una linea), si esta, y
 * despues las de siempre. Igual que en runtime/ y en herramientas/lanzador_aurora. */
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
	l360_log_flush();                /* el registro hasta aca, antes de irse */
	/* si anda no vuelve: termina el titulo como exit y XAM abre el otro .xex */
	const int r = xsdk_launch(path, NULL, 0);
	snprintf(line, sizeof(line), "exit: could not launch %s (%d)", path, r);
	l360_log(line);
}

/* Sale de Love360 y abre Aurora; si no la encuentra, vuelve al dashboard. Se llama solo cuando el
 * juego leyo Back mantenido 3 s: docs/PITFALLS.md de xsdk ("Ending under the Guide") pide terminar con
 * un boton que lea el titulo (XAM no le pasa Back con la Guia abierta), nunca solo. Por Xbox Home no
 * corre atexit, asi que aca no hay trabajo de salida que hacer: apagar la vibracion y abrir lo
 * siguiente. */
static void quit_to_aurora(void) __attribute__((noreturn));
static void quit_to_aurora(void)
{
	rumble_stop();
	l360_sys_save_flush();           /* lo que quedo en la cola de guardado, antes de irse */
	l360_audio_close();              /* xsdk_audio_close antes de abrir otro .xex (fase 3) */
	char path[260] = { 0 };
	FILE *f = fopen("game:/lanzador_aurora.txt", "r");
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

/* Back mantenido 3 s en cualquier mando sale. Un toque de Back llega a Balatro como siempre (en
 * esos 3 s tambien, como un Back mas). Back + Start no sirve: la consola lo toma para la captura de
 * pantalla y el juego nunca lo ve. */
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

/* ---------- archivos ---------- */

static int fetch_files;
static double fetch_bytes, fetch_ms;

/* Lee un archivo entero; NULL si no esta o si no se pudo leer. */
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

/* ---------- lista de lo que hay en game:\balatro\ (tarea 12, tirones) ----------
 * En la consola, abrir un archivo que no esta en el pendrive tardo hasta 872 ms
 * ("no esta resources/sounds/ambientFire3.idx", justo antes de un tiron de 939 ms): el boot busca el
 * .idx de cada sonido la primera vez que suena, y casi ninguno tiene. Cada carpeta se lista una sola
 * vez (opendir/readdir de xsdk; resources/sounds ya al arrancar, las demas la primera vez que se lee
 * algo de ellas) y lo que no esta en la lista no se intenta abrir. Los nombres se comparan sin
 * mayusculas, como la FAT del pendrive. Si una carpeta no se pudo listar entera, de esa carpeta se
 * sigue abriendo todo (nunca se da por faltante algo que podria estar). "sin_lista" en
 * game:\l360_gfx.txt la apaga. */
enum { LIST_DIRS = 48, LIST_DIR_CHARS = 160 };

typedef struct {
	char dir[LIST_DIR_CHARS];   /* en minusculas, sin barra al final; "" = game:\balatro\ */
	char **names;               /* en minusculas y ordenados; NULL si no se pudo listar */
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

/* Lista game:\balatro\<dir> (dir ya en minusculas) y la deja en lists[]; NULL si no hay lugar. */
static dirlist_t *list_add(const char *dir)
{
	if (list_count >= LIST_DIRS)
		return NULL;
	const int slot = list_count++;
	snprintf(lists[slot].dir, sizeof(lists[slot].dir), "%s", dir);
	char path[LIST_DIR_CHARS + 32];
	snprintf(path, sizeof(path), dir[0] ? GAME_DIR "%s" : "game:/balatro", dir);
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
	lists[slot].names = names ? names : malloc(sizeof(*names));   /* carpeta vacia: lista vacia, no "sin lista" */
	lists[slot].count = count;
	snprintf(line, sizeof(line), "  [files] %s: %d files, listed in %.1f ms", path, count, now_ms_sys() - t0);
	l360_log(line);
	return &lists[slot];
}

void l360_sys_list_off(void)
{
	list_off = 1;
	l360_log("  [files] sin_lista: opening each file without checking the folder listing");
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

/* ---------- musica en trozos (l360.fetch_start / l360.fetch_step) ---------- */

/* Una descarga a la vez, como en libXenon. El trozo se lee en un hilo aparte (FETCH_HW_THREAD):
 * leerlo en fetch_start frenaba el hilo principal, y el boot lo pide despues de present, con lo que
 * los primeros frames (SPLASH, los trozos 0 de todas las pistas) duraban 60-90 ms ("resto" de 60-70
 * ms en el [hitch], tarea 12), y un frenazo del pendrive en medio del juego seria un tiron de casi
 * un segundo. fetch_step espera a lo sumo los ms que le dan y devuelve "pendiente" si no termino.
 * Un archivo que no esta se avisa en fetch_step (nil y el motivo), no en fetch_start, como con
 * libXenon. La lista de la carpeta (l360_sys_game_missing) se mira en fetch_start, en el hilo
 * principal: el hilo de lectura no toca el registro, la lista ni Lua. Si el hilo no arranca, se
 * lee en fetch_start como antes. */
enum { FETCH_HW_THREAD = 3, FETCH_STACK = 32 * 1024 };

static struct {
	int active;
	int id;                 /* id que vale ahora; 0 = no hay ninguna descarga en curso */
	char name[200];         /* la ruta pedida, para el registro */
	char path[460];         /* game:\balatro\<ruta>, para el hilo */
	char error[260];        /* el motivo, si no se pudo leer */
	char *data;
	size_t len;
	int failed;
	int pending;            /* 1 mientras el hilo lo lee (bajo fetch_mu) */
	double ms;              /* lo que tardo leerlo, para readstats */
} fetch;

static int fetch_last_id;
static int fetch_thread_state;          /* 0 sin arrancar, 1 andando, -1 no arranco: se lee en el momento */
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
		fetch.pending = 2;               /* leyendo: fetch_start no lo vuelve a pedir */
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
	pthread_mutex_lock(&fetch_mu);       /* el hilo esta quieto (pending 0): el lock es por prolijidad */
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

/* fetch_step(id, ms): "pendiente", los datos, o nil y el motivo. Espera a lo sumo ms (0 a 1000) a
 * que el hilo termine de leer. */
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
			lua_pushstring(L, "pendiente");
			return 1;
		}
		const struct timespec one_ms = { 0, 1000 * 1000 };
		nanosleep(&one_ms, NULL);
	}
	fetch.active = 0;               /* el id ya no sirve, como en libXenon */
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

/* ---------- guardado (game:\save\, archivos comunes) ---------- */

/* Carpeta de guardado: game:\save\. Se crea la primera vez que se usa, si no esta (game: es la
 * carpeta del .xex). Lo que antes caia a "game:\balatro\l360save_*" por no haber guard_dir ahora
 * queda ordenado en su carpeta; love360_save.lua no cambia (ya hace las dos ranuras). */
static const char *save_dir(void)
{
	static int made;
	if (!made) {
		struct stat st;
		if (stat(SAVE_DIR_NO_SLASH, &st) != 0)
			mkdir(SAVE_DIR_NO_SLASH, 0777);   /* la primera vez; si falla, save_write devuelve false */
		made = 1;
	}
	return SAVE_DIR;
}

/* Nombre plano (letras, numeros, _ . -) de hasta 80 caracteres -> ruta completa; -1 si no sirve. */
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

/* ---------- guardado en un hilo aparte (tarea 12, tirones) ----------
 * Balatro guarda la partida en medio del juego (save_run) y escribir en el pendrive frenaba el frame.
 * l360.save_write copia los datos, los deja en una cola y vuelve enseguida con true; un hilo propio
 * (SAVE_HW_THREAD, lejos del hilo 0 que corre Lua) los escribe en orden. Lo que ve Lua no cambia:
 *  - save_read de un archivo que todavia esta en la cola devuelve lo que se mando a escribir.
 *  - Si un archivo esta dos veces en la cola sin empezar, se escribe solo el ultimo.
 *  - Las dos ranuras de love360_save.lua (.a y .b, por turno) siguen cuidando que un corte de luz a
 *    mitad de una escritura deje la otra entera: el hilo escribe una ranura por vez, en orden.
 *  - Un error al escribir sale en el registro desde el hilo principal (l360_sys_poll), no desde el
 *    hilo de escritura, que no toca el registro ni Lua.
 *  - Antes de salir a Aurora se espera a que la cola se vacie (SAVE_FLUSH_MS como mucho).
 *  - Si el hilo no arranca o no hay memoria para la copia, se escribe como antes, en el momento.
 * "guardado_directo" en game:\l360_gfx.txt lo apaga (todo como antes). */
enum {
	SAVE_HW_THREAD = 3,               /* nucleo 1, con el mezclador de audio (2); no el 0 de Lua */
	SAVE_STACK = 64 * 1024,
	SAVE_QUEUE_MAX = 16 * 1024 * 1024,   /* mas que esto en cola: save_write espera (nunca paso) */
	SAVE_FLUSH_MS = 5000,
};

typedef struct save_job {
	struct save_job *next;
	char path[200];
	char *data;
	size_t len;
	double queued_at;                 /* now_s() al encolar */
} save_job_t;

static pthread_mutex_t save_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t save_cv = PTHREAD_COND_INITIALIZER;       /* hay trabajo */
static pthread_cond_t save_done_cv = PTHREAD_COND_INITIALIZER;  /* termino uno */
static save_job_t *save_head, *save_tail;   /* sin empezar, en orden */
static save_job_t *save_busy;               /* el que se esta escribiendo (lo lee save_read) */
static size_t save_queued_bytes;
static int save_thread_state;               /* 0 sin arrancar, 1 andando, -1 no arranco: directo */
static int save_direct;                     /* "guardado_directo" en l360_gfx.txt */
static HANDLE save_thread;
/* Lo que el hilo deja para que el principal lo anote (bajo save_mu) */
static char save_note[8][300];
static int save_notes;

static int write_file(const char *path, const char *data, size_t len)
{
	int ok = 0;
	FILE *f = fopen(path, "wb");
	if (f) {
		ok = fwrite(data, 1, len, f) == len;
		if (fclose(f))          /* aca tambien hay que cerrar bien: la FAT se escribe al cerrar */
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

/* Encola una copia de data para path. 0 si no se pudo (sin hilo o sin memoria): el que llama escribe. */
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
	/* el mismo archivo sin empezar: se reemplazan sus datos (se escribe solo el ultimo) */
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

/* Si path esta en la cola (o escribiendose), lo empuja a Lua y da 1: lo ultimo que se mando gana. */
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

/* Lo que dejo el hilo de escritura, al registro (desde el hilo principal, una vez por frame). */
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
	l360_log("  [save] guardado_directo: writing synchronously, without a separate thread");
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

/* ---------- registro y archivos en game:\ ---------- */

/* upload(nombre, datos): en libXenon subia a la PC por TFTP; aca escribe game:\<nombre>. */
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

/* El registro de xsdk (game:\<nombre del .xex>.log, default.log en la consola) se escribe linea
 * por linea con NtWriteFile: cuando l360.upload_log() vuelve ya esta en el disco, sin buffer que
 * vaciar y sin PC a la que subirlo. Se deja la funcion porque love360_boot.lua la llama. */
static int l_upload_log(lua_State *L)
{
	(void)L;
	return 0;
}

/* ---------- red ---------- */

/* poll(): en libXenon atiende la red; aca no hay red que atender (el registro puede ir por el
 * net_log.txt de xsdk, que no necesita que el juego haga nada). */
static int l_poll(lua_State *L)
{
	(void)L;
	return 0;
}

/* ---------- lo que llama main.c ---------- */

void l360_sys_poll(void)
{
	save_log_notes();
	sample_pads();
	check_exit();
}

void l360_sys_register(lua_State *L)
{
	/* la primera vez sin nada en game:\save\: pasa la partida de la version de libXenon
	 * (game:\guardado\, que solo se lee) antes de que el boot lea los guardados */
	(void)l360_import_saves("game:/guardado/", save_dir(), l360_log);
	lua_pushcfunction(L, l_pad);         lua_setfield(L, -2, "pad");
	lua_pushcfunction(L, l_rumble);      lua_setfield(L, -2, "rumble");
	lua_pushcfunction(L, l_poll);        lua_setfield(L, -2, "poll");
	lua_pushcfunction(L, l_fetch_start); lua_setfield(L, -2, "fetch_start");
	lua_pushcfunction(L, l_fetch_step);  lua_setfield(L, -2, "fetch_step");
	lua_pushcfunction(L, l_upload);      lua_setfield(L, -2, "upload");
	lua_pushcfunction(L, l_upload_log);  lua_setfield(L, -2, "upload_log");
	lua_pushcfunction(L, l_save_dir);    lua_setfield(L, -2, "save_dir");
	lua_pushcfunction(L, l_save_read);   lua_setfield(L, -2, "save_read");
	lua_pushcfunction(L, l_save_write);  lua_setfield(L, -2, "save_write");
}
