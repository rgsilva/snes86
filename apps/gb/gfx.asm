; gfx.asm - BG renderer test ROM: four tile patterns in a (x+y)&3 grid,
; SCY=3 / SCX=5 to exercise coarse+fine scroll, BGP identity. Hangs
; forever; run under runpc with -cga to dump the final frame.

SECTION "entry", ROM0[$100]
    nop
    jp start

SECTION "main", ROM0[$150]
start:
    ld sp, $FFFE
    xor a
    ldh [$FF40], a      ; LCD off while we set up
    ld hl, $8000
    ld b, 16            ; tile 0: solid colour 0
    xor a
.t0:
    ld [hli], a
    dec b
    jr nz, .t0
    ld b, 8             ; tile 1: 1/2 checker
.t1:
    ld a, $AA
    ld [hli], a
    ld a, $55
    ld [hli], a
    dec b
    jr nz, .t1
    ld b, 16            ; tile 2: solid colour 3
    ld a, $FF
.t2:
    ld [hli], a
    dec b
    jr nz, .t2
    ld b, 8             ; tile 3: 3/0 vertical stripes
.t3:
    ld a, $F0
    ld [hli], a
    ld [hli], a
    dec b
    jr nz, .t3
    ld hl, $9800        ; map: tile = (row+col)&3
    ld c, 32
.mr:
    ld b, 32
.mc:
    ld a, b
    add a, c
    and 3
    ld [hli], a
    dec b
    jr nz, .mc
    dec c
    jr nz, .mr
    ld a, $E4           ; BGP identity (3,2,1,0)
    ldh [$FF47], a
    ld a, 3
    ldh [$FF42], a      ; SCY
    ld a, 5
    ldh [$FF43], a      ; SCX
    ld a, $91
    ldh [$FF40], a      ; LCD on, BG on, unsigned tiles
.hang:
    jr .hang
