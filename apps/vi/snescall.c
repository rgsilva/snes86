/*
 * snescall.c — the snes86 backend for levee: MS-DOS 2.0 + HLE BIOS.
 *
 * This replaces levee's bit-rotted doscall.c (which needed ANSI.SYS
 * and Microsoft C's crawcin()).  Everything on the screen goes through
 * BIOS INT 10h — the snes86 HLE BIOS has no ANSI.SYS and never will —
 * and all keyboard input comes from INT 16h, so Esc, Ctrl and the
 * arrow keys arrive raw, exactly the way vi wants them.
 *
 * DOS 2.0 discipline: every file operation here bottoms out in the
 * INT 21h handle calls (3Ch/3Dh/3Fh/40h/41h/42h/56h) plus FindFirst/
 * FindNext (4Eh/4Fh) — all present in DOS 2.0.  Nothing from the
 * DOS 3+ era is used (no exec-by-path, no 58h+, no ioctls).
 *
 * Screen strategy: one primitive — write char+attr at the tracked
 * cursor cell (INT 10h AH=09h, always CX=1: the SNES BIOS writes a
 * single cell) then reposition with AH=02h.  Teletype (AH=0Eh) is
 * used only where its scroll-at-bottom behaviour is wanted.  The
 * levee display layer's os_* hooks all return 1 ("handled"), so the
 * termcap machinery is never consulted; the tgetent/tgoto stubs at
 * the bottom exist only to satisfy the linker.
 *
 * Distributed under the same terms as levee itself (see levee/COPYRIGHT):
 * Copyright (c) 1982-2007 David L Parsons.  This backend was written
 * for the snes86 project in 2026 acknowledging that levee was developed
 * by David L Parsons (orc@pell.portland.or.us).
 */
#include "levee.h"
#include "extern.h"

#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <io.h>
#include <sys/stat.h>
#include <dos.h>
#include <i86.h>
#include <bios.h>
#include <malloc.h>

/* The Watcom near heap grows in _amblksiz chunks (default 32 KB).  On
 * the 108 KB machine vi loads with only ~8 KB of DOS memory to spare,
 * so a 32 KB sbrk fails before main() ("Not enough memory to allocate
 * file structures").  Grow gently instead: this definition overrides
 * the one in clibs.lib.
 */
unsigned int _amblksiz = 1024;

/* ---------------------------------------------------------------- */
/* file i/o (INT 21h handle calls via the Watcom runtime)            */

FILEDESC
OPEN_OLD(char *name)
{
    int fd = open(name, O_RDONLY | O_BINARY);

    return (fd == -1) ? NOWAY : (FILEDESC)fd;
}

FILEDESC
OPEN_NEW(char *name)
{
    int fd = open(name, O_WRONLY | O_CREAT | O_TRUNC | O_BINARY,
		  S_IREAD | S_IWRITE);

    return (fd == -1) ? NOWAY : (FILEDESC)fd;
}

int
CLOSE_FILE(FILEDESC f)
{
    return close((int)f);
}

long
SEEK_POSITION(FILEDESC f, long offset, int mode)
{
    return lseek((int)f, offset, mode);
}

int
READ_TEXT(FILEDESC f, void *buf, int size)
{
    return read((int)f, buf, size);
}

int
WRITE_TEXT(FILEDESC f, void *buf, int size)
{
    return write((int)f, buf, size);
}

int
os_unlink(char *name)
{
    return unlink(name);
}

int
os_rename(char *from, char *to)
{
    unlink(to);			/* DOS rename fails onto an existing file */
    return rename(from, to);
}

/* tempfile names: single-tasking machine, so a fixed name per template
 * is unique enough.  "$un" -> LV$UN.TMP ('$' is legal in DOS names).
 * %TMP% picks the directory; on the SNES that should be B:\ (C: is
 * read-only), on the runpc work floppy the current drive is writable.
 */
int
os_mktemp(char *dest, int size, const char *template)
{
    char *tmp = getenv("TMP");
    int need = (tmp ? strlen(tmp) : 0) + 1 + 2 + strlen(template) + 4 + 1;
    char *p;

    if (size <= need) {
	errno = E2BIG;
	return 0;
    }

    dest[0] = 0;
    if (tmp && *tmp) {
	strcpy(dest, tmp);
	p = dest + strlen(dest) - 1;
	if (*p != '\\' && *p != '/' && *p != ':')
	    strcat(dest, "\\");
    }
    strcat(dest, "LV");
    strcat(dest, template);
    strcat(dest, ".TMP");
    return 1;
}

/* backups (:set backup): FILE.EXT -> FILE.BAK */
char *
os_backupname(char *file)
{
    char *p = malloc(strlen(file) + 5);
    char *dot, *slash;

    unless (p)
	return 0;
    strcpy(p, file);
    dot = strrchr(p, '.');
    slash = strrchr(p, '\\');
    if (dot && (!slash || dot > slash) && dot != p)
	*dot = 0;
    strcat(p, ".BAK");
    return p;
}

char *
os_tilde(char *path)
{
    return 0;			/* no home directories on DOS 2.0 */
}

/* ---------------------------------------------------------------- */
/* screen (BIOS INT 10h)                                             */

#define NORMAL	0x07
#define REVERSE	0x70

static int scr_x, scr_y;	/* tracked cursor */
static unsigned char attr = NORMAL;

static void
bios_setxy(int x, int y)
{
    union REGS r;

    r.h.ah = 0x02;
    r.h.bh = 0;
    r.h.dh = (unsigned char)y;
    r.h.dl = (unsigned char)x;
    int86(0x10, &r, &r);
    scr_x = x;
    scr_y = y;
}

/* write one char+attr at the cursor cell (no cursor movement) */
static void
bios_cell(unsigned char c)
{
    union REGS r;

    r.h.ah = 0x09;
    r.h.al = c;
    r.h.bh = 0;
    r.h.bl = attr;
    r.w.cx = 1;			/* SNES BIOS writes exactly one cell */
    int86(0x10, &r, &r);
}

static void
bios_tty(unsigned char c)
{
    union REGS r;

    r.h.ah = 0x0E;
    r.h.al = c;
    r.h.bh = 0;
    int86(0x10, &r, &r);
}

/* scroll a full-width window: up=6/down=7, top..bot, n lines (0=clear) */
static void
bios_scroll(int fn, int top, int bot, int n)
{
    union REGS r;

    r.h.ah = (unsigned char)fn;
    r.h.al = (unsigned char)n;
    r.h.bh = NORMAL;
    r.h.ch = (unsigned char)top;
    r.h.cl = 0;
    r.h.dh = (unsigned char)bot;
    r.h.dl = (unsigned char)(COLS ? COLS - 1 : 79);
    int86(0x10, &r, &r);
}

int
os_gotoxy(int x, int y)
{
    bios_setxy(x, y);
    return 1;
}

int
os_write(char *s, int len)
{
    while (len-- > 0) {
	unsigned char c = (unsigned char)*s++;

	if (c == '\r') {
	    bios_setxy(0, scr_y);
	} else if (c == '\n') {
	    bios_tty('\n');	/* teletype: scrolls at the bottom row */
	    if (scr_y < LINES - 1)
		scr_y++;
	    bios_setxy(scr_x, scr_y);
	} else if (c == '\b') {
	    if (scr_x > 0)
		bios_setxy(scr_x - 1, scr_y);
	} else if (c == 7) {
	    bios_tty(7);
	} else {
	    bios_cell(c);
	    if (scr_x < COLS - 1)	/* clamp at the right edge; levee */
		scr_x++;		/* wraps lines itself */
	    bios_setxy(scr_x, scr_y);
	}
    }
    return 1;
}

int
os_newline(void)
{
    bios_tty('\r');
    bios_tty('\n');
    if (scr_y < LINES - 1)
	scr_y++;
    scr_x = 0;
    return 1;
}

int
os_clear_to_eol(void)
{
    int x = scr_x, y = scr_y;
    int i;

    for (i = x; i < COLS; i++) {
	bios_setxy(i, y);
	bios_cell(' ');
    }
    bios_setxy(x, y);
    return 1;
}

int
os_clearscreen(void)
{
    bios_scroll(0x06, 0, LINES ? LINES - 1 : 24, 0);
    bios_setxy(0, 0);
    return 1;
}

/* insert a blank line at the cursor row (push the rest down) */
int
os_openline(void)
{
    bios_scroll(0x07, scr_y, LINES - 1, 1);
    return 1;
}

/* scroll the whole screen back (down) one line */
int
os_scrollback(void)
{
    bios_scroll(0x07, 0, LINES - 1, 1);
    return 1;
}

int
os_cursor(int visible)
{
    union REGS r;

    r.h.ah = 0x01;
    r.w.cx = visible ? 0x0607 : 0x2607;
    int86(0x10, &r, &r);
    return 1;
}

int
os_highlight(int on)
{
    attr = on ? REVERSE : NORMAL;
    return 1;
}

int
os_Ping(void)
{
    bios_tty(7);
    return 1;
}

int
os_screensize(int *x, int *y)
{
    union REGS r;

    r.h.ah = 0x0F;		/* get video mode: AH = columns */
    int86(0x10, &r, &r);
    *x = r.h.ah ? r.h.ah : 80;
    *y = 25;
    return 1;
}

/* ---------------------------------------------------------------- */
/* keyboard (BIOS INT 16h)                                           */

int
getKey(void)
{
    unsigned k = _bios_keybrd(_KEYBRD_READ);
    unsigned char al = (unsigned char)k;
    unsigned char scan = (unsigned char)(k >> 8);

    if (al == 0 || al == 0xE0) {	/* extended key */
	switch (scan) {
	case 0x4B: return LTARROW;
	case 0x4D: return RTARROW;
	case 0x48: return UPARROW;
	case 0x50: return DNARROW;
	case 0x49: return 'U' - '@';	/* PgUp -> ^U */
	case 0x51: return 'D' - '@';	/* PgDn -> ^D */
	default:   return 0;
	}
    }
    return al;
}

void
set_input(void)
{
    /* raw BIOS input needs no setup */
}

void
reset_input(void)
{
}

int
os_initialize(void)
{
    TERMNAME = "snes86 bios";
    BELL = "\007";

    CA = TRUE;			/* cursor addressable: visual mode on */
    canUPSCROLL = TRUE;		/* os_scrollback works */
    canOL = TRUE;		/* os_openline works */

    Erasechar = '\b';		/* ^H */
    Eraseline = 21;		/* ^U */

    os_screensize(&COLS, &LINES);
    return 1;
}

int
os_restore(void)
{
    os_highlight(0);
    os_cursor(1);
    return 1;
}

int
os_cclass(unsigned int c)
{
    if (c == '\t' && !list)
	return CC_TAB;
    if (c == 127 || c < ' ')
	return CC_CTRL;
    return CC_PRINT;		/* 0x80+ is CP437, printable */
}

char *
dotfile(void)
{
    return "lv.rc";
}

/* ---------------------------------------------------------------- */
/* no pipes, no fork: :! and friends are switched off                */

int
os_subshell(char *cmd)
{
    prints("[no shell on this machine]");
    return -1;
}

FILE *
os_cmdopen(char *cmd, char *input, os_pid_t *pid)
{
    return 0;
}

int
os_cmdclose(FILE *f, os_pid_t pid)
{
    return -1;
}

/* ---------------------------------------------------------------- */
/* wildcards: FindFirst/FindNext (INT 21h 4Eh/4Fh — DOS 2.0 safe).   */
/* Lifted from levee's wincall.c, retargeted at _dos_findfirst().    */

static char *
lvbasename(char *s)
{
    char *p;

    for (p = s + strlen(s); p > s; --p)
	if (p[-1] == '/' || p[-1] == '\\' || p[-1] == ':')
	    return p;
    return s;
}

void
lowercase(char *s)		/* declared in extern.h; the *call.c
				 * backends traditionally provide it */
{
    for (; *s; s++)
	if (isupper(*s))
	    *s += 32;
}

static int
glob_addfile(char *file, int count, glob_t *result)
{
    char **newlist;

    if (count >= result->gl_pathalloc) {
	result->gl_pathalloc += 20;
	if (result->gl_pathv)
	    newlist = realloc(result->gl_pathv,
			      result->gl_pathalloc * sizeof result->gl_pathv[0]);
	else
	    newlist = calloc(result->gl_pathalloc,
			     sizeof result->gl_pathv[0]);
	unless (newlist)
	    return GLOB_NOSPACE;
	result->gl_pathv = newlist;
    }

    unless (result->gl_pathv[count - 1] = malloc(strlen(file) + 2))
	return GLOB_NOSPACE;

    strcpy(result->gl_pathv[count - 1], file);
    result->gl_pathv[count] = 0;
    result->gl_pathc++;
    result->gl_matchc = 1;
    return 0;
}

static int
glob_wildcard(char *path, int permit_nomatch, int count, glob_t *dta)
{
    char path_bfr[80];		/* DOS paths are short */
    char *file_part;
    struct find_t entry;
    int st;

    if (strlen(path) + 14 > sizeof path_bfr)
	return -1;

    strcpy(path_bfr, path);
    file_part = lvbasename(path_bfr);

    if (_dos_findfirst(path, _A_NORMAL | _A_RDONLY | _A_ARCH, &entry)) {
	return permit_nomatch ? glob_addfile(path, count, dta) : -1;
    }

    do {
	lowercase(entry.name);
	strcpy(file_part, entry.name);
	if (glob_addfile(path_bfr, count, dta))
	    return -1;
	++count;
	st = _dos_findnext(&entry);
    } while (st == 0);

    return 0;
}

int
os_glob(const char *pattern, int flags, glob_t *result)
{
    int count;

    if (result->gl_pathc == 0)
	result->gl_flags = flags;

    count = 1 + ((result->gl_flags & GLOB_DOOFFS) ? result->gl_offs : 0);
    if (result->gl_flags & GLOB_APPEND)
	count += result->gl_pathc;

    unless (flags & GLOB_NOMAGIC) {
	if (strcspn(pattern, "?*") < strlen(pattern)) {
	    int stat;

	    result->gl_flags |= GLOB_MAGCHAR;
	    stat = glob_wildcard((char *)pattern,
				 result->gl_flags & GLOB_NOCHECK,
				 count, result);
	    return stat ? GLOB_NOMATCH : 0;
	}
	else
	    result->gl_flags &= ~GLOB_MAGCHAR;
    }

    return glob_addfile((char *)pattern, count, result);
}

void
os_globfree(glob_t *collection)
{
    int x, start;

    start = (collection->gl_flags & GLOB_DOOFFS) ? collection->gl_offs : 0;

    for (x = 0; x < collection->gl_pathc; x++)
	if (collection->gl_pathv[start + x])
	    free(collection->gl_pathv[start + x]);
    if (collection->gl_pathc)
	free(collection->gl_pathv);
    memset(collection, 0, sizeof collection[0]);
}

/* ---------------------------------------------------------------- */
/* termcap stubs: os_initialize() returns 1, so the termcap paths in */
/* display.c are dead code — these exist only to satisfy the linker. */

int
tgetent(char *buf, char *term)
{
    return -1;
}

char *
tgetstr(char *id, char **area)
{
    return 0;
}

int
tgetnum(char *id)
{
    return -1;
}

char *
tgoto(char *cm, int col, int row)
{
    return "";
}
