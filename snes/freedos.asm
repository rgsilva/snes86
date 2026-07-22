; snes86 — FreeDOS 1.3 variant: the 172 KB BIGMEM guest booting FreeDOS
; (GPL — kernel + FreeCOM fetched at build time by freedos/mkfreedos.py
; and assembled into a 360 KB A: floppy, never committed). FreeDOS needs
; the full BIGMEM machine: the kernel dies in init at 108 KB and reaches
; FreeCOM exactly at 172 KB. Same free C: as the public MS-DOS build.
; Build: make freedos -> build/freedos.sfc
.DEFINE FREEDOS
.DEFINE BIGMEM
.INCLUDE "dosboot.asm"
