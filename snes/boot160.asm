; snes86 — self-booting 160 KB disk (40 cyl x 1 head x 8 spt): the A:
; floppy is build/bootdisk.img instead of DOS — the BIOS boots its
; sector 0 like any other, and INT 13h serves the single-sided 8-sector
; geometry. `make boot DISK=path.img` copies the disk into build/ and
; picks this stub by size. Proven tenant: MS Flight Simulator 1.0
; (disks/fs1.img). Same machine otherwise; free C: unless OVERLAYS=.
.DEFINE FSBOOT
.INCLUDE "dosboot.asm"
