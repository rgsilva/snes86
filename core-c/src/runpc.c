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
 *   -hdrw     allow writes to the -d fixed disk (written back on exit);
 *             default is read-only, as the SNES C: is
 *   -kdelay N hold keyboard input until step N (ELKS: login's tty open
 *             flushes anything typed during boot)
 *   -krate N  steps between piped keys (default 16384). Windows Setup
 *             flushes type-ahead per screen: script it at ~20M/key
 *   -rom F@S  map file F read-only at segment S (hex): ELKS ROMCODE kernel
 *             + ROMFS windows in the 1 MB space; verified unwritten on exit
 *   -entry S:O start execution at S:O (hex) instead of the boot sector
 *   -mouse S  drive the emulated Microsoft serial mouse (COM2, IRQ3) from a
 *             script: comma-separated STEP:DX:DY:BUTTONS events, e.g.
 *             -mouse 3000000:120:0:0,3400000:0:0:1,3500000:0:0:0
 *             (BUTTONS: bit0 = left, bit1 = right). The SNES build feeds the
 *             same device from the d-pad; this is how the C core proves it.
 * Interactive keys go straight to the guest (raw mode); quit with Ctrl-].
 * Arrow/function keys arrive as ANSI escape sequences and are translated
 * to XT scancodes (ASCII 0), so full-screen guests are drivable.
 *
 * Two environment levers for machine-detection experiments (both off by
 * default, both pure queries so nothing else changes):
 *   MODELBYTE=xx   the byte at F000:FFFE (default FF = original IBM PC)
 *   DOSVER=maj.min answer INT 21h AH=30h from the harness, so "needs a
 *                  newer DOS" can be told apart from "broken on us"
 */
#define _POSIX_C_SOURCE 200809L   /* select/termios/gettimeofday under a
                                   * strict -std=c11 libc (Linux) */
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
    /* fixed disk (DL=80h), read-only unless -hdrw */
    uint8_t *hd;
    long     hdsz;
    int      hd_cyls, hd_heads, hd_spt;
    int      hd_rw, hd_dirty;
    /* keyboard */
    int peek;          /* buffered key byte, -1 = none */
    int pushback;      /* byte read by the escape-sequence lookahead and
                        * not consumed by it, -1 = none (a lone ESC must
                        * not eat the key typed after it) */
    int peek_scan;     /* scancode override for the buffered key: extended
                        * keys (arrows, F-keys) arrive as ANSI escape
                        * sequences and have no ASCII, so the usual
                        * scancode(ascii) derivation can't reach them */
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
    /* CGA graphics: -cga dumps the B800 bitmap as PPM on exit/mode-away */
    const char *cga_out;
    uint8_t cga_3d9;         /* port 3D9 shadow: bit5 pal, bit4 bright, low bg */
    /* INT9 raw scancodes: booters/games (FS1, Snipes) never call INT16 */
    uint8_t s60;             /* port 60h latch */
    uint8_t s9q[8];          /* pending make/break codes (max: shift-wrapped
                              * key = 2A, make, break, AA) */
    int s9n, s9i;
    uint16_t kq[16];         /* INT16 tee ring for hooked-INT9 guests:
                              * (scan<<8)|ascii, like the SNES $0700 ring */
    int kqh, kqt;
    /* keyboard hold-off + jump-proof pump threshold (HLT idling makes
     * steps skip forward, so "steps & mask == 0" gates can miss);
     * s9next spaces INT9 deliveries so the guest ISR can't re-enter
     * itself at its post-sti tail (the SNES side's s9CD, host edition) */
    unsigned long long kdelay, next_pump, s9next, next_key;
    unsigned long long krate;  /* steps between piped keys (-krate). Full-
                                * screen installers (Windows Setup) drain
                                * the type-ahead buffer as each screen is
                                * painted, so a script must type SLOWER
                                * than the screen redraws or its keys are
                                * silently flushed. */
    /* Microsoft serial mouse (see mouse_* below). The SNES build carries the
     * identical device; keep the two in step. */
    uint8_t mtx[8];          /* device -> host byte queue (packet in flight) */
    int mth, mtt;
    uint8_t mier, mmcr, mlcr;/* the three UART registers the driver writes */
    int mdx, mdy;            /* motion not yet packed into a packet */
    uint8_t mbtn, mbtn_sent; /* bit0 left, bit1 right */
    unsigned long long mnext;/* next step a packet may be emitted */
    unsigned long long mwhen;/* step the next -mouse event is due */
    const char *mscript;     /* -mouse: STEP:DX:DY:B[,...] */
    int tickstep;            /* instructions per timer tick (-tick) */
    int pending_irq;         /* IRQ refused by the interrupt shadow (or by
                              * IF=0), retried each step; -1 = none */
    /* -rom: read-only blobs mapped into the 1 MB space (ELKS ROMCODE) */
    struct { const char *path; uint32_t base, len, sum; } rom[4];
    int nrom;
    struct timeval t0;
} Harness;

static volatile sig_atomic_t g_stop = 0;
static Harness *g_h;
static X86 *g_c;          /* text-mode B800 mirror (see txt_put) */

/* ------------------------------------------------------------------ */
/* Microsoft serial mouse — an 8250 on COM2 (0x2F8), IRQ3 -> INT 0Bh    */
/*                                                                      */
/* Windows 1.01 has no INT 33h anywhere: SETUP links one of its own     */
/* mouse drivers into WIN100.BIN and that driver owns the hardware.      */
/* MOUSE.DRV ("Microsoft Mouse (Bus/Serial)") probes the bus card at    */
/* 0x23C — which we do not answer, so the probe falls through — and     */
/* then a 1200-baud serial mouse on COM2 first, COM1 second. Hence      */
/* COM2: the port it tries first, so the probe's 65536-iteration        */
/* receive-drain loop is paid once instead of twice.                    */
/*                                                                      */
/* What the driver actually needs, and all this implements:             */
/*   * RTS rising (MCR bit1, written as part of 0x0B) resets the mouse, */
/*     which answers with the identity byte 'M' — that is the probe;    */
/*   * LSR bit0 = a byte is waiting, read from RBR at base+0;           */
/*   * IER bit0 = raise IRQ3 while a byte is waiting;                   */
/*   * three-byte packets: 0x40|L<<5|R<<4|(dy>>6)<<2|(dx>>6), dx&0x3F,  */
/*     dy&0x3F, deltas signed 8-bit, Y down-positive.                   */
/* Baud, parity and word length are written and ignored: bytes arrive   */
/* when we say they do.                                                 */

#define MOU_BASE 0x2F8
#define MOU_VEC  0x0B

static int mouse_pending(Harness *h) { return h->mth != h->mtt; }

static void mouse_push(Harness *h, uint8_t b)
{
    int n = (h->mtt + 1) & 7;
    if (n == h->mth) return;                     /* full: drop, like a UART */
    h->mtx[h->mtt] = b;
    h->mtt = n;
}

static uint8_t mouse_pop(Harness *h)
{
    uint8_t b;
    if (h->mth == h->mtt) return 0;
    b = h->mtx[h->mth];
    h->mth = (h->mth + 1) & 7;
    return b;
}

/* pack whatever motion/buttons have accumulated into one packet */
static void mouse_packet(Harness *h)
{
    int dx = h->mdx, dy = h->mdy;
    if (dx >  127) dx =  127;  if (dx < -128) dx = -128;
    if (dy >  127) dy =  127;  if (dy < -128) dy = -128;
    h->mdx -= dx;
    h->mdy -= dy;
    h->mbtn_sent = h->mbtn;
    mouse_push(h, (uint8_t)(0x40 | ((h->mbtn & 1) << 5) | ((h->mbtn & 2) << 3)
                            | (((dy >> 6) & 3) << 2) | ((dx >> 6) & 3)));
    mouse_push(h, (uint8_t)(dx & 0x3F));
    mouse_push(h, (uint8_t)(dy & 0x3F));
}

/* CGA status port: retrace bits must toggle or direct-video programs
 * (Turbo Pascal!) spin forever waiting for retrace to end */
static uint8_t io_in8(X86 *c, uint16_t port)
{
    (void)c;
    if ((port & 0xFFF8) == 0x3D8) {
        unsigned long long s = g_h ? g_h->steps : 0;
        return (uint8_t)(((s >> 5) & 1) | (((s >> 11) & 1) << 3));
    }
    if ((port & 0xFFF8) == MOU_BASE && g_h) {
        Harness *h = g_h;
        switch (port & 7) {
        case 0: return (h->mlcr & 0x80) ? 0x60 : mouse_pop(h);   /* DLL/RBR */
        case 1: return (h->mlcr & 0x80) ? 0x00 : h->mier;        /* DLM/IER */
        case 2: return mouse_pending(h) ? 0x04 : 0x01;           /* IIR */
        case 3: return h->mlcr;
        case 4: return h->mmcr;
        case 5: return (uint8_t)(0x60 | (mouse_pending(h) ? 1 : 0)); /* LSR */
        case 6: return 0x30;                                     /* MSR: CTS+DSR */
        default: return 0;                                       /* scratch */
        }
    }
    if (port == 0x20) return 0;   /* 8259 IRR/ISR. We vector IRQs straight at
                                   * the IVT, so nothing is ever "in service";
                                   * 0xFF read as "some IRQ in service" and cost
                                   * Windows 1.01 its mouse cursor — SYSTEM.DRV's
                                   * INT 8 handler issues OCW3 (0x0B) + IN 20h
                                   * and skips its whole timer-callback list
                                   * unless the register reads back zero, and
                                   * that list is what repaints the pointer. */
    if (port == 0x60 && g_h) return g_h->s60;    /* keyboard scancode latch */
    if (port == 0x61) return 0;                  /* 8255 port B */
    if (port == 0x64) return 0;                  /* KBC status: idle. 0xFF reads
                                                  * as "always busy" and ELKS's
                                                  * A20/8042 probe spins forever */
    return 0xFF;
}
static int g_trace = 0;   /* -T: freeze INT 1Ah ticks for lockstep traces */
static void on_sigint(int sig) { (void)sig; g_stop = 1; }

/* ------------------------------------------------------------------ */
/* CGA graphics (modes 4/5 = 320x200x4, 6 = 640x200x2)                 */

#include "cgafont.h"

static int gfx_mode(int m) { return m == 4 || m == 5 || m == 6; }

/* graphics-mode text: the BIOS draws glyphs into the bitmap */
static void cga_glyph(X86 *c, Harness *h, int row, int col, uint8_t ch,
                      uint8_t attr)
{
    const unsigned char *g = &cgafont[ch * 8];
    int xr = attr & 0x80, colr = attr & 3;
    if (row > 24 || row < 0) return;
    for (int l = 0; l < 8; l++) {
        int y = row * 8 + l;
        uint8_t *ln = &c->mem[0xB8000 + (y & 1) * 0x2000 + (y >> 1) * 80];
        if (h->vmode == 6) {                     /* 1bpp, 80 columns */
            if (col > 79) return;
            if (xr) ln[col] ^= g[l];
            else    ln[col]  = g[l];
        } else {                                 /* 2bpp, 40 columns */
            uint8_t b0 = 0, b1 = 0;
            if (col > 39) return;
            for (int i = 0; i < 4; i++) {
                if (g[l] & (0x80 >> i)) b0 |= (uint8_t)(colr << (6 - 2 * i));
                if (g[l] & (0x08 >> i)) b1 |= (uint8_t)(colr << (6 - 2 * i));
            }
            if (xr) { ln[col * 2] ^= b0; ln[col * 2 + 1] ^= b1; }
            else    { ln[col * 2]  = b0; ln[col * 2 + 1]  = b1; }
        }
    }
}

static void cga_scroll(X86 *c)
{
    for (int b = 0; b < 2; b++) {                /* 8 px = 4 lines/bank */
        uint8_t *bank = &c->mem[0xB8000 + b * 0x2000];
        memmove(bank, bank + 4 * 80, 96 * 80);
        memset(bank + 96 * 80, 0, 4 * 80);
    }
}

static const uint8_t cga_rgb[16][3] = {
    {0,0,0},       {0,0,170},    {0,170,0},    {0,170,170},
    {170,0,0},     {170,0,170},  {170,85,0},   {170,170,170},
    {85,85,85},    {85,85,255},  {85,255,85},  {85,255,255},
    {255,85,85},   {255,85,255}, {255,255,85}, {255,255,255}
};

static void cga_dump(X86 *c, Harness *h)
{
    if (!h->cga_out || !gfx_mode(h->vmode)) return;
    FILE *f = fopen(h->cga_out, "wb");
    if (!f) { perror(h->cga_out); return; }
    int w = (h->vmode == 6) ? 640 : 320;
    fprintf(f, "P6\n%d 200\n255\n", w);
    for (int y = 0; y < 200; y++) {
        const uint8_t *ln = &c->mem[0xB8000 + (y & 1) * 0x2000 + (y >> 1) * 80];
        for (int x = 0; x < w; x++) {
            int idx;
            if (h->vmode == 6) {
                idx = ((ln[x >> 3] >> (7 - (x & 7))) & 1) ? 15 : 0;
            } else {
                int v = (ln[x >> 2] >> (6 - 2 * (x & 3))) & 3;
                if (v == 0) idx = h->cga_3d9 & 0x0F;
                else        idx = v * 2 + ((h->cga_3d9 >> 5) & 1)
                                        + ((h->cga_3d9 & 0x10) ? 8 : 0);
            }
            fwrite(cga_rgb[idx], 1, 3, f);
        }
    }
    fclose(f);
    fprintf(stderr, "CGA mode %d %dx200 -> %s\n", h->vmode, w, h->cga_out);
}

/* GW-BASIC (and games) switch CGA modes by programming port 3D8
 * directly, never calling INT 10h — mode tracking must watch the port.
 * 3D8 bits: 0=80col, 1=graphics, 2=no color burst, 4=640x200 */
static int traceio(void)
{
    static int on = -1;
    if (on < 0) on = getenv("TRACEIO") != NULL;
    return on;
}

static void io_out8(X86 *c, uint16_t port, uint8_t v)
{
    if (!g_h) return;
    if (traceio())
        fprintf(stderr, "OUT %04X <- %02X\n", port, v);
    if ((port & 0xFFF8) == MOU_BASE) {
        switch (port & 7) {
        case 1: if (!(g_h->mlcr & 0x80)) g_h->mier = v; break;
        case 3: g_h->mlcr = v; break;
        case 4:
            /* RTS 0 -> 1 powers the mouse: it resets and identifies itself */
            if ((v & 2) && !(g_h->mmcr & 2)) {
                g_h->mth = g_h->mtt = 0;
                mouse_push(g_h, 'M');
            }
            g_h->mmcr = v;
            break;
        default: break;
        }
        return;
    }
    if (port == 0x3D9) {
        g_h->cga_3d9 = v;
    } else if (port == 0x3D8) {
        int newm = (v & 2) ? ((v & 0x10) ? 6 : ((v & 4) ? 5 : 4))
                           : ((v & 1) ? 3 : 1);
        if (gfx_mode(g_h->vmode) && !gfx_mode(newm))
            cga_dump(c, g_h);        /* leaving gfx: keep the frame */
        if (newm != g_h->vmode) {
            g_h->vmode = newm;
            g_h->cols = (newm == 6 || newm == 3) ? 80 : 40;
        }
    }
}

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

/* Mirror BIOS text output into the B800 text buffer. The HLE BIOS talks
 * to stdout, so a guest that paints with INT 10h teletype + cursor moves
 * (Windows 2.x Setup) leaves stdout an unreadable run-on and the exit
 * screen dump empty. Guests that write B800 themselves are unaffected. */
static void txt_put(Harness *h, uint8_t ch, uint8_t attr)
{
    if (!g_c || gfx_mode(h->vmode) || h->row < 0 || h->row > 24
        || h->col < 0 || h->col >= 80)
        return;
    uint32_t o = 0xB8000 + (uint32_t)(h->row * 80 + h->col) * 2;
    g_c->mem[o] = ch;
    g_c->mem[o + 1] = attr;
}

static void txt_clear(Harness *h)
{
    if (!g_c || gfx_mode(h->vmode)) return;
    for (int i = 0; i < 80 * 25; i++) {
        g_c->mem[0xB8000 + i * 2] = ' ';
        g_c->mem[0xB8000 + i * 2 + 1] = 0x07;
    }
}

static void txt_scroll(Harness *h)
{
    if (!g_c || gfx_mode(h->vmode)) return;
    memmove(&g_c->mem[0xB8000], &g_c->mem[0xB8000 + 160], 160 * 24);
    for (int i = 0; i < 80; i++) {
        g_c->mem[0xB8000 + 24 * 160 + i * 2] = ' ';
        g_c->mem[0xB8000 + 24 * 160 + i * 2 + 1] = 0x07;
    }
}

static void tty_putc(Harness *h, uint8_t ch)
{
    int was = h->row;
    putchar(ch);
    if (ch >= 32) txt_put(h, ch, 0x07);
    if (ch == '\r')      h->col = 0;
    else if (ch == '\n') h->row += (h->row < 24);
    else if (ch == 8)    h->col -= (h->col > 0);
    else if (ch >= 32 && ++h->col >= h->cols) { h->col = 0; h->row += (h->row < 24); }
    if (h->row == 24 && was == 24 && (ch == '\n' || (ch >= 32 && !h->col)))
        txt_scroll(h);                    /* pinned at the last row: the
                                           * real BIOS would have scrolled */
}

static int bios_video(X86 *c, Harness *h)
{
    uint8_t ah = rah(c);
    if (traceio() && ah != 0x02 && ah != 0x03 && ah != 0x09 && ah != 0x0E)
        fprintf(stderr, "INT10 AH=%02X AL=%02X BX=%04X\n", ah, ral(c), c->r[X86_BX]);
    switch (ah) {
    case 0x00: {                                 /* set mode */
        int newm = ral(c) & 0x7F;
        cga_dump(c, h);                          /* leaving gfx? keep the frame */
        h->vmode = newm;
        h->cols = (newm == 0 || newm == 1 || newm == 4 || newm == 5) ? 40 : 80;
        if (gfx_mode(newm)) {
            if (!(ral(c) & 0x80))                /* AL bit7 = no-clear */
                memset(&c->mem[0xB8000], 0, 0x4000);
            h->cga_3d9 = 0x30;                   /* bright cyan/magenta/white */
        } else {
            if (h->tty) fputs("\033[2J\033[H", stdout);
            h->row = h->col = 0;
            txt_clear(h);
        }
        h->row = h->col = 0;
        break;
    }
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
        if (gfx_mode(h->vmode)) {
            if (ral(c) == 0)                     /* AL=0: clear the bitmap */
                memset(&c->mem[0xB8000], 0, 0x4000);
            break;
        }
        if (ral(c) == 0) {                       /* AL=0: clear window */
            if (h->tty) fputs("\033[2J\033[H", stdout);
            h->row = h->col = 0;
            txt_clear(h);
        } else {
            for (int i = 0; i < ral(c); i++) txt_scroll(h);
        }
        break;
    case 0x08:                                   /* read char+attr */
        c->r[X86_AX] = 0x0720;
        if (g_c && !gfx_mode(h->vmode) && h->row >= 0 && h->row < 25
            && h->col >= 0 && h->col < 80) {
            uint32_t o = 0xB8000 + (uint32_t)(h->row * 80 + h->col) * 2;
            c->r[X86_AX] = (uint16_t)((g_c->mem[o + 1] << 8) | g_c->mem[o]);
        }
        break;
    case 0x09: case 0x0A: {                      /* write char (xN) */
        int n = c->r[X86_CX] ? c->r[X86_CX] : 1;
        if (gfx_mode(h->vmode))                  /* gfx: BL = color */
            for (int i = 0; i < n; i++)
                cga_glyph(c, h, h->row, h->col + i, ral(c),
                          (uint8_t)c->r[X86_BX]);
        for (int i = 0; i < n; i++) {
            int sc = h->col;
            h->col = sc + i;
            txt_put(h, ral(c), ah == 0x09 ? (uint8_t)c->r[X86_BX] : 0x07);
            h->col = sc;
            putchar(ral(c));
        }
        break;
    }
    case 0x0B: {                                 /* CGA palette/background */
        uint8_t bh = (uint8_t)(c->r[X86_BX] >> 8), bl = (uint8_t)c->r[X86_BX];
        if (bh == 0)                             /* background+border color */
            h->cga_3d9 = (uint8_t)((h->cga_3d9 & 0xE0) | (bl & 0x1F));
        else                                     /* palette select (bit 0) */
            h->cga_3d9 = (uint8_t)((h->cga_3d9 & ~0x20) | ((bl & 1) << 5));
        break;
    }
    case 0x0C: {                                 /* write pixel */
        int x = c->r[X86_CX], y = c->r[X86_DX];
        uint8_t v = ral(c), xr = (uint8_t)(v & 0x80);
        if (h->vmode == 6 && x < 640 && y < 200) {
            uint8_t *p = &c->mem[0xB8000 + (y & 1) * 0x2000 + (y >> 1) * 80 + (x >> 3)];
            uint8_t m = (uint8_t)(0x80 >> (x & 7));
            if (xr) *p ^= (v & 1) ? m : 0;
            else    *p = (uint8_t)((*p & ~m) | ((v & 1) ? m : 0));
        } else if ((h->vmode == 4 || h->vmode == 5) && x < 320 && y < 200) {
            uint8_t *p = &c->mem[0xB8000 + (y & 1) * 0x2000 + (y >> 1) * 80 + (x >> 2)];
            int sh = 6 - 2 * (x & 3);
            if (xr) *p ^= (uint8_t)((v & 3) << sh);
            else    *p = (uint8_t)((*p & ~(3 << sh)) | ((v & 3) << sh));
        }
        break;
    }
    case 0x0D: {                                 /* read pixel */
        int x = c->r[X86_CX], y = c->r[X86_DX];
        uint8_t v = 0;
        if (h->vmode == 6 && x < 640 && y < 200)
            v = (c->mem[0xB8000 + (y & 1) * 0x2000 + (y >> 1) * 80 + (x >> 3)]
                 >> (7 - (x & 7))) & 1;
        else if ((h->vmode == 4 || h->vmode == 5) && x < 320 && y < 200)
            v = (c->mem[0xB8000 + (y & 1) * 0x2000 + (y >> 1) * 80 + (x >> 2)]
                 >> (6 - 2 * (x & 3))) & 3;
        sal(c, v);
        break;
    }
    case 0x0E:                                   /* teletype */
        if (gfx_mode(h->vmode)) {
            uint8_t ch = ral(c);
            if (ch == '\r') {
                h->col = 0;
            } else if (ch == '\n') {
                if (++h->row > 24) { h->row = 24; cga_scroll(c); }
            } else if (ch == 8) {
                if (h->col) h->col--;
            } else if (ch != 7) {
                cga_glyph(c, h, h->row, h->col, ch, (uint8_t)c->r[X86_BX]);
                if (++h->col >= h->cols) {
                    h->col = 0;
                    if (++h->row > 24) { h->row = 24; cga_scroll(c); }
                }
            }
            putchar(ral(c));                     /* host console mirror */
            break;
        }
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

        if (traceio() && drive < 2)
            fprintf(stderr, "INT13 %s d%d C%d H%d S%d x%d -> %04X:%04X\n",
                    ah == 2 ? "rd" : "wr", drive, cyl, head, sec, cnt,
                    c->sr[X86_ES], c->r[X86_BX]);

        if (drive == 0x80 && h->hd) {            /* fixed disk (-hdrw: writable) */
            if (ah == 0x03 && !h->hd_rw) {       /* 03h = write protected */
                sah(c, 0x03); sal(c, 0); set_cf(c, 1); return 1;
            }
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
        if (ah == 0x02 && c->wp_n) {
            /* HLE DMA would bypass the mwr8 write trap: refuse reads
             * aimed at a -rom window instead of silently shredding it */
            uint32_t dst = glin(es, bx), dend = dst + (uint32_t)cnt * 512;
            for (int i = 0; i < c->wp_n; i++)
                if (dst < c->wp[i].hi && dend > c->wp[i].lo) {
                    fprintf(stderr, "[int13 rd into ROM window %05X-%05X "
                            "refused]\n", c->wp[i].lo, c->wp[i].hi - 1);
                    sah(c, 0x01);
                    sal(c, 0);
                    set_cf(c, 1);
                    return 1;
                }
        }
        for (long i = 0; i < (long)cnt * 512; i++) {
            uint32_t g = glin(es, (uint16_t)(bx + i));
            if (ah == 0x02)
                c->mem[g] = img[lba * 512 + i];
            else
                img[lba * 512 + i] = c->mem[g];
        }
        if (ah == 0x02) h->rd_sectors += (unsigned)cnt;
        else {
            h->wr_sectors += (unsigned)cnt;
            if (img == h->hd) h->hd_dirty = 1;
            else              h->disk_dirty = 1;
        }
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

/* shifted symbol -> unshifted key (US layout), 0 = not a shifted symbol.
 * Only the INT9 path needs this: a guest INT9 handler applies its own
 * modifier state, so '|' or 'A' must arrive as a real Shift press (the
 * INT16 path hands the ASCII over directly and stays shift-free). */
static uint8_t unshift(uint8_t ch)
{
    static const char *sym  = "!@#$%^&*()_+|:\"<>?~{}";
    static const char *base = "1234567890-=\\;',./`[]";
    const char *p = strchr(sym, ch);
    return (p && *p) ? (uint8_t)base[p - sym] : 0;
}

static uint8_t kb_xlate(uint8_t b)
{
    if (b == 0x0A) return 0x0D;                  /* host NL -> CR */
    if (b == 0x7F) return 0x08;                  /* DEL -> BS */
    return b;
}

/* ANSI escape sequence -> XT scancode (arrows/F-keys live on the 84-key
 * keypad, so no E0 prefix: the code IS the key). Returns 0 if unknown. */
static uint8_t esc_scan(const char *s, int n)
{
    if (n < 2) return 0;
    char f = s[n - 1];
    if (s[0] == 'O' || s[0] == '[') {
        switch (f) {                       /* CSI/SS3 letter finals */
        case 'A': return 0x48;             /* Up    */
        case 'B': return 0x50;             /* Down  */
        case 'C': return 0x4D;             /* Right */
        case 'D': return 0x4B;             /* Left  */
        case 'H': return 0x47;             /* Home  */
        case 'F': return 0x4F;             /* End   */
        case 'P': return 0x3B;             /* SS3 F1 */
        case 'Q': return 0x3C;
        case 'R': return 0x3D;
        case 'S': return 0x3E;
        default: break;
        }
    }
    if (s[0] == '[' && f == '~') {         /* CSI <n> ~ */
        int v = atoi(s + 1);
        switch (v) {
        case 1: return 0x47; case 2: return 0x52; case 3: return 0x53;
        case 4: return 0x4F; case 5: return 0x49; case 6: return 0x51;
        case 11: return 0x3B; case 12: return 0x3C; case 13: return 0x3D;
        case 14: return 0x3E; case 15: return 0x3F; case 17: return 0x40;
        case 18: return 0x41; case 19: return 0x42; case 20: return 0x43;
        case 21: return 0x44; case 23: return 0x85; case 24: return 0x86;
        default: break;
        }
    }
    return 0;
}

/* is another byte available right now? (escape-sequence lookahead only:
 * a lone ESC must not block waiting for a '[' that never comes) */
static int kb_ready(void)
{
    fd_set fds;
    struct timeval tv = { 0, 0 };
    FD_ZERO(&fds);
    FD_SET(0, &fds);
    return select(1, &fds, NULL, NULL, &tv) > 0;
}

/* pull one byte into h->peek if available; returns 1 if a key is buffered */
static int kb_poll(Harness *h)
{
    if (h->steps < h->kdelay)   /* -kdelay holds the INT 16h path too, not
                                 * just the INT 9 pump — FreeDOS's F8/F5
                                 * boot prompt eats early piped keys */
        return 0;
    if (h->peek >= 0)
        return 1;
    if (h->pushback >= 0) {
        h->peek = h->pushback;
        h->pushback = -1;
        h->peek_scan = 0;
        h->next_key = h->steps + h->krate;
        return 1;
    }
    if (h->eof)
        return 0;
    if (!h->tty && h->steps < h->next_key)
        return 0;               /* meter piped input to typing speed: a
                                 * pipe otherwise looks like an instant
                                 * burst and a type-ahead flush (TP3's
                                 * startup) drains the whole script. The
                                 * hooked-INT9 pump already meters at one
                                 * key per 16384 steps; match it here for
                                 * INT16-polite guests (our own IO.SYS). */
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
    h->peek_scan = 0;
    if (b == 0x1B && kb_ready()) {        /* ESC [ ... / ESC O ... */
        char seq[8];
        int n = 0;
        while (n < (int)sizeof seq - 1 && kb_ready()) {
            uint8_t x;
            if (read(0, &x, 1) <= 0) break;
            seq[n++] = (char)x;
            if (n == 1) {
                if (x != '[' && x != 'O') break;   /* not a CSI/SS3 intro */
            } else if (x >= '@' && x <= '~') {
                break;                            /* final byte */
            }
        }
        seq[n] = 0;
        uint8_t sc = esc_scan(seq, n);
        if (getenv("TRACEKB")) fprintf(stderr, "[kb esc \"%s\" -> %02X]\n", seq, sc);
        if (sc) {
            h->peek = 0;                  /* extended key: ASCII 0 */
            h->peek_scan = sc;
            h->next_key = h->steps + h->krate;
            return 1;
        }
        if (n == 1)                       /* lone ESC: give the byte back */
            h->pushback = (unsigned char)seq[0];
    }
    h->peek = kb_xlate(b);
    h->next_key = h->steps + h->krate;
    return 1;
}

static int int9_hooked(X86 *c)
{
    uint32_t v;
    memcpy(&v, &c->mem[9 * 4], 4);
    return v != 0x000004F0u;
}

static uint16_t bda_kb_pop(X86 *c, int consume)
{
    /* the real BIOS keyboard ring at 40:1E (head 40:1A, tail 40:1C):
     * a guest INT9 handler that speaks the BIOS protocol stores
     * translated keys here and expects INT16 to serve them */
    uint16_t hd, tl, v;
    memcpy(&hd, &c->mem[0x41A], 2);
    memcpy(&tl, &c->mem[0x41C], 2);
    if (hd == tl || hd < 0x1E || hd >= 0x3E) return 0;
    memcpy(&v, &c->mem[0x400 + hd], 2);
    if (consume) {
        hd += 2;
        if (hd >= 0x3E) hd = 0x1E;
        memcpy(&c->mem[0x41A], &hd, 2);
    }
    return v ? v : 0xFFFF;
}

/* scancode for the buffered key: an escape-sequence key carries its own */
static uint8_t kb_scan(Harness *h)
{
    if (getenv("TRACEKB")) fprintf(stderr, "[kb serve ascii=%02X scan=%02X]\n", h->peek, h->peek_scan);
    return h->peek_scan ? (uint8_t)h->peek_scan : scancode((uint8_t)h->peek);
}

static int bios_kbd(X86 *c, Harness *h)
{
    uint8_t ah = rah(c);
    if (ah == 0x00 || ah == 0x01) {
        uint16_t v = bda_kb_pop(c, ah == 0x00);
        if (v) {
            if (v == 0xFFFF) v = 0;
            c->r[X86_AX] = v;
            if (ah == 0x01) set_zf(c, 0);
            return 1;
        }
    }
    /* a guest INT9 hook replaces the BIOS handler: stdin belongs to the
     * IRQ1 pump. But serve the pump's tee ring here (BDA first, own ring
     * second — the same arbitration hle_int16 does on the SNES): a hook
     * that only monitors INT 9 and chains to our IRET stub never fills
     * the BDA, yet still expects INT 16h to have the key (FreeDOS). */
    if (int9_hooked(c) && (ah == 0x00 || ah == 0x01)) {
        if (h->kqh != h->kqt) {
            c->r[X86_AX] = h->kq[h->kqh];
            if (ah == 0x00) h->kqh = (h->kqh + 1) & 15;
            else set_zf(c, 0);
        } else if (ah == 0x01) {
            set_zf(c, 1);
        } else {
            c->r[X86_AX] = 0;
        }
        return 1;
    }
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
        c->r[X86_AX] = (uint16_t)((kb_scan(h) << 8) | h->peek);
        h->peek = -1;
        h->peek_scan = 0;
        return 1;
    case 0x01:                                   /* poll */
        if (kb_poll(h)) {
            set_zf(c, 0);
            c->r[X86_AX] = (uint16_t)((kb_scan(h) << 8) | h->peek);
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
        uint32_t ticks = (uint32_t)(h->steps / (unsigned)h->tickstep);
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

#define EQUIPMENT 0x0061   /* floppies present, 80x25 color, 2 drives, no
                            * FPU — matches the SNES build. GW-BASIC gates
                            * its graphics driver on a table lookup indexed
                            * by this exact byte; 0x21 lands on a zero entry
                            * and SCREEN silently refuses to switch modes. */

static int bios_hook(X86 *c, int n)
{
    Harness *h = c->ctx;
    h->int_count[n & 0xFF]++;
    logcall(h, n & 0xFF, rah(c));
    /* idle-loop tracking: INT 28h and empty AH=01 polls count as idle
     * (the poll case increments in bios_kbd); anything else is progress.
     * Our own timer tick (INT 8 and its 1Ch chain) must not reset the
     * count — it fires every tickstep, so the threshold would be
     * unreachable and the idle-at-prompt exit could never trigger. */
    if (n != 0x28 && n != 0x16 && n != 0x08 && n != 0x1C)
        h->idle = 0;
    /* first DOS buffered-line read = "boot to interactive prompt" (M3.5) */
    if (n == 0x21 && rah(c) == 0x0A && !h->prompt_steps)
        h->prompt_steps = h->steps;
    /* DOSVER=maj.min: answer INT 21h AH=30h from the harness instead of
     * letting DOS answer. Purely an experiment lever — it tells apart
     * "this program needs a newer DOS" from "this program is broken on
     * our machine" without patching the guest's MSDOS.SYS. */
    if (n == 0x21 && rah(c) == 0x30) {
        const char *dv = getenv("DOSVER");
        if (dv) {
            int mj = 0, mn = 0;
            sscanf(dv, "%d.%d", &mj, &mn);
            c->r[X86_AX] = (uint16_t)((mn << 8) | mj);
            c->r[X86_BX] = 0;
            c->r[X86_CX] = 0;
            return 1;
        }
    }
    switch (n) {
    case 0x10: return bios_video(c, h);
    case 0x11: c->r[X86_AX] = EQUIPMENT; return 1;
    case 0x12: c->r[X86_AX] = (uint16_t)h->mem_kb; return 1;
    case 0x13: return bios_disk(c, h);
    case 0x15:                     /* XT BIOS: cassette only -> unsupported.
                                    * Unhandled it vectors to the IRET stub and
                                    * ELKS's A20 query (AH=24h) "succeeds" with
                                    * garbage. CF=1/AH=86h is the real XT answer. */
        sah(c, 0x86);
        set_cf(c, 1);
        return 1;
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
    c->mem[0x41A] = 0x1E;                        /* BIOS kb ring empty: */
    c->mem[0x41C] = 0x1E;                        /* head = tail = 40:1E */
    c->mem[0x480] = 0x1E;                        /* buffer start/end (for */
    c->mem[0x482] = 0x3E;                        /* protocol-polite hooks) */
    c->mem[0x449] = 0x03;                        /* current video mode */
    c->mem[0x44A] = 80;                          /* columns */
    c->mem[0x44C] = 0x00; c->mem[0x44D] = 0x10;  /* page size 4096 */
    c->mem[0x460] = 0x07; c->mem[0x461] = 0x06;  /* cursor shape */
    c->mem[0x463] = 0xD4; c->mem[0x464] = 0x03;  /* CRTC base 3D4 */
    c->mem[0x465] = 0x29;                        /* 3D8 shadow: 80x25 on */
    c->mem[0x466] = 0x30;                        /* 3D9 shadow */
    {   /* model byte at F000:FFFE — original PC (FFh) by default;
         * MODELBYTE=xx overrides it for machine-detection experiments */
        const char *mb = getenv("MODELBYTE");
        c->mem[0xFFFFE] = mb ? (uint8_t)strtoul(mb, NULL, 16) : 0xFF;
    }
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
                int hl = 0;                      /* any inverse/coloured cell:
                                                  * marks the highlighted row
                                                  * of a text-mode menu */
                for (int col = 0; col < 80; col++) {
                    uint8_t ch = c->mem[0xB8000 + (r * 80 + col) * 2];
                    uint8_t at = c->mem[0xB8000 + (r * 80 + col) * 2 + 1];
                    if (at & 0x70) hl = 1;
                    line[col] = (ch >= 32 && ch < 127) ? ch : ' ';
                }
                line[80] = 0;
                fprintf(stderr, "%c%s|\n", hl ? '>' : '|', line);
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
    h.pushback = -1;
    h.pending_irq = -1;
    h.mem_kb = 256;
    h.krate = 16384;
    h.tickstep = 15000;
    h.cols = 80;
    h.vmode = 3;
    const char *img = NULL, *hdimg = NULL;
    long long limit = 0, trace = 0;      /* -T windows can exceed 2.1G steps */
    int writeback = 0;
    int entry_set = 0;
    unsigned entry_cs = 0, entry_ip = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-m") && i + 1 < argc)      h.mem_kb = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-l") && i + 1 < argc) limit = atoll(argv[++i]);
        else if (!strcmp(argv[i], "-T") && i + 1 < argc) { trace = atoll(argv[++i]); g_trace = 1; }
        else if (!strcmp(argv[i], "-c"))                 h.count_mode = 1;
        else if (!strcmp(argv[i], "-v"))                 h.verbose = 1;
        else if (!strcmp(argv[i], "-w"))                 writeback = 1;
        else if (!strcmp(argv[i], "-d") && i + 1 < argc) hdimg = argv[++i];
        else if (!strcmp(argv[i], "-hdrw"))              h.hd_rw = 1;
        else if (!strcmp(argv[i], "-krate") && i + 1 < argc)
            h.krate = (unsigned long long)atoll(argv[++i]);
        else if (!strcmp(argv[i], "-cga") && i + 1 < argc) h.cga_out = argv[++i];
        else if (!strcmp(argv[i], "-tick") && i + 1 < argc) {
            h.tickstep = atoi(argv[++i]);
            if (h.tickstep <= 0) {       /* 0 would divide-by-zero the tick
                                          * derivations, negatives wrap */
                fprintf(stderr, "-tick wants a positive instruction count\n");
                return 2;
            }
        }
        else if (!strcmp(argv[i], "-kdelay") && i + 1 < argc)
            h.kdelay = (unsigned long long)atoll(argv[++i]);
        else if (!strcmp(argv[i], "-mouse") && i + 1 < argc) {
            h.mscript = argv[++i];
            h.mwhen = strtoull(h.mscript, NULL, 10);
        }
        else if (!strcmp(argv[i], "-rom") && i + 1 < argc) {
            char *at = strchr(argv[++i], '@');
            if (!at || h.nrom >= 4) {
                fprintf(stderr, "-rom wants FILE@HEXSEG (max 4)\n");
                return 2;
            }
            *at = 0;
            h.rom[h.nrom].path = argv[i];
            h.rom[h.nrom].base = (uint32_t)strtoul(at + 1, NULL, 16) << 4;
            h.nrom++;
        }
        else if (!strcmp(argv[i], "-entry") && i + 1 < argc) {
            unsigned s, o;
            if (sscanf(argv[++i], "%x:%x", &s, &o) != 2) {
                fprintf(stderr, "-entry wants HEXSEG:HEXOFF\n");
                return 2;
            }
            entry_cs = s; entry_ip = o; entry_set = 1;
        }
        else if (argv[i][0] != '-')                      img = argv[i];
        else { fprintf(stderr, "unknown option %s\n", argv[i]); return 2; }
    }
    if (!img && !entry_set) {
        fprintf(stderr, "usage: runpc [-m kb] [-c] [-v] [-l steps] [-w] "
                        "[-kdelay N] [-rom FILE@SEG] [-entry SEG:OFF] "
                        "[-hdrw] image.img\n");
        return 2;
    }

    if (img) {
        FILE *f = fopen(img, "rb");
        if (!f) { perror(img); return 1; }
        if (fseek(f, 0, SEEK_END) || (h.disksz = ftell(f)) < 0 ||
            fseek(f, 0, SEEK_SET)) {
            fprintf(stderr, "%s: can't determine image size\n", img);
            return 1;
        }
        h.disk = malloc((size_t)h.disksz);
        if (!h.disk || fread(h.disk, 1, (size_t)h.disksz, f) != (size_t)h.disksz) {
            fprintf(stderr, "failed to read %s\n", img);
            return 1;
        }
        fclose(f);
    } else {
        /* -entry with no floppy (ELKS ROMFS boots diskless): blank 360K
         * so stray INT 13h reads return zeros instead of crashing */
        h.disksz = 368640;
        h.disk = calloc(1, (size_t)h.disksz);
        if (!h.disk) { fprintf(stderr, "out of memory\n"); return 1; }
    }
    if (disk_geometry(&h)) {
        fprintf(stderr, "%s: unsupported image size %ld\n",
                img ? img : "(blank)", h.disksz);
        return 1;
    }
    if (img && (h.disk[510] != 0x55 || h.disk[511] != 0xAA))
        fprintf(stderr, "warning: boot sector lacks 55AA signature\n");

    if (hdimg) {                       /* fixed disk: 17 spt, 4 heads */
        FILE *hf = fopen(hdimg, "rb");
        if (!hf) { perror(hdimg); return 1; }
        if (fseek(hf, 0, SEEK_END) || (h.hdsz = ftell(hf)) < 0 ||
            fseek(hf, 0, SEEK_SET)) {
            fprintf(stderr, "%s: can't determine image size\n", hdimg);
            return 1;
        }
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
    g_c = c;
    c->in8 = io_in8;
    c->out8 = io_out8;
    c->int_hook = bios_hook;
    c->ctx = &h;
    guest_bios_setup(c, &h);

    /* -rom blobs into the flat 1 MB space (read-only by contract: mwr8
     * reports stray writes as they happen via the wp windows below, and
     * a checksum is re-verified at exit as the backstop) */
    for (int i = 0; i < h.nrom; i++) {
        FILE *rf = fopen(h.rom[i].path, "rb");
        if (!rf) { perror(h.rom[i].path); return 1; }
        long rl;
        if (fseek(rf, 0, SEEK_END) || (rl = ftell(rf)) < 0 ||
            fseek(rf, 0, SEEK_SET)) {
            fprintf(stderr, "%s: can't determine image size\n", h.rom[i].path);
            return 1;
        }
        if (rl <= 0 || h.rom[i].base + (uint32_t)rl > (1u << 20)) {
            fprintf(stderr, "%s: doesn't fit below 1 MB at %05X\n",
                    h.rom[i].path, h.rom[i].base);
            return 1;
        }
        if (fread(c->mem + h.rom[i].base, 1, (size_t)rl, rf) != (size_t)rl) {
            fprintf(stderr, "failed to read %s\n", h.rom[i].path);
            return 1;
        }
        fclose(rf);
        h.rom[i].len = (uint32_t)rl;
        uint32_t s = 0;
        for (uint32_t j = 0; j < h.rom[i].len; j++)
            s = s * 31 + c->mem[h.rom[i].base + j];
        h.rom[i].sum = s;
        /* write trap: the exit checksum only proves THAT a window was
         * clobbered; the core's report says where and (via the step
         * counter) roughly when */
        c->wp[c->wp_n].lo = h.rom[i].base;
        c->wp[c->wp_n].hi = h.rom[i].base + h.rom[i].len;
        c->wp_n++;
    }

    if (entry_set) {
        /* ROM image entry (ELKS CONFIG_ROMCODE setup segment) */
        c->sr[X86_CS] = (uint16_t)entry_cs;
        c->ip = (uint16_t)entry_ip;
        c->sr[X86_SS] = 0x0000;
        c->r[X86_SP] = 0x7C00;
        c->r[X86_DX] = 0x0000;
    } else {
        /* boot: sector 0 -> 0000:7C00, jump there with DL = drive */
        memcpy(c->mem + 0x7C00, h.disk, 512);
        c->sr[X86_CS] = 0x0000;
        c->ip = 0x7C00;
        c->sr[X86_SS] = 0x0000;
        c->r[X86_SP] = 0x7C00;
        c->r[X86_DX] = 0x0000;                   /* DL = drive A: */
    }

    h.tty = isatty(0);
    setvbuf(stdout, NULL, _IONBF, 0);
    if (h.tty && !h.count_mode)
        tty_raw();
    signal(SIGINT, on_sigint);   /* raw mode disables ISIG, but an external
                                  * kill -INT must still exit cleanly (and
                                  * atexit tty_restore never runs on a
                                  * default-action signal death) */
    gettimeofday(&h.t0, NULL);

    while (!h.exit_flag && !g_stop) {
        x86_step(c);
        h.steps++;
        if (h.steps % (unsigned)h.tickstep == 0)
            h.pending_irq = 8;       /* timer tick due */
        if (h.pending_irq >= 0 && x86_irq(c, h.pending_irq))
            h.pending_irq = -1;      /* delivered. Under -T this is
                                      * DETERMINISTIC lockstep state: the
                                      * ELKS TRACE build mirrors x86_irq on
                                      * the same instruction count, and a
                                      * tick due at step N lands at N+1 when
                                      * step N loaded a segment register or
                                      * ran STI (the SNES TRACE build
                                      * implements the identical shadow
                                      * rule); IF=0 holds the tick pending
                                      * like the PIC would. -tick N changes
                                      * the cadence. */
        if ((h.steps & 0xFFF) == 0) {
            /* keep the BDA tick count live (TP polls 40:6C directly).
             * Step-derived, not wall-clock: at ~200 MIPS a wall-clock
             * tick makes 16-bit delay calibrations overflow. The default
             * 15000 steps/tick models a ~270 kIPS XT. */
            uint32_t tk = (uint32_t)(h.steps / (unsigned)h.tickstep);
            c->mem[0x46C] = (uint8_t)tk;
            c->mem[0x46D] = (uint8_t)(tk >> 8);
            c->mem[0x46E] = (uint8_t)(tk >> 16);
            c->mem[0x46F] = (uint8_t)(tk >> 24);
        }
        if (h.steps >= h.next_pump) {
            h.next_pump = h.steps + 16384;
            /* INT9 scancode pump (refill half): when the guest hooks INT 9
             * (IVT no longer our 0000:04F0 stub), stdin chars become
             * make+break scancodes queued in s9q. (INT16-polite programs
             * keep the bios_kbd path instead.) -kdelay holds input during
             * boot (ELKS flushes the tty at login). */
            uint32_t v9;
            memcpy(&v9, &c->mem[9 * 4], 4);
            if (v9 != 0x000004F0u && h.steps >= h.kdelay
                && h.s9i >= h.s9n && kb_poll(&h)) {
                if (h.peek == 0x1D && h.tty) {   /* Ctrl-]: quit harness,
                                                  * same as the INT16 path */
                    h.exit_flag = 1;
                    h.exit_reason = "Ctrl-]";
                    h.peek = -1;
                    h.peek_scan = 0;
                } else {
                    uint8_t ch = (uint8_t)h.peek;
                    uint8_t base = h.peek_scan ? 0 : unshift(ch);
                    int shift = base || (!h.peek_scan && ch >= 'A' && ch <= 'Z');
                    uint8_t sc = h.peek_scan ? (uint8_t)h.peek_scan
                                             : scancode(base ? base : ch);
                    h.peek = -1;
                    h.peek_scan = 0;
                    if (sc) {
                        int n = 0;
                        if (shift) h.s9q[n++] = 0x2A;    /* LShift make */
                        h.s9q[n++] = sc;
                        h.s9q[n++] = (uint8_t)(sc | 0x80);
                        if (shift) h.s9q[n++] = 0xAA;    /* LShift break */
                        h.s9n = n;
                        h.s9i = 0;
                        /* tee the keystroke into the INT16 ring too, like
                         * the SNES kb_push: a hooker that only MONITORS
                         * INT 9 and chains to the (IRET-stub) BIOS handler
                         * never stuffs the BDA — FreeDOS does exactly this
                         * — so bios_kbd falls back to this ring */
                        int nt = (h.kqt + 1) & 15;
                        if (nt != h.kqh) {
                            h.kq[h.kqt] = (uint16_t)((sc << 8) | ch);
                            h.kqt = nt;
                        }
                    }
                }
            }
        }
        /* -mouse: replay the script, then let the device speak. Packets are
         * paced one per timer tick, which is what a 40-report/second mouse
         * looks like on a machine this slow — and is exactly the cadence the
         * SNES build uses (one packet per NMI batch). */
        while (h.mscript && *h.mscript && h.steps >= h.mwhen) {
            const char *p = strchr(h.mscript, ':');
            int dx = 0, dy = 0, b = 0;
            if (p && sscanf(p + 1, "%d:%d:%d", &dx, &dy, &b) == 3) {
                h.mdx += dx;
                h.mdy += dy;
                h.mbtn = (uint8_t)b;
            }
            p = strchr(h.mscript, ',');
            h.mscript = p ? p + 1 : "";
            h.mwhen = *h.mscript ? strtoull(h.mscript, NULL, 10) : ~0ull;
        }
        if (!mouse_pending(&h) && h.steps >= h.mnext
            && (h.mdx || h.mdy || h.mbtn != h.mbtn_sent)) {
            mouse_packet(&h);
            h.mnext = h.steps + (unsigned)h.tickstep;
        }
        if (mouse_pending(&h) && (h.mier & 1)) {
            x86_irq(c, MOU_VEC);       /* refused under the shadow: retried */
        }

        /* delivery half, every iteration: hand over a queued code at the
         * first IF=1 instruction. Delivering only at pump time starves an
         * HLT-idling guest — the fast-forward jump pins pump fires to the
         * post-wake IRQ-handler entry, where IF is systematically 0.
         * The 5000-step spacing keeps a second code from re-entering the
         * guest ISR at its post-sti tail before the first char reaches
         * the tty queue (all codes "delivered", none surviving). */
        if (h.s9i < h.s9n && (c->flags & 0x0200) && h.steps >= h.s9next) {
            h.s60 = h.s9q[h.s9i];
            /* a refusal (sreg-load/STI shadow) keeps the code queued for a
             * retry next step — consuming it here would drop keys */
            if (x86_irq(c, 9)) {
                h.s9i++;
                h.s9next = h.steps + 5000;
            }
        }
        if (trace && h.steps <= (unsigned long long)trace)
            fprintf(stderr, "T %04X %04X %04X %04X %04X %04X %04X %04X "
                    "%04X %04X %04X %04X %04X %04X\n",
                    c->r[0], c->r[1], c->r[2], c->r[3], c->r[4], c->r[5],
                    c->r[6], c->r[7], c->sr[0], c->sr[1], c->sr[2],
                    c->sr[3], c->ip, c->flags);
        if (c->halted) {
            /* ELKS idles in HLT with IF=1 — skip ahead to the next timer
             * tick and wake it. HLT with IF=0 is a genuine hang: exit
             * (preserves the old behavior for crashed boot sectors).
             * Under -T stay frozen: the SNES TRACE build has no ticks. */
            if (g_trace) {
                /* deterministic trace: a halted CPU burns steps one at a
                 * time (each = one identical trace line, matching the SNES
                 * TRACE build's no-op x86step) until the tick wakes it */
            } else {
                if (!(c->flags & 0x0200)) { h.exit_reason = "guest HLT (IF=0)"; break; }
                h.steps += (unsigned)h.tickstep - (h.steps % (unsigned)h.tickstep);
                if (!x86_irq(c, 8))
                    h.pending_irq = 8;   /* the shadow can't be up mid-HLT,
                                          * but never drop a tick */
            }
        }
        if (limit && h.steps >= (unsigned long long)limit) {
            h.exit_reason = "step limit";
            break;
        }
    }
    if (g_stop && !h.exit_reason)
        h.exit_reason = "SIGINT";

    tty_restore();
    cga_dump(c, &h);                 /* -cga: keep the final graphics frame */
    print_stats(c, &h);

    /* the -rom read-only contract: a well-behaved ROMCODE guest never
     * writes its ROM windows; flag it loudly if this one did */
    for (int i = 0; i < h.nrom; i++) {
        uint32_t s = 0;
        for (uint32_t j = 0; j < h.rom[i].len; j++)
            s = s * 31 + c->mem[h.rom[i].base + j];
        if (s != h.rom[i].sum)
            fprintf(stderr, "WARNING: guest WROTE to ROM region %s@%05X\n",
                    h.rom[i].path, h.rom[i].base);
    }

    if (h.hd_dirty && hdimg) {       /* -hdrw: the install actually happened */
        FILE *wf = fopen(hdimg, "r+b");
        if (wf) {
            fwrite(h.hd, 1, (size_t)h.hdsz, wf);
            fclose(wf);
            fprintf(stderr, "hd image written back\n");
        } else
            perror(hdimg);
    }
    if (writeback && h.disk_dirty && img) {
        FILE *wf = fopen(img, "wb");
        if (wf) {
            fwrite(h.disk, 1, (size_t)h.disksz, wf);
            fclose(wf);
            fprintf(stderr, "disk image written back\n");
        }
    }
    x86_free(c);
    free(h.disk);
    return 0;
}
