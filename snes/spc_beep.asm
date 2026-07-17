; snes86 — SPC700 beep driver: the PC speaker, played by the S-SMP.
;
; One DSP voice looping a 16-sample square wave. The 65816 mailbox:
;   port0 ($F4) = DSP pitch low    port1 ($F5) = DSP pitch high
;   port2 ($F6) = 0 silence, nonzero play
; Tone freq = pitch / 2.048 (32kHz sample rate, 16-sample period);
; the 65816 computes pitch = 2443637 / PIT-divisor.
;
; Uploaded to $0200 via the IPL ROM protocol; entry at $0210.

.MEMORYMAP
DEFAULTSLOT 0
SLOT 0 $0000 SIZE $10000
.ENDME

.ROMBANKMAP
BANKSTOTAL 1
BANKSIZE $10000
BANKS 1
.ENDRO

.BANK 0 SLOT 0
.ORG $0200
.SECTION "Beep" FORCE

sdir:   .db $04, $02, $04, $02       ; sample 0: start $0204, loop $0204
brr:    .db $B3                      ; shift 11, filter 0, loop+end
        .db $77, $77, $77, $77       ; 8 samples +7
        .db $99, $99, $99, $99       ; 8 samples -7
        .db $00, $00, $00            ; pad so entry lands at $0210

entry:
    mov x, #$EF
    mov sp, x
    mov $F2, #$6C
    mov $F3, #$20                    ; FLG: echo off, unmuted
    mov $F2, #$0C
    mov $F3, #$7F                    ; master vol L
    mov $F2, #$1C
    mov $F3, #$7F                    ; master vol R
    mov $F2, #$2C
    mov $F3, #$00                    ; echo vol L
    mov $F2, #$3C
    mov $F3, #$00                    ; echo vol R
    mov $F2, #$5D
    mov $F3, #$02                    ; DIR = $0200
    mov $F2, #$2D
    mov $F3, #$00                    ; PMON off
    mov $F2, #$3D
    mov $F3, #$00                    ; NON off
    mov $F2, #$4D
    mov $F3, #$00                    ; EON off
    mov $F2, #$00
    mov $F3, #$7F                    ; v0 vol L
    mov $F2, #$01
    mov $F3, #$7F                    ; v0 vol R
    mov $F2, #$04
    mov $F3, #$00                    ; v0 SRCN 0
    mov $F2, #$05
    mov $F3, #$00                    ; v0 ADSR1 off -> GAIN
    mov $F2, #$07
    mov $F3, #$7F                    ; v0 GAIN: direct, max
    mov $F2, #$5C
    mov $F3, #$00                    ; clear KOF
    mov a, #$00
    mov $00, a                       ; playing = 0
hold:
    mov a, $F6                       ; wait out stale handshake values
    bne hold

loop:
    mov a, $F6                       ; command port
    beq off
    mov a, $F4                       ; pitch -> DSP v0 P
    mov $F2, #$02
    mov $F3, a
    mov a, $F5
    mov $F2, #$03
    mov $F3, a
    mov a, $00
    bne loop                         ; already keyed on
    mov $F2, #$5C
    mov $F3, #$00                    ; release any pending KOF
    mov $F2, #$4C
    mov $F3, #$01                    ; KON v0
    mov a, #$01
    mov $00, a
    bra loop
off:
    mov a, $00
    beq loop
    mov $F2, #$4C
    mov $F3, #$00
    mov $F2, #$5C
    mov $F3, #$01                    ; KOF v0
    mov a, #$00
    mov $00, a
    bra loop

.ENDS
