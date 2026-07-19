; snes86 — BIGMEM variant: 172 KB guest PC (108 KB WRAM + 64 KB cart
; SRAM, banks $70/$71). Same DOS/A:/C: machine as dosboot; the SRAM is
; guest high RAM instead of B:. Revives Elite (99 KB) + Starglider
; (95 KB). Build: make big -> build/dosboot_big.sfc
.DEFINE BIGMEM
.INCLUDE "dosboot.asm"
