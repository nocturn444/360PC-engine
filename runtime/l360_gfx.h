#ifndef L360_GFX_H
#define L360_GFX_H
/* l360.gfx on the xsdk GPU (task 07). Same Lua API as runtime/source/l360_gfx.h;
 * startup differs: the GPU and screen were already opened by main.c (text screen). */
#include <stdint.h>
#include "lua.h"
typedef struct {
    long draws, sends, skipped, dropped, frames, missing_images;
    long texture_bytes;
    unsigned long image_ms, gpu_wait_ms;
    /* when the last sync and last present started and ended (CLOCK_MONOTONIC ms), so that
     * main.c can split slow frames into pieces */
    double sync_at, sync_end_at, present_at, present_end_at;
} l360_gfx_stats_t;
extern l360_gfx_stats_t l360_gfx_stats;
/* With the GPU and xsdk_present already open (w x h): loads the shaders from game:\shaders\ and reserves the
 * vertices. 0 on success; otherwise the reason was already logged and main.c continues with the text screen. */
int  l360_gfx_init(uint32_t w, uint32_t h, void (*log)(const char *));
void l360_gfx_register(lua_State *L);          /* leaves the love.graphics table on the stack */
void l360_gfx_set_missing_cb(void (*cb)(const char *));
/* After main.c draws the text screen (changes target, shaders, stream 0 and slot 0) */
void l360_gfx_forget_state(void);
int  l360_gfx_width(void);
int  l360_gfx_height(void);
#endif
