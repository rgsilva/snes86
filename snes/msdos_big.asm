; snes86 — BIGMEM variant: 172 KB guest PC (108 KB WRAM + 64 KB cart
; SRAM, banks $70/$71). Same DOS/A:/C: machine as msdos; the SRAM is
; guest high RAM instead of B:. Same free C: as the public build
; (overlay content only via OVERLAYS=). Bigger guests don't currently
; run (see docs/FUTURE.md). Build: make msdos_big -> build/msdos_big.sfc
.DEFINE BIGMEM
.INCLUDE "dosboot.asm"
