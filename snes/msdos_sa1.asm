; snes86 — SA-1 variant: 300 KB guest PC (108 KB WRAM + 192 KB SA-1
; BW-RAM, banks $40-$42) AND a B: drive (BW-RAM bank $43). The SA-1
; cartridge is used purely as a RAM expander: the SA-1 CPU is never
; released from reset — only the Super MMC and the 256 KB BW-RAM chip
; are in play. Same DOS/A:/C: machine and the same free C: as the
; public build (overlay content only via OVERLAYS=).
; Build: make msdos_sa1 -> build/msdos_sa1.sfc
.DEFINE SA1                  ; the big machine: BW-RAM region layer plus
                             ; the seam-safe machinery it needs (rd16m/
                             ; wr16m, fetch_rebase, the norm_* folds)
.INCLUDE "dosboot.asm"
