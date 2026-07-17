/* runpc.c — boot a PC floppy image on the snes86 C core (host harness).
 *
 * M3 "boots DOS on the desktop": the validated 8086 core plus an HLE BIOS
 * (INT 10h/11h/12h/13h/16h/1Ah) wired to stdin/stdout and a floppy image.
 * No BIOS binary runs in the guest — the same strategy the SNES build will
 * use, so what boots here is what will boot there.
 *
 * Doubles as the M3.5 measuring rig: the guest instruction count from the
 * boot sector to the first keyboard wait (= interactive prompt) is recorded
 * and reported with SNES boot-time projections.
 *
 * usage: runpc [-m kb] [-c] [-v] [-l steps] [-w] image.img
 *   -m KB     conventional memory reported to the guest (default 256)
 *   -c        exit at the first keyboard wait, print stats
 *   -v        log the first occurrence of every INT xx/AH=yy (incl. DOS 21h)
 *   -l N      stop after N guest instructions
 *   -w        write modified disk image back to file on exit
 * Interactive keys go straight to the guest (raw mode); quit with Ctrl-].
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <termios.h>
#include <unistd.h>
#include <sys/select.h>
#include <sys/time.h>
#include "x86.h"

typedef struct {
    /* disk */
    uint8_t *disk;
    long     disksz;
    int      cyls, heads, spt;
    int      disk_dirty;
    /* fixed disk (DL=80h), read-only */
    uint8_t *hd;
    long     hdsz;
    int      hd_cyls, hd_heads, hd_spt;
    /* keyboard */
    int peek;          /* buffered key byte, -1 = none */
    int eof;           /* stdin exhausted (pipe mode) */
    int tty;
    /* config */
    int mem_kb;
    int count_mode;
    int verbose;
    /* stats */
    unsigned long long steps;
    unsigned long long prompt_steps;   /* steps at first INT 21h AH=0A */
    unsigned long long idle;           /* consecutive idle-loop INTs */
    unsigned long long int_count[256];
    unsigned long long rd_sectors, wr_sectors;
    uint8_t seen[256][32];             /* (int,ah) first-occurrence log */
    int exit_flag;
    const char *exit_reason;
    /* console cursor (approximate; enough for INT 10h AH=03) */
    int row, col, cols, vmode;
    struct timeval t0;
} Harness;

static volatile sig_atomic_t g_stop = 0;
static Harness *g_h;

/* CGA status port: retrace bits must toggle or direct-video programs
 * (Turbo Pascal!) spin forever waiting for retrace to end */
static uint8_t io_in8(X86 *c, uint16_t port)
{
    (void)c;
    if ((port & 0xFFF8) == 0x3D8) {
        unsigned long long s = g_h ? g_h->steps : 0;
        return (uint8_t)(((s >> 5) & 1) | (((s >> 11) & 1) << 3));
    }
    return 0xFF;
}
static int g_trace = 0;   /* -T: freeze INT 1Ah ticks for lockstep traces */
static void on_sigint(int sig) { (void)sig; g_stop = 1; }

/* ------------------------------------------------------------------ */
/* tty                                                                 */

static struct termios g_oldt;
static int g_rawset = 0;

static void tty_restore(void)
{
    if (g_rawset)
        tcsetattr(0, TCSANOW, &g_oldt);
}

static void tty_raw(void)
{
    struct termios t;
    if (tcgetattr(0, &t))
        return;
    g_oldt = t;
    t.c_lflag &= (tcflag_t)~(ICANON | ECHO | ISIG);
    t.c_iflag &= (tcflag_t)~(ICRNL | INLCR | IXON);
    t.c_cc[VMIN] = 1;
    t.c_cc[VTIME] = 0;
    tcsetattr(0, TCSANOW, &t);
    g_rawset = 1;
    atexit(tty_restore);
}

/* ------------------------------------------------------------------ */
/* guest memory / register helpers                                    */

static uint32_t glin(uint16_t seg, uint16_t off)
{
    return (((uint32_t)seg << 4) + off) & 0xFFFFF;
}

static uint8_t  rah(X86 *c) { return (uint8_t)(c->r[X86_AX] >> 8); }
static uint8_t  ral(X86 *c) { return (uint8_t)c->r[X86_AX]; }
static void sah(X86 *c, uint8_t v) { c->r[X86_AX] = (uint16_t)((c->r[X86_AX] & 0x00FF) | (v << 8)); }
static void sal(X86 *c, uint8_t v) { c->r[X86_AX] = (uint16_t)((c->r[X86_AX] & 0xFF00) | v); }

static void set_cf(X86 *c, int on)
{
    c->flags = on ? (c->flags | X86_CF) : (c->flags & (uint16_t)~X86_CF);
}

static void set_zf(X86 *c, int on)
{
    c->flags = on ? (c->flags | X86_ZF) : (c->flags & (uint16_t)~X86_ZF);
}

static void logcall(Harness *h, int n, uint8_t ah)
{
    if (!h->verbose)
        return;
    if (h->seen[n][ah >> 3] & (1u << (ah & 7)))
        return;
    h->seen[n][ah >> 3] |= (uint8_t)(1u << (ah & 7));
    fprintf(stderr, "[bios] first INT %02X AH=%02X at step %llu\n",
            n, ah, h->steps);
}

/* ------------------------------------------------------------------ */
/* INT 10h — video → stdout                                            */

static void tty_putc(Harness *h, uint8_t ch)
{
    putchar(ch);
    if (ch == '\r')      h->col = 0;
    else if (ch == '\n') h->row += (h->row < 24);
    else if (ch == 8)    h->col -= (h->col > 0);
    else if (ch >= 32 && ++h->col >= h->cols) { h->col = 0; h->row += (h->row < 24); }
}

static int bios_video(X86 *c, Harness *h)
{
    uint8_t ah = rah(c);
    switch (ah) {
    case 0x00:                                   /* set mode */
        h->vmode = ral(c) & 0x7F;
        h->cols = (h->vmode == 0 || h->vmode == 1) ? 40 : 80;
        if (h->tty) fputs("\033[2J\033[H", stdout);
        h->row = h->col = 0;
        break;
    case 0x01: break;                            /* cursor shape */
    case 0x02:                                   /* set cursor pos */
        h->row = (uint8_t)(c->r[X86_DX] >> 8);
        h->col = (uint8_t)c->r[X86_DX];
        break;
    case 0x03:                                   /* read cursor pos */
        c->r[X86_DX] = (uint16_t)((h->row << 8) | h->col);
        c->r[X86_CX] = 0x0607;
        break;
    case 0x05: break;                            /* select page */
    case 0x06: case 0x07:                        /* scroll up/down */
        if (ral(c) == 0 && h->tty) {             /* AL=0: clear window */
            fputs("\033[2J\033[H", stdout);
            h->row = h->col = 0;
        }
        break;
    case 0x08:                                   /* read char+attr */
        c->r[X86_AX] = 0x0720;
        break;
    case 0x09: case 0x0A: {                      /* write char (xN) */
        int n = c->r[X86_CX] ? c->r[X86_CX] : 1;
        for (int i = 0; i < n; i++)
            putchar(ral(c));
        break;
    }
    case 0x0E:                                   /* teletype */
        tty_putc(h, ral(c));
        break;
    case 0x0F:                                   /* get mode */
        c->r[X86_AX] = (uint16_t)((h->cols << 8) | h->vmode);
        c->r[X86_BX] &= 0x00FF;                  /* BH = page 0 */
        break;
    default:
        break;
    }
    return 1;
}

/* ------------------------------------------------------------------ */
/* INT 13h — disk → floppy image                                       */

static int bios_disk(X86 *c, Harness *h)
{
    uint8_t ah = rah(c);
    uint8_t drive = (uint8_t)c->r[X86_DX];
    switch (ah) {
    case 0x00: case 0x01: case 0x04: case 0x05:  /* reset/status/verify/format */
    case 0x0C: case 0x0D: case 0x10: case 0x11:  /* XT HD: seek/reset/ready/recal */
        sah(c, 0);
        set_cf(c, 0);
        return 1;
    case 0x08:                                   /* get drive parameters */
        if (drive == 0x80 && h->hd) {
            int mc = h->hd_cyls - 1;
            c->r[X86_CX] = (uint16_t)(((mc & 0xFF) << 8) |
                                      ((mc >> 2) & 0xC0) | h->hd_spt);
            c->r[X86_DX] = (uint16_t)(((h->hd_heads - 1) << 8) | 1);
            sah(c, 0);
            set_cf(c, 0);
            return 1;
        }
        sah(c, 0x01);
        set_cf(c, 1);
        return 1;
    case 0x02: case 0x03: {                      /* read / write sectors */
        int cnt   = ral(c);
        int cyl   = (uint8_t)(c->r[X86_CX] >> 8) | ((c->r[X86_CX] & 0xC0) << 2);
        int sec   = c->r[X86_CX] & 0x3F;
        int head  = (uint8_t)(c->r[X86_DX] >> 8);
        uint8_t *img; long total; int spt, heads, cyls;

        if (drive == 0x80 && h->hd) {            /* fixed disk, read-only */
            if (ah == 0x03) { sah(c, 0x03); sal(c, 0); set_cf(c, 1); return 1; }
            img = h->hd; total = h->hdsz / 512;
            spt = h->hd_spt; heads = h->hd_heads; cyls = h->hd_cyls;
        } else if (drive == 0) {
            img = h->disk; total = h->disksz / 512;
            spt = h->spt; heads = h->heads; cyls = h->cyls;
        } else {
            sah(c, 0x04); sal(c, 0); set_cf(c, 1); return 1;
        }
        long lba = ((long)cyl * heads + head) * spt + sec - 1;
        if (getenv("TRACE13") && drive == 0x80)
            fprintf(stderr, "[hd %s chs=%d/%d/%d cnt=%d lba=%ld]\n",
                    ah == 2 ? "rd" : "wr", cyl, head, sec, cnt, lba);
        if (cnt == 0 || sec < 1 || sec > spt ||
            head >= heads || cyl >= cyls || lba + cnt > total) {
            sah(c, 0x04);                        /* sector not found */
            sal(c, 0);
            set_cf(c, 1);
            return 1;
        }
        uint16_t es = c->sr[X86_ES], bx = c->r[X86_BX];
        for (long i = 0; i < (long)cnt * 512; i++) {
            uint32_t g = glin(es, (uint16_t)(bx + i));
            if (ah == 0x02)
                c->mem[g] = img[lba * 512 + i];
            else
                img[lba * 512 + i] = c->mem[g];
        }
        if (ah == 0x02) h->rd_sectors += (unsigned)cnt;
        else          { h->wr_sectors += (unsigned)cnt; h->disk_dirty = 1; }
        sah(c, 0);
        sal(c, (uint8_t)cnt);
        set_cf(c, 0);
        return 1;
    }
    default:
        fprintf(stderr, "[int13 AH=%02x DL=%02x unimplemented]\n", ah, drive);
        sah(c, 0x01);
        set_cf(c, 1);
        return 1;
    }
}

/* ------------------------------------------------------------------ */
/* INT 16h — keyboard ← stdin                                          */

static uint8_t scancode(uint8_t ch)
{
    static const struct { const char *row; uint8_t base; } rows[] = {
        { "1234567890-=", 0x02 },
        { "qwertyuiop[]", 0x10 },
        { "asdfghjkl;'`", 0x1E },
        { "\\zxcvbnm,./", 0x2B },
    };
    if (ch >= 'A' && ch <= 'Z') ch = (uint8_t)(ch + 32);
    switch (ch) {
    case '\r': return 0x1C;
    case ' ':  return 0x39;
    case 8:    return 0x0E;
    case 27:   return 0x01;
    case '\t': return 0x0F;
    default: break;
    }
    for (unsigned i = 0; i < sizeof rows / sizeof rows[0]; i++) {
        const char *p = strchr(rows[i].row, ch);
        if (p && *p)
            return (uint8_t)(rows[i].base + (p - rows[i].row));
    }
    return 0;
}

static uint8_t kb_xlate(uint8_t b)
{
    if (b == 0x0A) return 0x0D;                  /* host NL -> CR */
    if (b == 0x7F) return 0x08;                  /* DEL -> BS */
    return b;
}

/* pull one byte into h->peek if available; returns 1 if a key is buffered */
static int kb_poll(Harness *h)
{
    if (h->peek >= 0)
        return 1;
    if (h->eof)
        return 0;
    fd_set fds;
    struct timeval tv = { 0, 0 };
    FD_ZERO(&fds);
    FD_SET(0, &fds);
    if (select(1, &fds, NULL, NULL, &tv) <= 0)
        return 0;
    uint8_t b;
    ssize_t n = read(0, &b, 1);
    if (n <= 0) {
        h->eof = 1;
        return 0;
    }
    h->peek = kb_xlate(b);
    return 1;
}

static int bios_kbd(X86 *c, Harness *h)
{
    uint8_t ah = rah(c);
    switch (ah) {
    case 0x00:                                   /* read key (blocking) */
        if (!kb_poll(h)) {
            if (h->count_mode || h->eof) {
                h->exit_flag = 1;
                h->exit_reason = h->eof ? "stdin EOF at key wait"
                                        : "key wait (-c)";
                return 1;
            }
            uint8_t b;                           /* interactive: block */
            if (read(0, &b, 1) <= 0) {
                h->eof = 1;
                h->exit_flag = 1;
                h->exit_reason = "stdin EOF";
                return 1;
            }
            h->peek = kb_xlate(b);
        }
        if (h->peek == 0x1D && h->tty) {         /* Ctrl-]: quit harness */
            h->exit_flag = 1;
            h->exit_reason = "Ctrl-]";
            return 1;
        }
        c->r[X86_AX] = (uint16_t)((scancode((uint8_t)h->peek) << 8) | h->peek);
        h->peek = -1;
        return 1;
    case 0x01:                                   /* poll */
        if (kb_poll(h)) {
            set_zf(c, 0);
            c->r[X86_AX] = (uint16_t)((scancode((uint8_t)h->peek) << 8) | h->peek);
        } else {
            set_zf(c, 1);
            /* DOS 2.0 waits for input by spinning on INT 28h + AH=01
             * polls (it never blocks in AH=00). A long run of empty
             * polls with nothing else happening = sitting at a prompt. */
            h->idle++;
            if (h->idle > 100000 && (h->count_mode || h->eof)) {
                h->exit_flag = 1;
                h->exit_reason = h->eof ? "stdin EOF, guest idle at prompt"
                                        : "guest idle at prompt (-c)";
            }
        }
        return 1;
    case 0x02:                                   /* shift flags */
        sal(c, 0);
        return 1;
    default:
        return 1;
    }
}

/* ------------------------------------------------------------------ */
/* INT 1Ah — time                                                      */

static int bios_time(X86 *c, Harness *h)
{
    switch (rah(c)) {
    case 0x00: {                                 /* read tick count */
        if (g_trace) {
            c->r[X86_CX] = 0;
            c->r[X86_DX] = 0;
            sal(c, 0);
            return 1;
        }
        uint32_t ticks = (uint32_t)(h->steps / 15000);
        c->r[X86_CX] = (uint16_t)(ticks >> 16);
        c->r[X86_DX] = (uint16_t)ticks;
        sal(c, 0);                               /* no midnight rollover */
        /* mirror into the BIOS data area for direct readers */
        c->mem[0x46C] = (uint8_t)ticks;
        c->mem[0x46D] = (uint8_t)(ticks >> 8);
        c->mem[0x46E] = (uint8_t)(ticks >> 16);
        c->mem[0x46F] = (uint8_t)(ticks >> 24);
        return 1;
    }
    case 0x01:                                   /* set ticks: ignore */
        return 1;
    default:                                     /* no RTC on a PC/XT */
        set_cf(c, 1);
        return 1;
    }
}

/* ------------------------------------------------------------------ */
/* hook + boot                                                         */

#define EQUIPMENT 0x0021   /* floppy present, 80x25 color, 1 drive, no FPU */

static int bios_hook(X86 *c, int n)
{
    Harness *h = c->ctx;
    h->int_count[n & 0xFF]++;
    logcall(h, n & 0xFF, rah(c));
    /* idle-loop tracking: INT 28h and empty AH=01 polls count as idle
     * (the poll case increments in bios_kbd); anything else is progress */
    if (n != 0x28 && n != 0x16)
        h->idle = 0;
    /* first DOS buffered-line read = "boot to interactive prompt" (M3.5) */
    if (n == 0x21 && rah(c) == 0x0A && !h->prompt_steps)
        h->prompt_steps = h->steps;
    switch (n) {
    case 0x10: return bios_video(c, h);
    case 0x11: c->r[X86_AX] = EQUIPMENT; return 1;
    case 0x12: c->r[X86_AX] = (uint16_t)h->mem_kb; return 1;
    case 0x13: return bios_disk(c, h);
    case 0x16: return bios_kbd(c, h);
    case 0x19:
        h->exit_flag = 1;
        h->exit_reason = "guest issued INT 19h (reboot)";
        return 1;
    case 0x1A: return bios_time(c, h);
    default:   return 0;                         /* vector through guest IVT */
    }
}

static int disk_geometry(Harness *h)
{
    static const struct { long size; int c, hd, s; } geo[] = {
        {  163840, 40, 1,  8 }, {  184320, 40, 1,  9 },
        {  327680, 40, 2,  8 }, {  368640, 40, 2,  9 },
        {  737280, 80, 2,  9 }, { 1228800, 80, 2, 15 },
        { 1474560, 80, 2, 18 },
    };
    for (unsigned i = 0; i < sizeof geo / sizeof geo[0]; i++)
        if (geo[i].size == h->disksz) {
            h->cyls = geo[i].c;
            h->heads = geo[i].hd;
            h->spt = geo[i].s;
            return 0;
        }
    return -1;
}

static void guest_bios_setup(X86 *c, Harness *h)
{
    /* dummy IRET for all 256 vectors at 0000:04F0 — inside the BDA's
     * free scratch area, which nothing loads over (0x600 gets clobbered
     * by the boot sector's directory read at 0x500!) */
    c->mem[0x004F0] = 0xCF;
    for (int i = 0; i < 256; i++) {
        c->mem[i * 4 + 0] = 0xF0;
        c->mem[i * 4 + 1] = 0x04;
        c->mem[i * 4 + 2] = 0x00;
        c->mem[i * 4 + 3] = 0x00;
    }
    /* minimal BIOS data area */
    c->mem[0x410] = EQUIPMENT & 0xFF;            /* equipment word */
    c->mem[0x411] = EQUIPMENT >> 8;
    c->mem[0x413] = (uint8_t)h->mem_kb;          /* memory size KB */
    c->mem[0x414] = (uint8_t)(h->mem_kb >> 8);
    c->mem[0xFFFFE] = 0xFF;                      /* model byte: original PC */
}

static void print_stats(X86 *c, Harness *h)
{
    struct timeval now;
    gettimeofday(&now, NULL);
    double s = (double)(now.tv_sec - h->t0.tv_sec) +
               (double)(now.tv_usec - h->t0.tv_usec) / 1e6;
    fflush(stdout);
    fprintf(stderr, "\n== runpc stats ==\n");
    fprintf(stderr, "exit: %s at CS:IP=%04X:%04X\n",
            h->exit_reason ? h->exit_reason : "?", c->sr[X86_CS], c->ip);
    fprintf(stderr, "guest instructions: %llu (%.2fs host, %.1f M/s)\n",
            h->steps, s, s > 0 ? (double)h->steps / s / 1e6 : 0.0);
    fprintf(stderr, "stack @%04X:%04X:", c->sr[X86_SS], c->r[X86_SP]);
    for (int i = 0; i < 16; i++)
        fprintf(stderr, " %04X",
                c->mem[glin(c->sr[X86_SS], (uint16_t)(c->r[X86_SP] + 2*i))] |
                (c->mem[glin(c->sr[X86_SS], (uint16_t)(c->r[X86_SP] + 2*i + 1))] << 8));
    fprintf(stderr, "\n");
    fprintf(stderr, "disk: %llu sectors read, %llu written\n",
            h->rd_sectors, h->wr_sectors);
    fprintf(stderr, "INT calls:");
    for (int i = 0; i < 256; i++)
        if (h->int_count[i])
            fprintf(stderr, " %02X:%llu", i, h->int_count[i]);
    fprintf(stderr, "\n");
    {
        int any = 0;
        for (int i = 0; i < 4000 && !any; i++)
            any = c->mem[0xB8000 + 2 * i] > 32;
        if (any) {
            fprintf(stderr, "-- B800 text screen --\n");
            for (int r = 0; r < 25; r++) {
                char line[81];
                for (int col = 0; col < 80; col++) {
                    uint8_t ch = c->mem[0xB8000 + (r * 80 + col) * 2];
                    line[col] = (ch >= 32 && ch < 127) ? ch : ' ';
                }
                line[80] = 0;
                fprintf(stderr, "|%s|\n", line);
            }
        }
    }
    if (h->prompt_steps) {
        /* SNES @3.58MHz: ~795k native instr/s at ~4.5 cyc/instr;
         * 100-300 native per guest instruction => ~7950 to ~2650 gips */
        double lo = (double)h->prompt_steps / 7950.0;
        double hi = (double)h->prompt_steps / 2650.0;
        fprintf(stderr, "boot-to-prompt: %llu guest instructions\n",
                h->prompt_steps);
        fprintf(stderr, "SNES projection @3.58MHz: %.1f - %.1f min "
                        "(100-300 native/guest)\n", lo / 60.0, hi / 60.0);
    }
}

int main(int argc, char **argv)
{
    Harness h;
    memset(&h, 0, sizeof h);
    h.peek = -1;
    h.mem_kb = 256;
    h.cols = 80;
    h.vmode = 3;
    const char *img = NULL, *hdimg = NULL;
    long long limit = 0;
    int writeback = 0, trace = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-m") && i + 1 < argc)      h.mem_kb = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-l") && i + 1 < argc) limit = atoll(argv[++i]);
        else if (!strcmp(argv[i], "-T") && i + 1 < argc) { trace = atoi(argv[++i]); g_trace = 1; }
        else if (!strcmp(argv[i], "-c"))                 h.count_mode = 1;
        else if (!strcmp(argv[i], "-v"))                 h.verbose = 1;
        else if (!strcmp(argv[i], "-w"))                 writeback = 1;
        else if (!strcmp(argv[i], "-d") && i + 1 < argc) hdimg = argv[++i];
        else if (argv[i][0] != '-')                      img = argv[i];
        else { fprintf(stderr, "unknown option %s\n", argv[i]); return 2; }
    }
    if (!img) {
        fprintf(stderr, "usage: runpc [-m kb] [-c] [-v] [-l steps] [-w] image.img\n");
        return 2;
    }

    FILE *f = fopen(img, "rb");
    if (!f) { perror(img); return 1; }
    fseek(f, 0, SEEK_END);
    h.disksz = ftell(f);
    fseek(f, 0, SEEK_SET);
    h.disk = malloc((size_t)h.disksz);
    if (!h.disk || fread(h.disk, 1, (size_t)h.disksz, f) != (size_t)h.disksz) {
        fprintf(stderr, "failed to read %s\n", img);
        return 1;
    }
    fclose(f);
    if (disk_geometry(&h)) {
        fprintf(stderr, "%s: unsupported image size %ld\n", img, h.disksz);
        return 1;
    }
    if (h.disk[510] != 0x55 || h.disk[511] != 0xAA)
        fprintf(stderr, "warning: boot sector lacks 55AA signature\n");

    if (hdimg) {                       /* fixed disk: 17 spt, 4 heads */
        FILE *hf = fopen(hdimg, "rb");
        if (!hf) { perror(hdimg); return 1; }
        fseek(hf, 0, SEEK_END);
        h.hdsz = ftell(hf);
        fseek(hf, 0, SEEK_SET);
        h.hd = malloc((size_t)h.hdsz);
        if (!h.hd || fread(h.hd, 1, (size_t)h.hdsz, hf) != (size_t)h.hdsz) {
            fprintf(stderr, "failed to read %s\n", hdimg);
            return 1;
        }
        fclose(hf);
        h.hd_spt = 17;
        h.hd_heads = 4;
        h.hd_cyls = (int)(h.hdsz / (512L * 17 * 4));
        if (h.hdsz % (512L * 17 * 4)) {
            fprintf(stderr, "%s: not a whole number of cylinders\n", hdimg);
            return 1;
        }
    }

    X86 *c = x86_new();
    if (!c) { fprintf(stderr, "out of memory\n"); return 1; }
    g_h = &h;
    c->in8 = io_in8;
    c->int_hook = bios_hook;
    c->ctx = &h;
    guest_bios_setup(c, &h);

    /* boot: sector 0 -> 0000:7C00, jump there with DL = drive */
    memcpy(c->mem + 0x7C00, h.disk, 512);
    c->sr[X86_CS] = 0x0000;
    c->ip = 0x7C00;
    c->sr[X86_SS] = 0x0000;
    c->r[X86_SP] = 0x7C00;
    c->r[X86_DX] = 0x0000;                       /* DL = drive A: */

    h.tty = isatty(0);
    setvbuf(stdout, NULL, _IONBF, 0);
    if (h.tty && !h.count_mode)
        tty_raw();
    else
        signal(SIGINT, on_sigint);
    gettimeofday(&h.t0, NULL);

    while (!h.exit_flag && !g_stop) {
        x86_step(c);
        h.steps++;
        if (h.steps % 15000 == 0)
            x86_irq(c, 8);           /* 18.2 Hz timer tick (if IF set) */
        if ((h.steps & 0xFFF) == 0) {
            /* keep the BDA tick count live (TP polls 40:6C directly).
             * Step-derived, not wall-clock: at ~200 MIPS a wall-clock
             * tick makes 16-bit delay calibrations overflow. 15000
             * steps/tick models a ~270 kIPS XT. */
            uint32_t tk = (uint32_t)(h.steps / 15000);
            c->mem[0x46C] = (uint8_t)tk;
            c->mem[0x46D] = (uint8_t)(tk >> 8);
            c->mem[0x46E] = (uint8_t)(tk >> 16);
            c->mem[0x46F] = (uint8_t)(tk >> 24);
        }
        if (trace && h.steps <= (unsigned)trace)
            fprintf(stderr, "T %04X %04X %04X %04X %04X %04X %04X %04X "
                    "%04X %04X %04X %04X %04X %04X\n",
                    c->r[0], c->r[1], c->r[2], c->r[3], c->r[4], c->r[5],
                    c->r[6], c->r[7], c->sr[0], c->sr[1], c->sr[2],
                    c->sr[3], c->ip, c->flags);
        if (c->halted) { h.exit_reason = "guest HLT"; break; }
        if (limit && h.steps >= (unsigned long long)limit) {
            h.exit_reason = "step limit";
            break;
        }
    }
    if (g_stop && !h.exit_reason)
        h.exit_reason = "SIGINT";

    tty_restore();
    print_stats(c, &h);

    if (writeback && h.disk_dirty) {
        f = fopen(img, "wb");
        if (f) {
            fwrite(h.disk, 1, (size_t)h.disksz, f);
            fclose(f);
            fprintf(stderr, "disk image written back\n");
        }
    }
    x86_free(c);
    free(h.disk);
    return 0;
}
