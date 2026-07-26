/*
 * config.h for levee on snes86 — MS-DOS 2.0, 8086, Open Watcom v2,
 * small memory model.  Hand-written (levee's configure.sh is a unix
 * shell script; this is what --dos would have produced, tuned for
 * the 108 KB machine).
 *
 * The screen/keyboard layer lives in snescall.c: BIOS INT 10h for
 * output (no ANSI.SYS on this machine) and INT 16h for input.
 */
#ifndef __AC_LEVEE_D
#define __AC_LEVEE_D 1

#include <stdlib.h>

#define OS_DOS 1
#define os_pid_t int

/* 16 KB edit buffer: indices live in 16-bit ints (<= 32767) and the
 * whole DGROUP (buffer + yank + undo + globals + stack) must stay
 * under 64 KB in the small model — and the whole program must load on
 * the 108 KB machine.  16 K is plenty for the SNES's battery-backed
 * B: drive files.
 */
#define EDITSIZE 16384

#define GLOB_REQUIRED 1

#define HAVE_STRING_H 1
#define HAVE_MEMSET 1
#define HAVE_STRCHR 1
#define HAVE_STRDUP 1
#define HAVE_ERRNO_H 1
#define HAVE_UNISTD_H 1   /* Watcom: getopt()/optind/optarg live here */
#define HAVE_SYS_TYPES_H 1

#endif /* __AC_LEVEE_D */
