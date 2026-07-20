; snes86 — PUBLIC RELEASE variant. MS-DOS 2.0 (MIT) + a FREE C: drive:
; our own snes86 tools shipped with Turbo Pascal source, plus a generated
; CC0 demo tune. No copyrighted DOS software. A: = build/msdos_a.img,
; C: = build/hd_free.img (tools/mkhd_free.py). Build: make release.
.DEFINE MSDOSA
.DEFINE HDFREE
.INCLUDE "dosboot.asm"
