; snes86 — FSBOOT variant: the A: floppy is the Microsoft Flight
; Simulator 1.0 self-booting disk (../disks/fs1.img, 160KB 40/1/8)
; instead of PC DOS. Same machine otherwise; FS1 replaces DOS entirely.
; Build: make fs -> build/dosboot_fs.sfc
.DEFINE FSBOOT
.DEFINE DEVHD
.INCLUDE "dosboot.asm"
