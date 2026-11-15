#ifndef L360_IMPORTAR_H
#define L360_IMPORTAR_H
/* Pasar el guardado de la version de libXenon (tarea 11, item 3). Va aparte de l360_sys.c para
 * probarlo en la PC con carpetas temporales (pruebas/importar_guardado_pc). */

/* Si to_dir no tiene ningun l360save_* y from_dir si, copia los l360save_* de from_dir a to_dir.
 * from_dir solo se lee: nunca se escribe, se renombra ni se borra ahi (es la partida real del
 * dueno). Las copias van primero con nombre .tmp y se renombran recien cuando salieron todas, asi un
 * corte a mitad no deja un to_dir a medias que frene la proxima vez. Las carpetas terminan en '/'.
 * Devuelve los archivos copiados (0 si no hacia falta), o -1 si fallo (to_dir queda como estaba). */
int l360_import_saves(const char *from_dir, const char *to_dir, void (*log)(const char *));

#endif
