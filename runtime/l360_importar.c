/*
 * Love360 sobre xsdk: pasar el guardado de la version de libXenon a game:\save\ (tarea 11, item 3).
 *
 * La version de libXenon guardaba en <usb>:\love360\guardado\, que en el pendrive del dueno es la
 * misma carpeta que xsdk ve como game:\guardado\. La de xsdk guarda en game:\save\. La primera vez
 * que arranca sin nada en save\, copia lo que haya en guardado\ y lo anota en el registro.
 * guardado\ solo se lee: es la partida real del dueno (AGENTS.md).
 */
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "l360_importar.h"

enum { NAME_MAX_CHARS = 80, MAX_FILES = 64 };
#define PREFIX "l360save_"

/* Un nombre de guardado de Love360: l360save_ y despues letras, numeros, _ . - (como save_path) */
static int is_save_name(const char *name)
{
	size_t n = strlen(name);
	if (n <= strlen(PREFIX) || n > NAME_MAX_CHARS || strncmp(name, PREFIX, strlen(PREFIX)))
		return 0;
	for (const char *p = name; *p; p++)
		if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9')
		      || *p == '_' || *p == '.' || *p == '-'))
			return 0;
	return 1;
}

/* Los l360save_* de una carpeta, hasta MAX_FILES; -1 si no se puede abrir */
static int list_saves(const char *dir, char names[][NAME_MAX_CHARS + 1])
{
	DIR *d = opendir(dir);
	if (!d)
		return -1;
	int n = 0;
	struct dirent *e;
	while ((e = readdir(d)) && n < MAX_FILES)
		if (is_save_name(e->d_name))
			snprintf(names[n++], NAME_MAX_CHARS + 1, "%s", e->d_name);
	closedir(d);
	return n;
}

/* dir + name + ext en out; -1 si no entra (sin snprintf: el GCC de -Werror no ve que entra) */
static int join(char *out, size_t n, const char *dir, const char *name, const char *ext)
{
	size_t a = strlen(dir), b = strlen(name), c = strlen(ext);
	if (a + b + c + 1 > n)
		return -1;
	memcpy(out, dir, a);
	memcpy(out + a, name, b);
	memcpy(out + a + b, ext, c + 1);
	return 0;
}

/* Copia from (solo lectura) a to; 0 si salio entero */
static int copy_file(const char *from, const char *to)
{
	FILE *in = fopen(from, "rb");
	if (!in)
		return -1;
	FILE *out = fopen(to, "wb");
	if (!out) {
		fclose(in);
		return -1;
	}
	static char buf[16384];
	size_t got;
	int ok = 1;
	while ((got = fread(buf, 1, sizeof(buf), in)) > 0)
		if (fwrite(buf, 1, got, out) != got) {
			ok = 0;
			break;
		}
	if (ferror(in))
		ok = 0;
	fclose(in);
	if (fclose(out))                     /* la FAT se escribe al cerrar */
		ok = 0;
	return ok ? 0 : -1;
}

int l360_import_saves(const char *from_dir, const char *to_dir, void (*log)(const char *))
{
	static char have[MAX_FILES][NAME_MAX_CHARS + 1], old[MAX_FILES][NAME_MAX_CHARS + 1];
	char line[400], from[256], tmp[256], to[256];
	if (list_saves(to_dir, have) > 0)
		return 0;                        /* ya hay partida nueva: no se toca nada */
	int n = list_saves(from_dir, old);
	if (n <= 0)
		return 0;                        /* no hay guardado de libXenon (o no esta la carpeta) */
	int i;
	for (i = 0; i < n; i++) {
		if (join(from, sizeof(from), from_dir, old[i], "") || join(tmp, sizeof(tmp), to_dir, old[i], ".tmp")
		    || copy_file(from, tmp))
			break;
	}
	if (i < n) {
		snprintf(line, sizeof(line), "save: could not copy %.100s%.80s to %.100s; continuing without importing the old save",
			 from_dir, old[i], to_dir);
		if (log) log(line);
		for (int k = 0; k <= i && k < n; k++) {   /* solo en to_dir: los .tmp que alcanzaron a salir */
			if (!join(tmp, sizeof(tmp), to_dir, old[k], ".tmp"))
				remove(tmp);
		}
		return -1;
	}
	for (i = 0; i < n; i++) {
		if (join(tmp, sizeof(tmp), to_dir, old[i], ".tmp") || join(to, sizeof(to), to_dir, old[i], "")
		    || rename(tmp, to)) {
			snprintf(line, sizeof(line), "save: could not rename %.200s", tmp);
			if (log) log(line);
			return -1;
		}
	}
	snprintf(line, sizeof(line), "save: copied %d files from the libXenon version (%.80s) to %.80s; %.80s is left unchanged",
		 n, from_dir, to_dir, from_dir);
	if (log) log(line);
	return n;
}
