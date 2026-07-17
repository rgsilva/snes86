/* x86trace — reference-side of the M4 lockstep parity harness.
 *
 * Loads an instruction stream at guest linear 0x1000, applies the same
 * canonical initial state as snes/cputest.asm, steps N instructions and
 * prints one line of register state per step (matching the format the
 * Mesen2 Lua script produces from the 65816 core's WRAM snapshots).
 */
#include <stdio.h>
#include <stdlib.h>
#include "x86.h"

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: x86trace stream.bin count\n");
        return 2;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    int count = atoi(argv[2]);

    X86 *c = x86_new();
    size_t n = fread(c->mem + 0x1000, 1, 0x2000, f);
    fclose(f);
    if (!n) { fprintf(stderr, "empty stream\n"); return 1; }

    for (int i = 0; i < 0x1000; i++)
        c->mem[0x3000 + i] = (uint8_t)(i * 7 + 3);

    c->r[X86_AX] = 0x1111;
    c->r[X86_CX] = 0x2222;
    c->r[X86_DX] = 0x3333;
    c->r[X86_BX] = 0x2000;
    c->r[X86_SP] = 0x3FFE;
    c->r[X86_BP] = 0x2300;
    c->r[X86_SI] = 0x2100;
    c->r[X86_DI] = 0x2200;
    for (int s = 0; s < 4; s++)
        c->sr[s] = 0x0100;
    c->ip = 0;
    c->flags = 0xF002;

    for (int i = 0; i < count; i++) {
        x86_step(c);
        printf("%04X %04X %04X %04X %04X %04X %04X %04X "
               "%04X %04X %04X %04X %04X %04X\n",
               c->r[0], c->r[1], c->r[2], c->r[3],
               c->r[4], c->r[5], c->r[6], c->r[7],
               c->sr[0], c->sr[1], c->sr[2], c->sr[3],
               c->ip, c->flags);
    }
    x86_free(c);
    return 0;
}
