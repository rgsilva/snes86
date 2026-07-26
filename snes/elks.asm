; sneslinux — ELKS 0.9.1 ROM-XIP variant: the 300 KB SA-1 guest plus two
; cart-ROM windows the guest reads/executes in place — the ELKS kernel at
; guest E0000 (banks 14-15) and its ROMFS root at 80000 (banks 16-19).
; It rides the same SA-1 board as msdos_sa1 and freedos — 108 KB WRAM +
; 192 KB BW-RAM (banks $40-$42) — and on Linux that extra RAM is the
; difference between a kernel that cannot fork /etc/rc.sys and a usable
; machine. Boot enters the kernel image's INT 19h handler at E000:0014;
; console is ELKS's headless driver over INT 10h/16h, so the stock snes86
; console and keyboard just work. Build: make elks -> build/elks.sfc
; (needs build/elks_rom.bin + build/elks_romfs.bin — see sneslinux/PLAN.md).
.DEFINE ELKS
.DEFINE SA1
.INCLUDE "dosboot.asm"
