/* x86.h — 8086 real-mode CPU core, reference implementation (snes86 M3).
 *
 * Design contract: this core is the correctness oracle for the 65816 port.
 * Keep it boring, allocation-free after x86_new(), and single-steppable.
 * Memory model: flat 1 MiB, physical wrap at 0xFFFFF (like a real 8088).
 */
#ifndef X86_H
#define X86_H

#include <stdint.h>

/* r[] indices */
enum { X86_AX, X86_CX, X86_DX, X86_BX, X86_SP, X86_BP, X86_SI, X86_DI };
/* sr[] indices */
enum { X86_ES, X86_CS, X86_SS, X86_DS };

/* FLAGS bits */
#define X86_CF 0x0001
#define X86_PF 0x0004
#define X86_AF 0x0010
#define X86_ZF 0x0040
#define X86_SF 0x0080
#define X86_TF 0x0100
#define X86_IF 0x0200
#define X86_DF 0x0400
#define X86_OF 0x0800

typedef struct X86 X86;

typedef uint8_t (*x86_in8_fn)(X86 *c, uint16_t port);
typedef void    (*x86_out8_fn)(X86 *c, uint16_t port, uint8_t v);
/* Return nonzero to swallow the interrupt (HLE BIOS hook for the DOS phase);
 * return 0 to vector through the guest IVT as normal. */
typedef int     (*x86_int_fn)(X86 *c, int n);

struct X86 {
    uint16_t r[8];      /* AX CX DX BX SP BP SI DI */
    uint16_t sr[4];     /* ES CS SS DS */
    uint16_t ip;
    uint16_t flags;
    uint8_t  halted;
    uint8_t  _pad[3];
    uint8_t *mem;       /* 1 MiB flat */
    x86_in8_fn  in8;    /* NULL -> reads 0xFF (matches test-suite convention) */
    x86_out8_fn out8;   /* NULL -> writes ignored */
    x86_int_fn  int_hook;
    void    *ctx;       /* free for the embedder */
};

X86 *x86_new(void);        /* cpu + zeroed 1 MiB memory */
void x86_free(X86 *c);
void x86_reset(X86 *c);    /* CS=FFFF IP=0000, flags cleared, not halted */
void x86_step(X86 *c);     /* one instruction, prefixes + full REP included */
void x86_irq(X86 *c, int n); /* hardware interrupt: taken if IF=1, wakes HLT */

#endif
