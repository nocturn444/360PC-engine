/*
 * Love360 sobre xsdk: mando, archivos, guardado y salida (tarea 05 fase 4, tarea 08).
 *
 * Va en un archivo aparte de main.c para no chocar con la fase 2 (graficos), que trabaja en el
 * mismo main.c. Lo unico que main.c tiene que hacer es llamar a l360_sys_register(L) cuando arma
 * la tabla l360 y a l360_sys_poll() donde mira el mando (dentro de l360.poll_input).
 */
#ifndef L360_SYS_H
#define L360_SYS_H

#include "lua.h"

/* main.c lo implementa: una linea al registro de xsdk (game:\<titulo>.log) y a la pantalla. */
void l360_log(const char *s);
/* main.c lo implementa: espera (3 s como mucho) a que el hilo del registro escriba lo que quedo en
 * la cola. Lo llama la salida a Aurora. */
void l360_log_flush(void);

/* Agrega a la tabla que esta en la cima de la pila (la tabla l360) los campos de esta fase:
 * pad, rumble, poll, fetch_start, fetch_step, upload, upload_log, filetype, listdir, quit,
 * save_set_dir, save_dir, save_read y save_write. poll_input lo pone main.c, que es quien llama a l360_sys_poll(). Deja la tabla
 * donde estaba. */
void l360_sys_register(lua_State *L);

/* Una vez por frame: lee los mandos con XamInputGetState y mira la salida (Back + Start 2 s).
 * l360.pad y l360.rumble usan el estado que leyo esto; no leen el mando por su cuenta. */
void l360_sys_poll(void);

/* Suma lo que bajaron fetch_start/fetch_step a lo que informa l360.readstats() (los contadores
 * de l360.read viven en main.c). */
void l360_sys_readstats(int *files, double *bytes, double *ms);

/* Lista de lo que hay en cada carpeta de game:\ (tarea 12, tirones): en el pendrive,
 * abrir un archivo que no esta tardaba hasta 872 ms. l360_sys_list_dir(dir) lista
 * esa carpeta ya; las demas se listan la primera vez que se lee algo
 * de ellas. l360_sys_game_missing(ruta) da 1 solo si la carpeta se listo entera y ruta no esta:
 * entonces ni se intenta abrir. l360_sys_list_off() la apaga ("sin_lista" en l360_gfx.txt). */
void l360_sys_list_dir(const char *dir);
int l360_sys_game_missing(const char *path);
void l360_sys_list_off(void);

/* Guardado en un hilo aparte (tarea 12): save_write encola y vuelve. l360_sys_save_flush() espera a
 * que se escriba lo que quedo (lo llama la salida a Aurora). l360_sys_save_direct() lo apaga
 * ("guardado_directo" en l360_gfx.txt): se escribe en el momento, como antes. */
void l360_sys_save_flush(void);
void l360_sys_save_direct(void);

#endif
