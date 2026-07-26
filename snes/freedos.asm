; snes86 — FreeDOS 1.3 variant: the 300 KB SA-1 guest booting FreeDOS
; (GPL — kernel + FreeCOM fetched at build time by freedos/mkfreedos.py
; and assembled into a 360 KB A: floppy, never committed). FreeDOS needs
; a big machine: the kernel dies in init at 108 KB. It rides the same
; SA-1 board as msdos_sa1 — 108 KB WRAM + 192 KB BW-RAM (banks $40-$42)
; and a B: drive on BW-RAM bank $43. Same free C: as the public MS-DOS
; build. Build: make freedos -> build/freedos.sfc
.DEFINE FREEDOS
.DEFINE BIGMEM
.DEFINE SA1
.INCLUDE "dosboot.asm"
