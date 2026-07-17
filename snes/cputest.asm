; snes86 M4 — lockstep parity harness ROM.
;
; Runs an embedded 8086 instruction stream through the 65816 core and
; writes a 28-byte register snapshot to $7F:0000+ after every guest
; instruction. When done, writes $CAFE to $7F:FFFC (count at $7F:FFFA);
; test/cputest.lua hex-dumps the records for comparison against the C
; core's x86trace output. No PPU, no NMI — pure CPU.
;
; Canonical initial state (must match core-c/src/x86trace.c):
;   AX=1111 CX=2222 DX=3333 BX=2000 SP=3FFE BP=2300 SI=2100 DI=2200
;   ES=CS=SS=DS=0100, IP=0, FLAGS=F002
;   code at linear 0x1000, data pattern (i*7+3)&FF at linear 0x3000+i
;   (i < 0x1000), rest of guest memory zero.

.INCLUDE "hdr.asm"
.INCLUDE "build/stream_meta.asm"    ; .DEFINE STREAM_COUNT / STREAM_BYTES

.INCLUDE "cpu.asm"
.INCLUDE "cpu2.asm"

.BANK 0 SLOT 0
.ORG 0
.SECTION "TestMain" SEMIFREE

.ACCU 16
.INDEX 16

EmptyHandler:
    rti
VBlank:
    rti

Reset:
    sei
    clc
    xce
    rep #$38
    ldx #$1FFF
    txs
    lda #$0000
    tcd
    sep #$20
    lda.b #$8F
    sta.l $002100            ; forced blank, no PPU use
    stz.w $4200
    lda.b #$7E
    pha
    plb                      ; DBR = $7E: guest memory bank
    rep #$20

    ; -- zero guest memory $7E:2000-$7E:FFFF
    lda #$0000
    ldx #$2000
_zg: sta.l $7E0000,x
    inx
    inx
    bne _zg                  ; wraps at $10000

    ; -- copy instruction stream to linear 0x1000 ($7E:3000)
    ldx #0
_cp: lda.l stream_start,x
    sta.l $7E3000,x
    inx
    inx
    cpx #STREAM_BYTES
    bcc _cp

    ; -- data pattern at linear 0x3000 ($7E:5000): byte i = (i*7+3)&FF
    ldx #0
_dp:
    txa
    sta tmp0
    asl a
    asl a
    asl a                    ; i*8
    sec
    sbc tmp0                 ; i*7
    clc
    adc #3
    sep #$20
    sta.l $7E5000,x
    rep #$20
    inx
    cpx #$1000
    bcc _dp

    ; -- guest register init
    lda #$1111
    sta gAX
    lda #$2222
    sta gCX
    lda #$3333
    sta gDX
    lda #$2000
    sta gBX
    lda #$3FFE
    sta gSP
    lda #$2300
    sta gBP
    lda #$2100
    sta gSI
    lda #$2200
    sta gDI
    lda #$0100
    sta gES
    sta gCS
    sta gSS
    sta gDS
    ; cached 24-bit bases: $7E2000 + seg*16 = $7E3000
    asl a
    asl a
    asl a
    asl a                    ; 0x1000
    clc
    adc #GUEST_BASE          ; 0x3000
    sta bES
    sta bCS
    sta bSS
    sta bDS
    sep #$20
    lda.b #$7E
    sta bES+2
    sta bCS+2
    sta bSS+2
    sta bDS+2
    rep #$20
    stz gIP
    stz gHALT
    lda #$F002
    sta fSTATIC
    stz lfKIND
    stz snapPTR

    ; -- run
    lda #STREAM_COUNT
    sta stepCNT
_run:
    jsr x86step
    jsr snapshot
    dec stepCNT
    bne _run

    ; -- done: publish count + magic for the Lua script
    lda #STREAM_COUNT
    sta.l $7FFFFA
    lda #$CAFE
    sta.l $7FFFFC
_halt:
    bra _halt

;----------------------------------------------------------------------
; snapshot: 14 words -> $7F:0000 + snapPTR
;----------------------------------------------------------------------
snapshot:
    jsr flags_norm
    ldx snapPTR
    lda gAX
    sta.l $7F0000,x
    lda gCX
    sta.l $7F0002,x
    lda gDX
    sta.l $7F0004,x
    lda gBX
    sta.l $7F0006,x
    lda gSP
    sta.l $7F0008,x
    lda gBP
    sta.l $7F000A,x
    lda gSI
    sta.l $7F000C,x
    lda gDI
    sta.l $7F000E,x
    lda gES
    sta.l $7F0010,x
    lda gCS
    sta.l $7F0012,x
    lda gSS
    sta.l $7F0014,x
    lda gDS
    sta.l $7F0016,x
    lda gIP
    sta.l $7F0018,x
    lda fSTATIC
    sta.l $7F001A,x
    txa
    clc
    adc #28
    sta snapPTR
    rts

.ENDS

.BANK 1 SLOT 0
.ORG 0
.SECTION "StreamData" SEMIFREE

stream_start:
    .INCBIN "build/stream.bin"

.ENDS
