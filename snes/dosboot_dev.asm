; snes86 — DEVELOPER build. MS-DOS 2.0 + the FULL local C: app library
; (tools/mkhd.py, which pulls in copyrighted DOS software present only on
; the dev machine). The PUBLIC build is `make dosboot` (free C: only);
; this variant is for local testing. Build: make dev -> dosboot_dev.sfc
.DEFINE DEVHD
.INCLUDE "dosboot.asm"
