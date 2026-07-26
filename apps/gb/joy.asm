; joy.asm - joypad + sprite test. A sprite sits mid-screen; d-pad moves
; it. Button presses report over serial: A->"A", B->"B", Select->"C",
; Start->"S"+STOP. Headless: pipe x/z/space/Enter through runpc and
; check the serial output; interactive: watch the sprite move.

SECTION "entry", ROM0[$100]
    nop
    jp start

SECTION "main", ROM0[$150]
start:
    ld sp, $FFFE
    xor a
    ldh [$FF40], a
    ld hl, $8010        ; tile 1: solid colour 3 square
    ld b, 16
    ld a, $FF
.t1:
    ld [hli], a
    dec b
    jr nz, .t1
    ld hl, $FE00        ; sprite 0: center, tile 1
    ld a, 80
    ld [hli], a         ; Y+16
    ld a, 84
    ld [hli], a         ; X+8
    ld a, 1
    ld [hli], a         ; tile
    xor a
    ld [hli], a         ; attrs
    ld a, $E4
    ldh [$FF47], a
    ldh [$FF48], a      ; OBP0
    ld a, $93            ; LCD on, BG on, OBJ on, unsigned tiles
    ldh [$FF40], a
    ld a, 1              ; IE = VBlank; IME stays off, HALT still wakes
    ldh [$FFFF], a
    ld c, 0              ; last-buttons mask (BC is 0013 post-boot)
loop:
    xor a
    ldh [$FF0F], a       ; ack, else the next HALT falls straight through
    halt
    nop
    ; --- d-pad
    ld a, $20           ; select P14 (dpad)... bit4 low
    ldh [$FF00], a
    ldh a, [$FF00]
    cpl
    and $0F
    ld b, a             ; 1=R 2=L 4=U 8=D
    ld hl, $FE01        ; sprite X
    bit 0, b
    jr z, .nr
    inc [hl]
.nr:
    bit 1, b
    jr z, .nl
    dec [hl]
.nl:
    ld hl, $FE00        ; sprite Y
    bit 2, b
    jr z, .nu
    dec [hl]
.nu:
    bit 3, b
    jr z, .nd
    inc [hl]
.nd:
    ; --- buttons (edge-triggered via last-state in C)
    ld a, $10           ; select P15 (buttons)
    ldh [$FF00], a
    ldh a, [$FF00]
    cpl
    and $0F
    ld b, a             ; 1=A 2=B 4=Sel 8=Start
    ld a, c
    cpl
    and b               ; newly pressed
    ld c, b             ; remember
    bit 0, a
    jr z, .na
    ld b, a
    ld a, "A"
    call putc
    ld a, b
.na:
    bit 1, a
    jr z, .nb
    ld b, a
    ld a, "B"
    call putc
    ld a, b
.nb:
    bit 2, a
    jr z, .nc
    ld b, a
    ld a, "C"
    call putc
    ld a, b
.nc:
    bit 3, a
    jr z, .ns
    ld a, "S"
    call putc
    stop
.ns:
    jr loop

putc:
    push af
    ldh [$FF01], a
    ld a, $81
    ldh [$FF02], a
    pop af
    ret
