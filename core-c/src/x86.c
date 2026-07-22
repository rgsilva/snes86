/* x86.c — 8086 real-mode CPU core (snes86 reference implementation).
 *
 * Correctness first: this core must pass the SingleStepTests 8088 v2
 * vectors (captured from a real AMD D8088), so it implements the
 * undocumented-but-deterministic 8086 behaviors those vectors exercise:
 *   - PUSH SP pushes the already-decremented SP (pre-286 semantics)
 *   - divide error (INT 0) pushes the address of the NEXT instruction
 *   - a REP prefix on IDIV inverts the sign of the quotient (reenigne)
 *   - group-2 reg=6 is SETMO/SETMOC (dest = all ones, logic flags)
 *   - opcode aliases: 60-6F=70-7F, C0/C1/C8/C9=C2/C3/CA/CB, 82=80,
 *     0F=POP CS, D6=SALC, F6/F7 reg=1 = TEST, FF reg=7 = PUSH
 *   - shifts/rotates use the full unmasked count in CL (no 186+ &31)
 * Shift/rotate flags are produced by stepping one bit at a time, which is
 * what the hardware microcode does — multi-bit counts then come out right
 * by construction instead of by special-cased formulas.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "x86.h"

enum { AX, CX, DX, BX, SP, BP, SI, DI };
enum { ES, CS, SS, DS };

#define CF  X86_CF
#define PF  X86_PF
#define AF  X86_AF
#define ZF  X86_ZF
#define SF  X86_SF
#define TF  X86_TF
#define IF_ X86_IF
#define DF  X86_DF
#define OF  X86_OF

/* Bits that physically exist in the 8086 FLAGS register. Bits 1,12-15 read
 * as 1, bits 3,5 read as 0. Keeping flags canonical at all times means
 * PUSHF/LAHF/interrupt frames need no extra work. */
#define FMASK  0x0FD5
#define FFIXED 0xF002

static uint16_t canon(uint16_t f) { return (uint16_t)((f & FMASK) | FFIXED); }

/* ------------------------------------------------------------------ */
/* memory                                                              */

static uint32_t lin(uint16_t seg, uint16_t off)
{
    return (((uint32_t)seg << 4) + off) & 0xFFFFF;
}

static uint8_t mrd8(X86 *c, uint16_t seg, uint16_t off)
{
    return c->mem[lin(seg, off)];
}

static void mwr8(X86 *c, uint16_t seg, uint16_t off, uint8_t v)
{
    if (c->wp_n) {          /* write-protect report (runpc -rom): the write
                             * still lands — the exit checksum only says THAT
                             * a window was hit, this says the first WHERE */
        uint32_t a = lin(seg, off);
        for (int i = 0; i < c->wp_n; i++)
            if (!c->wp[i].hit && a >= c->wp[i].lo && a < c->wp[i].hi) {
                c->wp[i].hit = 1;
                fprintf(stderr, "WARNING: guest wrote %02X to protected "
                        "%05X (first hit; bisect with the step counter)\n",
                        v, a);
            }
    }
    c->mem[lin(seg, off)] = v;
}

/* 16-bit accesses wrap the OFFSET (offset 0xFFFF pairs with 0x0000 of the
 * same segment) — real 8086 behavior, exercised by the test vectors. */
static uint16_t mrd16(X86 *c, uint16_t seg, uint16_t off)
{
    return (uint16_t)(mrd8(c, seg, off) |
                      ((uint16_t)mrd8(c, seg, (uint16_t)(off + 1)) << 8));
}

static void mwr16(X86 *c, uint16_t seg, uint16_t off, uint16_t v)
{
    mwr8(c, seg, off, (uint8_t)v);
    mwr8(c, seg, (uint16_t)(off + 1), (uint8_t)(v >> 8));
}

static uint8_t fetch8(X86 *c)
{
    uint8_t v = mrd8(c, c->sr[CS], c->ip);
    c->ip++;
    return v;
}

static uint16_t fetch16(X86 *c)
{
    uint16_t v = fetch8(c);
    return (uint16_t)(v | ((uint16_t)fetch8(c) << 8));
}

static void push16(X86 *c, uint16_t v)
{
    c->r[SP] -= 2;
    mwr16(c, c->sr[SS], c->r[SP], v);
}

static uint16_t pop16(X86 *c)
{
    uint16_t v = mrd16(c, c->sr[SS], c->r[SP]);
    c->r[SP] += 2;
    return v;
}

/* ------------------------------------------------------------------ */
/* registers: 8-bit view. index 0-7 = AL CL DL BL AH CH DH BH          */

static uint8_t get_r8(X86 *c, int i)
{
    return (i < 4) ? (uint8_t)c->r[i] : (uint8_t)(c->r[i & 3] >> 8);
}

static void set_r8(X86 *c, int i, uint8_t v)
{
    if (i < 4)
        c->r[i] = (uint16_t)((c->r[i] & 0xFF00) | v);
    else
        c->r[i & 3] = (uint16_t)((c->r[i & 3] & 0x00FF) | ((uint16_t)v << 8));
}

/* ------------------------------------------------------------------ */
/* flags                                                               */

static void setf(X86 *c, uint16_t bit, int cond)
{
    if (cond) c->flags |= bit; else c->flags &= (uint16_t)~bit;
}

static int parity_even(uint8_t v)
{
    v ^= (uint8_t)(v >> 4);
    v ^= (uint8_t)(v >> 2);
    v ^= (uint8_t)(v >> 1);
    return !(v & 1);
}

static void szp8(X86 *c, uint8_t r)
{
    uint16_t f = c->flags & (uint16_t)~(SF | ZF | PF);
    if (!r)               f |= ZF;
    if (r & 0x80)         f |= SF;
    if (parity_even(r))   f |= PF;
    c->flags = f;
}

static void szp16(X86 *c, uint16_t r)
{
    uint16_t f = c->flags & (uint16_t)~(SF | ZF | PF);
    if (!r)                      f |= ZF;
    if (r & 0x8000)              f |= SF;
    if (parity_even((uint8_t)r)) f |= PF;   /* PF is always low-byte only */
    c->flags = f;
}

/* ------------------------------------------------------------------ */
/* ALU                                                                 */

static uint8_t add8(X86 *c, uint8_t a, uint8_t b, int cin)
{
    uint32_t r = (uint32_t)a + b + (uint32_t)cin;
    setf(c, CF, r > 0xFF);
    setf(c, AF, (a ^ b ^ r) & 0x10);
    setf(c, OF, (~(a ^ b) & (a ^ r)) & 0x80);
    szp8(c, (uint8_t)r);
    return (uint8_t)r;
}

static uint16_t add16(X86 *c, uint16_t a, uint16_t b, int cin)
{
    uint32_t r = (uint32_t)a + b + (uint32_t)cin;
    setf(c, CF, r > 0xFFFF);
    setf(c, AF, (a ^ b ^ r) & 0x10);
    setf(c, OF, (~(a ^ b) & (a ^ r)) & 0x8000);
    szp16(c, (uint16_t)r);
    return (uint16_t)r;
}

static uint8_t sub8(X86 *c, uint8_t a, uint8_t b, int bin)
{
    uint32_t r = (uint32_t)a - b - (uint32_t)bin;
    setf(c, CF, (uint32_t)b + (uint32_t)bin > a);
    setf(c, AF, (a ^ b ^ r) & 0x10);
    setf(c, OF, ((a ^ b) & (a ^ r)) & 0x80);
    szp8(c, (uint8_t)r);
    return (uint8_t)r;
}

static uint16_t sub16(X86 *c, uint16_t a, uint16_t b, int bin)
{
    uint32_t r = (uint32_t)a - b - (uint32_t)bin;
    setf(c, CF, (uint32_t)b + (uint32_t)bin > a);
    setf(c, AF, (a ^ b ^ r) & 0x10);
    setf(c, OF, ((a ^ b) & (a ^ r)) & 0x8000);
    szp16(c, (uint16_t)r);
    return (uint16_t)r;
}

static uint8_t log8(X86 *c, uint8_t r)
{
    setf(c, CF | OF | AF, 0);
    szp8(c, r);
    return r;
}

static uint16_t log16(X86 *c, uint16_t r)
{
    setf(c, CF | OF | AF, 0);
    szp16(c, r);
    return r;
}

/* op = (opcode>>3)&7 for the 00-3F block and for group 1:
 * ADD OR ADC SBB AND SUB XOR CMP */
static uint8_t alu8(X86 *c, int op, uint8_t a, uint8_t b)
{
    switch (op) {
    case 0:  return add8(c, a, b, 0);
    case 1:  return log8(c, (uint8_t)(a | b));
    case 2:  return add8(c, a, b, (c->flags & CF) ? 1 : 0);
    case 3:  return sub8(c, a, b, (c->flags & CF) ? 1 : 0);
    case 4:  return log8(c, (uint8_t)(a & b));
    case 5:  return sub8(c, a, b, 0);
    case 6:  return log8(c, (uint8_t)(a ^ b));
    default: sub8(c, a, b, 0); return a;    /* CMP: flags only */
    }
}

static uint16_t alu16(X86 *c, int op, uint16_t a, uint16_t b)
{
    switch (op) {
    case 0:  return add16(c, a, b, 0);
    case 1:  return log16(c, (uint16_t)(a | b));
    case 2:  return add16(c, a, b, (c->flags & CF) ? 1 : 0);
    case 3:  return sub16(c, a, b, (c->flags & CF) ? 1 : 0);
    case 4:  return log16(c, (uint16_t)(a & b));
    case 5:  return sub16(c, a, b, 0);
    case 6:  return log16(c, (uint16_t)(a ^ b));
    default: sub16(c, a, b, 0); return a;   /* CMP: flags only */
    }
}

/* INC/DEC touch every arithmetic flag except CF */
static uint8_t inc8(X86 *c, uint8_t v)
{
    uint16_t cf = c->flags & CF;
    uint8_t r = add8(c, v, 1, 0);
    c->flags = (uint16_t)((c->flags & ~CF) | cf);
    return r;
}

static uint8_t dec8(X86 *c, uint8_t v)
{
    uint16_t cf = c->flags & CF;
    uint8_t r = sub8(c, v, 1, 0);
    c->flags = (uint16_t)((c->flags & ~CF) | cf);
    return r;
}

static uint16_t inc16(X86 *c, uint16_t v)
{
    uint16_t cf = c->flags & CF;
    uint16_t r = add16(c, v, 1, 0);
    c->flags = (uint16_t)((c->flags & ~CF) | cf);
    return r;
}

static uint16_t dec16(X86 *c, uint16_t v)
{
    uint16_t cf = c->flags & CF;
    uint16_t r = sub16(c, v, 1, 0);
    c->flags = (uint16_t)((c->flags & ~CF) | cf);
    return r;
}

/* ------------------------------------------------------------------ */
/* decode                                                              */

typedef struct {
    int seg;    /* segment override index, -1 = none */
    int rep;    /* 0 = none, 1 = F3 (REP/REPZ), 2 = F2 (REPNZ) */
} Pfx;

typedef struct {
    int      mod, reg, rm;
    int      isreg;   /* mod == 3 */
    int      seg;     /* resolved segment register index (override applied) */
    uint16_t off;     /* effective offset when !isreg */
} EA;

static void modrm(X86 *c, Pfx *p, EA *e)
{
    uint8_t m = fetch8(c);
    e->mod = m >> 6;
    e->reg = (m >> 3) & 7;
    e->rm  = m & 7;
    e->isreg = (e->mod == 3);
    e->seg = DS;
    e->off = 0;
    if (e->isreg)
        return;

    uint16_t off = 0;
    int defseg = DS;
    switch (e->rm) {
    case 0: off = (uint16_t)(c->r[BX] + c->r[SI]); break;
    case 1: off = (uint16_t)(c->r[BX] + c->r[DI]); break;
    case 2: off = (uint16_t)(c->r[BP] + c->r[SI]); defseg = SS; break;
    case 3: off = (uint16_t)(c->r[BP] + c->r[DI]); defseg = SS; break;
    case 4: off = c->r[SI]; break;
    case 5: off = c->r[DI]; break;
    case 6:
        if (e->mod == 0) off = fetch16(c);          /* [disp16], DS default */
        else { off = c->r[BP]; defseg = SS; }
        break;
    case 7: off = c->r[BX]; break;
    }
    if (e->mod == 1)      off = (uint16_t)(off + (int8_t)fetch8(c));
    else if (e->mod == 2) off = (uint16_t)(off + fetch16(c));
    e->off = off;
    e->seg = (p->seg >= 0) ? p->seg : defseg;
}

static uint8_t rdm8(X86 *c, EA *e)
{
    return e->isreg ? get_r8(c, e->rm) : mrd8(c, c->sr[e->seg], e->off);
}

static void wrm8(X86 *c, EA *e, uint8_t v)
{
    if (e->isreg) set_r8(c, e->rm, v);
    else          mwr8(c, c->sr[e->seg], e->off, v);
}

static uint16_t rdm16(X86 *c, EA *e)
{
    return e->isreg ? c->r[e->rm] : mrd16(c, c->sr[e->seg], e->off);
}

static void wrm16(X86 *c, EA *e, uint16_t v)
{
    if (e->isreg) c->r[e->rm] = v;
    else          mwr16(c, c->sr[e->seg], e->off, v);
}

/* condition codes for Jcc, cc = low nibble of opcode */
static int cond(X86 *c, int cc)
{
    uint16_t f = c->flags;
    int r;
    switch (cc >> 1) {
    case 0:  r = (f & OF) != 0; break;
    case 1:  r = (f & CF) != 0; break;
    case 2:  r = (f & ZF) != 0; break;
    case 3:  r = (f & (CF | ZF)) != 0; break;
    case 4:  r = (f & SF) != 0; break;
    case 5:  r = (f & PF) != 0; break;
    case 6:  r = ((f & SF) != 0) != ((f & OF) != 0); break;
    default: r = (((f & SF) != 0) != ((f & OF) != 0)) || (f & ZF); break;
    }
    return (cc & 1) ? !r : r;
}

/* ------------------------------------------------------------------ */
/* interrupts                                                          */

static void do_int(X86 *c, int n)
{
    if (c->int_hook && c->int_hook(c, n))
        return;                          /* HLE BIOS swallowed it */
    push16(c, canon(c->flags));
    c->flags &= (uint16_t)~(IF_ | TF);
    push16(c, c->sr[CS]);
    push16(c, c->ip);
    c->ip     = mrd16(c, 0, (uint16_t)(n * 4));
    c->sr[CS] = mrd16(c, 0, (uint16_t)(n * 4 + 2));
}

/* ------------------------------------------------------------------ */
/* group 2: shifts/rotates. Bit-at-a-time like the microcode; count is
 * NOT masked on 8086. Rotates touch only CF/OF; shifts also set SZP
 * (AF left cleared — undefined on hardware, masked by the test suite). */

static void grp2(X86 *c, EA *e, int wide, int count)
{
    int msb = wide ? 15 : 7;
    uint16_t mask = wide ? 0xFFFF : 0x00FF;
    uint16_t v = wide ? rdm16(c, e) : rdm8(c, e);

    if (e->reg == 6) {                   /* SETMO/SETMOC (undocumented) */
        if (count) {
            v = mask;
            setf(c, CF | OF | AF, 0);
            if (wide) szp16(c, v); else szp8(c, (uint8_t)v);
        } else {
            return;                      /* SETMOC with CL=0: no-op */
        }
        if (wide) wrm16(c, e, v); else wrm8(c, e, (uint8_t)v);
        return;
    }

    if (count == 0)
        return;                          /* no flags touched, no write */

    int cf = (c->flags & CF) ? 1 : 0;
    int of = (c->flags & OF) ? 1 : 0;
    for (int i = 0; i < count; i++) {
        int hi = (v >> msb) & 1;
        switch (e->reg) {
        case 0:                                   /* ROL */
            cf = hi;
            v  = (uint16_t)(((v << 1) | (uint16_t)cf) & mask);
            of = cf ^ ((v >> msb) & 1);
            break;
        case 1:                                   /* ROR */
            cf = v & 1;
            v  = (uint16_t)((v >> 1) | ((uint16_t)cf << msb));
            of = ((v >> msb) ^ (v >> (msb - 1))) & 1;
            break;
        case 2: {                                 /* RCL */
            int t = hi;
            v  = (uint16_t)(((v << 1) | (uint16_t)cf) & mask);
            cf = t;
            of = cf ^ ((v >> msb) & 1);
            break;
        }
        case 3: {                                 /* RCR */
            int t = v & 1;
            v  = (uint16_t)((v >> 1) | ((uint16_t)cf << msb));
            cf = t;
            of = ((v >> msb) ^ (v >> (msb - 1))) & 1;
            break;
        }
        case 4:                                   /* SHL/SAL */
            cf = hi;
            v  = (uint16_t)((v << 1) & mask);
            of = cf ^ ((v >> msb) & 1);
            break;
        case 5:                                   /* SHR */
            cf = v & 1;
            v  = (uint16_t)(v >> 1);
            of = hi;
            break;
        default:                                  /* SAR (reg == 7) */
            cf = v & 1;
            v  = (uint16_t)((v >> 1) | (v & (uint16_t)(1u << msb)));
            of = 0;
            break;
        }
    }
    setf(c, CF, cf);
    setf(c, OF, of);
    if (e->reg >= 4) {                   /* shifts update SZP, rotates don't */
        setf(c, AF, 0);
        if (wide) szp16(c, v); else szp8(c, (uint8_t)v);
    }
    if (wide) wrm16(c, e, v); else wrm8(c, e, (uint8_t)v);
}

/* ------------------------------------------------------------------ */
/* 8088 microcode division: CORD/PREIDIV/POSTIDIV/NEGATE.
 *
 * Ported from MartyPC (MIT, (c) Daniel Balsom), which translated them
 * from reenigne's 8086 microcode disassembly. We need the microcode-
 * faithful version because a divide error (INT 0) pushes FLAGS to the
 * stack, exposing the "undefined" flag state the real chip computes
 * mid-division. Side effects reproduced exactly:
 *   - div-by-zero and quotient overflow both trap via the same path
 *   - IDIV traps on quotient -128/-32768 (magnitude check happens
 *     before the sign is applied — unlike later x86)
 *   - a REP prefix seeds the internal negate flag, flipping the IDIV
 *     quotient sign (reenigne's discovery)
 * Micro-ALU ops don't touch CPU flags except at the marked 'F' points. */

typedef struct { uint16_t sigma; int cy, ov, ac; } MRes;

static MRes msubw(int wide, uint16_t a, uint16_t b)
{
    MRes r;
    if (wide) {
        uint32_t d = (uint32_t)a - b;
        r.sigma = (uint16_t)d;
        r.cy = b > a;
        r.ov = (((a ^ b) & (a ^ r.sigma)) & 0x8000) != 0;
    } else {
        a &= 0xFF; b &= 0xFF;
        r.sigma = (uint16_t)((a - b) & 0xFF);
        r.cy = b > a;
        r.ov = (((a ^ b) & (a ^ r.sigma)) & 0x80) != 0;
    }
    r.ac = ((a ^ b ^ r.sigma) & 0x10) != 0;
    return r;
}

static MRes mrclw(int wide, uint16_t v, int cin)
{
    MRes r = { 0, 0, 0, 0 };
    if (wide) {
        r.cy = (v >> 15) & 1;
        r.sigma = (uint16_t)((v << 1) | (cin ? 1 : 0));
    } else {
        r.cy = (v >> 7) & 1;
        r.sigma = (uint16_t)(((v << 1) | (cin ? 1 : 0)) & 0xFF);
    }
    return r;
}

/* the microcode 'F' operator: latch ALU flags into the CPU flags */
static void mflags(X86 *c, int wide, MRes r)
{
    setf(c, AF, r.ac);
    setf(c, OF, r.ov);
    setf(c, CF, r.cy);
    if (wide) szp16(c, r.sigma); else szp8(c, (uint8_t)r.sigma);
}

/* NEGATE co-routine. NEG/COM of tmpa/tmpc are full 16-bit ops in the
 * microcode; only the LRCY sign checks are operand-width. */
static void cor_negate(X86 *c, int wide, uint16_t *tmpa, uint16_t *tmpb,
                       uint16_t *tmpc, int *neg, int skip)
{
    if (!skip) {
        uint16_t nc = (uint16_t)(0 - *tmpc);           /* 1b6 NEG tmpc */
        int carry = *tmpc != 0;
        *tmpc = nc;
        *tmpa = carry ? (uint16_t)~*tmpa               /* 1b8/1ba COM tmpa */
                      : (uint16_t)(0 - *tmpa);         /* 1b9/1ba NEG tmpa */
        *neg = !*neg;
    }
    int carry = (*tmpb >> (wide ? 15 : 7)) & 1;        /* 1bb LRCY tmpb */
    setf(c, CF, carry);
    if (carry) {                                       /* divisor negative */
        *tmpb = (uint16_t)(0 - *tmpb);                 /* 1be NEG tmpb */
        *neg = !*neg;
    }
}

static void pre_idiv(X86 *c, int wide, uint16_t *tmpa, uint16_t *tmpb,
                     uint16_t *tmpc, int *neg)
{
    int msb = (*tmpa >> (wide ? 15 : 7)) & 1;          /* 1b4 dividend<0? */
    cor_negate(c, wide, tmpa, tmpb, tmpc, neg, !msb);
}

/* CORD: the core non-restoring division loop. Returns nonzero on divide
 * error. tmpc holds the (complemented) quotient, tmpa the remainder. */
static int cord(X86 *c, int wide, uint16_t *ptmpc, uint16_t *ptmpa,
                uint16_t tmpb, int *pcarry)
{
    uint16_t tmpa = *ptmpa, tmpc = *ptmpc;
    int n = wide ? 16 : 8;

    MRes r = msubw(wide, tmpa, tmpb);                  /* 188 SUBT tmpa */
    mflags(c, wide, r);                                /* 189 F */
    if (!r.cy)
        return 1;                                      /* 18a NCY INT0 */
    int carry = r.cy;

    for (int i = 0; i < n; i++) {
        r = mrclw(wide, tmpc, carry); tmpc = r.sigma; carry = r.cy;  /* 18c */
        r = mrclw(wide, tmpa, carry); tmpa = r.sigma; carry = r.cy;  /* 18d */
        if (carry) {
            carry = 0;                                 /* 195 RCY */
            tmpa = msubw(wide, tmpa, tmpb).sigma;      /* 196 (no flags) */
        } else {
            r = msubw(wide, tmpa, tmpb);               /* 18f SUBT | F */
            mflags(c, wide, r);
            carry = r.cy;
            if (!carry)
                tmpa = r.sigma;                        /* 196 */
            /* else 191: keep tmpa, carry stays set (quotient bit) */
        }
    }

    r = mrclw(wide, tmpc, carry); tmpc = r.sigma;      /* 192/193 */
    carry = mrclw(wide, tmpc, r.cy).cy;                /* 194 (carry only) */
    setf(c, CF, carry);
    *ptmpc = tmpc;
    *ptmpa = tmpa;
    *pcarry = carry;
    return 0;
}

static int post_idiv(X86 *c, int wide, uint16_t *tmpa, uint16_t tmpb,
                     uint16_t tmpc, uint16_t *quot, int carry, int neg)
{
    if (!carry)
        return 1;                                      /* 1c4 NCY INT0 */
    int sign = (tmpb >> (wide ? 15 : 7)) & 1;          /* 1c5 LRCY tmpb */
    if (sign)
        *tmpa = (uint16_t)(0 - *tmpa);                 /* 1c6/1c8 NEG tmpa */
    *quot = neg ? (uint16_t)(tmpc + 1)                 /* 1c9 INC tmpc */
                : (uint16_t)~tmpc;                     /* 1cb COM tmpc */
    setf(c, CF | OF, 0);                               /* 1cc CCOF */
    return 0;
}

/* Full DIV/IDIV. Returns nonzero on divide error (caller raises INT 0).
 * neg is seeded from the REP prefix. */
static int mc_div(X86 *c, int wide, uint32_t dividend, uint16_t divisor,
                  int sign, int neg, uint16_t *q, uint16_t *rem)
{
    uint16_t hi = wide ? (uint16_t)(dividend >> 16)
                       : (uint16_t)((dividend >> 8) & 0xFF);
    uint16_t tmpa = hi;
    uint16_t tmpc = wide ? (uint16_t)dividend : (uint16_t)(dividend & 0xFF);
    uint16_t tmpb = divisor;
    int carry;

    if (sign)
        pre_idiv(c, wide, &tmpa, &tmpb, &tmpc, &neg);
    if (cord(c, wide, &tmpc, &tmpa, tmpb, &carry))
        return 1;
    uint16_t sigma = (uint16_t)~tmpc;                  /* 164 COM1 tmpc */
    if (sign && post_idiv(c, wide, &tmpa, hi, tmpc, &sigma, carry, neg))
        return 1;
    *q = sigma;
    *rem = tmpa;
    return 0;
}

/* ------------------------------------------------------------------ */
/* group 3: TEST/NOT/NEG/MUL/IMUL/DIV/IDIV                             */

static void grp3_8(X86 *c, Pfx *p, EA *e)
{
    switch (e->reg) {
    case 0: case 1: {                    /* TEST rm8,imm8 (1 = alias) */
        uint8_t v = rdm8(c, e);
        uint8_t imm = fetch8(c);
        log8(c, (uint8_t)(v & imm));
        break;
    }
    case 2: wrm8(c, e, (uint8_t)~rdm8(c, e)); break;          /* NOT */
    case 3: wrm8(c, e, sub8(c, 0, rdm8(c, e), 0)); break;     /* NEG */
    case 4: {                                                 /* MUL */
        uint16_t r = (uint16_t)((uint16_t)get_r8(c, 0) * rdm8(c, e));
        c->r[AX] = r;
        setf(c, CF | OF, (r & 0xFF00) != 0);
        break;
    }
    case 5: {                                                 /* IMUL */
        int16_t r = (int16_t)((int16_t)(int8_t)get_r8(c, 0) *
                              (int16_t)(int8_t)rdm8(c, e));
        c->r[AX] = (uint16_t)r;
        setf(c, CF | OF, r != (int16_t)(int8_t)r);
        break;
    }
    default: {                                            /* DIV / IDIV */
        uint16_t q, rem;
        if (mc_div(c, 0, c->r[AX], rdm8(c, e), e->reg == 7, p->rep != 0,
                   &q, &rem)) {
            do_int(c, 0);
            break;
        }
        set_r8(c, 0, (uint8_t)q);
        set_r8(c, 4, (uint8_t)rem);
        break;
    }
    }
}

static void grp3_16(X86 *c, Pfx *p, EA *e)
{
    switch (e->reg) {
    case 0: case 1: {
        uint16_t v = rdm16(c, e);
        uint16_t imm = fetch16(c);
        log16(c, (uint16_t)(v & imm));
        break;
    }
    case 2: wrm16(c, e, (uint16_t)~rdm16(c, e)); break;
    case 3: wrm16(c, e, sub16(c, 0, rdm16(c, e), 0)); break;
    case 4: {
        uint32_t r = (uint32_t)c->r[AX] * rdm16(c, e);
        c->r[AX] = (uint16_t)r;
        c->r[DX] = (uint16_t)(r >> 16);
        setf(c, CF | OF, c->r[DX] != 0);
        break;
    }
    case 5: {
        int32_t r = (int32_t)(int16_t)c->r[AX] * (int16_t)rdm16(c, e);
        c->r[AX] = (uint16_t)r;
        c->r[DX] = (uint16_t)((uint32_t)r >> 16);
        setf(c, CF | OF, r != (int32_t)(int16_t)r);
        break;
    }
    default: {                                            /* DIV / IDIV */
        uint16_t q, rem;
        uint32_t t = ((uint32_t)c->r[DX] << 16) | c->r[AX];
        if (mc_div(c, 1, t, rdm16(c, e), e->reg == 7, p->rep != 0,
                   &q, &rem)) {
            do_int(c, 0);
            break;
        }
        c->r[AX] = q;
        c->r[DX] = rem;
        break;
    }
    }
}

/* ------------------------------------------------------------------ */
/* BCD adjust                                                          */

/* BCD adjusts carry two hardware quirks (validated against the 8088 v2
 * vectors; undefined-flag ranges from MartyPC's hardware captures):
 *   - DAA/DAS: when AF is set on entry, the high-digit threshold is
 *     0x9F, not the documented 0x99.
 *   - AAA/AAS: AH is adjusted by exactly +/-1 — the +/-6 on AL does NOT
 *     carry into AH (Intel's "AX +/- 0x106" pseudocode is wrong). */

static void op_daa(X86 *c)
{
    uint8_t al = get_r8(c, 0), old_al = al;
    int old_cf = (c->flags & CF) != 0;
    int old_af = (c->flags & AF) != 0;
    uint8_t al_check = old_af ? 0x9F : 0x99;

    if (old_cf) setf(c, OF, al >= 0x1A && al <= 0x7F);
    else        setf(c, OF, al >= 0x7A && al <= 0x7F);

    if ((al & 0x0F) > 9 || old_af) {
        al = (uint8_t)(al + 6);
        setf(c, AF, 1);
    } else {
        setf(c, AF, 0);
    }
    if (old_al > al_check || old_cf) {
        al = (uint8_t)(al + 0x60);
        setf(c, CF, 1);
    } else {
        setf(c, CF, 0);
    }
    set_r8(c, 0, al);
    szp8(c, al);
}

static void op_das(X86 *c)
{
    uint8_t al = get_r8(c, 0), old_al = al;
    int old_cf = (c->flags & CF) != 0;
    int old_af = (c->flags & AF) != 0;
    uint8_t al_check = old_af ? 0x9F : 0x99;

    int of;
    if (!old_af && !old_cf)     of = al >= 0x9A && al <= 0xDF;
    else if (old_af && !old_cf) of = (al >= 0x80 && al <= 0x85) ||
                                     (al >= 0xA0 && al <= 0xE5);
    else if (!old_af && old_cf) of = al >= 0x80 && al <= 0xDF;
    else                        of = al >= 0x80 && al <= 0xE5;
    setf(c, OF, of);

    if ((al & 0x0F) > 9 || old_af) {
        al = (uint8_t)(al - 6);
        setf(c, AF, 1);
    } else {
        setf(c, AF, 0);
    }
    if (old_al > al_check || old_cf) {
        al = (uint8_t)(al - 0x60);
        setf(c, CF, 1);
    } else {
        setf(c, CF, 0);
    }
    set_r8(c, 0, al);
    szp8(c, al);
}

static void op_aaa(X86 *c)
{
    uint8_t old_al = get_r8(c, 0);
    uint8_t new_al;
    if ((old_al & 0x0F) > 9 || (c->flags & AF)) {
        set_r8(c, 4, (uint8_t)(get_r8(c, 4) + 1));
        new_al = (uint8_t)(old_al + 6);
        setf(c, AF | CF, 1);
    } else {
        new_al = old_al;
        setf(c, AF | CF, 0);
    }
    set_r8(c, 0, (uint8_t)(new_al & 0x0F));
    setf(c, ZF, new_al == 0);              /* undefined flags: hw-captured, */
    setf(c, PF, parity_even(new_al));      /* computed from pre-mask AL     */
    setf(c, SF, old_al >= 0x7A && old_al <= 0xF9);
    setf(c, OF, old_al >= 0x7A && old_al <= 0x7F);
}

static void op_aas(X86 *c)
{
    uint8_t old_al = get_r8(c, 0);
    int old_af = (c->flags & AF) != 0;
    uint8_t new_al;
    if ((old_al & 0x0F) > 9 || old_af) {
        set_r8(c, 4, (uint8_t)(get_r8(c, 4) - 1));
        new_al = (uint8_t)(old_al - 6);
        setf(c, AF | CF, 1);
    } else {
        new_al = old_al;
        setf(c, AF | CF, 0);
    }
    set_r8(c, 0, (uint8_t)(new_al & 0x0F));
    setf(c, ZF, new_al == 0);
    setf(c, PF, parity_even(new_al));
    setf(c, OF, old_af && old_al >= 0x80 && old_al <= 0x85);
    setf(c, SF, (!old_af && old_al >= 0x80) ||
                (old_af && (old_al <= 0x05 || old_al >= 0x86)));
}

/* ------------------------------------------------------------------ */
/* string ops (with REP handling; CX counts, ES:DI never overridable)  */

static void string_op(X86 *c, Pfx *p, uint8_t op)
{
    int wide = op & 1;
    uint16_t sseg = c->sr[(p->seg >= 0) ? p->seg : DS];
    int step = (c->flags & DF) ? -(wide + 1) : (wide + 1);

    for (;;) {
        if (p->rep && c->r[CX] == 0)
            break;
        int is_cmp = 0;
        switch (op & 0xFE) {
        case 0xA4:                                       /* MOVS */
            if (wide) mwr16(c, c->sr[ES], c->r[DI], mrd16(c, sseg, c->r[SI]));
            else      mwr8(c, c->sr[ES], c->r[DI], mrd8(c, sseg, c->r[SI]));
            c->r[SI] = (uint16_t)(c->r[SI] + step);
            c->r[DI] = (uint16_t)(c->r[DI] + step);
            break;
        case 0xA6:                                       /* CMPS: [SI]-[DI] */
            if (wide) sub16(c, mrd16(c, sseg, c->r[SI]),
                            mrd16(c, c->sr[ES], c->r[DI]), 0);
            else      sub8(c, mrd8(c, sseg, c->r[SI]),
                           mrd8(c, c->sr[ES], c->r[DI]), 0);
            c->r[SI] = (uint16_t)(c->r[SI] + step);
            c->r[DI] = (uint16_t)(c->r[DI] + step);
            is_cmp = 1;
            break;
        case 0xAA:                                       /* STOS */
            if (wide) mwr16(c, c->sr[ES], c->r[DI], c->r[AX]);
            else      mwr8(c, c->sr[ES], c->r[DI], get_r8(c, 0));
            c->r[DI] = (uint16_t)(c->r[DI] + step);
            break;
        case 0xAC:                                       /* LODS */
            if (wide) c->r[AX] = mrd16(c, sseg, c->r[SI]);
            else      set_r8(c, 0, mrd8(c, sseg, c->r[SI]));
            c->r[SI] = (uint16_t)(c->r[SI] + step);
            break;
        default:                                         /* SCAS: AL/AX-[DI] */
            if (wide) sub16(c, c->r[AX], mrd16(c, c->sr[ES], c->r[DI]), 0);
            else      sub8(c, get_r8(c, 0), mrd8(c, c->sr[ES], c->r[DI]), 0);
            c->r[DI] = (uint16_t)(c->r[DI] + step);
            is_cmp = 1;
            break;
        }
        if (!p->rep)
            break;
        c->r[CX]--;
        if (is_cmp) {
            if (p->rep == 1 && !(c->flags & ZF)) break;
            if (p->rep == 2 &&  (c->flags & ZF)) break;
        }
    }
}

/* ------------------------------------------------------------------ */
/* the dispatcher                                                      */

static void exec(X86 *c, Pfx *p, uint8_t op)
{
    EA e;

    /* 00-3F ALU block: xx0-xx5 of each row of 8 */
    if (op < 0x40 && (op & 7) < 6) {
        int aop = (op >> 3) & 7;
        switch (op & 7) {
        case 0: {                                  /* rm8, r8 */
            modrm(c, p, &e);
            uint8_t r = alu8(c, aop, rdm8(c, &e), get_r8(c, e.reg));
            if (aop != 7) wrm8(c, &e, r);
            break;
        }
        case 1: {                                  /* rm16, r16 */
            modrm(c, p, &e);
            uint16_t r = alu16(c, aop, rdm16(c, &e), c->r[e.reg]);
            if (aop != 7) wrm16(c, &e, r);
            break;
        }
        case 2: {                                  /* r8, rm8 */
            modrm(c, p, &e);
            uint8_t r = alu8(c, aop, get_r8(c, e.reg), rdm8(c, &e));
            if (aop != 7) set_r8(c, e.reg, r);
            break;
        }
        case 3: {                                  /* r16, rm16 */
            modrm(c, p, &e);
            uint16_t r = alu16(c, aop, c->r[e.reg], rdm16(c, &e));
            if (aop != 7) c->r[e.reg] = r;
            break;
        }
        case 4: {                                  /* AL, imm8 */
            uint8_t r = alu8(c, aop, get_r8(c, 0), fetch8(c));
            if (aop != 7) set_r8(c, 0, r);
            break;
        }
        default: {                                 /* AX, imm16 */
            uint16_t r = alu16(c, aop, c->r[AX], fetch16(c));
            if (aop != 7) c->r[AX] = r;
            break;
        }
        }
        return;
    }

    if (op >= 0x40 && op <= 0x47) { c->r[op & 7] = inc16(c, c->r[op & 7]); return; }
    if (op >= 0x48 && op <= 0x4F) { c->r[op & 7] = dec16(c, c->r[op & 7]); return; }
    if (op >= 0x50 && op <= 0x57) {
        /* 8086 PUSH SP pushes the new (decremented) SP */
        uint16_t v = c->r[op & 7];
        if ((op & 7) == SP) v = (uint16_t)(v - 2);
        push16(c, v);
        return;
    }
    if (op >= 0x58 && op <= 0x5F) { c->r[op & 7] = pop16(c); return; }
    if (op >= 0x60 && op <= 0x7F) {          /* Jcc (60-6F undoc aliases) */
        int8_t d = (int8_t)fetch8(c);
        if (cond(c, op & 0xF)) c->ip = (uint16_t)(c->ip + d);
        return;
    }
    if (op >= 0x90 && op <= 0x97) {          /* XCHG AX,r16 (90 = NOP) */
        uint16_t t = c->r[AX];
        c->r[AX] = c->r[op & 7];
        c->r[op & 7] = t;
        return;
    }
    if (op >= 0xB0 && op <= 0xB7) { set_r8(c, op & 7, fetch8(c)); return; }
    if (op >= 0xB8 && op <= 0xBF) { c->r[op & 7] = fetch16(c); return; }
    if (op >= 0xD8 && op <= 0xDF) { modrm(c, p, &e); return; }   /* ESC/FPU */

    switch (op) {
    case 0x06: case 0x0E: case 0x16: case 0x1E:            /* PUSH sreg */
        push16(c, c->sr[(op >> 3) & 3]);
        break;
    case 0x07: case 0x17: case 0x1F:                       /* POP sreg */
        c->sr[(op >> 3) & 3] = pop16(c);
        c->inhibit = 1;                  /* interrupt shadow: an IRQ between
                                          * POP SS and POP SP would frame on
                                          * a torn stack */
        break;
    case 0x0F:                                             /* POP CS (undoc) */
        c->sr[CS] = pop16(c);
        c->inhibit = 1;
        break;
    case 0x27: op_daa(c); break;
    case 0x2F: op_das(c); break;
    case 0x37: op_aaa(c); break;
    case 0x3F: op_aas(c); break;

    case 0x80: case 0x82: {                  /* grp1 rm8,imm8 (82 = alias) */
        modrm(c, p, &e);
        uint8_t a = rdm8(c, &e);
        uint8_t b = fetch8(c);
        uint8_t r = alu8(c, e.reg, a, b);
        if (e.reg != 7) wrm8(c, &e, r);
        break;
    }
    case 0x81: {                             /* grp1 rm16,imm16 */
        modrm(c, p, &e);
        uint16_t a = rdm16(c, &e);
        uint16_t b = fetch16(c);
        uint16_t r = alu16(c, e.reg, a, b);
        if (e.reg != 7) wrm16(c, &e, r);
        break;
    }
    case 0x83: {                             /* grp1 rm16,imm8 sign-extended */
        modrm(c, p, &e);
        uint16_t a = rdm16(c, &e);
        uint16_t b = (uint16_t)(int16_t)(int8_t)fetch8(c);
        uint16_t r = alu16(c, e.reg, a, b);
        if (e.reg != 7) wrm16(c, &e, r);
        break;
    }
    case 0x84: modrm(c, p, &e); log8(c, (uint8_t)(rdm8(c, &e) & get_r8(c, e.reg))); break;
    case 0x85: modrm(c, p, &e); log16(c, (uint16_t)(rdm16(c, &e) & c->r[e.reg])); break;
    case 0x86: {                             /* XCHG r8,rm8 */
        modrm(c, p, &e);
        uint8_t t = rdm8(c, &e);
        wrm8(c, &e, get_r8(c, e.reg));
        set_r8(c, e.reg, t);
        break;
    }
    case 0x87: {
        modrm(c, p, &e);
        uint16_t t = rdm16(c, &e);
        wrm16(c, &e, c->r[e.reg]);
        c->r[e.reg] = t;
        break;
    }
    case 0x88: modrm(c, p, &e); wrm8(c, &e, get_r8(c, e.reg)); break;
    case 0x89: modrm(c, p, &e); wrm16(c, &e, c->r[e.reg]); break;
    case 0x8A: modrm(c, p, &e); set_r8(c, e.reg, rdm8(c, &e)); break;
    case 0x8B: modrm(c, p, &e); c->r[e.reg] = rdm16(c, &e); break;
    case 0x8C: modrm(c, p, &e); wrm16(c, &e, c->sr[e.reg & 3]); break;
    case 0x8D: modrm(c, p, &e); c->r[e.reg] = e.off; break;    /* LEA */
    case 0x8E:                               /* MOV sreg,rm16 */
        modrm(c, p, &e);
        c->sr[e.reg & 3] = rdm16(c, &e);
        c->inhibit = 1;                      /* shadow (MOV SS,x / MOV SP,y) */
        break;
    case 0x8F: {                             /* POP rm16 */
        modrm(c, p, &e);
        uint16_t v = pop16(c);
        wrm16(c, &e, v);
        break;
    }

    case 0x98: c->r[AX] = (uint16_t)(int16_t)(int8_t)get_r8(c, 0); break; /* CBW */
    case 0x99: c->r[DX] = (c->r[AX] & 0x8000) ? 0xFFFF : 0x0000; break;  /* CWD */
    case 0x9A: {                             /* CALL far ptr16:16 */
        uint16_t off = fetch16(c);
        uint16_t seg = fetch16(c);
        push16(c, c->sr[CS]);
        push16(c, c->ip);
        c->sr[CS] = seg;
        c->ip = off;
        break;
    }
    case 0x9B: break;                        /* WAIT */
    case 0x9C: push16(c, canon(c->flags)); break;
    case 0x9D: c->flags = canon(pop16(c)); break;
    case 0x9E:                               /* SAHF */
        c->flags = canon((uint16_t)((c->flags & 0xFF00) | get_r8(c, 4)));
        break;
    case 0x9F: set_r8(c, 4, (uint8_t)canon(c->flags)); break;  /* LAHF */

    case 0xA0: {                             /* MOV AL,[moffs] */
        uint16_t off = fetch16(c);
        set_r8(c, 0, mrd8(c, c->sr[(p->seg >= 0) ? p->seg : DS], off));
        break;
    }
    case 0xA1: {
        uint16_t off = fetch16(c);
        c->r[AX] = mrd16(c, c->sr[(p->seg >= 0) ? p->seg : DS], off);
        break;
    }
    case 0xA2: {
        uint16_t off = fetch16(c);
        mwr8(c, c->sr[(p->seg >= 0) ? p->seg : DS], off, get_r8(c, 0));
        break;
    }
    case 0xA3: {
        uint16_t off = fetch16(c);
        mwr16(c, c->sr[(p->seg >= 0) ? p->seg : DS], off, c->r[AX]);
        break;
    }

    case 0xA4: case 0xA5: case 0xA6: case 0xA7:
    case 0xAA: case 0xAB: case 0xAC: case 0xAD: case 0xAE: case 0xAF:
        string_op(c, p, op);
        break;

    case 0xA8: log8(c, (uint8_t)(get_r8(c, 0) & fetch8(c))); break;
    case 0xA9: log16(c, (uint16_t)(c->r[AX] & fetch16(c))); break;

    case 0xC0: case 0xC2: {                  /* RET imm16 (C0 = alias) */
        uint16_t imm = fetch16(c);
        c->ip = pop16(c);
        c->r[SP] = (uint16_t)(c->r[SP] + imm);
        break;
    }
    case 0xC1: case 0xC3:                    /* RET (C1 = alias) */
        c->ip = pop16(c);
        break;
    case 0xC4: {                             /* LES r16,m32 */
        modrm(c, p, &e);
        c->r[e.reg] = mrd16(c, c->sr[e.seg], e.off);
        c->sr[ES]   = mrd16(c, c->sr[e.seg], (uint16_t)(e.off + 2));
        break;
    }
    case 0xC5: {                             /* LDS r16,m32 */
        modrm(c, p, &e);
        c->r[e.reg] = mrd16(c, c->sr[e.seg], e.off);
        c->sr[DS]   = mrd16(c, c->sr[e.seg], (uint16_t)(e.off + 2));
        break;
    }
    case 0xC6: modrm(c, p, &e); wrm8(c, &e, fetch8(c)); break;   /* reg ignored */
    case 0xC7: modrm(c, p, &e); wrm16(c, &e, fetch16(c)); break;
    case 0xC8: case 0xCA: {                  /* RETF imm16 (C8 = alias) */
        uint16_t imm = fetch16(c);
        c->ip = pop16(c);
        c->sr[CS] = pop16(c);
        c->r[SP] = (uint16_t)(c->r[SP] + imm);
        break;
    }
    case 0xC9: case 0xCB:                    /* RETF (C9 = alias) */
        c->ip = pop16(c);
        c->sr[CS] = pop16(c);
        break;
    case 0xCC: do_int(c, 3); break;
    case 0xCD: do_int(c, fetch8(c)); break;
    case 0xCE: if (c->flags & OF) do_int(c, 4); break;
    case 0xCF:                               /* IRET */
        c->ip = pop16(c);
        c->sr[CS] = pop16(c);
        c->flags = canon(pop16(c));
        break;

    case 0xD0: modrm(c, p, &e); grp2(c, &e, 0, 1); break;
    case 0xD1: modrm(c, p, &e); grp2(c, &e, 1, 1); break;
    case 0xD2: modrm(c, p, &e); grp2(c, &e, 0, get_r8(c, 1)); break;
    case 0xD3: modrm(c, p, &e); grp2(c, &e, 1, get_r8(c, 1)); break;
    case 0xD4: {                             /* AAM imm8 — divides via CORD */
        uint8_t imm = fetch8(c);
        uint16_t tmpc = get_r8(c, 0), tmpa = 0;
        int carry;
        if (cord(c, 0, &tmpc, &tmpa, imm, &carry)) {
            szp8(c, 0);
            setf(c, CF | AF | OF, 0);
            do_int(c, 0);                    /* AAM 0: divide error */
            break;
        }
        set_r8(c, 4, (uint8_t)~tmpc);        /* COM1: quotient -> AH */
        set_r8(c, 0, (uint8_t)tmpa);         /* remainder -> AL */
        szp8(c, get_r8(c, 0));
        setf(c, CF | AF | OF, 0);
        break;
    }
    case 0xD5: {                             /* AAD imm8 */
        uint8_t imm = fetch8(c);
        uint8_t r = add8(c, (uint8_t)(get_r8(c, 4) * imm), get_r8(c, 0), 0);
        set_r8(c, 0, r);
        set_r8(c, 4, 0);
        break;
    }
    case 0xD6:                               /* SALC (undocumented) */
        set_r8(c, 0, (c->flags & CF) ? 0xFF : 0x00);
        break;
    case 0xD7:                               /* XLAT */
        set_r8(c, 0, mrd8(c, c->sr[(p->seg >= 0) ? p->seg : DS],
                          (uint16_t)(c->r[BX] + get_r8(c, 0))));
        break;

    case 0xE0: {                             /* LOOPNZ */
        int8_t d = (int8_t)fetch8(c);
        if (--c->r[CX] && !(c->flags & ZF)) c->ip = (uint16_t)(c->ip + d);
        break;
    }
    case 0xE1: {                             /* LOOPZ */
        int8_t d = (int8_t)fetch8(c);
        if (--c->r[CX] && (c->flags & ZF)) c->ip = (uint16_t)(c->ip + d);
        break;
    }
    case 0xE2: {                             /* LOOP */
        int8_t d = (int8_t)fetch8(c);
        if (--c->r[CX]) c->ip = (uint16_t)(c->ip + d);
        break;
    }
    case 0xE3: {                             /* JCXZ */
        int8_t d = (int8_t)fetch8(c);
        if (!c->r[CX]) c->ip = (uint16_t)(c->ip + d);
        break;
    }

    case 0xE4: { uint16_t pt = fetch8(c); set_r8(c, 0, c->in8 ? c->in8(c, pt) : 0xFF); break; }
    case 0xE5: {
        uint16_t pt = fetch8(c);
        uint8_t lo = c->in8 ? c->in8(c, pt) : 0xFF;
        uint8_t hi = c->in8 ? c->in8(c, (uint16_t)(pt + 1)) : 0xFF;
        c->r[AX] = (uint16_t)(lo | ((uint16_t)hi << 8));
        break;
    }
    case 0xE6: { uint16_t pt = fetch8(c); if (c->out8) c->out8(c, pt, get_r8(c, 0)); break; }
    case 0xE7: {
        uint16_t pt = fetch8(c);
        if (c->out8) {
            c->out8(c, pt, get_r8(c, 0));
            c->out8(c, (uint16_t)(pt + 1), get_r8(c, 4));
        }
        break;
    }
    case 0xEC: set_r8(c, 0, c->in8 ? c->in8(c, c->r[DX]) : 0xFF); break;
    case 0xED: {
        uint8_t lo = c->in8 ? c->in8(c, c->r[DX]) : 0xFF;
        uint8_t hi = c->in8 ? c->in8(c, (uint16_t)(c->r[DX] + 1)) : 0xFF;
        c->r[AX] = (uint16_t)(lo | ((uint16_t)hi << 8));
        break;
    }
    case 0xEE: if (c->out8) c->out8(c, c->r[DX], get_r8(c, 0)); break;
    case 0xEF:
        if (c->out8) {
            c->out8(c, c->r[DX], get_r8(c, 0));
            c->out8(c, (uint16_t)(c->r[DX] + 1), get_r8(c, 4));
        }
        break;

    case 0xE8: {                             /* CALL rel16 */
        uint16_t d = fetch16(c);
        push16(c, c->ip);
        c->ip = (uint16_t)(c->ip + d);
        break;
    }
    case 0xE9: {                             /* JMP rel16 */
        uint16_t d = fetch16(c);
        c->ip = (uint16_t)(c->ip + d);
        break;
    }
    case 0xEA: {                             /* JMP far ptr16:16 */
        uint16_t off = fetch16(c);
        uint16_t seg = fetch16(c);
        c->sr[CS] = seg;
        c->ip = off;
        break;
    }
    case 0xEB: {                             /* JMP rel8 */
        int8_t d = (int8_t)fetch8(c);
        c->ip = (uint16_t)(c->ip + d);
        break;
    }

    case 0xF4: c->halted = 1; break;
    case 0xF5: c->flags ^= CF; break;        /* CMC */
    case 0xF6: modrm(c, p, &e); grp3_8(c, p, &e); break;
    case 0xF7: modrm(c, p, &e); grp3_16(c, p, &e); break;
    case 0xF8: setf(c, CF, 0); break;
    case 0xF9: setf(c, CF, 1); break;
    case 0xFA: setf(c, IF_, 0); break;
    case 0xFB:                               /* STI sets IF at once, but
                                              * delivery waits one more
                                              * instruction (STI;RET tails) */
        setf(c, IF_, 1);
        c->inhibit = 1;
        break;
    case 0xFC: setf(c, DF, 0); break;
    case 0xFD: setf(c, DF, 1); break;

    case 0xFE:                               /* grp4: INC/DEC rm8 */
        modrm(c, p, &e);
        if (e.reg == 0)      wrm8(c, &e, inc8(c, rdm8(c, &e)));
        else if (e.reg == 1) wrm8(c, &e, dec8(c, rdm8(c, &e)));
        /* reg 2-7: undefined, not in the test set; treated as no-op */
        break;

    case 0xFF:                               /* grp5 */
        modrm(c, p, &e);
        switch (e.reg) {
        case 0: wrm16(c, &e, inc16(c, rdm16(c, &e))); break;
        case 1: wrm16(c, &e, dec16(c, rdm16(c, &e))); break;
        case 2: {                            /* CALL rm16 */
            uint16_t t = rdm16(c, &e);
            push16(c, c->ip);
            c->ip = t;
            break;
        }
        case 3: {                            /* CALL far m16:16 */
            uint16_t off = mrd16(c, c->sr[e.seg], e.off);
            uint16_t seg = mrd16(c, c->sr[e.seg], (uint16_t)(e.off + 2));
            push16(c, c->sr[CS]);
            push16(c, c->ip);
            c->sr[CS] = seg;
            c->ip = off;
            break;
        }
        case 4: c->ip = rdm16(c, &e); break; /* JMP rm16 */
        case 5: {                            /* JMP far m16:16 */
            uint16_t off = mrd16(c, c->sr[e.seg], e.off);
            uint16_t seg = mrd16(c, c->sr[e.seg], (uint16_t)(e.off + 2));
            c->sr[CS] = seg;
            c->ip = off;
            break;
        }
        default: {                           /* PUSH rm16 (7 = alias of 6) */
            uint16_t v = rdm16(c, &e);
            if (e.isreg && e.rm == SP) v = (uint16_t)(v - 2);
            push16(c, v);
            break;
        }
        }
        break;

    default:
        /* unreachable: every top-level opcode is handled above */
        break;
    }
}

/* ------------------------------------------------------------------ */
/* public API                                                          */

void x86_step(X86 *c)
{
    if (c->halted)
        return;

    /* end of the interrupt shadow: a sreg load or STI set inhibit LAST
     * step so x86_irq couldn't split e.g. MOV SS,x / MOV SP,y. Cleared
     * exactly once per architectural instruction — the prefix loop below
     * continues without re-entering here, so prefixes can't cut the
     * shadow short. */
    c->inhibit = 0;

    Pfx p = { -1, 0 };
    int trap = (c->flags & TF) != 0;
    uint8_t op;

    for (;;) {
        op = fetch8(c);
        switch (op) {
        case 0x26: p.seg = ES; continue;
        case 0x2E: p.seg = CS; continue;
        case 0x36: p.seg = SS; continue;
        case 0x3E: p.seg = DS; continue;
        case 0xF0: case 0xF1: continue;      /* LOCK */
        case 0xF2: p.rep = 2; continue;
        case 0xF3: p.rep = 1; continue;
        default: break;
        }
        break;
    }

    exec(c, &p, op);

    if (trap && (c->flags & TF))
        do_int(c, 1);
}

int x86_irq(X86 *c, int n)
{
    if (c->inhibit)             /* sreg-load/STI shadow: caller retries */
        return 0;
    if (!(c->flags & IF_))
        return 0;
    c->halted = 0;
    do_int(c, n);
    return 1;
}

void x86_reset(X86 *c)
{
    memset(c->r, 0, sizeof c->r);
    memset(c->sr, 0, sizeof c->sr);
    c->sr[CS] = 0xFFFF;
    c->ip     = 0;
    c->flags  = canon(0);
    c->halted = 0;
    c->inhibit = 0;
}

X86 *x86_new(void)
{
    X86 *c = calloc(1, sizeof *c);
    if (!c)
        return NULL;
    c->mem = calloc(1, 1 << 20);
    if (!c->mem) {
        free(c);
        return NULL;
    }
    x86_reset(c);
    return c;
}

void x86_free(X86 *c)
{
    if (c) {
        free(c->mem);
        free(c);
    }
}
