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
  NAME "SNES86 PC-DOS BOOT   "
  ;    "123456789012345678901"
  FASTROM
  LOROM
  CARTRIDGETYPE $02             ; ROM + RAM + battery
  ROMSIZE $0C                   ; 4 MB
  SRAMSIZE $05                  ; 32 KB, the B: disk
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
