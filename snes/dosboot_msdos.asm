; snes86 — MS-DOS 2.0 variant. Boots the MIT-licensed Microsoft MS-DOS 2.0
; from the ROM disk instead of IBM PC-DOS 2.00. A: is the MS-DOS boot floppy
; (build/msdos_a.img, from msdos/mkmsdos.py); C: is the same app library.
; Build: make msdos  ->  build/dosboot_msdos.sfc
.DEFINE MSDOSA
.INCLUDE "dosboot.asm"
