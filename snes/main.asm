; snes86 M1 — mode-5 64x28 text console, standalone ROM.
;
; Console scheme (see tools/mkfont.py): mode 5 hi-res, two layers interleave
; the 64 text columns — BG2 (2bpp) carries even columns, BG1 (4bpp) odd ones.
; A char write is a single 2-byte tilemap write; scrolling is a ring buffer
; over the 32-row tilemap driven by the BG vertical scroll registers. The
; emulator core (M4+) will print through this exact interface.
;
; VRAM map (word addresses):
;   $0000-$03FF  BG2 tilemap 32x32 (even text columns)
;   $0400-$07FF  BG1 tilemap 32x32 (odd text columns)
;   $1000-$1FFF  BG2 tiles, 2bpp: 256 x [glyph][blank]
;   $3000-$4FFF  BG1 tiles, 4bpp: 256 x [blank][glyph]
;
; All VRAM/scroll traffic goes through a queue drained in NMI, so printing
; is safe at any time. Queue entry: addr word ($8000 flag = "set VOFS"),
; data word.
;
; Demo: banner + A> prompt. START "types" dir + Enter and prints a canned
; copy of the PC DOS 2.00 directory listing captured from the C core run
; (the real thing arrives at M6).

.INCLUDE "hdr.asm"

.DEFINE CR $0D
.DEFINE BLANK_ENTRY $2040        ; space glyph pair, priority bit set
.DEFINE CURSOR_ENTRY $21B6       ; block glyph (219*2) | priority
.DEFINE QMASK $0FFF              ; 4 KB queue, byte-offset mask
.DEFINE QBASE $0800

.ENUM $0000
nmi_count  dw
q_head     dw                    ; producer (main), byte offset into queue
q_tail     dw                    ; consumer (NMI)
cur_row    dw                    ; 0..27
cur_col    dw                    ; 0..63
top_slot   dw                    ; ring top tilemap row, 0..31
joy_prev   dw
joy_now    dw
start_edge dw
state      dw                    ; 0 idle, 1 typing, 2 listing
script_ptr dw
delay      dw
cursor_on  dw
t_char     dw
t0         dw
t1         dw
t2         dw
t_cnt      dw
.ENDE

.BANK 0 SLOT 0
.ORG 0
.SECTION "MainCode" SEMIFREE

EmptyHandler:
    rti

;----------------------------------------------------------------------
; enqueue: A = vram word addr (or $8000|x for VOFS cmd), Y = data word.
; A/X 16-bit. Single producer; NMI only reads q_head.
;----------------------------------------------------------------------
enqueue:
    ldx q_head
    sta.w QBASE,x
    tya
    sta.w QBASE+2,x
    txa
    clc
    adc.w #4
    and.w #QMASK
    sta q_head
    rts

; free bytes in queue -> A (16-bit)
qfree:
    lda q_tail
    sec
    sbc q_head
    sec
    sbc.w #4
    and.w #QMASK
    rts

;----------------------------------------------------------------------
; calc_cell: A = vram word addr of tilemap entry for (cur_row, cur_col)
;----------------------------------------------------------------------
calc_cell:
    lda top_slot
    clc
    adc cur_row
    and.w #$001F
    asl a
    asl a
    asl a
    asl a
    asl a                        ; physrow * 32
    sta t0
    lda.w #0
    sta t1
    lda cur_col
    and.w #$0001
    beq _cc_even
    lda.w #$0400                 ; odd columns live in the BG1 map
    sta t1
_cc_even:
    lda cur_col
    lsr a
    clc
    adc t0
    clc
    adc t1
    rts

; enqueue a blank at the current cell (cursor erase)
blank_cell:
    jsr calc_cell
    ldy.w #BLANK_ENTRY
    jsr enqueue
    rts

;----------------------------------------------------------------------
; putc: print char in A (16-bit, high byte 0). CR = newline (CRLF).
;----------------------------------------------------------------------
putc:
    sta t_char
    lda cursor_on
    beq _pc_nocursor
    lda.w #0
    sta cursor_on
    jsr blank_cell
_pc_nocursor:
    lda t_char
    cmp.w #CR
    beq _pc_cr
    jsr calc_cell
    pha
    lda t_char
    asl a
    ora.w #$2000                 ; priority bit
    tay
    pla
    jsr enqueue
    lda cur_col
    inc a
    sta cur_col
    cmp.w #64
    bcc _pc_done
    lda.w #0
    sta cur_col
    jsr newline
_pc_done:
    rts
_pc_cr:
    lda.w #0
    sta cur_col
    jsr newline
    rts

;----------------------------------------------------------------------
; newline: advance a row; at the bottom, ring-scroll: bump top_slot,
; blank the row that wraps around, then queue the new VOFS.
;----------------------------------------------------------------------
newline:
    lda cur_row
    cmp.w #27
    bcs _nl_scroll
    inc a
    sta cur_row
    rts
_nl_scroll:
    lda top_slot
    inc a
    and.w #$001F
    sta top_slot
    clc
    adc.w #27                    ; physical row of the new bottom line
    and.w #$001F
    asl a
    asl a
    asl a
    asl a
    asl a
    sta t0
    lda.w #0
    sta t2
_nl_clr:
    lda t0
    clc
    adc t2
    ldy.w #BLANK_ENTRY
    jsr enqueue                  ; BG2 map
    lda t0
    clc
    adc t2
    clc
    adc.w #$0400
    ldy.w #BLANK_ENTRY
    jsr enqueue                  ; BG1 map
    lda t2
    inc a
    sta t2
    cmp.w #32
    bcc _nl_clr
    ; VOFS = top*8 - 1 (SNES shows line VOFS+1 first)
    lda top_slot
    asl a
    asl a
    asl a
    dec a
    and.w #$03FF
    tay
    lda.w #$8000
    jsr enqueue
    rts

; puts: print zero-terminated string at script_ptr (used for the banner)
puts:
    lda (script_ptr)
    and.w #$00FF
    beq _ps_done
    jsr putc
    inc script_ptr
    bra puts
_ps_done:
    rts

;----------------------------------------------------------------------
; reset
;----------------------------------------------------------------------
Reset:
    sei
    clc
    xce                          ; native mode
    rep #$38                     ; A16, X16, decimal off
    ldx.w #$1FFF
    txs
    lda.w #$0000
    tcd
    sep #$20                     ; A8
    lda.b #$00
    pha
    plb                          ; DBR = 0

    lda.b #$8F
    sta $2100                    ; forced blank
    ; -- baseline PPU/CPU register init --
    stz $2101
    stz $2102
    stz $2103
    stz $2104
    lda.b #$05
    sta $2105                    ; mode 5
    stz $2106
    lda.b #$04
    sta $2107                    ; BG1 map @ word $0400, 32x32
    stz $2108                    ; BG2 map @ word $0000, 32x32
    stz $2109
    stz $210A
    lda.b #$13
    sta $210B                    ; BG1 chr @ $3000, BG2 chr @ $1000
    stz $210C
    stz $210D                    ; BG1HOFS = 0
    stz $210D
    lda.b #$FF                   ; BG1VOFS = -1 (top_slot 0)
    sta $210E
    lda.b #$03
    sta $210E
    stz $210F                    ; BG2HOFS = 0
    stz $210F
    lda.b #$FF                   ; BG2VOFS = -1
    sta $2110
    lda.b #$03
    sta $2110
    stz $2111
    stz $2111
    stz $2112
    stz $2112
    stz $2113
    stz $2113
    stz $2114
    stz $2114
    lda.b #$80
    sta $2115                    ; VRAM word increment after high byte
    stz $211A
    stz $211B
    stz $211B
    stz $211C
    stz $211C
    stz $211D
    stz $211D
    stz $211E
    stz $211E
    stz $211F
    stz $211F
    stz $2120
    stz $2120
    stz $2121
    stz $2123
    stz $2124
    stz $2125
    stz $2126
    stz $2127
    stz $2128
    stz $2129
    stz $212A
    stz $212B
    lda.b #$03
    sta $212C                    ; main screen: BG1+BG2
    sta $212D                    ; sub screen: BG1+BG2 (required in mode 5)
    stz $212E
    stz $212F
    lda.b #$30
    sta $2130                    ; color math off
    stz $2131
    lda.b #$E0
    sta $2132
    stz $2133
    stz $4200
    lda.b #$FF
    sta $4201
    stz $4202
    stz $4203
    stz $4204
    stz $4205
    stz $4206
    stz $4207
    stz $4208
    stz $4209
    stz $420A
    stz $420B
    stz $420C
    stz $420D                    ; slow ROM

    ; -- palette: color 0 black, color 1 phosphor green (shared by both BGs)
    stz $2121
    stz $2122
    stz $2122
    lda.b #$E0
    sta $2122
    lda.b #$03
    sta $2122

    ; -- font DMA: BG2 2bpp -> $1000, BG1 4bpp -> $3000
    rep #$20
    lda.w #$1000
    sta $2116
    sep #$20
    lda.b #$01
    sta $4300                    ; mode 1: write $2118/$2119, A-bus inc
    lda.b #$18
    sta $4301
    rep #$20
    lda.w #font_bg2
    sta $4302
    sep #$20
    lda.b #:font_bg2
    sta $4304
    rep #$20
    lda.w #$2000
    sta $4305
    sep #$20
    lda.b #$01
    sta $420B

    rep #$20
    lda.w #$3000
    sta $2116
    lda.w #font_bg1
    sta $4302
    sep #$20
    lda.b #:font_bg1
    sta $4304
    rep #$20
    lda.w #$4000
    sta $4305
    sep #$20
    lda.b #$01
    sta $420B

    ; -- clear both tilemaps to blank entries (2048 words from $0000)
    rep #$20
    lda.w #$0000
    sta $2116
    lda.w #BLANK_ENTRY
    ldx.w #2048
_clr_map:
    sta $2118
    dex
    bne _clr_map

    ; -- console state + demo banner
    rep #$30
    lda.w #0
    sta nmi_count
    sta q_head
    sta q_tail
    sta cur_row
    sta cur_col
    sta top_slot
    sta joy_prev
    sta joy_now
    sta state
    sta delay
    sta cursor_on
    lda.w #banner_str
    sta script_ptr
    jsr puts

    ; -- NMI + auto-joypad on, then screen on
    sep #$20
    lda.b #$81
    sta $4200
    rep #$30
    wai
    wai
    sep #$20
    lda.b #$0F
    sta $2100                    ; full brightness
    rep #$30

;----------------------------------------------------------------------
; main loop: one iteration per frame
;----------------------------------------------------------------------
main_loop:
    wai
    jsr read_pad
    jsr update_cursor
    jsr run_script
    bra main_loop

read_pad:
    lda joy_now
    sta joy_prev
    sep #$20
_rp_wait:
    lda $4212
    lsr a
    bcs _rp_wait                 ; wait for auto-joypad read to finish
    rep #$20
    lda $4218
    sta joy_now
    lda joy_prev
    eor.w #$FFFF
    and joy_now
    and.w #$1000                 ; START, newly pressed
    sta start_edge
    rts

update_cursor:
    lda state
    bne _uc_done                 ; blink only while idle
    lda nmi_count
    and.w #$000F
    bne _uc_done
    lda cursor_on
    eor.w #1
    sta cursor_on
    beq _uc_erase
    jsr calc_cell
    ldy.w #CURSOR_ENTRY
    jsr enqueue
    rts
_uc_erase:
    jsr calc_cell
    ldy.w #BLANK_ENTRY
    jsr enqueue
_uc_done:
    rts

run_script:
    lda state
    beq _rs_idle
    cmp.w #1
    beq _rs_typing
    bra _rs_listing
_rs_idle:
    lda start_edge
    beq _rs_done
    lda.w #1
    sta state
    lda.w #type_str
    sta script_ptr
    lda.w #0
    sta delay
_rs_done:
    rts
_rs_typing:
    lda delay
    beq _rs_type_now
    dec a
    sta delay
    rts
_rs_type_now:
    lda (script_ptr)
    and.w #$00FF
    bne _rs_type_it
    lda.w #2                     ; typing done -> print the listing
    sta state
    lda.w #listing_str
    sta script_ptr
    rts
_rs_type_it:
    jsr putc
    inc script_ptr
    lda.w #8                     ; typewriter cadence
    sta delay
    rts
_rs_listing:
    lda.w #24                    ; chars per frame
    sta t_cnt
_rs_l_loop:
    jsr qfree
    cmp.w #304                   ; room for char + worst-case scroll burst
    bcc _rs_done
    lda (script_ptr)
    and.w #$00FF
    bne _rs_l_emit
    lda.w #0                     ; listing done -> idle at the prompt
    sta state
    rts
_rs_l_emit:
    jsr putc
    inc script_ptr
    lda t_cnt
    dec a
    sta t_cnt
    bne _rs_l_loop
    rts

;----------------------------------------------------------------------
; NMI: ack, drain the VRAM/VOFS queue (budget 96 entries/frame)
;----------------------------------------------------------------------
VBlank:
    rep #$30
    pha
    phx
    phy
    sep #$20
    lda $4210                    ; ack NMI
    lda.b #$80
    sta $2115
    rep #$30
    inc nmi_count
    ldy.w #96
_vb_drain:
    lda q_tail
    cmp q_head
    beq _vb_done
    tax
    lda.w QBASE,x
    bmi _vb_vofs
    sta $2116
    lda.w QBASE+2,x
    sta $2118
_vb_next:
    txa
    clc
    adc.w #4
    and.w #QMASK
    sta q_tail
    dey
    bne _vb_drain
_vb_done:
    rep #$30
    ply
    plx
    pla
    rti
_vb_vofs:
    lda.w QBASE+2,x
    sep #$20
    sta $210E                    ; BG1VOFS low
    xba
    sta $210E                    ; BG1VOFS high
    xba
    sta $2110                    ; BG2VOFS low
    xba
    sta $2110                    ; BG2VOFS high
    rep #$20
    bra _vb_next

;----------------------------------------------------------------------
; demo text
;----------------------------------------------------------------------
banner_str:
    .db "snes86 - M1 console test", CR
    .db "mode 5 hi-res, 64x28 text, ring scroll", CR
    .db "8086 core: 3,007,000/3,007,000 vectors pass", CR
    .db CR
    .db "press START", CR
    .db CR
    .db "A>", 0

type_str:
    .db "dir", CR, 0

listing_str:
    .db CR
    .db " Volume in drive A has no label", CR
    .db " Directory of  A:\\", CR
    .db CR
    .db "COMMAND  COM    17664   3-08-83  12:00p", CR
    .db "ANSI     SYS     1664   3-08-83  12:00p", CR
    .db "FORMAT   COM     6016   3-08-83  12:00p", CR
    .db "CHKDSK   COM     6400   3-08-83  12:00p", CR
    .db "SYS      COM     1408   3-08-83  12:00p", CR
    .db "DISKCOPY COM     2444   3-08-83  12:00p", CR
    .db "DISKCOMP COM     2074   3-08-83  12:00p", CR
    .db "COMP     COM     2523   3-08-83  12:00p", CR
    .db "EDLIN    COM     4608   3-08-83  12:00p", CR
    .db "MODE     COM     3139   3-08-83  12:00p", CR
    .db "FDISK    COM     6177   3-08-83  12:00p", CR
    .db "BACKUP   COM     3687   3-08-83  12:00p", CR
    .db "RESTORE  COM     4003   3-08-83  12:00p", CR
    .db "PRINT    COM     4608   3-08-83  12:00p", CR
    .db "RECOVER  COM     2304   3-08-83  12:00p", CR
    .db "ASSIGN   COM      896   3-08-83  12:00p", CR
    .db "TREE     COM     1513   3-08-83  12:00p", CR
    .db "GRAPHICS COM      789   3-08-83  12:00p", CR
    .db "SORT     EXE     1280   3-08-83  12:00p", CR
    .db "FIND     EXE     5888   3-08-83  12:00p", CR
    .db "MORE     COM      384   3-08-83  12:00p", CR
    .db "BASIC    COM    16256   3-08-83  12:00p", CR
    .db "BASICA   COM    25984   3-08-83  12:00p", CR
    .db "       23 File(s)     31232 bytes free", CR
    .db CR
    .db "A>", 0

.ENDS

;----------------------------------------------------------------------
; font data (generated by tools/mkfont.py)
;----------------------------------------------------------------------
.BANK 1 SLOT 0
.ORG 0
.SECTION "FontData" SEMIFREE

font_bg2:
    .INCBIN "build/font_bg2.bin"
font_bg1:
    .INCBIN "build/font_bg1.bin"

.ENDS
