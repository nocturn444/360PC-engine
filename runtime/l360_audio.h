#ifndef L360_AUDIO_H
#define L360_AUDIO_H

#include <stdint.h>
#include "lua.h"

/* Sonido sobre xsdk (tarea 09): el mezclador de runtime/source/l360_audio.c con salida por
 * xsdk_audio_* desde un hilo propio. La interfaz para Lua (tabla l360.audio) es la de docs/audio.md. */

int  l360_audio_init(void);      /* xsdk_audio_open + arranca el feeder; 0 si salio bien, si no el NTSTATUS */
void l360_audio_close(void);     /* al salir: xsdk_audio_close y espera al feeder (corto); se puede repetir */
void l360_audio_update(void);    /* libera buffers pendientes; una vez por frame */
void l360_audio_register(lua_State *L); /* deja la tabla l360.audio en la pila */

/* Decodifica un bloque IMA ADPCM mono (WAV formato 0x11) de `bytes` bytes en 1 + 2 * (bytes - 4)
 * muestras; devuelve cuantas escribio. La usa el mezclador; publica para la prueba contra ffmpeg. */
uint32_t l360_adpcm_decode_mono(const uint8_t *blk, uint32_t bytes, int16_t *out);

#endif
