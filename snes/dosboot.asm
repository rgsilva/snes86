; snes86 — the boot ROM: boots MS-DOS 2.0 (and, as `elks`, Linux) on the
; 65816 core. PC DOS 2.00 was the original bring-up target and survives
; behind .IFDEF PCDOS.
;
; The full HLE-BIOS machine: the parity-proven CPU core plus native
; handlers for INT 10h (mode-5 console), INT 11h/12h (equipment/memory),
; INT 13h (360 KB ROM floppy in banks 2-13, write-protected; SRAM B:;
; ROM C: in banks 14+), INT 16h (keyboard ring; START injects "dir\r"),
; INT 1Ah (NMI-derived ticks).
;
; Guest memory: linear 0x00000-0x1AFFF (108 KB) at $7E:5000-$7F:FFFF.
; CGA adapter RAM: 16 KB at $7E:1000-$7E:4FFF (B000-BFFF segments map
; here; the 80x25 text page is offset 0, graphics bitmaps will share it).
; Boot: sector 0 -> 0000:7C00, all IVT vectors -> IRET stub at 0000:0600.
; (The DOS date/time prompt is skipped the normal way, by AUTOEXEC.BAT's
; presence on the boot floppy — see msdos/mkmsdos.py — not by injected keys.)

.DEFINE DOSBIOS
.INCLUDE "build/trace_meta.asm"

.INCLUDE "hdr_dos.asm"
.INCLUDE "cpu.asm"
.INCLUDE "cpu2.asm"

; console / harness state (above the core's DP usage)
.ENUM $00C0
cNMI     dw                  ; frame counter
cQH      dw                  ; VRAM queue head (producer, byte offset)
cQT      dw                  ; VRAM queue tail (NMI)
cROW     dw                  ; cursor row 0-27
cCOL     dw                  ; cursor col 0-63
cTOP     dw                  ; ring top tilemap row
cJoyP    dw
cJoyN    dw
cTickA   dw                  ; 16.16 tick accumulator (18.2 Hz from NMI)
cTickL   dw
cTickH   dw
cKbH     dw                  ; keyboard ring: byte offsets into kbRING
cKbT     dw
cT0      dw
cT1      dw
tSKIP    dw                  ; trace-mode skip counter (nothing else touches)
kSEL     dw                  ; on-screen keyboard: selected key index
kMOD     dw                  ; bit0 shift, bit1 ctrl (sticky)
kVIS     dw                  ; keyboard visible
kRPT     dw                  ; d-pad autorepeat timer
kROWS    dw                  ; terminal scroll threshold (22 vis / 27 hid)
kT0      dw                  ; keyboard temps (NMI-only: never share the
kT1      dw                  ; core/INT13 temps, which may be live when
kT2      dw                  ; the NMI fires mid-instruction)
kT3      dw
cTickP   dw                  ; timer tick pending (INT 8 delivery)
cT2n     dw                  ; INT13 scratch
kPAN     dw                  ; horizontal pan (0-16), L/R buttons
scanROW  dw                  ; scanner round-robin row
kSHV     dw                  ; shift state the key labels were drawn with
.ENDE

.DEFINE CQBASE $0800         ; 512 B VRAM write queue (native WRAM; kbd-only
.DEFINE CQMASK $01FF         ; traffic since M8, so 128 entries is plenty —
                             ; halved for the mode-6 staging buffer below.
                             ; $1000-$4FFF is the CGA adapter RAM, and the
                             ; NATIVE STACK works down from $0FFF: nothing
                             ; may live above $0DFF (see Reset)
.DEFINE BLANKE $2040         ; space glyph pair | priority

; ANSI/CSI parser + INT 10h scroll scratch ($0700-$073F kb ring,
; $0740-$077F HDMA tables, $0800 queue — this slice is free)
.ENUM $0780
aST      dw                  ; 0 normal, 1 saw ESC, 2 in CSI params
aP1      dw                  ; first CSI parameter (before ';')
aAC      dw                  ; accumulating/last CSI parameter
aT0      dw                  ; scroll scratch
aT1      dw
aT2      dw
cWID     dw                  ; console width: 80 (modes 2/3) or 40 (0/1)
cMODE    dw                  ; current INT 10h video mode byte
sFLIP    dw                  ; PIT ch2 divisor byte flip-flop
sDIV     dw                  ; PIT ch2 divisor (1193182 Hz / div = tone)
sGATE    dw                  ; speaker gate (port 61h bits 0-1 both set)
sD0      dw                  ; pitch divide scratch
sD1      dw
sREM     dw
cBEEP    dw                  ; BEL beep frames remaining (NMI countdown)
nCNT     dw                  ; scanner loop counter (Y is the LUT index)
nTIL     dw                  ; scanner tile word scratch
nNEXT    dw                  ; next dynamic pair slot (index into sr_pairs)
nP       dw                  ; sr_alloc scratch: pair number
nFG      dw                  ; sr_alloc scratch: fg color
nBG      dw                  ; sr_alloc scratch: bg color
cATTR    dw                  ; current teletype attribute (ANSI SGR)
aNP      dw                  ; CSI parameter count
cGFX     dw                  ; 0 = text, 1 = CGA graphics (mode 4/5/6)
s3D8     dw                  ; port 3D8 shadow (mode select)
s3D9     dw                  ; port 3D9 shadow: bit5 pal, bit4 bright, low bg
cPALD    dw                  ; palette dirty -> NMI rewrites CGRAM 0-3
gROW     dw                  ; gfx scanner round-robin tile row (0-24)
gSTG     dw                  ; staged tile row + 1 awaiting VRAM DMA (0=none)
s60      dw                  ; INT9: port 60h scancode latch
s9H      dw                  ; INT9: scancode queue head (byte off in $0600)
s9T      dw                  ; INT9: scancode queue tail
s9CD     dw                  ; INT9: inter-scancode hold-off in FRAMES
                             ; (NMI decrements): a real key is held ~100ms;
                             ; back-to-back make/break would let a slow
                             ; poll loop see only the break
bPIT     dw                  ; beep: DSP P value (raw pitch)
bGON     dw                  ; beep: gate on/off
bDIRTY   dw                  ; beep: NMI must (re)send to the SPC
mFH      dw                  ; MIDI FIFO head (producer, byte off in $0540)
mFT      dw                  ; MIDI FIFO tail (NMI sequencer)
mDLY     dw                  ; frames until the event at mFT ($FFFF idle)
mSEQ     dw                  ; SPC command sequence counter (1-15)
mPKn     dw                  ; packet assembly byte counter (0-3)
mAOF     dw                  ; all-notes-off request
mEVN     dw                  ; events-per-frame guard
mVNX     dw                  ; voice-steal round robin
mVCE     dw                  ; voice chosen for the current note-on
.ENDE

; MIDI WRAM: chprog[16] = per-channel GM program at $0520, vChan[8] at
; $0530, vNote[8] at $0538 ($FF = voice free), FIFO $0540-$06FF (112
; four-byte packets: [delta-frames][status][d1][d2]).

.DEFINE STG   $0A00          ; gfx staging buffer: one tile row — 640 bytes
                             ; (mode 4/5) or 1024 (mode 6, to $0DFF). Must
                             ; stay below $0E00: the native stack owns the
                             ; top of this page (a lesson paid for twice)
.DEFINE CGMAP $2800          ; BG3 64x32 tilemap (VRAM word addr)
.DEFINE CGTIL $5000          ; BG3 2bpp tile data: 1000 tiles, 8000 words
; CGA mode 6 (M10p6): 640x200x1 on hires BG2 (SNES mode 5), shown as a
; 512px window panned by re-render like the 80-col text console. The
; window is 64 chars x 25 rows = 1600 2bpp chars — past the 1024-char
; index ceiling of one base — so HDMA ch6 rebands $210B per row group
; (mode 6 needs no $2105 raster split; the whole frame stays mode 5):
.DEFINE CG6B1 $5000          ; rows 0-15: chars 0-1023 at base $5000
.DEFINE CG6B2 $7000          ; rows 16-23: chars 0-511 at base $7000
.DEFINE CG6B3 $2C00          ; row 24: chars 384-447 at base $2000

.BANK 0 SLOT 0
.ORG 0
.SECTION "DosBoot" SEMIFREE

.ACCU 16
.INDEX 16

EmptyHandler:
    rti

;----------------------------------------------------------------------
; console (mode-5 64x28, same scheme the M1 demo proved out)
; CR = col 0, LF = next line. All code here must preserve Y (guest IP).
;----------------------------------------------------------------------
con_enq:                     ; A = vram addr / $8000 vofs-cmd, X free
    pha
_ce_wait:
    lda cQT
    sec
    sbc cQH
    sec
    sbc #4
    and #CQMASK
    cmp #$0130
    bcs _ce_room             ; keep >= room for a scroll burst
    wai
    bra _ce_wait
_ce_room:
    pla
    ldx cQH
    sta.w CQBASE,x
    lda cT0
    sta.w CQBASE+2,x
    txa
    clc
    adc #4
    and #CQMASK
    sta cQH
    rts

con_off:                     ; A = buffer offset of (cROW, cCOL)
    lda cROW
    asl a
    asl a
    asl a
    asl a
    asl a
    sta cT1
    asl a
    asl a
    clc
    adc cT1                  ; row*160
    pha                      ; halve for 40-col (real CGA stride)
    lda cWID
    cmp #80
    beq _co_d
    pla
    lsr a
    bra _co_s
_co_d:
    pla
_co_s:
    sta cT1
    lda cCOL
    asl a
    clc
    adc cT1
    rts

con_putc:                    ; A = char -> 80x25 text page at VBUF
    and #$00FF
    ldx aST                  ; ANSI escape in progress?
    bne _cp_esc
    cmp #$001B
    bne _cp_norm
    inc aST                  ; ESC: start sequence
    rts
_cp_norm:
    cmp #$000D
    bne _cp_ncr
    stz cCOL
    rts
_cp_ncr:
    cmp #$000A
    bne _cp_nnl
    jmp con_nl
_cp_nnl:
    cmp #$0008
    bne _cp_nbs
    lda cCOL
    beq _cp_done
    dec cCOL
_cp_done:
    rts
_cp_nbs:
    cmp #$0007
    bne _cp_nbel
    jmp beep_bel             ; BEL rings the S-SMP
_cp_nbel:
    ldx cGFX
    bne _cp_gfx
    sta cT0
    jsr con_off
    tax
    lda cATTR
    xba
    and #$FF00
    ora cT0
    sta.l VBUF,x          ; char + current attribute
_cp_adv:
    lda cCOL
    inc a
    sta cCOL
    cmp cWID
    bcc _cp_ret
    stz cCOL
    jmp con_nl
_cp_ret:
    rts
_cp_gfx:                     ; graphics: blit the glyph, BL(&3) = color
    pha
    lda gBX
    and #$0003
    bne _cp_gc
    lda #3                   ; teletype with BL=0 would be invisible
_cp_gc:
    sta aT1
    pla
    jsr gfx_glyph
    bra _cp_adv

; ---- minimal ANSI/CSI parser (the '96 Infocom interpreter emits these):
; ESC[r;cH cursor, ESC[2J clear, ESC[K clear-eol, ESC[..m attrs (ignored)
_cp_esc:
    cpx #1
    bne _cp_csi
    cmp #$005B               ; '[' after ESC?
    bne _cp_abort
    inc aST                  ; -> collecting params
    stz aP1
    stz aAC
    stz aNP
    rts
_cp_abort:
    stz aST                  ; lone ESC: drop it, print char as-is
    bra _cp_norm
_cp_csi:
    cmp #$003B               ; ';'
    bne _cp_dig
    lda aAC
    sta aP1
    stz aAC
    inc aNP
    rts
_cp_dig:
    cmp #$0030               ; '0'-'9': aAC = aAC*10 + digit
    bcc _cp_fin
    cmp #$003A
    bcs _cp_fin
    and #$000F
    sta cT0
    lda aAC
    asl a
    asl a
    clc
    adc aAC                  ; *5
    asl a                    ; *10
    clc
    adc cT0
    sta aAC
    rts
_cp_fin:                     ; A = final letter; aP1/aAC = params
    stz aST
    cmp #$0048               ; 'H' / 'f': set cursor (1-based row;col)
    beq _cp_pos
    cmp #$0066
    beq _cp_pos
    cmp #$004A               ; 'J': clear screen
    beq _cp_cls
    cmp #$004B               ; 'K': clear to end of line
    beq _cp_eol
    cmp #$006D               ; 'm': set attributes (SGR)
    beq _cp_sgr
    rts
_cp_cls:
    jmp con_clear
_cp_pos:
    lda aP1
    beq _cp_pr0
    dec a
_cp_pr0:
    cmp #25
    bcc _cp_pr1
    lda #24
_cp_pr1:
    sta cROW
    lda aAC
    beq _cp_pc0
    dec a
_cp_pc0:
    cmp #80
    bcc _cp_pc1
    lda #79
_cp_pc1:
    sta cCOL
    rts
_cp_eol:
    jsr con_off
    tax
    lda #80
    sec
    sbc cCOL
    sta cT0
    lda cATTR
    xba
    and #$FF00
    ora #$0020
_cp_ek:
    sta.l VBUF,x
    inx
    inx
    dec cT0
    bne _cp_ek
    rts

_cp_sgr:                     ; ESC[..m — apply up to two SGR parameters
    lda aNP
    beq _cp_sg1
    lda aP1
    jsr sgr_apply
_cp_sg1:
    lda aAC
    jsr sgr_apply
    rts

sgr_apply:                   ; A = SGR parameter -> update cATTR
    bne _sg_n0
    lda #$0007               ; 0: reset
    sta cATTR
    rts
_sg_n0:
    cmp #1
    bne _sg_n1
    lda cATTR
    ora #$0008               ; 1: bold -> intensity bit
    sta cATTR
    rts
_sg_n1:
    cmp #7
    bne _sg_n7
    lda #$0070               ; 7: reverse video
    sta cATTR
    rts
_sg_n7:
    cmp #30
    bcc _sg_r
    cmp #38
    bcs _sg_bg
    sec
    sbc #30
    asl a
    tax
    lda cATTR
    and #$00F8               ; keep bg + intensity
    ora.l ansi2cga,x
    sta cATTR
    rts
_sg_bg:
    cmp #40
    bcc _sg_r
    cmp #48
    bcs _sg_r
    sec
    sbc #40
    asl a
    tax
    lda.l ansi2cga,x
    asl a
    asl a
    asl a
    asl a
    sta cT0
    lda cATTR
    and #$000F
    ora cT0
    sta cATTR
_sg_r:
    rts

ansi2cga: .dw 0, 4, 2, 6, 1, 5, 3, 7

attr_reset:                  ; LUT: all unallocated except $07 -> pair 0
    ldx #$0000
    lda #$FFFF
_ar_l:
    sta.w $0400,x
    inx
    inx
    cpx #$0100
    bcc _ar_l
    stz.w $040E              ; attr $07 = the fixed green pair
    stz nNEXT
    lda #$0007
    sta cATTR
    rts

con_nl:
    lda cROW
    cmp #24
    bcs _nl_full
    inc a
    sta cROW
    rts
_nl_full:
    lda cGFX
    beq _nl_scroll
    jmp gfx_nlscr            ; graphics: shift the bitmap up 8 scanlines
_nl_scroll:                  ; scroll the buffer up one row (stride-aware)
    phy                      ; Y is the guest IP — MVN clobbers X/Y!
    phx
    phb
    lda cWID
    cmp #80
    bne _nl_s40
    ; 80-col: move rows 1-24 (24*160-1 bytes) up, clear last row (160 bytes)
    lda #3839
    ldx #VBOFS+160
    ldy #VBOFS
    .db $54, $7E, $7E        ; mvn $7E,$7E
    plb
    ldx #$0000
    lda #$0720
_nl_c:
    sta.l VBUF+3840,x
    inx
    inx
    cpx #160
    bcc _nl_c
    plx
    ply
    rts
_nl_s40:                     ; 40-col: 80-byte rows -> move 24*80-1, clear 80
    lda #1919
    ldx #VBOFS+80
    ldy #VBOFS
    .db $54, $7E, $7E        ; mvn $7E,$7E
    plb
    ldx #$0000
    lda #$0720
_nl_c4:
    sta.l VBUF+1920,x
    inx
    inx
    cpx #80
    bcc _nl_c4
    plx
    ply
    rts

con_clear:
    ldx #$0000
    lda #$0720
_cc_f:
    sta.l VBUF,x
    inx
    inx
    cpx #4000
    bcc _cc_f
    stz cROW
    stz cCOL
    rts

;----------------------------------------------------------------------
; PC speaker -> S-SMP. Guest OUTs to the PIT ($42/$43) and the gate
; ($61) land here; tone = 1193182/divisor Hz, forwarded to the SPC700
; beep driver as DSP pitch = 2443637/divisor (see spc_beep.asm).
; Preserves Y (guest IP). X and cT0 are scratch.
;----------------------------------------------------------------------
spk_out:                     ; X = port, A = value (low byte)
    cpx #$0042
    beq _sk_div
    cpx #$0043
    beq _sk_ctl
    cpx #$0061
    beq _sk_gate
    cpx #$03D8
    beq _sk_38j
    cpx #$03D9
    beq _sk_39j
    cpx #$0330
    beq _sk_mdj
    cpx #$0331
    beq _sk_mcj
    rts
_sk_38j:
    jmp _sk_3d8
_sk_39j:
    jmp _sk_3d9
_sk_mdj:
    jmp midi_data
_sk_mcj:
    jmp midi_ctl
_sk_ctl:
    stz sFLIP                ; control write resets the byte flip-flop
    rts
_sk_div:
    and #$00FF
    ldx sFLIP
    bne _sk_hi
    sta sDIV                 ; low byte (high cleared by the AND)
    inc sFLIP
    rts
_sk_hi:
    xba
    and #$FF00
    sta cT0
    lda sDIV
    and #$00FF
    ora cT0
    sta sDIV
    stz sFLIP
    lda sGATE                ; retune a playing note (GW-BASIC PLAY)
    bne _sk_send
    rts
_sk_gate:
    and #$0003               ; bits 0-1 both set = speaker on
    cmp #$0003
    beq _sk_on
    stz sGATE
    stz bGON                 ; NMI sends the key-off (single SPC sender)
    lda #1
    sta bDIRTY
    rts
_sk_on:
    lda sGATE
    bne _sk_r                ; already on
    inc sGATE
_sk_send:
    ; pitch = 2443637 / divisor, clamped to the DSP's 14 bits
    lda sDIV
    beq _sk_r
    lda #$4A75               ; 2443637 = $00254A75
    sta sD0
    lda #$0025
    sta sD1
    stz sREM
    ldx #32
_sk_dl:
    asl sD0
    rol sD1
    rol sREM
    bcs _sk_sb               ; bit 17 out: remainder >= divisor for sure
    lda sREM
    cmp sDIV
    bcc _sk_nx
_sk_sb:
    lda sREM
    sec
    sbc sDIV
    sta sREM
    inc sD0                  ; quotient bit
_sk_nx:
    dex
    bne _sk_dl
    lda sD1
    bne _sk_mx
    lda sD0
    cmp #$4000
    bcc _sk_snd
_sk_mx:
    lda #$3FFF
_sk_snd:
    sta bPIT                 ; NMI raw-KONs voice 7 with this pitch
    lda #1
    sta bGON
    sta bDIRTY
_sk_r:
    rts

beep_bel:                    ; BEL: ~886 Hz for 12 frames
    lda #$0717
    sta bPIT
    lda #1
    sta bGON
    sta bDIRTY
    lda #12
    sta cBEEP
    rts

apu_upload:                  ; IPL-ROM upload of spc_beep to $0200, run it
    sep #$20
    ldx #$0000
_au_w0:
    lda.l $002140
    cmp #$AA
    beq _au_go
    dex
    bne _au_w0
    rep #$20                 ; APU never answered: run silent
    rts
_au_go:
    rep #$20
    lda #$0200
    sta.l $002142            ; dest address
    sep #$20
    lda #$01
    sta.l $002141
    lda #$CC
    sta.l $002140
_au_wc:
    lda.l $002140
    cmp #$CC
    bne _au_wc
    ldx #$0000
_au_l:
    lda.l spc_blob,x
    sta.l $002141
    txa
    sta cT0
    sta.l $002140
_au_k:
    lda.l $002140
    cmp cT0
    bne _au_k
    inx
    cpx #1024
    bcc _au_l
    rep #$20
    lda #$0210
    sta.l $002142            ; entry point
    sep #$20
    lda #$00
    sta.l $002141
    lda #1                   ; last counter + 2 (mod 256): go
    sta.l $002140
    ldx #200                 ; let the IPL take the jump...
_au_j:
    dex
    bne _au_j
    lda #$00                 ; ...then scrub the mailbox: the driver
    sta.l $002140            ; holds until port3 reads 0, and the IPL
    sta.l $002141            ; jump left the entry address in ports 2/3
    sta.l $002142            ; (unscrubbed port3 = a session of debugging)
    sta.l $002143
    rep #$20
    rts

spc_blob:
.INCBIN "build/spc_midi64.bin" SKIP $0200 READ 1024

bdisk_start:                 ; B: format template (bank 0: bank 1 is full)
.INCBIN "build/bdisk.bin"

con_puts:                    ; X = string address (bank 0)
    phy
    txy
_ps_l:
    lda.w $0000,y
    and #$00FF
    beq _ps_d
    phy
    jsr con_putc
    ply
    iny
    bra _ps_l
_ps_d:
    ply
    rts

;----------------------------------------------------------------------
; HLE BIOS handlers (called from do_int; must preserve Y = return IP)
;----------------------------------------------------------------------
hle_int10:
    lda gAX
    xba
    and #$00FF
    cmp #$000E
    bne _h10_n1
    lda gAX
    jmp con_putc
_h10_n1:
    cmp #$0002
    bne _h10_n2
    lda gDX                  ; DH=row DL=col
    xba
    and #$00FF
    cmp #25
    bcs _h10_ret
    sta cROW
    lda gDX
    and #$00FF
    cmp #80
    bcs _h10_ret
    sta cCOL
_h10_ret:
    rts
_h10_n2:
    cmp #$0003
    bne _h10_n3
    lda cROW
    xba
    and #$FF00
    ora cCOL
    sta gDX
    lda #$0607
    sta gCX
    rts
_h10_n3:
    cmp #$0000
    beq _h10_mdj
    cmp #$0006
    beq _h10_scrj
    cmp #$0007
    beq _h10_scrj
    cmp #$0008
    bne _h10_n4
    jsr con_off
    tax
    lda.l VBUF,x          ; AL = char, AH = its real attribute
    sta gAX
    rts
_h10_n4:
    cmp #$000F
    bne _h10_n5
    lda cWID
    xba
    and #$FF00               ; AH = columns
    ora cMODE                ; AL = mode
    sta gAX
    rts
_h10_n5:
    cmp #$0009
    beq _h10_wc
    cmp #$000A
    beq _h10_wca
    cmp #$000B
    beq _h10_paj
    cmp #$000C
    beq _h10_psj
    cmp #$000D
    beq _h10_pgj
    rts
_h10_paj:
    jmp _h10_pal
_h10_psj:
    jmp _h10_pset
_h10_pgj:
    jmp _h10_pget
_h10_mdj:
    jmp _h10_mode
_h10_scrj:
    jmp _h10_scr
_h10_wc:                     ; AH=9: char AL with attribute BL
    ldx cGFX
    bne _h10_gwc
    jsr con_off
    tax
    lda gBX
    xba
    and #$FF00
    sta cT0
    lda gAX
    and #$00FF
    ora cT0
    sta.l VBUF,x
    rts
_h10_wca:                    ; AH=0A: char only, cell attribute kept
    ldx cGFX
    bne _h10_gwc
    jsr con_off
    tax
    lda.l VBUF,x
    and #$FF00
    sta cT0
    lda gAX
    and #$00FF
    ora cT0
    sta.l VBUF,x
    rts
_h10_gwc:                    ; gfx: draw AL, BL = literal color (no 0->3)
    lda gBX
    and #$0003
    sta aT1
    lda gAX
    jmp gfx_glyph

_h10_mode:                   ; AH=0 set mode: 0/1=40col 2/3=80col 4/5/6=CGA gfx
    lda gAX
    and #$007F               ; bit7 = keep the framebuffer
    sta cMODE
    cmp #4
    bcc _h10_mtxt
    cmp #7
    bcs _h10_mtxt
    cmp #6                   ; M10p6: mode 6 = true 640x200 on hires BG2
    bne _h10_m45
    lda #80                  ; 80 text columns; pan window 16, like text
    sta cWID
    lda #$001E               ; 3D8 shadow: 80col|gfx|video|640 (pal_apply
    sta s3D8                 ; keys the mono palette off bit4)
    bra _h10_mgo
_h10_m45:
    lda #40
    sta cWID
    lda #$000A               ; 3D8 shadow: gfx|video
    sta s3D8
_h10_mgo:
    stz kPAN
    jsr gfx_enter
    lda gAX
    and #$0080
    bne _h10_mgk
    jsr gfx_fbclr
_h10_mgk:
    rts
_h10_mtxt:
    lda cGFX
    beq _h10_mt2
    jsr gfx_exit
_h10_mt2:
    lda cMODE
    cmp #2
    bcs _h10_m80
    lda #40
    bra _h10_mw
_h10_m80:
    lda #80
_h10_mw:
    sta cWID
    stz kPAN
    jsr attr_reset
_h10_clear:
    jmp con_clear

_h10_sret:
    rts

_h10_scr:
    ; window scroll, full-width windows only (CL=0, DL>=79)
    lda gCX
    and #$00FF
    bne _h10_sret
    lda cWID
    dec a
    sta aT2
    lda gDX
    and #$00FF
    cmp aT2
    bcc _h10_sret
    lda gCX
    xba
    and #$00FF               ; CH = top row
    cmp #25
    bcs _h10_sret
    sta cT0
    lda gDX
    xba
    and #$00FF               ; DH = bottom row
    cmp #25
    bcc _h10_sb
    lda #24
_h10_sb:
    cmp cT0
    bcc _h10_sret
    sec
    sbc cT0
    inc a
    sta cT1                  ; window height (rows)
    lda gAX
    and #$00FF               ; AL = line count
    beq _h10_wclr
    cmp cT1
    bcs _h10_wclr            ; scrolling the whole window = clear it
    sta cT2n
    lda gAX
    xba
    and #$00FF
    cmp #$0007
    beq _h10_dn
    ; ---- scroll up: rows top+AL..bot -> top, blank the bottom AL rows
    lda cT1
    sec
    sbc cT2n
    jsr mul160
    dec a
    sta aT0                  ; byte count - 1
    lda cT0
    clc
    adc cT2n
    jsr row_addr
    sta aT1                  ; src
    lda cT0
    jsr row_addr             ; dst
    phy                      ; Y = guest IP; MVN clobbers X/Y
    phx
    phb
    tay
    ldx aT1
    lda aT0
    .db $54, $7E, $7E        ; mvn $7E,$7E
    plb
    plx
    ply
    lda cT0
    clc
    adc cT1
    sec
    sbc cT2n
    jsr row_addr
    tax                      ; blank start
    lda cT2n
    bra _h10_blank
_h10_wclr:                   ; clear rows top..top+height-1
    lda cT0
    jsr row_addr
    tax
    lda cT1
    bra _h10_blank
_h10_dn:
    ; ---- scroll down: rows top..bot-AL -> top+AL, blank the top AL rows
    lda cT1
    sec
    sbc cT2n
    jsr mul160
    dec a
    sta aT0                  ; byte count - 1
    lda cT0
    jsr row_addr
    clc
    adc aT0
    sta aT1                  ; src (highest byte, MVP descends)
    lda cT0
    clc
    adc cT2n
    jsr row_addr
    clc
    adc aT0                  ; dst (highest byte)
    phy
    phx
    phb
    tay
    ldx aT1
    lda aT0
    .db $44, $7E, $7E        ; mvp $7E,$7E
    plb
    plx
    ply
    lda cT0
    jsr row_addr
    tax
    lda cT2n
_h10_blank:                  ; X = buffer addr, A = row count
    jsr mul160
    lsr a
    sta aT0                  ; words
    lda gBX
    and #$FF00               ; BH = fill attribute (already the high byte)
    ora #$0020
_h10_bl:
    sta.l $7E0000,x
    inx
    inx
    dec aT0
    bne _h10_bl
    rts

mul160:                      ; A = rows -> rows * (cWID*2): 160 in 80-col text,
    asl a                    ; 80 in 40-col (real CGA row stride). Preserves X
    asl a                    ; (_h10_blank holds an addr in X across this call).
    asl a
    asl a
    asl a                    ; *32
    sta aT2
    asl a
    asl a                    ; *128
    clc
    adc aT2                  ; *160
    pha
    lda cWID
    cmp #80
    beq _m160_d
    pla
    lsr a                    ; 40-col: *80
    rts
_m160_d:
    pla
    rts

row_addr:                    ; A = row -> in-bank ($7E) addr VBOFS + row*160
    jsr mul160
    clc
    adc #VBOFS
    rts

hle_int11:
.IFDEF BIGMEM
    lda #$0021               ; ONE floppy: under BIGMEM the SRAM banks are
    sta gAX                  ; guest RAM above 108 KB, so the B: vdisk is
    rts                      ; gone (a B: access would read guest memory
.ELSE                        ; as a FAT and a write would corrupt it)
    lda #$0061               ; two floppies (A: B:), 80x25 color; C: is
    sta gAX                  ; the fixed disk (INT 13h DL=80h)
    rts
.ENDIF

hle_int12:
    lda #GUESTKB             ; KB of guest RAM (172 in the BIGMEM variant)
    sta gAX
    rts

.IFDEF ELKS
hle_int15:                   ; XT answer: cassette only -> unsupported.
    lda gAX                  ; Falling through to the IRET stub makes
    and #$00FF               ; ELKS's A20 query (AH=24h) "succeed" with
    ora #$8600               ; garbage; CF=1/AH=86h is what a real XT
    sta gAX                  ; BIOS says and what ELKS expects.
    jsr flags_norm
    lda fSTATIC
    ora #$0001               ; CF=1
    sta fSTATIC
    rts
.ENDIF

hle_int1A:
    lda gAX
    xba
    and #$00FF
    bne _h1a_set
    lda cTickH
    sta gCX
    lda cTickL
    sta gDX
    sep #$20
    stz gAX                  ; AL=0: no midnight rollover
    rep #$20
    rts
_h1a_set:
    cmp #$0001
    beq _h1a_ret
    jsr flags_norm
    lda fSTATIC
    ora #$0001
    sta fSTATIC
_h1a_ret:
    rts

; BIOS keyboard ring in the guest BDA (head 40:1A, tail 40:1C, data
; 40:1E-3D): a guest INT9 handler speaking the BIOS protocol stores
; translated keys there and expects INT16 to serve them. Returns key in
; A + carry SET, or carry CLEAR if empty. X = consume flag (0 = peek).
bda_pop:
    lda.l $7E541A            ; head
    cmp.l $7E541C            ; tail
    beq _bp_no
    cmp #$001E
    bcc _bp_no
    cmp #$003E
    bcs _bp_no
    phy
    tay
    txa
    beq _bp_pk
    tya                      ; consume: head += 2 (wrap 3E -> 1E)
    inc a
    inc a
    cmp #$003E
    bcc _bp_wr
    lda #$001E
_bp_wr:
    sta.l $7E541A
_bp_pk:
    tyx
    lda.l $7E5400,x          ; the key word
    ply
    sec
    rts
_bp_no:
    clc
    rts

hle_int16:
    lda gAX
    xba
    and #$00FF
    bne _h16_n0
    ; AH=0: pop key (DOS 2.0 polls AH=1 first, so this never blocks)
    ldx #1
    jsr bda_pop
    bcc _h16_ours0
    sta gAX
    rts
_h16_ours0:
    lda cKbH
    cmp cKbT
    beq _h16_empty0
    ldx cKbH
    lda.w $0700,x
    sta gAX
    txa
    clc
    adc #2
    and #$003E
    sta cKbH
    rts
_h16_empty0:
    dey                      ; ring empty: rewind IP so INT 16h re-executes
    dey                      ; (emulator-level blocking; NMI will add keys)
    rts
_h16_n0:
    cmp #$0001
    bne _h16_n1
    jsr flags_norm
    ldx #0                   ; peek the BIOS BDA ring first
    jsr bda_pop
    bcc _h16_ours1
    sta gAX
    lda fSTATIC
    and #$FFBF               ; ZF=0: key available
    sta fSTATIC
    rts
_h16_ours1:
    lda cKbH
    cmp cKbT
    beq _h16_zf1
    ldx cKbH
    lda.w $0700,x
    sta gAX
    lda fSTATIC
    and #$FFBF               ; ZF=0: key available
    sta fSTATIC
    rts
_h16_zf1:
    lda fSTATIC
    ora #F_ZF
    sta fSTATIC
    rts
_h16_n1:
    cmp #$0002
    bne _h16_ret
    sep #$20
    stz gAX
    rep #$20
_h16_ret:
    rts

;----------------------------------------------------------------------
; INT 13h: floppy = 360 KB image in ROM banks 2-13 (read-only)
; geometry 40 cyl / 2 heads / 9 spt; LBA = (cyl*2+head)*9 + sec-1
;----------------------------------------------------------------------
hle_int13:
    lda gAX
    xba
    and #$00FF
    beq _h13_ok              ; 00 reset
    cmp #$0001
    beq _h13_ok              ; 01 status
    cmp #$0004
    beq _h13_ok              ; 04 verify
    cmp #$0002
    beq _h13_read
    cmp #$0003
    beq _h13_read            ; writes: routed per-drive (B: is writable)
    cmp #$0008
    beq _h13_parm            ; 08 get drive parameters (fixed disk only)
    cmp #$000C
    beq _h13_ok              ; XT fixed-disk extras: 0C seek
    cmp #$000D
    beq _h13_ok              ; 0D alternate reset
    cmp #$0010
    beq _h13_ok              ; 10 test ready
    cmp #$0011
    beq _h13_ok              ; 11 recalibrate
_h13_bad:
    lda #$0001
_h13_err:
    xba
    and #$FF00
    sta cT0
    lda gAX
    and #$00FF
    ora cT0
    sta gAX
    jsr flags_norm
    lda fSTATIC
    ora #$0001               ; CF=1
    sta fSTATIC
    rts
_h13_ok:
    lda gAX
    and #$00FF
    sta gAX                  ; AH=0
    jsr flags_norm
    lda fSTATIC
    and #$FFFE               ; CF=0
    sta fSTATIC
    rts
_h13_parm:                   ; AH=08: only the fixed disk answers
    lda gDX
    and #$00FF
    cmp #$0080
    bne _h13_bad
.IFDEF ELKS
    bra _h13_bad             ; ELKS variant: no fixed disk (banks 14+
                             ; hold the kernel/ROMFS images)
.ENDIF
    lda #$6A11               ; CH=max cyl 106, CL=spt 17 (cyl hi bits 0)
    sta gCX
    lda #$0301               ; DH=max head 3, DL=1 fixed disk present
    sta gDX
    bra _h13_ok
_h13_read:
    lda gDX
    and #$00FF
    cmp #$0080
    bne _h13_flp
.IFDEF ELKS
    jmp _h13_bad             ; no fixed disk in the ELKS variant (banks
                             ; 14+ are the kernel/ROMFS images) — CF=1,
                             ; AH=01, same as runpc without -d
.ELSE
    jmp _h13_hd              ; C: fixed disk: own geometry
.ENDIF
_h13_badn:
    jmp _h13_bad
_h13_flp:
.IFDEF FSBOOT
    ; 160 KB booter floppy: 40 cyl / 1 head / 8 spt. LBA = cyl*8 + sec-1
    lda gDX
    and #$FF00
    bne _h13_badj            ; head 0 only
    lda gDX
    and #$00FF
    cmp #2
    bcs _h13_badj
    lda gCX
    and #$003F
    beq _h13_badj
    cmp #9
    bcs _h13_badj
    dec a
    sta cT0                  ; sec-1
    lda gCX
    xba
    and #$00FF               ; cyl
    cmp #40
    bcs _h13_badj
    asl a
    asl a
    asl a                    ; cyl*8
    clc
    adc cT0
    sta cT0                  ; LBA
.ELSE
    ; floppy validation: DL<2, DH<2 (B: also needs DH=0), 1<=sec<=9, cyl<40
    lda gDX
    and #$FE00
    bne _h13_badn
    lda gDX
    and #$00FF
    cmp #2
    bcs _h13_badn
    lda gCX
    and #$003F
    beq _h13_badn
    cmp #10
    bcs _h13_badn
    dec a
    sta cT0                  ; sec-1
    lda gCX
    xba
    and #$00FF               ; cyl
    cmp #40
    bcs _h13_badn
    sta cT1                  ; cyl
    asl a                    ; cyl*2
    sta cT2n
    lda gDX
    xba
    and #$00FF               ; head
    clc
    adc cT2n                 ; cyl*2+head
    sta cT1
    asl a
    asl a
    asl a
    clc
    adc cT1                  ; *9
    clc
    adc cT0
    sta cT0                  ; LBA
.ENDIF
    ldx #24
    lda gBX
    jsr mk_ptr               ; mPTR = ES:BX
    phy
    lda gAX
    and #$00FF
    beq _h13_al0             ; AL=0 would dec-wrap into a 65535-sector
    sta cT1                  ; sectors remaining          runaway copy
    lda gDX
    and #$00FF
    beq _h13_romA
.IFDEF BIGMEM
_h13_al0:                    ; BIGMEM: no B: — the SRAM banks are guest
    ply                      ; RAM above 108 KB (see hle_int11)
    lda #$0001               ; invalid request
    jmp _h13_err
.ELSE
    jmp _h13_vdisk           ; DL=1 -> B: VRAM disk
_h13_al0:
    ply
    lda #$0001               ; invalid request
    jmp _h13_err
.ENDIF
_h13_romA:
    lda #$0082               ; A: ROM disk, banks $82+
_h13_rom:
    sta cT2n                 ; bank base for _h13_sec
    ; ---- ROM drives: read-only
    lda gAX
    xba
    and #$00FF
    cmp #$0003
    bne _h13_sec
    ply
    lda #$0003               ; write-protected
    jmp _h13_err
_h13_badj:
    jmp _h13_bad
_h13_sec:
    lda cT0
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    clc
    adc cT2n                 ; per-drive bank base (fast mirrors)
    sep #$20
    sta mPTR2+2
    rep #$20
    lda cT0
    and #$003F
    asl a
    xba
    and #$FE00
    clc
    adc #$8000
    sta mPTR2
.IFDEF BIGMEM
    jsr bigmem_seccopy       ; SRAM isn't reachable by the WRAM DMA; copy
    jmp _h13_nc              ; the sector byte-wise, seam-aware (also
.ENDIF                       ; advances mPTR across region boundaries)
    ; DMA the 512-byte sector ROM(mPTR2) -> WRAM(mPTR) via the $2180
    ; WMDATA port. ~5x the old word loop; Y (guest IP) is untouched.
    sep #$20
    lda mPTR                 ; WMADD = dest linear (offset + $7E/$7F bank)
    sta.l $002181
    lda mPTR+1
    sta.l $002182
    lda mPTR+2
    and #$01                 ; $7E->0, $7F->1
    sta.l $002183
    lda #$00
    sta.l $004300            ; DMAP0: A->B, inc A, 1-byte to 1 reg
    lda #$80
    sta.l $004301            ; BBAD0 = $2180 (WMDATA)
    rep #$20
    lda mPTR2
    sta.l $004302            ; A1T0 = source offset
    sep #$20
    lda mPTR2+2
    sta.l $004304            ; A1B0 = source bank
    rep #$20
    lda #512
    sta.l $004305            ; DAS0 = 512 bytes
    sep #$20
    lda #$01
    sta.l $00420B            ; trigger ch0
    rep #$20
    lda mPTR
    clc
    adc #512
    sta mPTR
    bcc _h13_nc
    sep #$20
    inc mPTR+2
    rep #$20
_h13_nc:
    inc cT0
    dec cT1
    lda cT1
    beq _h13_secd
    jmp _h13_sec
_h13_secd:
    ply
    jmp _h13_ok

.IFDEF BIGMEM
; --- BIGMEM: copy 512 bytes ROM(mPTR2) -> guest(mPTR), one byte at a
; time, remapping mPTR at each region seam ($7F:FFFF->$70:0000 WRAM->
; SRAM page 0, $70:7FFF->$71:0000 page 0->page 1). The dest may be
; WRAM, SRAM, or straddle a seam. mPTR ends past the sector; mPTR2 is
; recomputed by the caller so trashing it is fine.
bigmem_seccopy:
    ldx #512
_bsc:
    sep #$20
    lda [mPTR2]
    sta [mPTR]
    rep #$20
    inc mPTR2                ; source: +1 byte (no ROM-bank cross in a sector)
    jsr gadv_ptr             ; dest: +1 byte, seam-aware
    dex
    bne _bsc
    rts

; advance mPTR by one guest byte, folding region boundaries into the
; real WRAM/SRAM banks (A/X/Y preserved except A).
gadv_ptr:
    rep #$20
    inc mPTR
    beq _ga_wrap             ; low16 $FFFF -> 0: bank changed (WRAM top)
    lda mPTR
    cmp #$8000
    beq _ga_8000             ; possible SRAM page boundary
    rts
_ga_wrap:
    sep #$20
    inc mPTR+2
    lda mPTR+2
    cmp #$80                 ; $7F -> $80: WRAM end -> SRAM page 0
    bne _ga_wd
    lda #$70
    sta mPTR+2
_ga_wd:
    rep #$20
    rts
_ga_8000:
    sep #$20
    lda mPTR+2
    cmp #$70                 ; page 0 end -> page 1 start
    beq _ga_71
    cmp #$71                 ; page 1 end -> wrap page 0 (past 172 KB)
    bne _ga_8d
    lda #$70
    bra _ga_8w
_ga_71:
    lda #$71
_ga_8w:
    sta mPTR+2
    rep #$20
    stz mPTR
    rts
_ga_8d:
    rep #$20
    rts
.ENDIF

    ; ---- C: fixed disk (DL=80h): 107 cyl x 4 heads x 17 spt, ROM banks
    ; $8E-$FF via the fast mirrors, read-only. LBA fits 16 bits (<=7275).
_h13_hd:
    lda gDX
    and #$FC00               ; head < 4
    bne _h13_badj2
    lda gCX
    and #$00C0               ; cyl bits 8-9 must be 0 (cyl < 107)
    bne _h13_badj2
    lda gCX
    and #$003F               ; 1 <= sec <= 17
    beq _h13_badj2
    cmp #18
    bcs _h13_badj2
    dec a
    sta cT0                  ; sec-1
    lda gCX
    xba
    and #$00FF               ; cyl
    cmp #107
    bcs _h13_badj2
    asl a
    asl a                    ; cyl*4
    sta cT2n
    lda gDX
    xba
    and #$00FF               ; head
    clc
    adc cT2n                 ; cyl*4 + head
    sta cT1
    asl a
    asl a
    asl a
    asl a                    ; *16
    clc
    adc cT1                  ; *17
    clc
    adc cT0
    sta cT0                  ; LBA
    ldx #24
    lda gBX
    jsr mk_ptr               ; mPTR = ES:BX
    phy
    lda gAX
    and #$00FF
    sta cT1                  ; sectors remaining
    lda #$008E
    sta cT2n                 ; HD bank base
    lda gAX
    xba
    and #$00FF
    cmp #$0003
    bne _h13_secj
    ply
    lda #$0003               ; fixed disk is ROM: write-protected
    jmp _h13_err
_h13_secj:
    jmp _h13_sec
_h13_badj2:
    jmp _h13_bad

    ; ---- drive B: SRAM disk (LBA 0-63, 32 KB), read/write, persistent
_h13_vdisk:
    lda cT0                  ; IO.SYS's DPB addresses B: as 2-sided 9-spt
    clc                      ; (same as A:), so head 1 is legitimate -
    adc cT1                  ; the LBA math above already folded it in
    cmp #65
    bcs _h13_vbad
_h13_vsec:
    lda cT0
    xba
    asl a                    ; LBA*512 -> SRAM offset
    sta mPTR2
    sep #$20
    lda.b #$70               ; SRAM bank
    sta mPTR2+2
    rep #$20
    lda gAX
    xba
    and #$00FF
    cmp #$0003
    beq _h13_vw
    ldy #0
_h13_vr:
    lda [mPTR2],y            ; SRAM -> guest
    sta [mPTR],y
    iny
    iny
    cpy #512
    bcc _h13_vr
    bra _h13_vnext
_h13_vw:
    ldy #0
_h13_vwl:
    lda [mPTR],y             ; guest -> SRAM
    sta [mPTR2],y
    iny
    iny
    cpy #512
    bcc _h13_vwl
_h13_vnext:
    lda mPTR
    clc
    adc #512
    sta mPTR
    bcc _h13_vnc
    sep #$20
    inc mPTR+2
    rep #$20
_h13_vnc:
    inc cT0
    dec cT1
    lda cT1
    bne _h13_vsec
    ply
    jmp _h13_ok
_h13_vbad:
    ply
    lda #$0004               ; sector not found
    jmp _h13_err

;----------------------------------------------------------------------
; keyboard inject: START types "dir" + Enter (called from NMI)
;----------------------------------------------------------------------
kb_push:                     ; A = (scan<<8)|ascii -> INT16 ring + INT9 queue
    pha
    lda.l $7E5024            ; guest INT9 hook replaces the BIOS handler:
    cmp #$04F0               ; the INT16 ring starves while hooked, keys
    bne _kp_hkd              ; flow as raw scancodes only
    lda.l $7E5026
    bne _kp_hkd
    pla
    ldx cKbT
    sta.w $0700,x            ; 32-entry ring in low WRAM
    txa
    clc
    adc #2
    and #$003E
    sta cKbT
    lda.w $0700,x            ; recover the entry, take the scancode
    bra _kp_q
_kp_hkd:
    pla
_kp_q:
    xba
    and #$00FF
    beq _kp_n9               ; no scancode: INT16-only synthetic key
    sta s60                  ; latch for raw port-60h pollers
    ldx s9H
    sta.w $0600,x            ; make code
    ora #$0080
    pha
    txa
    clc
    adc #2
    and #$001E
    tax
    pla
    sta.w $0600,x            ; break code
    txa
    clc
    adc #2
    and #$001E
    sta s9H
_kp_n9:
    rts

;----------------------------------------------------------------------
; NMI: ack, drain VRAM queue, ticks, joypad (DBR must be 0 for MMIO)
;----------------------------------------------------------------------
VBlank:
    jml _vb_fast             ; NMI vector runs in bank $00: go fast
_vb_fast:
    rep #$30
    pha
    phx
    phy
    phb
    sep #$20
    lda.b #$00
    pha
    plb
    lda $4210
    lda.b #$80
    sta $2115
    rep #$20
    inc cNMI
    lda s9CD                 ; INT9 inter-key hold-off, in real frames
    beq _vb_ncd              ; (run_slow passes are useless as a clock:
    dec a                    ; REP-heavy guests make them ~2/frame)
    sta s9CD
_vb_ncd:
.IFNDEF TRACE
    ; 18.2065 Hz tick from 60.1 Hz NMI: add 0.30303 in 16.16 fixed point
    lda cTickA
    clc
    adc #19854
    sta cTickA
    bcc _vb_notick
    inc cTickL
    bne _vb_tkw
    inc cTickH
_vb_tkw:
    lda #1
    sta cTickP               ; request a guest INT 8
    lda cTickL               ; mirror into guest BDA 40:6C (TP polls it)
    sta.l $7E546C
    lda cTickH
    sta.l $7E546E
_vb_notick:
.ENDIF
    lda cBEEP                ; timed BEL: gate the speaker off at zero
    beq _vb_nbeep
    dec a
    sta cBEEP
    bne _vb_nbeep
    stz bGON
    lda #1
    sta bDIRTY
_vb_nbeep:
    jsr midi_frame           ; beep flags + the 60Hz MIDI sequencer
    lda cGFX
    bne _vb_gfx1
    brl _vb_ngfx             ; (the mode-6 upload grew past beq range)
_vb_gfx1:
    sep #$20                 ; BG3HOFS = kPAN*8 (0 or 64: left/right window)
    lda kPAN
    asl a
    asl a
    asl a
    sta $2111
    stz $2111
    rep #$20
    lda gSTG                 ; staged tile row -> VRAM (ch1: ch0 is INT13's)
    bne _vb_stg1
    brl _vb_nstg
_vb_stg1:
    dec a
    sta kT0
    lda cMODE
    cmp #6
    bne _vb_s45
    lda kT0                  ; mode 6: banded rows, 512 words each
    cmp #16
    bcs _vb_s6b
    xba                      ; row*256 (high byte was clear)
    asl a                    ; row*512
    clc
    adc #CG6B1
    bra _vb_s6w
_vb_s6b:
    cmp #24
    bcs _vb_s6c
    sec
    sbc #16
    xba
    asl a                    ; (row-16)*512
    clc
    adc #CG6B2
    bra _vb_s6w
_vb_s6c:
    lda #CG6B3
_vb_s6w:
    sta $2116
    lda #1024
    bra _vb_sgo
_vb_s45:
    lda kT0                  ; VMADD = CGTIL + row*320
    asl a
    asl a
    asl a
    asl a
    asl a
    asl a                    ; row*64
    sta kT1
    lda kT0
    xba
    and #$FF00               ; row*256
    clc
    adc kT1
    clc
    adc #CGTIL
    sta $2116
    lda #640
_vb_sgo:
    sta kT1                  ; DMA byte count
    sep #$20
    lda.b #$01               ; DMA ch1: mode 1 -> $2118/19
    sta $4310
    lda.b #$18
    sta $4311
    stz $4314                ; source bank 0 (WRAM mirror)
    rep #$20
    lda #STG
    sta $4312
    lda kT1
    sta $4315
    sep #$20
    lda.b #$02
    sta $420B
    rep #$20
    stz gSTG
_vb_nstg:
    lda cPALD
    beq _vb_ngfx
    jsr pal_apply
    stz cPALD
_vb_ngfx:
    ldy #24                  ; drain budget (queue now kbd-only)
_vb_drain:
    lda cQT
    cmp cQH
    beq _vb_pad
    tax
    lda.w CQBASE,x
    bmi _vb_vofs
    sta $2116
    lda.w CQBASE+2,x
    sta $2118
_vb_next:
    txa
    clc
    adc #4
    and #CQMASK
    sta cQT
    dey
    bne _vb_drain
_vb_pad:
    sep #$20
_vb_jw:
    lda $4212
    lsr a
    bcs _vb_jw
    rep #$20
    lda cJoyN
    sta cJoyP
    lda $4218
    sta cJoyN
    jsr kbd_frame
    jsr kbd_shift            ; before scan_rows: label writes don't self-heal
    lda cGFX
    beq _vb_txts
    jsr gfx_scan             ; gfx: convert next tile row into staging
    bra _vb_done
_vb_txts:
    jsr scan_rows            ; LAST: if the repaint overruns vblank only
_vb_done:
    rep #$30
    plb
    ply
    plx
    pla
    rti
_vb_vofs:
    lda cGFX                 ; mode 6: ch3's data is the bitmap's constant
    beq _vbv_ok              ; -1 — a queued terminal-scroll vofs must not
    lda cMODE                ; clobber it (still consume the entry)
    cmp #6
    beq _vb_next
_vbv_ok:
    lda.w CQBASE+2,x
    sep #$20
    sta $0741
    sta $0744
    sta $0751
    sta $0754
    xba
    sta $0742
    sta $0745
    sta $0752
    sta $0755
    rep #$20
    bra _vb_next

;----------------------------------------------------------------------
; reset
;----------------------------------------------------------------------
Reset:
    sei
    clc
    xce
    jml _rst_fast            ; reset vectors land in bank $00: go fast
_rst_fast:
    rep #$38
    ldx #$0FFF               ; native stack BELOW the CGA adapter RAM!
    txs                      ; ($1000-$4FFF is framebuffer: a 16 KB clear
                             ; at $1FFF ate a live return address once —
                             ; cost a full debugging session. And the
                             ; mode-6 staging buffer reaching $0FFF ate
                             ; the NMI's saved frame — cost another one.
                             ; Staging now ends $0DFF; worst native depth
                             ; is ~40 bytes.)
    lda #$0000
    tcd
    ; -- zero all of bank-0 low WRAM ($0000-$1FFF) up front. Mesen's
    ; power-on RAM is RANDOM; every uninitialized display var, HDMA
    ; table byte or scratch would otherwise be seed-dependent garbage
    ; (green DOS console vs black, unstable CGA colors run-to-run). The
    ; stack is empty here (no jsr yet), so wiping page $0F is safe.
    ldx #$1FFE
_rst_wz:
    stz.w $0000,x
    dex
    dex
    bpl _rst_wz
    sep #$20
    lda.b #$00
    pha
    plb

    lda.b #$8F
    sta $2100
    ; PPU init: mode 5 two-layer 64-col console (as proven in M1)
    stz $2101
    stz $2102
    stz $2103
    stz $2104
    lda.b #$05
    sta $2105
    stz $2106
    lda.b #$04
    sta $2107
    stz $2108
    stz $2109
    stz $210A
    lda.b #$13
    sta $210B
    stz $210C
    stz $210D
    stz $210D
    lda.b #$FF
    sta $210E
    lda.b #$03
    sta $210E
    stz $210F
    stz $210F
    lda.b #$FF
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
    sta $2115
    stz $211A
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
    sta $212C
    sta $212D
    stz $212E
    stz $212F
    lda.b #$30
    sta $2130
    stz $2131
    lda.b #$E0
    sta $2132
    stz $2133
    stz $4200
    lda.b #$FF
    sta $4201
    stz $420B
    stz $420C
    lda.b #$01
    sta $420D                ; FastROM: 3.58 MHz cartridge access

    ; CGRAM: fonts encode bg = color 1, fg = color 2, so each palette
    ; holds one (bg, fg) attribute pair. Pair 0 (CGRAM 1/2, shared by
    ; both layers' palette 0) = the default black/green. Pair 7 is the
    ; fixed keyboard highlight: 2bpp pal 7 = CGRAM 29/30, 4bpp pal 7 =
    ; CGRAM 113/114 (yellow bg, black fg). Pairs 1-3, 5-6 are allocated
    ; dynamically from CGA attribute bytes (2bpp pal 4 aliases 4bpp
    ; pal 1 in CGRAM, so pair 4 is unusable).
    stz $2121                ; clear ALL 256 CGRAM entries first — only a
    ldx #512                 ; few are set below; the rest were random at
_cg_clr:                     ; power-on and leaked into CGA/gfx colors
    stz $2122
    dex
    bne _cg_clr
    stz $2121
    stz $2122
    stz $2122                ; backdrop black
    stz $2122
    stz $2122                ; pair 0 bg: black
    lda.b #$E0
    sta $2122
    lda.b #$03
    sta $2122                ; pair 0 fg: green
    lda.b #29
    sta $2121
    lda.b #$FF
    sta $2122
    lda.b #$03
    sta $2122                ; pair 7 bg: yellow (2bpp)
    stz $2122
    stz $2122                ; pair 7 fg: black
    lda.b #113
    sta $2121
    lda.b #$FF
    sta $2122
    lda.b #$03
    sta $2122                ; pair 7 bg: yellow (4bpp)
    stz $2122
    stz $2122

    ; fonts -> VRAM
    rep #$20
    lda #$1000
    sta $2116
    sep #$20
    lda.b #$01
    sta $4300
    lda.b #$18
    sta $4301
    rep #$20
    lda #font_bg2
    sta $4302
    sep #$20
    lda.b #:font_bg2
    sta $4304
    rep #$20
    lda #$3000
    sta $4305
    sep #$20
    lda.b #$01
    sta $420B
    rep #$20
    lda #$3000
    sta $2116
    lda #font_bg1
    sta $4302
    sep #$20
    lda.b #:font_bg1
    sta $4304
    rep #$20
    lda #$4000
    sta $4305
    sep #$20
    lda.b #$01
    sta $420B

    ; clear tilemaps
    rep #$20
    lda #$0000
    sta $2116
    lda #BLANKE
    ldx #2048
_rst_clr:
    sta $2118
    dex
    bne _rst_clr

    ; -- adapter RAM + guest memory: zero $7E:1000-$7E:FFFF (16 KB CGA
    ; adapter then guest low) and all of $7F (guest 108 KB to $7F:FFFF)
    lda #$0000
    ldx #VBOFS
_rst_z1:
    sta.l $7E0000,x
    inx
    inx
    bne _rst_z1
    ldx #$0000
_rst_z2:
    sta.l $7F0000,x
    inx
    inx
    bne _rst_z2
.IFDEF BIGMEM
    ; -- guest high RAM (108-172 KB) is the 64 KB cart SRAM, banks $70/$71
    ldx #$0000
_rst_zs:
    sta.l $700000,x
    sta.l $710000,x
    inx
    inx
    cpx #$8000
    bcc _rst_zs
.ENDIF

    ; -- IVT: all 256 vectors -> 0000:04F0 (IRET stub in BDA scratch,
    ; safe from the boot sector's directory read at 0x500-0x6FF)
    ldx #$0000
_rst_ivt:
    lda #$04F0
    sta.l $7E5000,x
    inx
    inx
    lda #$0000
    sta.l $7E5000,x
    inx
    inx
    cpx #$0400
    bcc _rst_ivt
    sep #$20
    lda.b #$CF               ; IRET
    sta.l $7E54F0
    rep #$20

    ; -- BIOS data area: equipment + memory size
    lda #$0061
    sta.l $7E5410
    lda #GUESTKB
    sta.l $7E5413
    lda #$001E               ; BIOS kb ring in the BDA: head = tail = 1E
    sta.l $7E541A            ; (served by INT16 when a guest INT9 hook
    sta.l $7E541C            ; stores keys BIOS-protocol style)
    sta.l $7E5480
    lda #$003E
    sta.l $7E5482

    ; -- boot sector: image offset 0 (bank 2) -> linear 0x7C00
    ldx #$0000
_rst_bs:
    lda.l $828000,x
    sta.l $7ECC00,x
    inx
    inx
    cpx #$0200
    bcc _rst_bs

    ; -- guest registers
    lda #$0000
    sta gAX
    sta gCX
    sta gBX
    sta gSI
    sta gDI
    sta gBP
    sta gDX                  ; DL = 0: boot drive A
    sta gES
    sta gCS
    sta gSS
    sta gDS
    sta gHALT
    sta gINHIB
    sta lfKIND
    lda #$7C00
    sta gIP
    sta gSP
    lda #$F002
    sta fSTATIC
    lda #GUEST_BASE
    sta bES
    sta bCS
    sta bSS
    sta bDS
.IFDEF BIGMEM
    sta bCSc                 ; naive CS base: fetch_rebase derives from
.ENDIF                       ; this in every BIGMEM build
    sep #$20
    lda.b #$7E
    sta bES+2
    sta bCS+2
    sta bSS+2
    sta bDS+2
.IFDEF BIGMEM
    sta bCSc+2
.ENDIF
    rep #$20
.IFDEF ELKS
    ; ELKS ROM boot: enter the option-ROM's INT 19h handler at E000:0014
    ; (the 55AA init at :0003 only hooks INT 19h and RETFs to a BIOS we
    ; don't have). bCS = folded base of segment E000 = kernel ROM bank 0
    ; at its $8000 half — what EFOLD would produce for naive $8C:5000.
    lda #$E000
    sta gCS
    lda #$0014
    sta gIP
    lda #$8000
    sta bCS                  ; real folded pointer for the first fetch
    lda #$5000
    sta bCSc                 ; NAIVE E000 base ($7E5000+E0000 = $8C:5000)
    sep #$20
    lda.b #EK_B0
    sta bCS+2
    lda.b #$8C
    sta bCSc+2
    rep #$20
    ; zero the SRAM guest RAM (banks $70/$71): Mesen powers it random and
    ; persists .srm across runs; the C-core oracle (and a sane fresh
    ; machine) sees zeros — keeps boots deterministic and lockstep exact
    lda #$0000
    ldx #$0000
_rst_zsram:
    sta.l $700000,x
    sta.l $710000,x
    inx
    inx
    cpx #$8000
    bcc _rst_zsram
.ENDIF

.IFNDEF BIGMEM
    ; -- B: SRAM disk ($70:0000, 32 KB, battery-backed). Format from the
    ; ROM template ONLY if the boot signature is missing — a formatted
    ; disk means the battery kept the user's files: preserve them.
    ; (In the BIGMEM variant the SRAM is guest high RAM, not B:.)
    lda.l $7001FE
    cmp #$AA55
    bne _rst_dofmt
    lda.l $700200
    and #$00FF
    cmp #$00FC               ; B: FAT media byte
    beq _rst_fmtd
_rst_dofmt:
    ldx #$0000
_rst_fmt:
    lda.l bdisk_start,x
    sta.l $700000,x
    inx
    inx
    cpx #4608
    bcc _rst_fmt
_rst_fmtd:
.ENDIF

    ; -- on-screen keyboard: draw into its tilemaps, set up the HDMA
    ; raster split (terminal scrolls above, keyboard fixed below)
    stz kSHV                 ; before kbd_draw: its kbd_color tail reads it
    jsr kbd_draw
    stz kSEL
    stz kMOD
    stz kVIS
    stz kRPT
    lda #27
    sta kROWS
    stz cTOP                 ; kbd_tables derives the vofs from cTOP — it
    jsr kbd_tables           ; must be zeroed BEFORE the tables are built
                             ; (power-on WRAM is random: boot-time garbage
                             ; here scrambled the whole display)
    sep #$20
    lda.b #$02               ; ch2: mode 2 (write-twice) -> $210E BG1VOFS
    sta.l $004320
    lda.b #$0E
    sta.l $004321
    lda.b #$02               ; ch3: -> $2110 BG2VOFS
    sta.l $004330
    lda.b #$10
    sta.l $004331
    stz.w $4340              ; ch4: mode 0 -> $2107 BG1SC
    lda.b #$07
    sta.l $004341
    stz.w $4350              ; ch5: mode 0 -> $2108 BG2SC
    lda.b #$08
    sta.l $004351
    stz.w $4324
    stz.w $4334
    stz.w $4344
    stz.w $4354              ; tables live in bank 0 WRAM
    sep #$20
    stz.w $4360              ; ch6: mode 0 -> $2105 (CGA gfx mode split)
    lda.b #$05
    sta.l $004361
    lda.b #$01               ; ch7: mode 1 -> $212C+$212D (TM and TS both:
    sta.l $004370            ; mode 5 shows the subscreen in odd columns)
    lda.b #$2C
    sta.l $004371
    stz.w $4364
    stz.w $4374              ; tables in bank 0 WRAM
    rep #$20
    lda #$0740
    sta.l $004322
    lda #$0750
    sta.l $004332
    lda #$0760
    sta.l $004342
    lda #$0770
    sta.l $004352
    lda #$0500
    sta.l $004362
    lda #$0510
    sta.l $004372
    sep #$20
    lda.b #$3C               ; HDMA on channels 2-5 (ch6/7 join in gfx)
    sta.l $00420C
    rep #$20

    ; -- console state + keyboard: pre-answer DATE and TIME prompts
    stz cNMI
    stz cQH
    stz cQT
    stz cGFX                 ; CGA graphics state (WRAM is random at
    stz gROW                 ; power-on — every var needs an init!)
    stz gSTG
    stz cPALD
    stz s3D8
    stz s3D9
    stz s60                  ; INT9 scancode latch + queue
    stz s9H
    stz s9T
    stz s9CD
    stz bPIT                 ; beep + MIDI card state
    stz bGON
    stz bDIRTY
    stz mFH
    stz mFT
    stz mSEQ
    stz mPKn
    stz mAOF
    stz mVNX
    stz mVCE
    lda #$FFFF
    sta mDLY
    ldx #0                   ; chprog[16] = 0, vChan/vNote: voices free
_rst_mv:
    stz.w $0520,x
    inx
    inx
    cpx #$0018
    bcc _rst_mv
    lda #$FFFF
    sta.w $0538
    sta.w $053A
    sta.w $053C
    sta.w $053E
    stz cROW
    stz cCOL
    stz cTOP
    stz cJoyP
    stz cJoyN
    stz cTickA
    stz cTickL
    stz cTickH
    stz cKbH
    stz cKbT
    stz cTickP
    stz kPAN
    stz scanROW
    lda #80
    sta cWID
    lda #3
    sta cMODE
    stz aST
    stz sFLIP
    stz sDIV
    stz sGATE
    stz cBEEP
    jsr attr_reset
    jsr apu_upload
    jsr con_clear

    ; -- NMI + autojoy on, screen on
    sep #$20
    lda.b #$81
    sta $4200
    rep #$30
    wai
    wai
    sep #$20
    lda.b #$0F
    sta $2100
    rep #$30

    ldx #boot_banner
    jsr con_puts

    ; -- run the 8086 forever
.IFDEF TRACE
; ELKS traces store records in the VBUF adapter RAM ($7E1000, host-owned;
; only the on-screen text suffers) — the DOS location $7FA000+ is guest
; linear 84-106K and LIVE ELKS memory (init code at CS=1A40 = 105K!):
; records and guest corrupted each other, showing phantom one-register
; divergences. Sentinels move with them ($7E4FF8/$7E4FFA).
.IFDEF ELKS
.DEFINE TRB  $7E2000
.DEFINE TRBC $7E4FF8
.DEFINE TRBM $7E4FFA
.ELSE
.DEFINE TRB  $7FA000
.DEFINE TRBC $7FFFFA
.DEFINE TRBM $7FFFFC
.ENDIF
    stz snapPTR
.IFDEF ELKS
    lda #TRACE_SKIPL         ; deep windows: 32-bit skip = H*65536 + L
    sta tSKIP                ; (high word lives in a VBUF cell)
    lda #TRACE_SKIPH
    sta.l $7E4FF6
.ELSE
    lda #TRACE_SKIP
    sta tSKIP
.ENDIF
    lda #TRACE_COUNT
    sta stepCNT
.IFDEF ELKS
    lda #15000
    sta.l $7E4FF4            ; deterministic-tick countdown (VBUF cell)
    lda #0
    sta.l $7E4FF2            ; pending-tick flag (WRAM powers up random)
.ENDIF
_rst_run:
    jsr x86step
.IFDEF ELKS
    lda.l $7E4FF4            ; every -tick instructions: mirror runpc
    dec a                    ; exactly. Due -> pending; the sreg-load/STI
    sta.l $7E4FF4            ; shadow defers it one instruction, IF=0
    bne _rst_ntdue           ; holds it like the PIC, IF=1 wakes HLT +
    lda #15000               ; vectors INT 8. (runpc implements the same
    sta.l $7E4FF4            ; rules — the two stay in lockstep.)
    lda #1
    sta.l $7E4FF2            ; pending-tick flag (VBUF cell)
_rst_ntdue:
    lda.l $7E4FF2
    beq _rst_notick
    lda gINHIB
    bne _rst_notick          ; shadowed: retry after the next instruction
    lda fSTATIC
    and #$0200
    beq _rst_notick          ; IF=0: held pending like the PIC (runpc rule)
    lda #0
    sta.l $7E4FF2            ; delivered: clear the pending mark
    stz gHALT
    lda #8
    jsr do_int
    sty gIP
_rst_notick:
    stz gINHIB               ; the shadow lasts exactly one instruction
.ENDIF
    lda tSKIP
    beq _rst_sk0
    dec tSKIP
    bra _rst_run
_rst_sk0:
.IFDEF ELKS
    lda.l $7E4FF6
    beq _rst_snap
    dec a
    sta.l $7E4FF6
    lda #$FFFF               ; consume another 65536 (this iteration + FFFF)
    sta tSKIP
    bra _rst_run
.ENDIF
_rst_snap:
    jsr dsnap
    dec stepCNT
    bne _rst_run
    lda #TRACE_COUNT
    sta.l TRBC
    lda #$CAFE
    sta.l TRBM
_rst_halt:
    wai
    bra _rst_halt
dsnap:
    jsr flags_norm
    ldx snapPTR
    lda gAX
    sta.l TRB+$00,x
    lda gCX
    sta.l TRB+$02,x
    lda gDX
    sta.l TRB+$04,x
    lda gBX
    sta.l TRB+$06,x
    lda gSP
    sta.l TRB+$08,x
    lda gBP
    sta.l TRB+$0A,x
    lda gSI
    sta.l TRB+$0C,x
    lda gDI
    sta.l TRB+$0E,x
    lda gES
    sta.l TRB+$10,x
    lda gCS
    sta.l TRB+$12,x
    lda gSS
    sta.l TRB+$14,x
    lda gDS
    sta.l TRB+$16,x
    lda gIP
    sta.l TRB+$18,x
    lda fSTATIC
    sta.l TRB+$1A,x
    txa
    clc
    adc #28
    sta snapPTR
    rts
.ELSE
_rst_run:
    ldy gIP
    lda #64
    sta tSKIP                ; dispatch gas (tSKIP is trace-only state,
    jmp step_lean            ; free in this build) — the core threads
                             ; from op to op and calls back here:
run_slow:                    ; gas exhausted (or HLT): service and refuel
    sty gIP
    lda #64
    sta tSKIP
    lda gINHIB               ; sreg-load/STI shadow: the instruction that
    beq _rs_shok             ; just retired blocks delivery until one more
    stz gINHIB               ; runs (MOV SS,x / MOV SP,y must be atomic).
    bra _rs_n9               ; Skip both delivery checks this pass — but
_rs_shok:                    ; still honor a parked HLT below (STI;HLT).
    lda cTickP
    beq _rs_nirq
    lda fSTATIC              ; IF lives in the static flag bits
    and #$0200
    beq _rs_nirq
    stz cTickP
    lda #8                   ; 18.2 Hz timer tick -> guest IVT[8]
    jsr do_int
    sty gIP
    stz gHALT                ; 8086: interrupt delivery wakes HLT. Without
                             ; this, HLT with a tick already pending vectors
                             ; the handler but re-parks on gHALT=1 with the
                             ; handler's IF=0 — machine freezes mid-boot.
_rs_nirq:
    lda s9CD                 ; hold-off pending (the NMI counts it down)
    bne _rs_n9
    lda s9T                  ; pending scancode -> IRQ1 when the guest
    cmp s9H                  ; hooked INT9 (FS1, Snipes: raw keyboard)
    beq _rs_n9
    lda fSTATIC
    and #$0200
    beq _rs_n9
    lda.l $7E5024            ; IVT[9] offset: still our 0000:04F0 stub?
    cmp #$04F0
    bne _rs_9go
    lda.l $7E5026            ; IVT[9] segment
    bne _rs_9go
    lda s9T                  ; unhooked: drop (the INT16 ring has the key)
    inc a
    inc a
    and #$001E
    sta s9T
    bra _rs_n9
_rs_9go:
    ldx s9T
    lda.w $0600,x
    and #$00FF
    sta s60                  ; the handler INs this from port 60h
    lda s9T
    inc a
    inc a
    and #$001E
    sta s9T
    lda #8                   ; frames of key-held time before the next code
    sta s9CD
    lda #9
    jsr do_int
    sty gIP
    stz gHALT                ; same wake rule for IRQ1 delivery
_rs_n9:
    lda gHALT
    bne _rst_halt
    jmp step_lean
_rst_halt:
    wai                      ; HLT with IF=1: sleep to the next NMI, then
    lda fSTATIC              ; rejoin run_slow — it delivers any pending
    and #$0200               ; tick/key and resumes the guest after the
    beq _rst_halt            ; HLT. IF=0 stays parked (a real 8086 hang).
    stz gHALT                ; (Was ELKS-only; correct for DOS too — any
    jmp run_slow             ; app idling in STI;HLT used to freeze here.)
.ENDIF


;----------------------------------------------------------------------
; on-screen keyboard. Runs from the NMI (DBR=0, inside vblank), so all
; VRAM writes here go straight to the ports. Uses only kT0-kT3 temps
; (the core's cT0/cT1/mA temps may be live mid-INT 13h when NMI fires).
;----------------------------------------------------------------------
scan_rows:                   ; repaint 2 virtual rows -> tilemaps
    lda #2
    sta kT3
_sr_l:
    lda scanROW
    inc a
    cmp #25
    bcc _sr_ok
    lda #0
_sr_ok:
    sta scanROW
    stz kT2                  ; vertical offset (keyboard visible + deep cursor)
    lda kVIS
    beq _sr_nv
    lda cROW
    cmp #23
    bcc _sr_nv
    sec
    sbc #22
    sta kT2
_sr_nv:
    lda scanROW
    sec
    sbc kT2
    bmi _sr_nxj
    cmp #23
    bcs _sr_chk
    bra _sr_go
_sr_chk:
    ldx kVIS                 ; rows 23-24 only visible without keyboard
    bne _sr_nxj
    cmp #25
    bcc _sr_go
_sr_nxj:
    jmp _sr_next
_sr_go:
    sta kT1                  ; screen row
    ; src offset = scanROW*(cWID*2) + kPAN*2  (160-byte rows in 80-col text,
    ; 80-byte rows in 40-col — real CGA stride, so direct-B800 40-col
    ; programs like Starglider aren't interleaved into the 80-col buffer)
    lda scanROW
    asl a
    asl a
    asl a
    asl a
    asl a
    sta kT0
    asl a
    asl a
    clc
    adc kT0                  ; scanROW*160
    pha
    lda cWID
    cmp #80
    beq _sr_st
    pla
    lsr a                    ; 40-col: scanROW*80
    bra _sr_sd
_sr_st:
    pla
_sr_sd:
    sta kT0
    lda kPAN
    asl a
    clc
    adc kT0
    sta kT0
    ; BG2 (even columns): map addr = row*32. Per cell: tile from the
    ; char byte, palette bits from the attribute byte via the LUT at
    ; WRAM $0400 (Y indexes it; nCNT is the loop counter).
    lda kT1
    asl a
    asl a
    asl a
    asl a
    asl a
    sta.w $2116
    ldx kT0
    lda #32
    sta nCNT
    lda cWID
    cmp #80
    beq _sr_b2
    jmp _sr_w40
_sr_b2:
    lda.l VBUF,x
    tay
    and #$FF00
    cmp #$0700               ; the default attr: no LUT, palette 0
    bne _sr_b2s
    tya
    and #$00FF
    asl a
    ora #$2000
    bra _sr_b2w
_sr_b2s:
    tya
    and #$00FF
    asl a
    sta nTIL
    tya
    xba
    and #$007F
    asl a
    tay
    lda.w $0400,y            ; attr -> palette bits
    cmp #$FFFF
    bne _sr_b2h
    jsr sr_alloc
_sr_b2h:
    ora nTIL
    ora #$2000
_sr_b2w:
    sta.w $2118
    inx
    inx
    inx
    inx
    dec nCNT
    bne _sr_b2
    ; BG1 (odd columns): map addr = $0400 + row*32
    lda kT1
    asl a
    asl a
    asl a
    asl a
    asl a
    clc
    adc #$0400
    sta.w $2116
    ldx kT0
    inx
    inx
    lda #32
    sta nCNT
_sr_b1:
    lda.l VBUF,x
    tay
    and #$FF00
    cmp #$0700
    bne _sr_b1s
    tya
    and #$00FF
    asl a
    ora #$2000
    bra _sr_b1w
_sr_b1s:
    tya
    and #$00FF
    asl a
    sta nTIL
    tya
    xba
    and #$007F
    asl a
    tay
    lda.w $0400,y
    cmp #$FFFF
    bne _sr_b1h
    jsr sr_alloc
_sr_b1h:
    ora nTIL
    ora #$2000
_sr_b1w:
    sta.w $2118
    inx
    inx
    inx
    inx
    dec nCNT
    bne _sr_b1
    bra _sr_next
    ; 40-column mode: one char per 16px cell, double-width glyphs
    ; (fat font at tiles 512+2c) on BG2; BG1 fully transparent.
_sr_w40:
    lda.l VBUF,x
    tay
    and #$00FF
    cmp #$0080
    bcc _sr_w40k
    lda #$0000
_sr_w40k:
    asl a
    ora #$0200
    sta nTIL
    tya
    xba
    and #$007F
    asl a
    tay
    lda.w $0400,y
    cmp #$FFFF
    bne _sr_w40h
    jsr sr_alloc
_sr_w40h:
    ora nTIL
    ora #$2000
    sta.w $2118
    inx
    inx
    dec nCNT
    bne _sr_w40
    lda kT1
    asl a
    asl a
    asl a
    asl a
    asl a
    clc
    adc #$0400
    sta.w $2116
    lda #32
    sta nCNT
    lda #$2000               ; tile 0 = fully transparent
_sr_w40b:
    sta.w $2118
    dec nCNT
    bne _sr_w40b
_sr_next:
    dec kT3
    lda kT3
    beq _sr_done
    jmp _sr_l
_sr_done:
    rts

sr_alloc:                    ; Y = (attr&$7F)*2 -> A = palette bits.
    phx                      ; Allocates a dynamic pair, writes its two
    ldx nNEXT                ; colors to CGRAM (we are in vblank), and
    cpx #10                  ; fills the LUT. Preserves X.
    bcc _sa_go
    lda #$0000               ; pool exhausted: default green pair
    sta.w $0400,y
    plx
    rts
_sa_go:
    lda.l sr_pairs,x
    sta nP
    inx
    inx
    stx nNEXT
    tya
    lsr a                    ; the attribute byte
    and #$000F
    asl a
    tax
    lda.l cga_pal,x
    sta nFG
    tya
    lsr a
    and #$0070
    lsr a
    lsr a
    lsr a                    ; bg*2
    tax
    lda.l cga_pal,x
    sta nBG
    lda nP
    asl a
    asl a
    inc a                    ; 2bpp pal p: CGRAM 4p+1
    jsr _sa_wr
    lda nP
    asl a
    asl a
    asl a
    asl a
    inc a                    ; 4bpp pal p: CGRAM 16p+1
    jsr _sa_wr
    lda nP
    xba
    asl a
    asl a                    ; palette bits p<<10
    sta.w $0400,y
    plx
    rts
_sa_wr:                      ; CGRAM address A: write bg then fg
    sep #$20
    sta.l $002121
    lda nBG
    sta.l $002122
    lda nBG+1
    sta.l $002122
    lda nFG
    sta.l $002122
    lda nFG+1
    sta.l $002122
    rep #$20
    rts

sr_pairs: .dw 1, 2, 3, 5, 6
cga_pal:  .dw $0000, $5400, $02A0, $56A0, $0015, $5415, $0155, $56B5
          .dw $294A, $7D4A, $2BEA, $7FEA, $295F, $7D5F, $2BFF, $7FFF

kbd_frame:
    lda cJoyP
    eor #$FFFF
    and cJoyN
    sta kT0
    and #$0020               ; L: pan left
    beq _kf_pr
    lda kPAN
    sec
    sbc #8
    bpl _kf_pw
    lda #0
_kf_pw:
    sta kPAN
_kf_pr:
    lda kT0
    and #$0010               ; R: pan right
    beq _kf_pd
    lda cWID
    sec
    sbc #64                  ; max pan: 16 (80-col), wraps to 8 via 40-32
    bpl _kf_pmx
    lda #8                   ; 40-col mode: 32 visible of 40
_kf_pmx:
    sta kT1
    lda kPAN
    clc
    adc #8
    cmp kT1
    bcc _kf_pw2
    lda kT1
_kf_pw2:
    sta kPAN
_kf_pd:
    lda kVIS
    beq _kf_hid
    jmp _kf_vis
_kf_hid:
    lda kT0                  ; hidden: SELECT=show; START/B/X/Y = Enter/
    and #$2000               ; Backspace/Space/Escape (d-pad = arrows)
    beq _kf_h1
    jmp kbd_toggle
_kf_h1:
    lda kT0
    and #$1000               ; START: Enter
    beq _kf_h2
    lda #$1C0D
    jsr kb_push
_kf_h2:
    lda kT0
    and #$8000               ; B: Backspace
    beq _kf_h3
    lda #$0E08
    jsr kb_push
_kf_h3:
    lda kT0
    and #$0040               ; X: Space
    beq _kf_h3b
    lda #$3920
    jsr kb_push
_kf_h3b:
    lda kT0
    and #$4000               ; Y: Escape
    beq _kf_h4
    lda #$011B
    jsr kb_push
_kf_h4:
    ; d-pad -> arrow keys (extended scancodes, AL=0) with autorepeat
    lda kT0
    and #$0F00               ; newly pressed direction?
    bne _kf_anew
    lda cJoyN
    and #$0F00               ; still held?
    beq _kf_arst
    inc kRPT
    lda kRPT
    cmp #15                  ; initial delay, then every 3 frames
    bcc _kf_ad
    lda #12
    sta kRPT
    lda cJoyN
    and #$0F00
    bra _kf_asel
_kf_anew:
    stz kRPT
_kf_asel:
    bit #$0800
    beq _kf_a1
    lda #$4800               ; up
    jmp kb_push
_kf_a1:
    bit #$0400
    beq _kf_a2
    lda #$5000               ; down
    jmp kb_push
_kf_a2:
    bit #$0200
    beq _kf_a3
    lda #$4B00               ; left
    jmp kb_push
_kf_a3:
    bit #$0100
    beq _kf_ad
    lda #$4D00               ; right
    jmp kb_push
_kf_arst:
    stz kRPT
_kf_ad:
    rts
_kf_vis:
    lda kT0
    and #$2000               ; SELECT: hide
    beq _kf_v1
    jmp kbd_toggle
_kf_v1:
    lda kT0
    and #$8000               ; B: backspace
    beq _kf_v2
    lda #$0E08
    jsr kb_push
_kf_v2:
    lda kT0
    and #$1000               ; START: enter
    beq _kf_v3
    lda #$1C0D
    jsr kb_push
_kf_v3:
    lda kT0
    and #$0040               ; X: space
    beq _kf_v4
    lda #$3920
    jsr kb_push
_kf_v4:
    lda kT0
    and #$4000               ; Y: sticky shift
    beq _kf_v5
    lda kMOD
    eor #$0001
    sta kMOD
_kf_v5:
    lda kT0
    and #$0080               ; A: press selected key
    beq _kf_v6
    jsr kbd_emit
_kf_v6:
    lda cJoyN
    and #$0F00               ; d-pad held?
    bne _kf_pad
    stz kRPT
    rts
_kf_pad:
    lda kT0
    and #$0F00
    bne _kf_fresh
    dec kRPT
    lda kRPT
    bne _kf_done
    lda #5
    sta kRPT
    bra _kf_domove
_kf_fresh:
    lda #18
    sta kRPT
_kf_domove:
    lda kSEL
    ldx #$0000
    jsr kbd_color
    jsr kbd_nav
    lda kSEL
    ldx #$1C00
    jsr kbd_color
_kf_done:
    rts

kbd_rec_x:                   ; A = key idx -> X = kbd_keys offset (idx*6)
    sta kT1
    asl a
    clc
    adc kT1
    asl a
    tax
    rts

kbd_grid_rd:                 ; grid[kT2*64 + kT3] -> A
    lda kT2
    asl a
    asl a
    asl a
    asl a
    asl a
    asl a
    clc
    adc kT3
    tax
    lda.l kbd_grid,x
    and #$00FF
    rts

kbd_nav:
    lda kSEL
    jsr kbd_rec_x
    lda.l kbd_keys,x         ; lo=row hi=col
    sta kT1
    and #$00FF
    sta kT2                  ; row
    lda kT1
    xba
    and #$00FF
    sta kT3                  ; col
    lda cJoyN
    and #$0800               ; up
    beq _kn_1
    lda kT2
    beq _kn_ret
    dec a
    sta kT2
    bra _kn_updown
_kn_1:
    lda cJoyN
    and #$0400               ; down
    beq _kn_2
    lda kT2
    cmp #4
    bcs _kn_ret
    inc a
    sta kT2
_kn_updown:
    jsr kbd_at
    cmp #$00FF
    beq _kn_ret
    sta kSEL
_kn_ret:
    rts
_kn_2:
    lda cJoyN
    and #$0200               ; left
    beq _kn_3
_kn_ll:
    lda kT3
    beq _kn_ret
    dec a
    sta kT3
    jsr kbd_grid_rd
    cmp #$00FF
    beq _kn_ll
    cmp kSEL
    beq _kn_ll
    sta kSEL
    rts
_kn_3:
    lda cJoyN
    and #$0100               ; right
    beq _kn_ret
_kn_rr:
    lda kT3
    cmp #63
    bcs _kn_ret
    inc a
    sta kT3
    jsr kbd_grid_rd
    cmp #$00FF
    beq _kn_rr
    cmp kSEL
    beq _kn_rr
    sta kSEL
    rts

kbd_at:                      ; key at (kT2,kT3), scanning left then right
    jsr kbd_grid_rd
    cmp #$00FF
    bne _ka_ret
_ka_l:
    lda kT3
    beq _ka_r0
    dec a
    sta kT3
    jsr kbd_grid_rd
    cmp #$00FF
    beq _ka_l
    rts
_ka_r0:
    lda #63
    sta kT3
_ka_r:
    jsr kbd_grid_rd
    cmp #$00FF
    bne _ka_ret
    dec kT3
    lda kT3
    bne _ka_r
    lda #$00FF
_ka_ret:
    rts

kbd_emit:
    lda kSEL
    jsr kbd_rec_x
    lda.l kbd_keys+3,x       ; lo=ascii hi=shifted
    sta kT1
    and #$00FF
    cmp #$00FF               ; SHIFT key
    bne _ke_1
    lda kMOD
    eor #$0001
    sta kMOD
    rts
_ke_1:
    cmp #$00FE               ; CTRL key
    bne _ke_2
    lda kMOD
    eor #$0002
    sta kMOD
    rts
_ke_2:
    sta kT2
    lda kMOD
    and #$0001
    beq _ke_3
    lda kT1
    xba
    and #$00FF
    sta kT2                  ; shifted char
_ke_3:
    lda kMOD
    and #$0002
    beq _ke_4
    lda kT2
    and #$001F               ; ctrl-<key>
    sta kT2
_ke_4:
    lda.l kbd_keys+4,x       ; lo=shifted hi=scan
    and #$FF00
    ora kT2
    jsr kb_push
    stz kMOD
    rts

kbd_color:                   ; A = key idx, X = palette bits ($0000/$0400)
    stx kT0
    jsr kbd_rec_x
    lda.l kbd_keys,x
    sta kT1                  ; lo=row hi=col
    lda.l kbd_keys+2,x
    and #$00FF
    sta kT2                  ; len
_kc_l:
    lda kT1
    and #$00FF
    asl a
    asl a
    asl a
    asl a
    asl a
    asl a
    sta kT3
    lda kT1
    xba
    and #$00FF
    clc
    adc kT3                  ; row*64+col
    tax
    lda kSHV                 ; glyph from the table matching the drawn
    bne _kc_sh               ; shift state (else re-painting the selected
    lda.l kbd_rows,x         ; key would un-shift its label)
    bra _kc_g
_kc_sh:
    lda.l kbd_rows_sh,x
_kc_g:
    and #$00FF
    asl a
    ora #$2000
    ora kT0
    pha
    lda kT1
    and #$00FF
    asl a
    asl a
    asl a
    asl a
    asl a                    ; row*32
    sta kT3
    lda kT1
    xba
    and #$00FF
    lsr a
    bcc _kc_e
    clc
    adc #$0C00
    bra _kc_s
_kc_e:
    clc
    adc #$0800
_kc_s:
    clc
    adc kT3
    sta.w $2116
    pla
    sta.w $2118
    lda kT1
    clc
    adc #$0100               ; col++
    sta kT1
    dec kT2
    lda kT2
    bne _kc_l
    rts

kbd_draw:                    ; init-time: render all 5 rows (forced blank)
    stz kT1                  ; lo=row hi=col, walk all cells
_kd_l:
    lda #1
    sta kT2
    lda kT1
    pha
    ; draw this single cell via kbd_color-style write: reuse loop body by
    ; temporarily treating each cell as a 1-length key with pal 0
    stz kT0
    pla
    sta kT1
    lda kT1
    and #$00FF
    asl a
    asl a
    asl a
    asl a
    asl a
    asl a
    sta kT3
    lda kT1
    xba
    and #$00FF
    clc
    adc kT3
    tax
    lda.l kbd_rows,x
    and #$00FF
    asl a
    ora #$2000
    pha
    lda kT1
    and #$00FF
    asl a
    asl a
    asl a
    asl a
    asl a
    sta kT3
    lda kT1
    xba
    and #$00FF
    lsr a
    bcc _kd_e
    clc
    adc #$0C00
    bra _kd_s
_kd_e:
    clc
    adc #$0800
_kd_s:
    clc
    adc kT3
    sta.w $2116
    pla
    sta.w $2118
    ; next cell: col++, wrap to next row after 63
    lda kT1
    clc
    adc #$0100
    sta kT1
    xba
    and #$00FF
    bne _kd_l                ; col wrapped to 0? (256 cols -> carry into row)
    lda kT1
    inc a
    sta kT1
    and #$00FF
    cmp #5
    bcc _kd_l
    ; highlight the initial selection
    lda #0
    ldx #$1C00
    jmp kbd_color

kbd_shift:                   ; redraw the shift-sensitive key labels when
    lda kMOD                 ; the sticky shift changed since they were
    and #$0001               ; last drawn (covers Y latch, the SHIFT key,
    cmp kSHV                 ; and kbd_emit's auto-unlatch). NMI-only:
    bne _ks_go               ; VRAM writes go straight to the ports, and
    rts                      ; ~47 delta cells fit the vblank budget.
_ks_go:
    sta kSHV
    stz kT0                  ; byte offset into kbd_sdelta (4 B records)
_ks_l:
    ldx kT0
    lda.l kbd_sdelta,x       ; lo=row hi=col
    sta kT1
    and #$00FF
    cmp #$00FF               ; row $FF: end of table
    beq _ks_hl
    asl a
    asl a
    asl a
    asl a
    asl a                    ; row*32
    sta kT2
    lda kT1
    xba
    and #$00FF               ; col
    lsr a                    ; col/2, carry = col&1
    bcc _ks_e
    clc
    adc #$0C00               ; odd cols: BG1 map
    bra _ks_s
_ks_e:
    clc
    adc #$0800               ; even cols: BG2 map
_ks_s:
    clc
    adc kT2
    sta.w $2116
    lda kT0
    clc
    adc kSHV                 ; record byte 2 = normal, 3 = shifted glyph
    tax
    lda.l kbd_sdelta+2,x
    and #$00FF
    asl a
    ora #$2000
    sta.w $2118
    lda kT0
    clc
    adc #4
    sta kT0
    bra _ks_l
_ks_hl:
    lda kSEL                 ; the selection may be among the redrawn
    ldx #$1C00               ; cells: repaint its highlight
    jmp kbd_color

kbd_toggle:
    lda kVIS
    eor #$0001
    sta kVIS
    beq _kt_off
    lda #22
    bra _kt_st
_kt_off:
    lda #27
_kt_st:
    sta kROWS
    lda cROW
    cmp kROWS
    bcc _kt_ok
    lda kROWS
    sta cROW
_kt_ok:
    jmp kbd_tables

kbd_tables:                  ; (re)build the HDMA tables per kVIS (DBR=0)
    lda cTOP
    asl a
    asl a
    asl a
    dec a
    and #$03FF
    sta kT0
    sep #$20
    lda.b #128
    sta.w $0740
    sta.w $0750
    sta.w $0760
    sta.w $0770
    lda kT0
    sta.w $0741
    sta.w $0751
    lda kT0+1
    sta.w $0742
    sta.w $0752
    lda.b #$04
    sta.w $0761
    stz.w $0771
    lda kVIS
    bne _kt_v2
    lda.b #96
    bra _kt_c2
_kt_v2:
    lda.b #56
_kt_c2:
    sta.w $0743
    sta.w $0753
    sta.w $0762
    sta.w $0772
    lda kT0
    sta.w $0744
    sta.w $0754
    lda kT0+1
    sta.w $0745
    sta.w $0755
    lda.b #$04
    sta.w $0763
    stz.w $0773
    lda kVIS
    beq _kt_hid
    lda.b #40
    sta.w $0746
    sta.w $0756
    sta.w $0764
    sta.w $0774
    lda.b #71                ; scanline 184 -> keyboard map row 0
    sta.w $0747
    sta.w $0757
    stz.w $0748
    stz.w $0758
    lda.b #$0C               ; BG1 map -> $0C00
    sta.w $0765
    lda.b #$08               ; BG2 map -> $0800
    sta.w $0775
    stz.w $0749
    stz.w $0759
    stz.w $0766
    stz.w $0776
    bra _kt_gfx
_kt_hid:
    stz.w $0746
    stz.w $0756
    stz.w $0764
    stz.w $0774
_kt_gfx:
    ; ch6 ($2105 video mode, 1-byte data) + ch7 ($212C+$212D main+sub
    ; screens, 2-byte data) tables: the CGA split (HDMA on while cGFX).
    ; Regions: mode 1 BG3-only bitmap to line 200 (184 with kbd), then
    ; mode-5 kbd (TM=TS=BG1|BG2, the hires pair) or a backdrop border.
    ; CGA mode 6 (M10p6) instead keeps the whole frame in SNES mode 5
    ; and rebands the BG2 char base ($210B) on ch6 — see _kt_m6.
    rep #$20
    lda cGFX
    beq _kt_m45
    lda cMODE
    cmp #6
    beq _kt_m6
_kt_m45:
    sep #$20
    lda.b #128
    sta.w $0500
    sta.w $0510
    lda.b #$01
    sta.w $0501
    lda.b #$04
    sta.w $0511
    stz.w $0512              ; TS off in the bitmap region
    lda kVIS
    bne _kt_g2
    lda.b #72
    bra _kt_g3
_kt_g2:
    lda.b #56
_kt_g3:
    sta.w $0502
    sta.w $0513
    lda.b #$01
    sta.w $0503
    lda.b #$04
    sta.w $0514
    stz.w $0515
    lda kVIS
    bne _kt_g4
    lda.b #24
    sta.w $0504
    sta.w $0516
    lda.b #$05
    sta.w $0505
    stz.w $0517              ; border: no layers -> backdrop
    stz.w $0518
    bra _kt_g5
_kt_g4:
    lda.b #40
    sta.w $0504
    sta.w $0516
    lda.b #$05               ; mode 5 for the on-screen keyboard
    sta.w $0505
    lda.b #$03               ; TM+TS: BG1+BG2
    sta.w $0517
    sta.w $0518
_kt_g5:
    stz.w $0506              ; end of both tables
    stz.w $0519
    rep #$20
    rts

_kt_m6:                      ; CGA mode 6: ch6 rebands $210B (BG2 chars);
    sep #$20                 ; BG1 nibble stays 3 so the kbd font lives
    lda.b #$80               ; lines 0-127 -> chars $5000
    sta.w $0500
    lda.b #$53
    sta.w $0501
    lda kVIS
    beq _k6_nv
    lda.b #56                ; 128-183 -> chars $7000 (kbd hides row 24)
    sta.w $0502
    lda.b #$73
    sta.w $0503
    lda.b #40
    sta.w $0504
    lda.b #$13               ; kbd region: the text fonts
    sta.w $0505
    stz.w $0506
    bra _k6_c7
_k6_nv:
    lda.b #64                ; 128-191 -> chars $7000
    sta.w $0502
    lda.b #$73
    sta.w $0503
    lda.b #8                 ; 192-199: row 24 in the $2C00 gap
    sta.w $0504
    lda.b #$23
    sta.w $0505
    lda.b #24                ; border: back to the text fonts
    sta.w $0506
    lda.b #$13
    sta.w $0507
    stz.w $0508
_k6_c7:
    lda.b #$80               ; ch7: bitmap = BG2 on main AND sub (hires
    sta.w $0510              ; pairs even/odd dots across the screens)
    lda.b #$02
    sta.w $0511
    sta.w $0512
    lda kVIS
    bne _k6_v7
    lda.b #72                ; to line 200
    sta.w $0513
    lda.b #$02
    sta.w $0514
    sta.w $0515
    lda.b #24                ; border: no layers -> backdrop
    sta.w $0516
    stz.w $0517
    stz.w $0518
    stz.w $0519
    bra _k6_sc
_k6_v7:
    lda.b #56                ; to line 184
    sta.w $0513
    lda.b #$02
    sta.w $0514
    sta.w $0515
    lda.b #40                ; mode-5 kbd: BG1+BG2
    sta.w $0516
    lda.b #$03
    sta.w $0517
    sta.w $0518
    stz.w $0519
_k6_sc:
    lda.b #$28               ; ch5 d1/d2: BG2SC = the bitmap map ($2800)
    sta.w $0771              ; over the bitmap (kbd entry keeps $08)
    sta.w $0773
    lda.b #$FF               ; ch3 d1/d2: BG2VOFS = the bitmap's -1
    sta.w $0751              ; (kbd entry keeps its own scroll)
    sta.w $0754
    lda.b #$03
    sta.w $0752
    sta.w $0755
    rep #$20
    rts

;----------------------------------------------------------------------
; CGA graphics (M10): modes 4/5/6. The adapter RAM at VBUF doubles as
; the live framebuffer; the NMI converts one tile row per frame into
; SNES 2bpp planar tiles (round-robin, full repaint every 25 frames).
; Modes 4/5: HDMA ch6/7 split the frame into a mode-1 BG3 bitmap region
; (320px: 256 shown + 64 by hw scroll) and the mode-5 text/keyboard
; region. Mode 6 (M10p6): the whole frame stays SNES mode 5 and the
; 640x200x1 bitmap lives on hires BG2 as a 512px window panned by
; re-render; ch6 rebands the BG2 char base ($210B) per row group and
; ch5/ch3 data is overridden for the bitmap (tables: kbd_tables).
;----------------------------------------------------------------------

_sk_3d9:                     ; CGA color select -> palette dirty
    and #$00FF
    sta s3D9
    lda #1
    sta cPALD
    rts
_sk_3d8:                     ; CGA mode select: bit1 = graphics (GW-BASIC
    and #$00FF               ; and games switch modes here, not INT 10h)
    sta s3D8
    and #$0002
    beq _sk_txt
    lda s3D8                 ; bit4 = 640x200 mono -> mode 6
    and #$0010
    beq _sk_g4
    lda #6
    bra _sk_gt
_sk_g4:
    lda #4
_sk_gt:
    sta cT0
    lda cGFX
    beq _sk_gen
    lda cMODE                ; already in gfx: only a 4<->6 flip re-enters
    cmp cT0
    beq _sk_dn
_sk_gen:
    lda cT0
    sta cMODE
    cmp #6
    bne _sk_gw4
    lda #80
    bra _sk_gww
_sk_gw4:
    lda #40
_sk_gww:
    sta cWID
    stz kPAN
    jmp gfx_enter            ; no clear: programs clear B800 themselves
_sk_txt:
    lda cGFX
    beq _sk_dn
    jsr gfx_exit
    lda #3
    sta cMODE
    lda #80
    sta cWID
    stz kPAN
    jsr attr_reset
    jmp con_clear
_sk_dn:
    rts

;----------------------------------------------------------------------
; SNES-MIDI interface (M14). The guest streams 4-byte packets
; ([delta-frames][status][d1][d2]) to port $330; port $331 read = free
; packet slots, write = reset+silence. The NMI is the 60 Hz sequencer
; clock and the ONLY SPC sender (guest beep paths set bPIT/bGON/bDIRTY
; flags — no mailbox reentrancy by construction). SPC protocol in
; spc_midi.asm: F4-F6 = args, F7 = (seq<<4)|op, SPC echoes F7 to ack.
;----------------------------------------------------------------------

spc_cmd:                     ; NMI ctx. A = op, kT0/kT1/kT2 -> F4/F5/F6
    pha
    sep #$20
    lda kT0
    sta.l $002140
    lda kT1
    sta.l $002141
    lda kT2
    sta.l $002142
    rep #$20
    lda mSEQ
    inc a
    and #$000F
    bne _sc_sq
    lda #1
_sc_sq:
    sta mSEQ
    asl a
    asl a
    asl a
    asl a
    sta kT3
    pla
    ora kT3
    sta kT3                  ; final command byte = ack value
    sep #$20
    sta.l $002143
    rep #$20
    ldx #220                 ; bounded ack wait (~SPC loop latency)
_sc_w:
    sep #$20
    lda.l $002143
    rep #$20
    and #$00FF
    cmp kT3
    beq _sc_ok
    dex
    bne _sc_w
_sc_ok:
    rts

gm_map:                      ; GM program>>3 -> instrument 0-5
    .db 0, 3, 1, 0, 0, 2, 2, 2, 1, 1, 1, 4, 3, 0, 0, 0

midi_frame:                  ; NMI: beep flags, then the sequencer
    lda bDIRTY
    beq _mf_seq
    stz bDIRTY
    lda bGON
    beq _mf_boff
    lda bPIT
    sta kT0                  ; P lo (spc_cmd stores low bytes)
    xba
    sta kT1                  ; P hi
    lda #4                   ; raw KON, voice 7
    jsr spc_cmd
    bra _mf_seq
_mf_boff:
    lda #7
    sta kT0
    lda #2                   ; KOF voice 7
    jsr spc_cmd
_mf_seq:
    lda mAOF
    beq _mf_t
    stz mAOF
    lda #3                   ; all notes off
    jsr spc_cmd
_mf_t:
    lda mDLY
    beq _mf_fire             ; due this frame
    cmp #$FFFF
    beq _mf_arm              ; idle: look for work
    dec mDLY
    rts
_mf_arm:
    lda mFT
    cmp mFH
    beq _mf_done             ; FIFO empty
    ldx mFT
    lda.w $0540,x
    and #$00FF               ; the packet's delta
    sta mDLY
    bne _mf_done             ; wait it out
_mf_fire:
    lda #8                   ; guard: at most 8 events per frame
    sta mEVN
_mf_ev:
    jsr midi_event
    lda mFT                  ; consume the packet
    clc
    adc #4
    cmp #448
    bcc _mf_adv
    lda #0
_mf_adv:
    sta mFT
    cmp mFH
    beq _mf_idle
    ldx mFT
    lda.w $0540,x
    and #$00FF
    sta mDLY
    bne _mf_done             ; next event later
    dec mEVN
    bne _mf_ev               ; chained zero-delta events
    rts                      ; guard hit: resume next frame (mDLY = 0)
_mf_idle:
    lda #$FFFF
    sta mDLY
_mf_done:
    rts

midi_event:                  ; process the packet at $0540+mFT
    ldx mFT
    lda.w $0541,x            ; status
    and #$00FF
    cmp #$0090
    bcc _me_off              ; $8x = note off
    cmp #$00A0
    bcc _me_on               ; $9x
    cmp #$00C0
    bcc _me_rts              ; $Ax/$Bx ignored
    cmp #$00D0
    bcc _me_prog             ; $Cx
    lda #1                   ; anything else from the player = all off
    sta mAOF
_me_rts:
    rts
_me_prog:                    ; chprog[chan] = d1
    and #$000F
    tax
    lda mFT
    clc
    adc #2                   ; d1 offset
    phx
    tax
    lda.w $0540,x
    plx
    sep #$20
    sta.w $0520,x
    rep #$20
    rts
_me_off:
    jsr _me_findv            ; A = voice or $FFFF
    bmi _me_rts
    tax
    sep #$20
    lda #$FF
    sta.w $0538,x            ; free the voice
    rep #$20
    txa
    sta kT0
    lda #2                   ; KOF
    jmp spc_cmd
_me_on:
    ldx mFT
    lda.w $0543,x            ; d2 = velocity
    and #$00FF
    beq _me_off              ; vel 0 = note off
    sta kT2
    ; ---- pick a voice: first free, else round-robin steal
    ldx #0
_me_fv:
    lda.w $0538,x
    and #$00FF
    cmp #$00FF
    beq _me_have
    inx
    cpx #8
    bcc _me_fv
    lda mVNX                 ; steal
    inc a
    and #$0007
    sta mVNX
    tax
_me_have:
    stx mVCE                 ; the chosen voice
    ldx mFT
    lda.w $0541,x
    and #$000F
    sta kT3                  ; channel
    lda.w $0542,x            ; note
    and #$00FF
    sta kT0                  ; -> SPC F4
    ldx mVCE
    sep #$20
    sta.w $0538,x            ; vNote = note
    lda kT3
    sta.w $0530,x            ; vChan
    rep #$20
    ; ---- instrument: percussion channel 9, else gm_map[program>>3]
    lda kT3
    cmp #9
    bne _me_gm
    lda #5
    bra _me_inst
_me_gm:
    ldx kT3
    lda.w $0520,x            ; chprog (bytes; read 16-bit, mask)
    and #$00FF
    lsr a
    lsr a
    lsr a
    tax
    lda.l gm_map,x
    and #$00FF
_me_inst:
    asl a
    asl a
    asl a
    asl a                    ; inst<<4
    ora mVCE
    sta kT1                  ; (inst<<4) | voice
    lda #1                   ; KON
    jmp spc_cmd

_me_findv:                   ; match chan+note of the packet -> voice
    ldx mFT
    lda.w $0541,x
    and #$000F
    sta kT3                  ; chan
    lda.w $0542,x
    and #$00FF
    sta kT0                  ; note
    ldx #0
_me_sv:
    lda.w $0538,x
    and #$00FF
    cmp kT0
    bne _me_nx
    lda.w $0530,x
    and #$00FF
    cmp kT3
    bne _me_nx
    txa
    rts
_me_nx:
    inx
    cpx #8
    bcc _me_sv
    lda #$FFFF
    rts

midi_data:                   ; port 330 write: assemble packets into FIFO
    and #$00FF
    pha
    lda mFH
    clc
    adc mPKn
    tax
    pla
    sep #$20
    sta.w $0540,x
    rep #$20
    lda mPKn
    inc a
    sta mPKn
    cmp #4
    bcc _md_r
    stz mPKn
    lda mFH                  ; publish the packet
    clc
    adc #4
    cmp #448
    bcc _md_w
    lda #0
_md_w:
    sta mFH
_md_r:
    rts

midi_ctl:                    ; port 331 write: reset the card + silence
    stz mFH
    stz mFT
    stz mPKn
    lda #$FFFF
    sta mDLY
    lda #1
    sta mAOF
    rts

midi_stat:                   ; port 331 read: free packet slots (guest ctx)
    lda mFH
    sec
    sbc mFT
    bcs _ms_u
    clc
    adc #448
_ms_u:
    sta cT0                  ; used bytes
    lda #444
    sec
    sbc cT0
    lsr a
    lsr a                    ; free packets (0-111)
    and #$00FF
    rts

gfx_fbclr:                   ; zero the 16 KB framebuffer (guest ctx)
    ldx #$0000
    lda #$0000
_gfc:
    sta.l VBUF,x
    inx
    inx
    cpx #$4000
    bcc _gfc
    rts

_h10_pal:                    ; AH=0B: BH=0 bg/border color, BH=1 palette
    lda gBX
    xba
    and #$00FF
    bne _hpa_sel
    lda gBX
    and #$001F
    sta cT0
    lda s3D9
    and #$00E0
    ora cT0
    sta s3D9
    bra _hpa_dn
_hpa_sel:
    lda gBX
    and #$0001
    asl a
    asl a
    asl a
    asl a
    asl a                    ; -> bit 5
    sta cT0
    lda s3D9
    and #$FFDF
    ora cT0
    sta s3D9
_hpa_dn:
    lda #1
    sta cPALD
    rts

gfx_pofs:                    ; gCX=x gDX=y -> X = fb byte offset, cT1 = shift
    lda cMODE
    cmp #6
    beq _gpo_m6
    lda gDX
    lsr a                    ; y>>1, carry = y&1
    sta cT0
    lda #$0000
    bcc _gpo_e
    lda #$2000               ; odd scanlines: second bank
_gpo_e:
    sta aT0
    lda cT0
    asl a
    asl a
    asl a
    asl a                    ; *16
    sta cT0
    asl a
    asl a                    ; *64
    clc
    adc cT0                  ; (y>>1)*80
    clc
    adc aT0
    sta aT0
    lda gCX
    lsr a
    lsr a                    ; x>>2
    clc
    adc aT0
    tax
    lda gCX
    and #$0003
    asl a
    sta cT0
    lda #6
    sec
    sbc cT0                  ; shift = 6 - 2*(x&3)
    sta cT1
    rts
_gpo_m6:                     ; mode 6, 1bpp: byte = x>>3, shift = 7-(x&7)
    lda gDX
    lsr a                    ; y>>1, carry = y&1
    sta cT0
    lda #$0000
    bcc _gp6_e
    lda #$2000               ; odd scanlines: second bank
_gp6_e:
    sta aT0
    lda cT0
    asl a
    asl a
    asl a
    asl a                    ; *16
    sta cT0
    asl a
    asl a                    ; *64
    clc
    adc cT0                  ; (y>>1)*80
    clc
    adc aT0
    sta aT0
    lda gCX
    lsr a
    lsr a
    lsr a                    ; x>>3
    clc
    adc aT0
    tax
    lda gCX
    and #$0007
    sta cT0
    lda #7
    sec
    sbc cT0                  ; shift = 7 - (x&7)
    sta cT1
    rts

_h10_pset:                   ; AH=0C: write pixel AL at (CX,DX); bit7 = XOR
    lda cGFX
    beq _hps_r
    lda gDX
    cmp #200
    bcs _hps_r
    lda cMODE
    cmp #6
    beq _hps_x6
    lda gCX
    cmp #320
    bcs _hps_r
    jsr gfx_pofs
    lda gAX
    and #$0003
    sta cT0                  ; value at pixel position
    lda #$0003
    sta aT0                  ; mask
    bra _hps_sh
_hps_x6:
    lda gCX
    cmp #640
    bcs _hps_r
    jsr gfx_pofs
    lda gAX
    and #$0001
    sta cT0                  ; 1bpp value
    lda #$0001
    sta aT0                  ; mask
_hps_sh:
    lda cT1
    beq _hps_go
    dec cT1
    asl cT0
    asl aT0
    bra _hps_sh
_hps_go:
    lda gAX
    and #$0080
    bne _hps_xor
    lda aT0
    eor #$FFFF
    sta aT0
    lda.l VBUF,x
    and aT0
    ora cT0
    bra _hps_wr
_hps_xor:
    lda.l VBUF,x
    eor cT0
_hps_wr:
    sep #$20
    sta.l VBUF,x             ; write only the target byte
    rep #$20
_hps_r:
    rts

_h10_pget:                   ; AH=0D: read pixel (CX,DX) -> AL
    lda cGFX
    beq _hps_r
    lda gDX
    cmp #200
    bcs _hps_r
    lda gCX
    cmp #320
    bcc _hpg_bi
    lda cMODE                ; only mode 6 reaches x = 320-639
    cmp #6
    bne _hps_r
    lda gCX
    cmp #640
    bcs _hps_r
_hpg_bi:
    jsr gfx_pofs
    lda.l VBUF,x
    and #$00FF
_hpg_sh:
    ldx cT1
    beq _hpg_go
    dec cT1
    lsr a
    bra _hpg_sh
_hpg_go:
    ldx cMODE
    cpx #6
    bne _hpg_m4
    and #$0001
    bra _hpg_msk
_hpg_m4:
    and #$0003
_hpg_msk:
    sta cT0
    lda gAX
    and #$FF00
    ora cT0
    sta gAX
    rts

pal_apply:                   ; CGRAM 0-3 from s3D9 (forced blank or vblank!
    phy                      ; NMI-off in guest ctx). kT3 is scratch.
    sep #$20
    lda.b #$00
    sta.l $002121
    rep #$20
    lda s3D8                 ; entry 0 (background): mode 6 (640x200) is
    and #$0010               ; mono — background is ALWAYS black there, and
    bne _pa_bg0              ; 3D9's low nibble is the FOREGROUND color, not
    lda s3D9                 ; the bg. (FS sets it 15 = white -> white bg.)
    and #$000F
    asl a
    tax
    lda.l cga_pal16,x
    bra _pa_bgw
_pa_bg0:
    lda #$0000               ; mode 6: black background
_pa_bgw:
    sep #$20
    sta.l $002122
    xba
    sta.l $002122
    rep #$20
    ldy #1                   ; entries 1-3: idx = v*2 + pal + bright*8;
_pa_c:                       ; mode 6 (3D8 bit4): fg = 3D9's low nibble
    lda s3D8
    and #$0010
    beq _pa_c45
    lda s3D9
    and #$000F
    asl a
    tax
    lda.l cga_pal16,x
    bra _pa_cw
_pa_c45:
    lda s3D9
    and #$0020
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a                    ; palette select -> 0/1
    sta kT3
    lda s3D9
    and #$0010
    lsr a                    ; bright -> 0/8
    clc
    adc kT3
    sta kT3
    tya
    asl a                    ; v*2
    clc
    adc kT3
    asl a                    ; word index
    tax
    lda.l cga_pal16,x
_pa_cw:
    sep #$20
    sta.l $002122
    xba
    sta.l $002122
    rep #$20
    iny
    cpy #4
    bcc _pa_c
    ply
    rts

gfx_enter:                   ; guest ctx: switch the PPU to the gfx split.
    phy                      ; NMI masked throughout (mid-setup NMI would
    sep #$20                 ; race our VMADD/DMA registers).
    lda.b #$00
    sta.l $004200
    lda.b #$8F
    sta.l $002100            ; forced blank
    lda.b #$80
    sta.l $002115
    rep #$20
    lda #1
    sta cGFX
    stz gROW
    stz gSTG
    stz cPALD
    lda cMODE
    cmp #6
    beq _ge_m6               ; M10p6: the hires BG2 machine
    lda #$0030               ; default: bright cyan/magenta/white, black bg
    sta s3D9
    jsr pal_apply
    ; BG3 tilemap: (r,c) -> tile r*40+c; cols 0-31 in screen A at CGMAP,
    ; cols 32-39 in screen B at CGMAP+$400 (cols 40-63 never visible)
    lda #CGMAP
    sta.l $002116
    stz cT1                  ; r
_ge_ra:
    ldx #0                   ; c within screen A
_ge_ca:
    jsr _ge_tile
    inx
    cpx #32
    bcc _ge_ca
    inc cT1
    lda cT1
    cmp #32
    bcc _ge_ra
    stz cT1
_ge_rb:
    ldx #32                  ; c within screen B
_ge_cb:
    jsr _ge_tile
    inx
    cpx #64
    bcc _ge_cb
    inc cT1
    lda cT1
    cmp #32
    bcc _ge_rb
    ; zero the tile region
    lda #CGTIL
    sta.l $002116
    lda #16000
    jsr _ge_zero
    ; BG3 registers
    sep #$20
    lda.b #$29               ; map $2800, 64x32
    sta.l $002109
    lda.b #$05               ; chars $5000
    sta.l $00210C
    lda.b #$00
    sta.l $002111            ; HOFS 0
    sta.l $002111
    lda.b #$FF
    sta.l $002112            ; VOFS -1
    lda.b #$03
    sta.l $002112
    lda.b #$13               ; $210B + ch6 back from a mode-6 stint
    sta.l $00210B
    lda.b #$05               ; ch6 -> $2105 (the mode-4 raster split)
    sta.l $004361
    rep #$20
    bra _ge_fin

_ge_m6:                      ; CGA mode 6: 512px window on hires BG2
    lda #$003F               ; BIOS mode-6 default: fg white in 3D9 low
    sta s3D9
    lda s3D8
    ora #$0010               ; ensure the mono bit for pal_apply
    sta s3D8
    jsr pal_apply
    ; BG2 32x32 map at CGMAP: rows 0-15 char r*64+c*2 (band $5000),
    ; rows 16-23 char (r-16)*64+c*2 (band $7000), row 24 char 384+c*2
    ; (band $2000 -> $2C00). Rows 25+ sit under the kbd/border regions.
    lda #CGMAP
    sta.l $002116
    stz cT1                  ; r
_g6_r:
    ldx #0                   ; c
_g6_c:
    jsr _g6_tile
    inx
    cpx #32
    bcc _g6_c
    inc cT1
    lda cT1
    cmp #32
    bcc _g6_r
    ; zero the char bands
    lda #CG6B1
    sta.l $002116
    lda #24576               ; $5000-$7FFF (bands 1+2)
    jsr _ge_zero
    lda #CG6B3
    sta.l $002116
    lda #1024                ; the row-24 block
    jsr _ge_zero
    sep #$20
    lda.b #$28               ; BG2 map $2800, 32x32
    sta.l $002108
    lda.b #$53               ; BG2 chars $5000 (ch6 rebands per region)
    sta.l $00210B
    lda.b #$00
    sta.l $00210F            ; BG2HOFS 0: the window pans by re-render
    sta.l $00210F
    lda.b #$FF
    sta.l $002110            ; BG2VOFS -1 (ch3's data holds it there too)
    lda.b #$03
    sta.l $002110
    lda.b #$05               ; SNES mode 5 for the whole frame — ch6 is
    sta.l $002105            ; free to reband $210B instead of $2105
    lda.b #$0B
    sta.l $004361
    rep #$20
_ge_fin:
    jsr kbd_tables           ; rebuild HDMA tables (gfx split boundaries)
    sep #$20
    lda.b #$FC               ; HDMA: kbd ch2-5 + gfx split ch6/7
    sta.l $00420C
    lda.b #$0F
    sta.l $002100            ; screen on
    lda.b #$81
    sta.l $004200            ; NMI + autojoy back on
    rep #$20
    ply
    rts

_ge_tile:                    ; cT1 = r, X = c: write one tilemap entry
    lda cT1
    cmp #25
    bcs _get_z
    cpx #40
    bcs _get_z
    asl a
    asl a
    asl a                    ; r*8
    sta cT0
    asl a
    asl a                    ; r*32
    clc
    adc cT0                  ; r*40
    sta cT0
    txa
    clc
    adc cT0
    bra _get_w
_get_z:
    lda #0
_get_w:
    sta.l $002118
    rts

_g6_tile:                    ; cT1 = r, X = c: one BG2 bitmap map entry
    lda cT1
    cmp #16
    bcs _g6t_b2
    asl a
    asl a
    asl a
    asl a
    asl a
    asl a                    ; r*64
    bra _g6t_c
_g6t_b2:
    cmp #24
    bcs _g6t_b3
    sec
    sbc #16
    asl a
    asl a
    asl a
    asl a
    asl a
    asl a                    ; (r-16)*64
    bra _g6t_c
_g6t_b3:
    cmp #25
    bcs _g6t_z
    lda #384                 ; row 24 lives in the $2C00 gap
_g6t_c:
    sta cT0
    txa
    asl a                    ; c*2: a 16px hires tile = chars (c, c+1)
    clc
    adc cT0
    bra _g6t_w
_g6t_z:
    lda #0
_g6t_w:
    sta.l $002118
    rts

_ge_zero:                    ; fixed-source zero A bytes at VMADD (ch0,
    sta.l $004305            ; forced blank; A 16-bit in and out)
    sep #$20
    lda.b #$09               ; mode 1, fixed A-address
    sta.l $004300
    lda.b #$18
    sta.l $004301
    rep #$20
    lda #zero_w
    sta.l $004302
    sep #$20
    lda.b #:zero_w
    sta.l $004304
    lda.b #$01
    sta.l $00420B
    rep #$20
    rts

gfx_exit:                    ; guest ctx: back to the mode-5 text console
    phy
    sep #$20
    lda.b #$00
    sta.l $004200
    lda.b #$8F
    sta.l $002100
    lda.b #$3C               ; HDMA: kbd channels only
    sta.l $00420C
    lda.b #$05               ; mode 5 everywhere
    sta.l $002105
    lda.b #$03               ; TM+TS: BG1+BG2 (mode-5 hires pair)
    sta.l $00212C
    sta.l $00212D
    lda.b #$13               ; $210B + ch6 back from a mode-6 stint
    sta.l $00210B
    lda.b #$05
    sta.l $004361
    lda.b #$00               ; CGRAM 0-2: backdrop black, pair0 black/green
    sta.l $002121
    sta.l $002122
    sta.l $002122
    sta.l $002122
    sta.l $002122
    lda.b #$E0
    sta.l $002122
    lda.b #$03
    sta.l $002122
    rep #$20
    stz cGFX
    stz gSTG
    stz cPALD
    jsr kbd_tables
    sep #$20
    lda.b #$0F
    sta.l $002100
    lda.b #$81
    sta.l $004200
    rep #$20
    ply
    rts

gfx_glyph:                   ; A = char, aT1 = color 0-3, at cROW/cCOL.
    phy                      ; Draws 8x8 into the bitmap (guest ctx).
    and #$00FF
    asl a
    asl a
    asl a
    sta aT0                  ; font byte index = char*8
    lda cMODE
    cmp #6
    bne _gg_m45
    brl _gg_m6
_gg_m45:
    lda cROW
    asl a
    asl a                    ; row*4
    sta cT0
    asl a
    asl a                    ; row*16
    clc
    adc cT0                  ; row*20
    asl a
    asl a
    asl a
    asl a                    ; row*320 (line-pair pitch x4 pairs)
    clc
    adc cCOL
    clc
    adc cCOL
    sta cT1                  ; fb offset of the cell's even-line 0
    lda #4
    sta cT2n                 ; 4 line pairs
_gg_pair:
    jsr _gg_expand           ; even line
    ldx cT1
    lda aT2
    sta.l VBUF,x
    jsr _gg_expand           ; odd line (second bank)
    lda cT1
    clc
    adc #$2000
    tax
    lda aT2
    sta.l VBUF,x
    lda cT1
    clc
    adc #80
    sta cT1
    dec cT2n
    bne _gg_pair
    ply
    rts
_gg_expand:                  ; font[aT0++] -> aT2 = two CGA bytes (color
    ldx aT0                  ; aT1 on set bits, 0 on clear)
    lda.l cgafont,x
    and #$00FF
    xba                      ; font bits into 15-8: 16-bit asl carries
    sta cT0                  ; the glyph's MSB first
    inc aT0
    ldx #8
    lda #0
_gg_bit:
    asl a
    asl a
    asl cT0                  ; MSB first
    bcc _gg_bn
    ora aT1
_gg_bn:
    dex
    bne _gg_bit
    xba                      ; low byte = left CGA byte (little-endian)
    sta aT2
    rts

_gg_m6:                      ; mode 6: the cell is one byte per line and
    lda cROW                 ; the font byte IS the bitmap byte (runpc
    asl a                    ; draws glyphs the same way)
    asl a                    ; row*4
    sta cT0
    asl a
    asl a                    ; row*16
    clc
    adc cT0                  ; row*20
    asl a
    asl a
    asl a
    asl a                    ; row*320
    clc
    adc cCOL
    sta cT1                  ; fb offset of the cell's even line 0
    lda #4
    sta cT2n                 ; 4 line pairs
_gg6_pair:
    ldx aT0
    lda.l cgafont,x          ; even line
    inc aT0
    and #$00FF
    ldx cT1
    sep #$20
    sta.l VBUF,x
    rep #$20
    ldx aT0
    lda.l cgafont,x          ; odd line (second bank)
    inc aT0
    and #$00FF
    pha
    lda cT1
    clc
    adc #$2000
    tax
    pla
    sep #$20
    sta.l VBUF,x
    rep #$20
    lda cT1
    clc
    adc #80
    sta cT1
    dec cT2n
    bne _gg6_pair
    ply
    rts

gfx_nlscr:                   ; graphics newline at row 24: scroll the
    phy                      ; bitmap up 8 scanlines, clear the bottom
    phx
    phb
    lda #7679
    ldx #VBOFS+320
    ldy #VBOFS
    .db $54, $7E, $7E        ; even-line bank
    lda #7679
    ldx #VBOFS+$2000+320
    ldy #VBOFS+$2000
    .db $54, $7E, $7E        ; odd-line bank
    plb
    ldx #$0000
    lda #$0000
_nlg_c:
    sta.l VBUF+7680,x
    sta.l VBUF+$2000+7680,x
    inx
    inx
    cpx #320
    bcc _nlg_c
    plx
    ply
    rts

; one tile line: read 2 CGA bytes (8 px), LUT to planar, store to staging.
; kT1 = src index (row*320 + c*2), kT2 = staging offset (c*16), kT0/kT3
; scratch. OFS folds the line's scanline-interleave displacement.
.MACRO GLINE ARGS OFS, SOFS
    ldx kT1
    lda.l $7E0000+VBOFS+OFS,x
    sta kT0
    and #$00FF
    asl a
    tax
    lda.l cgalut_hi,x
    sta kT3
    lda kT0
    xba
    and #$00FF
    asl a
    tax
    lda.l cgalut_lo,x
    ora kT3
    ldx kT2
    sta.w STG+SOFS,x
.ENDM

; mode-6 line: one CGA byte (8 px, 1bpp) IS the SNES plane-0 byte (same
; MSB-left bit order); plane 1 stays 0. Cheaper than mode 4 — no LUTs.
.MACRO GLINE6 ARGS OFS, SOFS
    ldx kT1
    lda.l $7E0000+VBOFS+OFS,x
    and #$00FF
    ldx kT2
    sta.w STG+SOFS,x
.ENDM

gfx_scan:                    ; NMI tail: convert tile row gROW -> staging
    lda cMODE
    cmp #6
    bne _gs_m45
    brl gfx_scan6
_gs_m45:
    lda gROW
    asl a
    asl a
    asl a
    asl a
    asl a
    asl a                    ; row*64
    sta kT1
    lda gROW
    xba
    and #$FF00               ; row*256
    clc
    adc kT1
    sta kT1                  ; src index = row*320
    stz kT2
    lda #40
    sta nCNT
_gs_tile:
    GLINE $0000, 0
    GLINE $2000, 2
    GLINE $0050, 4
    GLINE $2050, 6
    GLINE $00A0, 8
    GLINE $20A0, 10
    GLINE $00F0, 12
    GLINE $20F0, 14
    lda kT1
    inc a
    inc a
    sta kT1
    lda kT2
    clc
    adc #16
    sta kT2
    dec nCNT
    beq _gs_rdone
    jmp _gs_tile             ; loop body > bra range (8 unrolled GLINEs)
_gs_rdone:
    lda gROW
    inc a
    sta gSTG                 ; converted row + 1, awaiting DMA
    cmp #25
    bcc _gs_st               ; advance round-robin: 0..24
    lda #0
_gs_st:
    sta gROW
    rts

gfx_scan6:                   ; mode 6: 64 chars of the 512px window; the
    lda gROW                 ; window starts kPAN bytes into each line,
    asl a                    ; so a pan repaints itself within 25 frames
    asl a
    asl a
    asl a
    asl a
    asl a                    ; row*64
    sta kT1
    lda gROW
    xba
    and #$FF00               ; row*256
    clc
    adc kT1
    clc
    adc kPAN                 ; src = row*320 + kPAN
    sta kT1
    stz kT2
    lda #64
    sta nCNT
_g6s_tile:
    GLINE6 $0000, 0
    GLINE6 $2000, 2
    GLINE6 $0050, 4
    GLINE6 $2050, 6
    GLINE6 $00A0, 8
    GLINE6 $20A0, 10
    GLINE6 $00F0, 12
    GLINE6 $20F0, 14
    inc kT1
    lda kT2
    clc
    adc #16
    sta kT2
    dec nCNT
    beq _g6s_done
    jmp _g6s_tile            ; loop body > bra range (8 unrolled GLINE6s)
_g6s_done:
    lda gROW
    inc a
    sta gSTG                 ; converted row + 1, awaiting DMA
    cmp #25
    bcc _g6s_st
    lda #0
_g6s_st:
    sta gROW
    rts

.INCLUDE "build/kbdlayout.asm"

boot_banner:
.IFDEF ELKS
    .db "booting...", $0D, $0A, 0
.ELSE
.IFDEF BIGMEM
    .db "snes86: 8086 core up, 172KB guest RAM", $0D, $0A
.ELSE
    .db "snes86: 8086 core up, 108KB guest RAM", $0D, $0A
.ENDIF
.IFDEF PCDOS
    .db "booting PC DOS 2.00 from ROM disk...", $0D, $0A, $0D, $0A, 0
.ELSE
.IFDEF FREEDOS
    .db "booting FreeDOS 1.3 from ROM disk...", $0D, $0A, $0D, $0A, 0
.ELSE
    .db "booting MS-DOS 2.00 from ROM disk...", $0D, $0A, $0D, $0A, 0
.ENDIF
.ENDIF
.ENDIF

.ENDS

;----------------------------------------------------------------------
; fonts (bank 1)
;----------------------------------------------------------------------
.BANK 1 SLOT 0
.ORG 0
.SECTION "FontData" SEMIFREE

font_bg2:
    .INCBIN "build/font_bg2.bin"
font_bg1:
    .INCBIN "build/font_bg1.bin"

; CGA chunky->planar LUTs (tools/mkcgalut.py): HI[256] words place a CGA
; byte's 4 pixels in the left tile half, LO[256] in the right; word =
; plane0 low byte + plane1 high = one $2118/19 write. Then the CGA
; 16-color palette in BGR555.
cgalut_hi:
    .INCBIN "build/cgalut.bin" SKIP 0 READ 512
cgalut_lo:
    .INCBIN "build/cgalut.bin" SKIP 512 READ 512
cga_pal16:
    .INCBIN "build/cgalut.bin" SKIP 1024 READ 32
cgafont:                     ; raw 1bpp CP437 font (mkfont.py), MSB=left
    .INCBIN "build/cgafont.bin"
zero_w:
    .dw 0

.ENDS

;----------------------------------------------------------------------
; A: floppy image across banks 2-13. Normal build: the 360KB DOS disk.
; FSBOOT build (`make boot` with a 160 KB image): build/bootdisk.img is
; a self-booting single-sided disk (5 banks; it replaces DOS entirely —
; our BIOS boots its boot sector like any other; MS Flight Simulator
; 1.0 is the proven tenant). BOOTIMG (`make boot` with a 360 KB image):
; the self-booting disk simply takes the A: slot below.
;----------------------------------------------------------------------
.IFDEF FSBOOT
.BANK 2 SLOT 0
.ORG 0
.SECTION "Disk2" FORCE
.INCBIN "build/bootdisk.img" SKIP 0 READ 32768
.ENDS
.BANK 3 SLOT 0
.ORG 0
.SECTION "Disk3" FORCE
.INCBIN "build/bootdisk.img" SKIP 32768 READ 32768
.ENDS
.BANK 4 SLOT 0
.ORG 0
.SECTION "Disk4" FORCE
.INCBIN "build/bootdisk.img" SKIP 65536 READ 32768
.ENDS
.BANK 5 SLOT 0
.ORG 0
.SECTION "Disk5" FORCE
.INCBIN "build/bootdisk.img" SKIP 98304 READ 32768
.ENDS
.BANK 6 SLOT 0
.ORG 0
.SECTION "Disk6" FORCE
.INCBIN "build/bootdisk.img" SKIP 131072 READ 32768
.ENDS
.ELSE
.IFNDEF ELKS                 ; ELKS boots from the ROM windows in banks
.IFDEF BOOTIMG               ; 14+; the 360 KB DOS floppy would be dead
.DEFINE AIMG "build/bootdisk.img" ; weight in banks 2-13 (a DL=0 probe
.ELSE                        ; now reads zero-filled banks and fails
.IFDEF PCDOS                 ; cleanly)
.DEFINE AIMG "build/adisk.img"
.ELSE
.IFDEF FREEDOS
.DEFINE AIMG "build/freedos_a.img"
.ELSE
.DEFINE AIMG "build/msdos_a.img"
.ENDIF
.ENDIF
.ENDIF
.BANK 2 SLOT 0
.ORG 0
.SECTION "Disk2" FORCE
.INCBIN AIMG SKIP 0 READ 32768
.ENDS
.BANK 3 SLOT 0
.ORG 0
.SECTION "Disk3" FORCE
.INCBIN AIMG SKIP 32768 READ 32768
.ENDS
.BANK 4 SLOT 0
.ORG 0
.SECTION "Disk4" FORCE
.INCBIN AIMG SKIP 65536 READ 32768
.ENDS
.BANK 5 SLOT 0
.ORG 0
.SECTION "Disk5" FORCE
.INCBIN AIMG SKIP 98304 READ 32768
.ENDS
.BANK 6 SLOT 0
.ORG 0
.SECTION "Disk6" FORCE
.INCBIN AIMG SKIP 131072 READ 32768
.ENDS
.BANK 7 SLOT 0
.ORG 0
.SECTION "Disk7" FORCE
.INCBIN AIMG SKIP 163840 READ 32768
.ENDS
.BANK 8 SLOT 0
.ORG 0
.SECTION "Disk8" FORCE
.INCBIN AIMG SKIP 196608 READ 32768
.ENDS
.BANK 9 SLOT 0
.ORG 0
.SECTION "Disk9" FORCE
.INCBIN AIMG SKIP 229376 READ 32768
.ENDS
.BANK 10 SLOT 0
.ORG 0
.SECTION "Disk10" FORCE
.INCBIN AIMG SKIP 262144 READ 32768
.ENDS
.BANK 11 SLOT 0
.ORG 0
.SECTION "Disk11" FORCE
.INCBIN AIMG SKIP 294912 READ 32768
.ENDS
.BANK 12 SLOT 0
.ORG 0
.SECTION "Disk12" FORCE
.INCBIN AIMG SKIP 327680 READ 32768
.ENDS
.BANK 13 SLOT 0
.ORG 0
.SECTION "Disk13" FORCE
.INCBIN AIMG SKIP 360448 READ 8192
.ENDS
.ENDIF                       ; IFNDEF ELKS (A: floppy banks)
.ENDIF
.IFDEF OVERLAYHD             ; OVERLAYS= build (any DOS target): the
.DEFINE HDIMG "build/hd_overlay.img" ; free C: with extra content merged
.ELSE
.DEFINE HDIMG "build/hd_free.img"
.ENDIF
.IFDEF ELKS
; sneslinux: no C: hard disk — banks 14+ carry the ELKS ROM-XIP images
; instead (local artifacts, see ../../PLAN.md in the sneslinux tree):
;   banks 14-15 (SNES $8E-$8F) = elks_rom.bin   (64 KB kernel, XIP @ E0000)
;   banks 16-19 (SNES $90-$93) = elks_romfs.bin (root fs window @ 80000,
;                                <= 128 KB; the tail bank INCBINs to EOF)
.BANK 14 SLOT 0
.ORG 0
.SECTION "ElksK14" FORCE
.INCBIN "build/elks_rom.bin" SKIP 0 READ 32768
.ENDS
.BANK 15 SLOT 0
.ORG 0
.SECTION "ElksK15" FORCE
.INCBIN "build/elks_rom.bin" SKIP 32768 READ 32768
.ENDS
.BANK 16 SLOT 0
.ORG 0
.SECTION "ElksR16" FORCE
.INCBIN "build/elks_romfs.bin" SKIP 0 READ 32768
.ENDS
.BANK 17 SLOT 0
.ORG 0
.SECTION "ElksR17" FORCE
.INCBIN "build/elks_romfs.bin" SKIP 32768 READ 32768
.ENDS
.BANK 18 SLOT 0
.ORG 0
.SECTION "ElksR18" FORCE
.INCBIN "build/elks_romfs.bin" SKIP 65536 READ 32768
.ENDS
.BANK 19 SLOT 0
.ORG 0
.SECTION "ElksR19" FORCE
.INCBIN "build/elks_romfs.bin" SKIP 98304
.ENDS
.ELSE
.BANK 14 SLOT 0
.ORG 0
.SECTION "HDisk14" FORCE
.INCBIN HDIMG SKIP 0 READ 32768
.ENDS
.BANK 15 SLOT 0
.ORG 0
.SECTION "HDisk15" FORCE
.INCBIN HDIMG SKIP 32768 READ 32768
.ENDS
.BANK 16 SLOT 0
.ORG 0
.SECTION "HDisk16" FORCE
.INCBIN HDIMG SKIP 65536 READ 32768
.ENDS
.BANK 17 SLOT 0
.ORG 0
.SECTION "HDisk17" FORCE
.INCBIN HDIMG SKIP 98304 READ 32768
.ENDS
.BANK 18 SLOT 0
.ORG 0
.SECTION "HDisk18" FORCE
.INCBIN HDIMG SKIP 131072 READ 32768
.ENDS
.BANK 19 SLOT 0
.ORG 0
.SECTION "HDisk19" FORCE
.INCBIN HDIMG SKIP 163840 READ 32768
.ENDS
.BANK 20 SLOT 0
.ORG 0
.SECTION "HDisk20" FORCE
.INCBIN HDIMG SKIP 196608 READ 32768
.ENDS
.BANK 21 SLOT 0
.ORG 0
.SECTION "HDisk21" FORCE
.INCBIN HDIMG SKIP 229376 READ 32768
.ENDS
.BANK 22 SLOT 0
.ORG 0
.SECTION "HDisk22" FORCE
.INCBIN HDIMG SKIP 262144 READ 32768
.ENDS
.BANK 23 SLOT 0
.ORG 0
.SECTION "HDisk23" FORCE
.INCBIN HDIMG SKIP 294912 READ 32768
.ENDS
.BANK 24 SLOT 0
.ORG 0
.SECTION "HDisk24" FORCE
.INCBIN HDIMG SKIP 327680 READ 32768
.ENDS
.BANK 25 SLOT 0
.ORG 0
.SECTION "HDisk25" FORCE
.INCBIN HDIMG SKIP 360448 READ 32768
.ENDS
.BANK 26 SLOT 0
.ORG 0
.SECTION "HDisk26" FORCE
.INCBIN HDIMG SKIP 393216 READ 32768
.ENDS
.BANK 27 SLOT 0
.ORG 0
.SECTION "HDisk27" FORCE
.INCBIN HDIMG SKIP 425984 READ 32768
.ENDS
.BANK 28 SLOT 0
.ORG 0
.SECTION "HDisk28" FORCE
.INCBIN HDIMG SKIP 458752 READ 32768
.ENDS
.BANK 29 SLOT 0
.ORG 0
.SECTION "HDisk29" FORCE
.INCBIN HDIMG SKIP 491520 READ 32768
.ENDS
.BANK 30 SLOT 0
.ORG 0
.SECTION "HDisk30" FORCE
.INCBIN HDIMG SKIP 524288 READ 32768
.ENDS
.BANK 31 SLOT 0
.ORG 0
.SECTION "HDisk31" FORCE
.INCBIN HDIMG SKIP 557056 READ 32768
.ENDS
.BANK 32 SLOT 0
.ORG 0
.SECTION "HDisk32" FORCE
.INCBIN HDIMG SKIP 589824 READ 32768
.ENDS
.BANK 33 SLOT 0
.ORG 0
.SECTION "HDisk33" FORCE
.INCBIN HDIMG SKIP 622592 READ 32768
.ENDS
.BANK 34 SLOT 0
.ORG 0
.SECTION "HDisk34" FORCE
.INCBIN HDIMG SKIP 655360 READ 32768
.ENDS
.BANK 35 SLOT 0
.ORG 0
.SECTION "HDisk35" FORCE
.INCBIN HDIMG SKIP 688128 READ 32768
.ENDS
.BANK 36 SLOT 0
.ORG 0
.SECTION "HDisk36" FORCE
.INCBIN HDIMG SKIP 720896 READ 32768
.ENDS
.BANK 37 SLOT 0
.ORG 0
.SECTION "HDisk37" FORCE
.INCBIN HDIMG SKIP 753664 READ 32768
.ENDS
.BANK 38 SLOT 0
.ORG 0
.SECTION "HDisk38" FORCE
.INCBIN HDIMG SKIP 786432 READ 32768
.ENDS
.BANK 39 SLOT 0
.ORG 0
.SECTION "HDisk39" FORCE
.INCBIN HDIMG SKIP 819200 READ 32768
.ENDS
.BANK 40 SLOT 0
.ORG 0
.SECTION "HDisk40" FORCE
.INCBIN HDIMG SKIP 851968 READ 32768
.ENDS
.BANK 41 SLOT 0
.ORG 0
.SECTION "HDisk41" FORCE
.INCBIN HDIMG SKIP 884736 READ 32768
.ENDS
.BANK 42 SLOT 0
.ORG 0
.SECTION "HDisk42" FORCE
.INCBIN HDIMG SKIP 917504 READ 32768
.ENDS
.BANK 43 SLOT 0
.ORG 0
.SECTION "HDisk43" FORCE
.INCBIN HDIMG SKIP 950272 READ 32768
.ENDS
.BANK 44 SLOT 0
.ORG 0
.SECTION "HDisk44" FORCE
.INCBIN HDIMG SKIP 983040 READ 32768
.ENDS
.BANK 45 SLOT 0
.ORG 0
.SECTION "HDisk45" FORCE
.INCBIN HDIMG SKIP 1015808 READ 32768
.ENDS
.BANK 46 SLOT 0
.ORG 0
.SECTION "HDisk46" FORCE
.INCBIN HDIMG SKIP 1048576 READ 32768
.ENDS
.BANK 47 SLOT 0
.ORG 0
.SECTION "HDisk47" FORCE
.INCBIN HDIMG SKIP 1081344 READ 32768
.ENDS
.BANK 48 SLOT 0
.ORG 0
.SECTION "HDisk48" FORCE
.INCBIN HDIMG SKIP 1114112 READ 32768
.ENDS
.BANK 49 SLOT 0
.ORG 0
.SECTION "HDisk49" FORCE
.INCBIN HDIMG SKIP 1146880 READ 32768
.ENDS
.BANK 50 SLOT 0
.ORG 0
.SECTION "HDisk50" FORCE
.INCBIN HDIMG SKIP 1179648 READ 32768
.ENDS
.BANK 51 SLOT 0
.ORG 0
.SECTION "HDisk51" FORCE
.INCBIN HDIMG SKIP 1212416 READ 32768
.ENDS
.BANK 52 SLOT 0
.ORG 0
.SECTION "HDisk52" FORCE
.INCBIN HDIMG SKIP 1245184 READ 32768
.ENDS
.BANK 53 SLOT 0
.ORG 0
.SECTION "HDisk53" FORCE
.INCBIN HDIMG SKIP 1277952 READ 32768
.ENDS
.BANK 54 SLOT 0
.ORG 0
.SECTION "HDisk54" FORCE
.INCBIN HDIMG SKIP 1310720 READ 32768
.ENDS
.BANK 55 SLOT 0
.ORG 0
.SECTION "HDisk55" FORCE
.INCBIN HDIMG SKIP 1343488 READ 32768
.ENDS
.BANK 56 SLOT 0
.ORG 0
.SECTION "HDisk56" FORCE
.INCBIN HDIMG SKIP 1376256 READ 32768
.ENDS
.BANK 57 SLOT 0
.ORG 0
.SECTION "HDisk57" FORCE
.INCBIN HDIMG SKIP 1409024 READ 32768
.ENDS
.BANK 58 SLOT 0
.ORG 0
.SECTION "HDisk58" FORCE
.INCBIN HDIMG SKIP 1441792 READ 32768
.ENDS
.BANK 59 SLOT 0
.ORG 0
.SECTION "HDisk59" FORCE
.INCBIN HDIMG SKIP 1474560 READ 32768
.ENDS
.BANK 60 SLOT 0
.ORG 0
.SECTION "HDisk60" FORCE
.INCBIN HDIMG SKIP 1507328 READ 32768
.ENDS
.BANK 61 SLOT 0
.ORG 0
.SECTION "HDisk61" FORCE
.INCBIN HDIMG SKIP 1540096 READ 32768
.ENDS
.BANK 62 SLOT 0
.ORG 0
.SECTION "HDisk62" FORCE
.INCBIN HDIMG SKIP 1572864 READ 32768
.ENDS
.BANK 63 SLOT 0
.ORG 0
.SECTION "HDisk63" FORCE
.INCBIN HDIMG SKIP 1605632 READ 32768
.ENDS
.BANK 64 SLOT 0
.ORG 0
.SECTION "HDisk64" FORCE
.INCBIN HDIMG SKIP 1638400 READ 32768
.ENDS
.BANK 65 SLOT 0
.ORG 0
.SECTION "HDisk65" FORCE
.INCBIN HDIMG SKIP 1671168 READ 32768
.ENDS
.BANK 66 SLOT 0
.ORG 0
.SECTION "HDisk66" FORCE
.INCBIN HDIMG SKIP 1703936 READ 32768
.ENDS
.BANK 67 SLOT 0
.ORG 0
.SECTION "HDisk67" FORCE
.INCBIN HDIMG SKIP 1736704 READ 32768
.ENDS
.BANK 68 SLOT 0
.ORG 0
.SECTION "HDisk68" FORCE
.INCBIN HDIMG SKIP 1769472 READ 32768
.ENDS
.BANK 69 SLOT 0
.ORG 0
.SECTION "HDisk69" FORCE
.INCBIN HDIMG SKIP 1802240 READ 32768
.ENDS
.BANK 70 SLOT 0
.ORG 0
.SECTION "HDisk70" FORCE
.INCBIN HDIMG SKIP 1835008 READ 32768
.ENDS
.BANK 71 SLOT 0
.ORG 0
.SECTION "HDisk71" FORCE
.INCBIN HDIMG SKIP 1867776 READ 32768
.ENDS
.BANK 72 SLOT 0
.ORG 0
.SECTION "HDisk72" FORCE
.INCBIN HDIMG SKIP 1900544 READ 32768
.ENDS
.BANK 73 SLOT 0
.ORG 0
.SECTION "HDisk73" FORCE
.INCBIN HDIMG SKIP 1933312 READ 32768
.ENDS
.BANK 74 SLOT 0
.ORG 0
.SECTION "HDisk74" FORCE
.INCBIN HDIMG SKIP 1966080 READ 32768
.ENDS
.BANK 75 SLOT 0
.ORG 0
.SECTION "HDisk75" FORCE
.INCBIN HDIMG SKIP 1998848 READ 32768
.ENDS
.BANK 76 SLOT 0
.ORG 0
.SECTION "HDisk76" FORCE
.INCBIN HDIMG SKIP 2031616 READ 32768
.ENDS
.BANK 77 SLOT 0
.ORG 0
.SECTION "HDisk77" FORCE
.INCBIN HDIMG SKIP 2064384 READ 32768
.ENDS
.BANK 78 SLOT 0
.ORG 0
.SECTION "HDisk78" FORCE
.INCBIN HDIMG SKIP 2097152 READ 32768
.ENDS
.BANK 79 SLOT 0
.ORG 0
.SECTION "HDisk79" FORCE
.INCBIN HDIMG SKIP 2129920 READ 32768
.ENDS
.BANK 80 SLOT 0
.ORG 0
.SECTION "HDisk80" FORCE
.INCBIN HDIMG SKIP 2162688 READ 32768
.ENDS
.BANK 81 SLOT 0
.ORG 0
.SECTION "HDisk81" FORCE
.INCBIN HDIMG SKIP 2195456 READ 32768
.ENDS
.BANK 82 SLOT 0
.ORG 0
.SECTION "HDisk82" FORCE
.INCBIN HDIMG SKIP 2228224 READ 32768
.ENDS
.BANK 83 SLOT 0
.ORG 0
.SECTION "HDisk83" FORCE
.INCBIN HDIMG SKIP 2260992 READ 32768
.ENDS
.BANK 84 SLOT 0
.ORG 0
.SECTION "HDisk84" FORCE
.INCBIN HDIMG SKIP 2293760 READ 32768
.ENDS
.BANK 85 SLOT 0
.ORG 0
.SECTION "HDisk85" FORCE
.INCBIN HDIMG SKIP 2326528 READ 32768
.ENDS
.BANK 86 SLOT 0
.ORG 0
.SECTION "HDisk86" FORCE
.INCBIN HDIMG SKIP 2359296 READ 32768
.ENDS
.BANK 87 SLOT 0
.ORG 0
.SECTION "HDisk87" FORCE
.INCBIN HDIMG SKIP 2392064 READ 32768
.ENDS
.BANK 88 SLOT 0
.ORG 0
.SECTION "HDisk88" FORCE
.INCBIN HDIMG SKIP 2424832 READ 32768
.ENDS
.BANK 89 SLOT 0
.ORG 0
.SECTION "HDisk89" FORCE
.INCBIN HDIMG SKIP 2457600 READ 32768
.ENDS
.BANK 90 SLOT 0
.ORG 0
.SECTION "HDisk90" FORCE
.INCBIN HDIMG SKIP 2490368 READ 32768
.ENDS
.BANK 91 SLOT 0
.ORG 0
.SECTION "HDisk91" FORCE
.INCBIN HDIMG SKIP 2523136 READ 32768
.ENDS
.BANK 92 SLOT 0
.ORG 0
.SECTION "HDisk92" FORCE
.INCBIN HDIMG SKIP 2555904 READ 32768
.ENDS
.BANK 93 SLOT 0
.ORG 0
.SECTION "HDisk93" FORCE
.INCBIN HDIMG SKIP 2588672 READ 32768
.ENDS
.BANK 94 SLOT 0
.ORG 0
.SECTION "HDisk94" FORCE
.INCBIN HDIMG SKIP 2621440 READ 32768
.ENDS
.BANK 95 SLOT 0
.ORG 0
.SECTION "HDisk95" FORCE
.INCBIN HDIMG SKIP 2654208 READ 32768
.ENDS
.BANK 96 SLOT 0
.ORG 0
.SECTION "HDisk96" FORCE
.INCBIN HDIMG SKIP 2686976 READ 32768
.ENDS
.BANK 97 SLOT 0
.ORG 0
.SECTION "HDisk97" FORCE
.INCBIN HDIMG SKIP 2719744 READ 32768
.ENDS
.BANK 98 SLOT 0
.ORG 0
.SECTION "HDisk98" FORCE
.INCBIN HDIMG SKIP 2752512 READ 32768
.ENDS
.BANK 99 SLOT 0
.ORG 0
.SECTION "HDisk99" FORCE
.INCBIN HDIMG SKIP 2785280 READ 32768
.ENDS
.BANK 100 SLOT 0
.ORG 0
.SECTION "HDisk100" FORCE
.INCBIN HDIMG SKIP 2818048 READ 32768
.ENDS
.BANK 101 SLOT 0
.ORG 0
.SECTION "HDisk101" FORCE
.INCBIN HDIMG SKIP 2850816 READ 32768
.ENDS
.BANK 102 SLOT 0
.ORG 0
.SECTION "HDisk102" FORCE
.INCBIN HDIMG SKIP 2883584 READ 32768
.ENDS
.BANK 103 SLOT 0
.ORG 0
.SECTION "HDisk103" FORCE
.INCBIN HDIMG SKIP 2916352 READ 32768
.ENDS
.BANK 104 SLOT 0
.ORG 0
.SECTION "HDisk104" FORCE
.INCBIN HDIMG SKIP 2949120 READ 32768
.ENDS
.BANK 105 SLOT 0
.ORG 0
.SECTION "HDisk105" FORCE
.INCBIN HDIMG SKIP 2981888 READ 32768
.ENDS
.BANK 106 SLOT 0
.ORG 0
.SECTION "HDisk106" FORCE
.INCBIN HDIMG SKIP 3014656 READ 32768
.ENDS
.BANK 107 SLOT 0
.ORG 0
.SECTION "HDisk107" FORCE
.INCBIN HDIMG SKIP 3047424 READ 32768
.ENDS
.BANK 108 SLOT 0
.ORG 0
.SECTION "HDisk108" FORCE
.INCBIN HDIMG SKIP 3080192 READ 32768
.ENDS
.BANK 109 SLOT 0
.ORG 0
.SECTION "HDisk109" FORCE
.INCBIN HDIMG SKIP 3112960 READ 32768
.ENDS
.BANK 110 SLOT 0
.ORG 0
.SECTION "HDisk110" FORCE
.INCBIN HDIMG SKIP 3145728 READ 32768
.ENDS
.BANK 111 SLOT 0
.ORG 0
.SECTION "HDisk111" FORCE
.INCBIN HDIMG SKIP 3178496 READ 32768
.ENDS
.BANK 112 SLOT 0
.ORG 0
.SECTION "HDisk112" FORCE
.INCBIN HDIMG SKIP 3211264 READ 32768
.ENDS
.BANK 113 SLOT 0
.ORG 0
.SECTION "HDisk113" FORCE
.INCBIN HDIMG SKIP 3244032 READ 32768
.ENDS
.BANK 114 SLOT 0
.ORG 0
.SECTION "HDisk114" FORCE
.INCBIN HDIMG SKIP 3276800 READ 32768
.ENDS
.BANK 115 SLOT 0
.ORG 0
.SECTION "HDisk115" FORCE
.INCBIN HDIMG SKIP 3309568 READ 32768
.ENDS
.BANK 116 SLOT 0
.ORG 0
.SECTION "HDisk116" FORCE
.INCBIN HDIMG SKIP 3342336 READ 32768
.ENDS
.BANK 117 SLOT 0
.ORG 0
.SECTION "HDisk117" FORCE
.INCBIN HDIMG SKIP 3375104 READ 32768
.ENDS
.BANK 118 SLOT 0
.ORG 0
.SECTION "HDisk118" FORCE
.INCBIN HDIMG SKIP 3407872 READ 32768
.ENDS
.BANK 119 SLOT 0
.ORG 0
.SECTION "HDisk119" FORCE
.INCBIN HDIMG SKIP 3440640 READ 32768
.ENDS
.BANK 120 SLOT 0
.ORG 0
.SECTION "HDisk120" FORCE
.INCBIN HDIMG SKIP 3473408 READ 32768
.ENDS
.BANK 121 SLOT 0
.ORG 0
.SECTION "HDisk121" FORCE
.INCBIN HDIMG SKIP 3506176 READ 32768
.ENDS
.BANK 122 SLOT 0
.ORG 0
.SECTION "HDisk122" FORCE
.INCBIN HDIMG SKIP 3538944 READ 32768
.ENDS
.BANK 123 SLOT 0
.ORG 0
.SECTION "HDisk123" FORCE
.INCBIN HDIMG SKIP 3571712 READ 32768
.ENDS
.BANK 124 SLOT 0
.ORG 0
.SECTION "HDisk124" FORCE
.INCBIN HDIMG SKIP 3604480 READ 32768
.ENDS
.BANK 125 SLOT 0
.ORG 0
.SECTION "HDisk125" FORCE
.INCBIN HDIMG SKIP 3637248 READ 32768
.ENDS
.BANK 126 SLOT 0
.ORG 0
.SECTION "HDisk126" FORCE
.INCBIN HDIMG SKIP 3670016 READ 32768
.ENDS
.BANK 127 SLOT 0
.ORG 0
.SECTION "HDisk127" FORCE
.INCBIN HDIMG SKIP 3702784 READ 22528
.ENDS
.ENDIF
