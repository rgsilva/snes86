; sneslinux — ELKS 0.9.1 ROM-XIP variant: the 172 KB BIGMEM guest plus two
; cart-ROM windows the guest reads/executes in place — the ELKS kernel at
; guest E0000 (banks 14-15) and its ROMFS root at 80000 (banks 16-19).
; Boot enters the kernel image's INT 19h handler at E000:0014; console is
; ELKS's headless driver over INT 10h/16h, so the stock snes86 console and
; keyboard just work. Build: make elks -> build/elks.sfc (needs
; build/elks_rom.bin + build/elks_romfs.bin — see sneslinux/PLAN.md).
.DEFINE ELKS
.DEFINE BIGMEM
.INCLUDE "dosboot.asm"
