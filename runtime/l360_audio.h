#ifndef L360_AUDIO_H
#define L360_AUDIO_H

#include <stdint.h>
#include "lua.h"

/* Sound over xsdk (task 09): the mixer in runtime/source/l360_audio.c with output through
 * xsdk_audio_* from its own thread. The Lua interface (l360.audio table) is the one in docs/audio.md. */

int  l360_audio_init(void);      /* xsdk_audio_open + starts the feeder; 0 on success, otherwise the NTSTATUS */
void l360_audio_close(void);     /* on exit: xsdk_audio_close and wait for the feeder (brief); may be called again */
void l360_audio_update(void);    /* frees pending buffers; once per frame */
void l360_audio_register(lua_State *L); /* leaves the l360.audio table on the stack */

/* Decodes one mono IMA ADPCM block (WAV format 0x11) of `bytes` bytes into 1 + 2 * (bytes - 4)
 * samples; returns how many were written. Used by the mixer; public for the test against ffmpeg. */
uint32_t l360_adpcm_decode_mono(const uint8_t *blk, uint32_t bytes, int16_t *out);

#endif
