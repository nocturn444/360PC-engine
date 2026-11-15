/*
 * Love360 on xsdk: controller, files, saving and exit (task 05 phase 4, task 08).
 *
 * It lives in its own file, apart from main.c, so it does not clash with phase 2 (graphics), which
 * works in the same main.c. The only thing main.c has to do is call l360_sys_register(L) when it
 * builds the l360 table, and l360_sys_poll() where it reads the controller (inside l360.poll_input).
 */
#ifndef L360_SYS_H
#define L360_SYS_H

#include "lua.h"

/* main.c implements it: one line to the xsdk log (game:\<title>.log) and to the screen. */
void l360_log(const char *s);
/* main.c implements it: waits (3 s at most) for the log thread to write what is left in
 * the queue. Called on the exit to Aurora. */
void l360_log_flush(void);

/* Adds to the table on top of the stack (the l360 table) the fields of this phase:
 * pad, rumble, poll, fetch_start, fetch_step, upload, upload_log, filetype, listdir, quit,
 * save_set_dir, save_dir, save_read and save_write. main.c sets poll_input, since it is the one
 * that calls l360_sys_poll(). Leaves the table where it was. */
void l360_sys_register(lua_State *L);

/* Once per frame: reads the controllers with XamInputGetState and checks for exit (Back + Start 2 s).
 * l360.pad and l360.rumble use the state read here; they do not read the controller on their own. */
void l360_sys_poll(void);

/* Adds what fetch_start/fetch_step downloaded to what l360.readstats() reports (the l360.read
 * counters live in main.c). */
void l360_sys_readstats(int *files, double *bytes, double *ms);

/* Listing of what is in each game:\ folder (task 12, hitches): on the USB stick, opening a file
 * that is not there took up to 872 ms. l360_sys_list_dir(dir) lists that folder now; the others
 * are listed the first time something is read from them. l360_sys_game_missing(path) returns 1
 * only if the folder was listed in full and path is not in it: then it is not even opened.
 * l360_sys_list_off() turns it off ("sin_lista" in l360_gfx.txt). */
void l360_sys_list_dir(const char *dir);
int l360_sys_game_missing(const char *path);
void l360_sys_list_off(void);

/* Saving on a separate thread (task 12): save_write queues and returns. l360_sys_save_flush() waits
 * until what is left is written (called on the exit to Aurora). l360_sys_save_direct() turns it off
 * ("guardado_directo" in l360_gfx.txt): it writes right away, as before. */
void l360_sys_save_flush(void);
void l360_sys_save_direct(void);

#endif
