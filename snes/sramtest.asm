; SRAM extent probe. Requests 128 KB SRAM (SRAMSIZE $07) and measures how
; many distinct 32 KB banks the emulator/cart actually backs. LoROM maps
; SRAM into banks $70-$7D ($0000-$7FFF each); $7E-$7F are always WRAM, so
; we probe $70..$7D (14 banks). A "real" bank reads back its own unique
; signature; a mirrored one reads a later writer's signature; open-bus
; beyond the real size reads neither. The count of self-matches = the
; number of distinct physical 32 KB banks. Result -> WRAM $0004.

.MEMORYMAP
  SLOTSIZE $8000
  DEFAULTSLOT 0
  SLOT 0 $8000
.ENDME
.ROMBANKSIZE $8000
.ROMBANKS 4

.SNESHEADER
  ID "SNES"
  NAME "SRAM PROBE 128K      "
  LOROM
  CARTRIDGETYPE $02             ; ROM + RAM + battery
  ROMSIZE $08                   ; 128 KB ROM (4 banks; plenty)
  SRAMSIZE $07                  ; ask for 128 KB SRAM
  COUNTRY $01
  LICENSEECODE $00
  VERSION $00
.ENDSNES

.SNESNATIVEVECTOR
  COP EmptyHandler
  BRK EmptyHandler
  ABORT EmptyHandler
  NMI EmptyHandler
  IRQ EmptyHandler
.ENDNATIVEVECTOR
.SNESEMUVECTOR
  COP EmptyHandler
  ABORT EmptyHandler
  NMI EmptyHandler
  RESET Reset
  IRQBRK EmptyHandler
.ENDEMUVECTOR

.BANK 0 SLOT 0
.ORG 0
.SECTION "Main" SEMIFREE

.DEFINE NBANKS 14                ; $70..$7D

EmptyHandler:
    rti

Reset:
    sei
    clc
    xce
    rep #$30
    ldx #$1FFF
    txs
    lda #$0000
    tcd

    ; -- WRITE PHASE: [$70+i : 0000] = $C000 | i, for i = 0..NBANKS-1.
    ; $F0/$F1 = pointer offset (0), $F2 = pointer bank.
    ldy #0
_wr:
    stz $F0                      ; offset low16 = $0000
    tya
    clc
    adc #$0070
    sep #$20
    sta $F2                      ; bank byte = $70 + i
    rep #$20
    tya
    ora #$C000                   ; distinct signature per bank
    sta [$F0]
    iny
    cpy #NBANKS
    bcc _wr

    ; -- READ PHASE: count banks that read back their OWN signature.
    ldy #0
    ldx #0
_rd:
    stz $F0
    tya
    clc
    adc #$0070
    sep #$20
    sta $F2
    rep #$20
    lda [$F0]
    sta $00                      ; got
    tya
    ora #$C000                   ; expected
    cmp $00
    bne _rd_n
    inx                          ; self-match: a distinct physical bank
_rd_n:
    iny
    cpy #NBANKS
    bcc _rd
    stx $04                      ; RESULT: distinct 32 KB banks (× 32 = KB)

_halt:
    wai
    bra _halt

.ENDS
