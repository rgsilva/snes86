; snes86 — BIGMEM variant: 172 KB guest PC (108 KB WRAM + 64 KB cart
; SRAM, banks $70/$71). Same DOS/A:/C: machine as dosboot; the SRAM is
; guest high RAM instead of B:. Revives Rogue; bigger guests don't
; currently run (see docs/FUTURE.md). Build: make big -> build/dosboot_big.sfc
.DEFINE BIGMEM
.DEFINE DEVHD
.INCLUDE "dosboot.asm"
