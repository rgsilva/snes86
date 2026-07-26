;== snes86 DOS boot ROM — LoROM, 256 KB (code + fonts + 180 KB disk) ==

.MEMORYMAP
  SLOTSIZE $8000
  DEFAULTSLOT 0
  SLOT 0 $8000
.ENDME

.ROMBANKSIZE $8000
.ROMBANKS 128

.SNESHEADER
  ID "SNES"
.IFDEF ELKS
  NAME "SNESLINUX ELKS 172K  "
.ELSE
.IFDEF FREEDOS
  NAME "SNES86 FREEDOS SA1300"
.ELSE
.IFDEF PCDOS
  NAME "SNES86 PC-DOS BOOT   "
.ELSE
.IFDEF SA1
  NAME "SNES86 MS-DOS SA1300 "
.ELSE
.IFDEF BIGMEM
  NAME "SNES86 MS-DOS 172K   "
.ELSE
  NAME "SNES86 MS-DOS BOOT   "
.ENDIF
.ENDIF
.ENDIF
.ENDIF
.ENDIF
  ;    "123456789012345678901"
  FASTROM
  LOROM
.IFDEF SA1
  CARTRIDGETYPE $35             ; SA-1 + RAM + battery (map-mode byte is
                                ; patched to $23 post-link: wla has no
                                ; SA-1 mode — see tools/mksa1hdr.py)
.ELSE
  CARTRIDGETYPE $02             ; ROM + RAM + battery
.ENDIF
  ROMSIZE $0C                   ; 4 MB
.IFDEF SA1
  SRAMSIZE $07                  ; wla caps the field at $07; mksa1hdr.py
                                ; bumps it to $08 = 256 KB BW-RAM
.ELSE
.IFDEF BIGMEM
  SRAMSIZE $07                  ; 128 KB header -> 64 KB usable = guest hi RAM
.ELSE
  SRAMSIZE $05                  ; 32 KB, the B: disk
.ENDIF
.ENDIF
  COUNTRY $01
  LICENSEECODE $00
  VERSION $00
.ENDSNES

.BASE $80                       ; labels resolve to the fast mirrors

.SNESNATIVEVECTOR
  COP EmptyHandler
  BRK EmptyHandler
  ABORT EmptyHandler
  NMI VBlank
  IRQ EmptyHandler
.ENDNATIVEVECTOR

.SNESEMUVECTOR
  COP EmptyHandler
  ABORT EmptyHandler
  NMI EmptyHandler
  RESET Reset
  IRQBRK EmptyHandler
.ENDEMUVECTOR
