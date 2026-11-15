#ifndef L360_GFX_H
#define L360_GFX_H
/* l360.gfx sobre la GPU de xsdk (tarea 07). La misma API para Lua que runtime/source/l360_gfx.h;
 * cambia el arranque: la GPU y la pantalla ya las abrio main.c (pantalla de texto). */
#include <stdint.h>
#include "lua.h"
typedef struct {
    long draws, sends, skipped, dropped, frames, missing_images;
    long texture_bytes;
    unsigned long image_ms, gpu_wait_ms;
    /* cuando empezo y termino el ultimo sync y el ultimo present (ms de CLOCK_MONOTONIC), para que
     * main.c parta en pedazos los frames lentos */
    double sync_at, sync_end_at, present_at, present_end_at;
} l360_gfx_stats_t;
extern l360_gfx_stats_t l360_gfx_stats;
/* Con la GPU y xsdk_present ya abiertos (w x h): carga los shaders de game:\shaders\ y reserva los
 * vertices. 0 si anduvo; si no, el motivo ya fue al registro y main.c sigue con la pantalla de texto. */
int  l360_gfx_init(uint32_t w, uint32_t h, void (*log)(const char *));
void l360_gfx_register(lua_State *L);          /* deja en la pila la tabla de love.graphics */
void l360_gfx_set_missing_cb(void (*cb)(const char *));
/* Despues de que main.c dibuja la pantalla de texto (cambia target, shaders, stream 0 y slot 0) */
void l360_gfx_forget_state(void);
int  l360_gfx_width(void);
int  l360_gfx_height(void);
#endif
