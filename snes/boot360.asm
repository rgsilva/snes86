; snes86 — self-booting 360 KB disk (40 cyl x 2 heads x 9 spt): the disk
; replaces the DOS A: floppy wholesale — the BIOS boots its sector 0
; like any other; the geometry is the standard A: shape, so no INT 13h
; special-casing. `make boot DISK=path.img` copies the disk into build/
; and picks this stub by size. Same machine otherwise; free C: unless
; OVERLAYS=.
.DEFINE BOOTIMG
.INCLUDE "dosboot.asm"
