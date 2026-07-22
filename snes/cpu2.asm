; snes86 — 8086 core, part 2 (M5): everything the M4 skeleton left out.
; Included after cpu.asm; optable entries in cpu.asm reference these.
; Same conventions: A/X/Y 16-bit, DBR=$7E, Y = guest IP inside handlers.

.BANK 0 SLOT 0
.ORG 0
.SECTION "CpuCore2" SEMIFREE

.ACCU 16
.INDEX 16

;----------------------------------------------------------------------
; helpers
;----------------------------------------------------------------------
push16v:                     ; push A onto the guest stack (no gIP commit)
    sta tmp1
    lda gSP
    dec a
    dec a
    sta gSP
    ldx #30                  ; bSS
    jsr mk_ptr
    lda tmp1
.IFDEF BIGMEM
    jmp wr16m
.ELSE
    sta [mPTR]
    rts
.ENDIF

pop16v:                      ; A <- popped word
    ldx #30
    lda gSP
    jsr mk_ptr
    lda gSP
    inc a
    inc a
    sta gSP
.IFDEF BIGMEM
    jmp rd16m
.ELSE
    lda [mPTR]
    rts
.ENDIF

seg_src_x:                   ; X = DP offset of source base (override or DS)
    ldx ovSEG
    bne _ssx_done
    ldx #33                  ; bDS
_ssx_done:
    rts

; recompute a 24-bit cached base. X = seg DP offset (16/18/20/22).
; base = $7E:GUEST_BASE + seg*16; clobbers X.
upd_base_x:
    txa
    sec
    sbc #16
    lsr a
    sta tmp1
    asl a
    clc
    adc tmp1
    clc
    adc #24
    sta tmp1                 ; dest base DP offset
    lda.b 0,x                ; seg value
    sta tmp0
.IFDEF DOSBIOS
    ; CGA/MDA segments (B000-BFFF) redirect to the 16 KB adapter RAM
    and #$F000
    cmp #$B000
    bne _ub_norm
    lda tmp0
    asl a
    asl a
    asl a
    asl a
    and #$3FFF               ; wrap inside the 16 KB window
    clc
    adc #VBOFS
    ldx tmp1
    sta.b 0,x
    sep #$20
    lda #$7E
    sta.b 2,x
    rep #$20
    rts
_ub_norm:
    lda tmp0
.ENDIF
    asl a
    asl a
    asl a
    asl a                    ; seg<<4 (low 16)
    clc
    adc #GUEST_BASE
    ldx tmp1
    sta.b 0,x
    lda #0
    rol a                    ; carry out of the low add
    sta tmp1
    lda tmp0
    xba
    and #$00FF
    lsr a
    lsr a
    lsr a
    lsr a                    ; seg>>12
    clc
    adc tmp1
    clc
    adc #$007E
    sep #$20
    sta.b 2,x
    rep #$20
.IFDEF BIGMEM
.IFDEF ELKS
    cpx.w #27                ; CS reload: stash the NAIVE base in bCSc
    bne _ub_nocs             ; BEFORE the fold — fetch and CS-override
    lda.b 0,x                ; folds must start from naive space
    sta bCSc
    sep #$20
    lda.b 2,x
    sta bCSc+2
    rep #$20
_ub_nocs:
.ENDIF
    jmp norm_base_x          ; fold a 108-172 KB base ($80) into SRAM
.ENDIF
    rts

upd_bCS:
    ldx #18
    jmp upd_base_x

;----------------------------------------------------------------------
; prefixes (state persists; back to the fetch loop, Y already advanced)
;----------------------------------------------------------------------
opP26: lda #24
       sta ovSEG
       jmp step_fetch
opP2E:
.IFDEF ELKS
       lda #bCSc             ; CS override: read via the canonical fold
.ELSE
       lda #27
.ENDIF
       sta ovSEG
       jmp step_fetch
opP36: lda #30
       sta ovSEG
       jmp step_fetch
opP3E: lda #33
       sta ovSEG
       jmp step_fetch
opPF0: jmp step_fetch        ; LOCK / F1 alias
opPF2: lda #2
       sta pREP
       jmp step_fetch
opPF3: lda #1
       sta pREP
       jmp step_fetch

;----------------------------------------------------------------------
; segment register traffic
;----------------------------------------------------------------------
.MACRO PUSHSEG ARGS SRC
    lda SRC
    jsr push16v
    jmp step_next
.ENDM
op06: PUSHSEG gES
op0E: PUSHSEG gCS
op16: PUSHSEG gSS
op1E: PUSHSEG gDS

.MACRO POPSEG ARGS SEGOFF
    jsr pop16v
    ldx #SEGOFF
    sta.b 0,x
    jsr upd_base_x
    jmp step_next
.ENDM
op07: POPSEG 16
op0F: POPSEG 18              ; POP CS (8086 quirk)
op17: POPSEG 20
op1F: POPSEG 22

op8C:                        ; MOV rm16, sreg
    jsr decode_modrm
    lda mREG
    and #$0006
    clc
    adc #16
    tax
    lda.b 0,x
    jsr rm_write16
    jmp step_next

op8E:                        ; MOV sreg, rm16
    jsr decode_modrm
    jsr rm_read16
    sta tmp2
    lda mREG
    and #$0006
    clc
    adc #16
    tax
    lda tmp2
    sta.b 0,x
    jsr upd_base_x
    jmp step_next

op8F:                        ; POP rm16
    jsr decode_modrm
    lda mPTR                 ; pop16v clobbers mPTR (stack access)
    sta mPTR2
    lda mPTR+1               ; copies bytes 1-2 (incl. bank)
    sta mPTR2+1
    jsr pop16v
    sta tmp2
    lda mPTR2
    sta mPTR
    lda mPTR2+1
    sta mPTR+1
    lda tmp2
    jsr rm_write16
    jmp step_next

opC4:                        ; LES r16, m32
    jsr decode_modrm
    lda [mPTR]
    ldx mREG
    sta.b 0,x
    inc mPTR
    inc mPTR
    lda [mPTR]
    sta gES
    ldx #16
    jsr upd_base_x
    jmp step_next

opC5:                        ; LDS r16, m32
    jsr decode_modrm
    lda [mPTR]
    ldx mREG
    sta.b 0,x
    inc mPTR
    inc mPTR
    lda [mPTR]
    sta gDS
    ldx #22
    jsr upd_base_x
    jmp step_next

;----------------------------------------------------------------------
; control flow
;----------------------------------------------------------------------
opE8:                        ; CALL rel16
    lda [bCS],y
    iny
    iny
    sta tmp0
    tya
    jsr push16v
    tya
    clc
    adc tmp0
    tay
    jmp step_next

opC3:                        ; RET (C1 alias)
    jsr pop16v
    tay
    jmp step_next

opC2:                        ; RET imm16 (C0 alias)
    lda [bCS],y
    iny
    iny
    sta tmp2
    jsr pop16v
    tay
    lda gSP
    clc
    adc tmp2
    sta gSP
    jmp step_next

op9A:                        ; CALL far ptr16:16
    lda [bCS],y
    iny
    iny
    sta tmp0
    lda [bCS],y
    iny
    iny
    sta tmp2
    lda gCS
    jsr push16v
    tya
    jsr push16v
    lda tmp2
    sta gCS
    ldy tmp0
    jsr upd_bCS
    jmp step_next

opEA:                        ; JMP far ptr16:16
    lda [bCS],y
    iny
    iny
    sta tmp0
    lda [bCS],y
    sta gCS
    ldy tmp0
    jsr upd_bCS
    jmp step_next

opCB:                        ; RETF (C9 alias)
    jsr pop16v
    tay
    jsr pop16v
    sta gCS
    jsr upd_bCS
    jmp step_next

opCA:                        ; RETF imm16 (C8 alias)
    lda [bCS],y
    iny
    iny
    sta tmp2
    jsr pop16v
    tay
    jsr pop16v
    sta gCS
    jsr upd_bCS
    lda gSP
    clc
    adc tmp2
    sta gSP
    jmp step_next

; interrupt entry: A = vector, Y = return IP; exits with Y = handler IP
do_int:
    sta dINT
.IFDEF DOSBIOS
    ; HLE BIOS: handled vectors return natively, no guest IVT involved
    lda dINT
    and #$00FF
    cmp #$0010
    beq _di_10
    cmp #$0011
    beq _di_11
    cmp #$0012
    beq _di_12
    cmp #$0013
    beq _di_13
    cmp #$0016
    beq _di_16
    cmp #$001A
    beq _di_1A
.IFDEF ELKS
    cmp #$0015
    beq _di_15
.ENDIF
    bra _di_guest
.IFDEF ELKS
_di_15: jmp hle_int15
.ENDIF
_di_10: jmp hle_int10
_di_11: jmp hle_int11
_di_12: jmp hle_int12
_di_13: jmp hle_int13
_di_16: jmp hle_int16
_di_1A: jmp hle_int1A
_di_guest:
.ENDIF
    jsr flags_norm
    lda fSTATIC
    jsr push16v
    lda fSTATIC
    and #$FCFF               ; clear IF and TF
    sta fSTATIC
    lda gCS
    jsr push16v
    tya
    jsr push16v
    lda dINT
    asl a
    asl a
    clc
    adc #GUEST_BASE
    sta mPTR
    sep #$20
    lda #$7E
    sta mPTR+2
    rep #$20
    lda [mPTR]
    tay
    inc mPTR
    inc mPTR
    lda [mPTR]
    sta gCS
    jsr upd_bCS
    rts

opCC:                        ; INT3
    lda #3
    jsr do_int
    jmp step_next

opCD:                        ; INT imm8
    lda [bCS],y
    iny
    and #$00FF
    jsr do_int
    jmp step_next

opCE:                        ; INTO
    jsr flags_norm
    lda fSTATIC
    and #F_OF
    beq _into_no
    lda #4
    jsr do_int
_into_no:
    jmp step_next

opCF:                        ; IRET
    jsr pop16v
    tay
    jsr pop16v
    sta gCS
    jsr upd_bCS
    jsr pop16v
    and #$0FD5
    ora #$F002
    sta fSTATIC
    stz lfKIND
    jmp step_next

opE0:                        ; LOOPNZ rel8
    jsr fetch_d8s
    sta tmp0
    jsr flags_norm
    dec gCX
    lda gCX
    beq _e0_no
    lda fSTATIC
    and #F_ZF
    bne _e0_no
    tya
    clc
    adc tmp0
    tay
_e0_no:
    jmp step_next

opE1:                        ; LOOPZ rel8
    jsr fetch_d8s
    sta tmp0
    jsr flags_norm
    dec gCX
    lda gCX
    beq _e1_no
    lda fSTATIC
    and #F_ZF
    beq _e1_no
    tya
    clc
    adc tmp0
    tay
_e1_no:
    jmp step_next

opE2:                        ; LOOP rel8
    jsr fetch_d8s
    sta tmp0
    dec gCX
    lda gCX
    beq _e2_no
    tya
    clc
    adc tmp0
    tay
_e2_no:
    jmp step_next

opE3:                        ; JCXZ rel8
    jsr fetch_d8s
    sta tmp0
    lda gCX
    bne _e3_no
    tya
    clc
    adc tmp0
    tay
_e3_no:
    jmp step_next

;----------------------------------------------------------------------
; grp4 (FE): INC/DEC rm8. reg 2-7 undefined -> no-op (matches C core)
;----------------------------------------------------------------------
opFE:
    jsr decode_modrm
    jsr fixup8
    lda mREG                 ; rewritten by fixup8: 0->0, 1->2
    beq _fe_inc
    cmp #2
    beq _fe_dec
    jmp step_next
_fe_inc:
    jsr save_cf
    jsr rm_read8
    sta lfA
    inc a
    and #$00FF
    sta lfR
    jsr rm_write8
    lda #1
    sta lfB
    lda #LF_ADD8
    sta lfKIND
    jmp step_next
_fe_dec:
    jsr save_cf
    jsr rm_read8
    sta lfA
    dec a
    and #$00FF
    sta lfR
    jsr rm_write8
    lda #1
    sta lfB
    lda #LF_SUB8
    sta lfKIND
    jmp step_next

;----------------------------------------------------------------------
; grp5 (FF)
;----------------------------------------------------------------------
opFF:
    jsr decode_modrm
    ldx mREG
    jmp (g5tab,x)

g5tab:
    .dw g5_inc, g5_dec, g5_call, g5_callf, g5_jmp, g5_jmpf, g5_push, g5_push

g5_inc:
    jsr save_cf
    jsr rm_read16
    sta lfA
    inc a
    sta lfR
    jsr rm_write16
    lda #1
    sta lfB
    lda #LF_ADD16
    sta lfKIND
    jmp step_next

g5_dec:
    jsr save_cf
    jsr rm_read16
    sta lfA
    dec a
    sta lfR
    jsr rm_write16
    lda #1
    sta lfB
    lda #LF_SUB16
    sta lfKIND
    jmp step_next

g5_call:
    jsr rm_read16
    sta tmp2
    tya
    jsr push16v
    ldy tmp2
    jmp step_next

g5_callf:                    ; CALL far m16:16
    lda [mPTR]
    sta tmp0
    inc mPTR
    inc mPTR
    lda [mPTR]
    sta tmp2
    lda gCS
    jsr push16v
    tya
    jsr push16v
    lda tmp2
    sta gCS
    ldy tmp0
    jsr upd_bCS
    jmp step_next

g5_jmp:
    jsr rm_read16
    tay
    jmp step_next

g5_jmpf:
    lda [mPTR]
    sta tmp0
    inc mPTR
    inc mPTR
    lda [mPTR]
    sta gCS
    ldy tmp0
    jsr upd_bCS
    jmp step_next

g5_push:                     ; PUSH rm16 (8086: PUSH SP pushes new SP)
    jsr rm_read16
    sta tmp2
    lda mISREG
    beq _g5p_go
    lda mRM
    cmp #8                   ; rm = SP
    bne _g5p_go
    lda tmp2
    dec a
    dec a
    sta tmp2
_g5p_go:
    lda tmp2
    jsr push16v
    jmp step_next

;----------------------------------------------------------------------
; string ops. Source segment = DS (overridable); dest is always ES:DI.
;----------------------------------------------------------------------
.MACRO REPWRAP ARGS ONCE
    lda pREP
    bne _rw\@
    jsr ONCE
    jmp step_next
_rw\@:
    lda gCX
    beq _rd\@
_rl\@:
    jsr ONCE
    dec gCX
    lda gCX
    bne _rl\@
_rd\@:
    jmp step_next
.ENDM

; ---- chunked forward REP MOVS: per-run pointer setup, per-element
; cost drops from ~85 to ~32 cycles. DF=1 and 64K-edge cases fall back
; to the per-element helper (identical semantics: ascending copy).
.MACRO REPMOVF ARGS ONCE, WIDE
    lda pREP
    bne _mf\@
    jsr ONCE
    jmp step_next
_mf\@:
    lda gCX
    beq _md\@
.IFDEF BIGMEM
    jmp _mb\@                ; 172 KB: per-element re-normalises each ptr so
.ENDIF                       ; the copy folds correctly across WRAM/SRAM seams
    lda fSTATIC
    and #F_DF
    bne _mb\@                ; backward: rare, keep per-element
_mc\@:
    lda gSI                  ; 64K-boundary starts: one element the
    beq _m1\@                ; slow way sidesteps the 0x10000 encoding
    lda gDI
    beq _m1\@
    lda gSI
    eor #$FFFF
    inc a                    ; bytes until SI wraps
.IF WIDE == 1
    lsr a                    ; elements until SI wraps
.ENDIF
    sta tmp0
    lda gDI
    eor #$FFFF
    inc a
.IF WIDE == 1
    lsr a
.ENDIF
    sta tmp1
    lda gCX                  ; N = min(CX, wrapSI, wrapDI), cap $2000
    cmp tmp0
    bcc _mA\@
    lda tmp0
_mA\@:
    cmp tmp1
    bcc _mB\@
    lda tmp1
_mB\@:
    cmp #$2000
    bcc _mC\@
    lda #$2000
_mC\@:
    bne _mD\@
    bra _m1\@                ; N=0 (odd start near wrap): slow element
_mD\@:
    sta tmp2                 ; N elements
.IF WIDE == 1
    asl a
.ENDIF
    sta tmp0                 ; N bytes
    phy
    jsr seg_src_x
    lda gSI
    jsr mk_ptr
    ldx #24
    lda gDI
    jsr mk_ptr2
    ldy #0
.IF WIDE == 1
_ml\@:
    lda [mPTR],y
    sta [mPTR2],y
    iny
    iny
    cpy tmp0
    bcc _ml\@
.ELSE
    sep #$20
_ml\@:
    lda [mPTR],y
    sta [mPTR2],y
    iny
    cpy tmp0
    bcc _ml\@
    rep #$20
.ENDIF
    ply
    lda gSI
    clc
    adc tmp0
    sta gSI
    lda gDI
    clc
    adc tmp0
    sta gDI
    lda gCX
    sec
    sbc tmp2
    sta gCX
    bne _mc\@
_md\@:
    jmp step_next
_m1\@:
    jsr ONCE
    dec gCX
    lda gCX
    bne _mc\@
    bra _md\@
_mb\@:
    jsr ONCE
    dec gCX
    lda gCX
    bne _mb\@
    bra _md\@
.ENDM

; ---- chunked forward REP STOS: the guest memset
.MACRO REPSTOF ARGS ONCE, WIDE
    lda pREP
    bne _sf\@
    jsr ONCE
    jmp step_next
_sf\@:
    lda gCX
    beq _sd\@
.IFDEF BIGMEM
    jmp _sb\@                ; 172 KB: per-element, seam-correct (see REPMOVF)
.ENDIF
    lda fSTATIC
    and #F_DF
    bne _sb\@
_sc\@:
    lda gDI
    beq _s1\@
    lda gDI
    eor #$FFFF
    inc a
.IF WIDE == 1
    lsr a
.ENDIF
    sta tmp1
    lda gCX
    cmp tmp1
    bcc _sA\@
    lda tmp1
_sA\@:
    cmp #$2000
    bcc _sB\@
    lda #$2000
_sB\@:
    bne _sC\@
    bra _s1\@
_sC\@:
    sta tmp2
.IF WIDE == 1
    asl a
.ENDIF
    sta tmp0
    phy
    ldx #24
    lda gDI
    jsr mk_ptr
    ldy #0
.IF WIDE == 1
    lda gAX
_sl\@:
    sta [mPTR],y
    iny
    iny
    cpy tmp0
    bcc _sl\@
.ELSE
    sep #$20
    lda gAX
_sl\@:
    sta [mPTR],y
    iny
    cpy tmp0
    bcc _sl\@
    rep #$20
.ENDIF
    ply
    lda gDI
    clc
    adc tmp0
    sta gDI
    lda gCX
    sec
    sbc tmp2
    sta gCX
    bne _sc\@
_sd\@:
    jmp step_next
_s1\@:
    jsr ONCE
    dec gCX
    lda gCX
    bne _sc\@
    bra _sd\@
_sb\@:
    jsr ONCE
    dec gCX
    lda gCX
    bne _sb\@
    bra _sd\@
.ENDM

op_A4: REPMOVF movs8_once, 0
op_A5: REPMOVF movs16_once, 1
op_AA: REPSTOF stos8_once, 0
op_AB: REPSTOF stos16_once, 1
op_AC: REPWRAP lods8_once
op_AD: REPWRAP lods16_once



.MACRO REPZWRAP ARGS ONCE
    lda pREP
    bne _zw\@
    jsr ONCE
    jmp step_next
_zw\@:
    lda gCX
    beq _zd\@
_zl\@:
    jsr ONCE
    dec gCX
    lda gCX
    beq _zd\@
    lda pREP
    cmp #1
    beq _ze\@
    lda lfR                  ; REPNE: stop when equal (result 0)
    beq _zd\@
    bra _zl\@
_ze\@:
    lda lfR                  ; REPE: stop when not equal
    bne _zd\@
    bra _zl\@
_zd\@:
    jmp step_next
.ENDM

op_A6: REPZWRAP cmps8_once
op_A7: REPZWRAP cmps16_once
op_AE: REPZWRAP scas8_once
op_AF: REPZWRAP scas16_once

movs8_once:
    jsr seg_src_x
    lda gSI
    jsr mk_ptr
    ldx #24
    lda gDI
    jsr mk_ptr2
    sep #$20
    lda [mPTR]
    sta [mPTR2]
    rep #$20
    jsr str_si8
    jmp str_di8

movs16_once:
    jsr seg_src_x
    lda gSI
    jsr mk_ptr
.IFDEF BIGMEM
    jsr rd16m                ; source word (seam-safe), then dest via mPTR
    pha
    ldx #24
    lda gDI
    jsr mk_ptr
    pla
    jsr wr16m
.ELSE
    ldx #24
    lda gDI
    jsr mk_ptr2
    lda [mPTR]
    sta [mPTR2]
.ENDIF
    jsr str_si16
    jmp str_di16

stos8_once:
    ldx #24
    lda gDI
    jsr mk_ptr
    lda gAX
    sep #$20
    sta [mPTR]
    rep #$20
    jmp str_di8

stos16_once:
    ldx #24
    lda gDI
    jsr mk_ptr
    lda gAX
.IFDEF BIGMEM
    jsr wr16m
.ELSE
    sta [mPTR]
.ENDIF
    jmp str_di16

lods8_once:
    jsr seg_src_x
    lda gSI
    jsr mk_ptr
    sep #$20
    lda [mPTR]
    sta gAX
    rep #$20
    jmp str_si8

lods16_once:
    jsr seg_src_x
    lda gSI
    jsr mk_ptr
.IFDEF BIGMEM
    jsr rd16m
.ELSE
    lda [mPTR]
.ENDIF
    sta gAX
    jmp str_si16

cmps8_once:                  ; flags of [SI] - ES:[DI]
    jsr seg_src_x
    lda gSI
    jsr mk_ptr
    lda [mPTR]
    and #$00FF
    sta lfA
    ldx #24
    lda gDI
    jsr mk_ptr
    lda [mPTR]
    and #$00FF
    sta lfB
    jsr alu_sub8
    jsr str_si8
    jmp str_di8

cmps16_once:
    jsr seg_src_x
    lda gSI
    jsr mk_ptr
.IFDEF BIGMEM
    jsr rd16m
.ELSE
    lda [mPTR]
.ENDIF
    sta lfA
    ldx #24
    lda gDI
    jsr mk_ptr
.IFDEF BIGMEM
    jsr rd16m
.ELSE
    lda [mPTR]
.ENDIF
    sta lfB
    jsr alu_sub16
    jsr str_si16
    jmp str_di16

scas8_once:                  ; flags of AL - ES:[DI]
    lda gAX
    and #$00FF
    sta lfA
    ldx #24
    lda gDI
    jsr mk_ptr
    lda [mPTR]
    and #$00FF
    sta lfB
    jsr alu_sub8
    jmp str_di8

scas16_once:
    lda gAX
    sta lfA
    ldx #24
    lda gDI
    jsr mk_ptr
.IFDEF BIGMEM
    jsr rd16m
.ELSE
    lda [mPTR]
.ENDIF
    sta lfB
    jsr alu_sub16
    jmp str_di16

str_si8:
    lda fSTATIC
    and #F_DF
    bne _s8b
    inc gSI
    rts
_s8b:
    dec gSI
    rts
str_di8:
    lda fSTATIC
    and #F_DF
    bne _d8b
    inc gDI
    rts
_d8b:
    dec gDI
    rts
str_si16:
    lda fSTATIC
    and #F_DF
    bne _s16b
    inc gSI
    inc gSI
    rts
_s16b:
    dec gSI
    dec gSI
    rts
str_di16:
    lda fSTATIC
    and #F_DF
    bne _d16b
    inc gDI
    inc gDI
    rts
_d16b:
    dec gDI
    dec gDI
    rts

;----------------------------------------------------------------------
; grp2 (D0-D3): shifts/rotates, bit-at-a-time; reg6 = SETMO/SETMOC
;----------------------------------------------------------------------
opD0:
    jsr decode_modrm
    ldx mREG
    stx aluIDX
    jsr fixup8
    lda #1
    sta sCNT
    jmp grp2_8
opD1:
    jsr decode_modrm
    ldx mREG
    stx aluIDX
    lda #1
    sta sCNT
    jmp grp2_16
opD2:
    jsr decode_modrm
    ldx mREG
    stx aluIDX
    jsr fixup8
    lda gCX
    and #$00FF
    sta sCNT
    jmp grp2_8
opD3:
    jsr decode_modrm
    ldx mREG
    stx aluIDX
    lda gCX
    and #$00FF
    sta sCNT
    jmp grp2_16

grp2_8:
    lda aluIDX
    cmp #12                  ; SETMO/SETMOC
    beq _g28_setmo
    lda sCNT
    beq _g28_nop
    jsr flags_norm
    lda fSTATIC
    and #$0001
    sta sCF
    stz sOF
    jsr rm_read8
    sta sVAL
    ldx aluIDX
    jsr (g2tab8,x)
    lda sVAL
    jsr rm_write8
    lda aluIDX
    cmp #8
    bcs _g28_shift
    ; rotate: only CF/OF change
    lda fSTATIC
    and #$F7FE
    ora sCF
    ldx sOF
    beq _g28_rot_st
    ora #F_OF
_g28_rot_st:
    sta fSTATIC
_g28_nop:
    jmp step_next
_g28_shift:                  ; SHL/SHR/SAR: SZP too, AF cleared
    lda fSTATIC
    and #F_KEEP
    sta tmp2
    lda sVAL
    sta lfR
    jsr szp8_f
    lda tmp2
    ora sCF
    ldx sOF
    beq _g28_sh_st
    ora #F_OF
_g28_sh_st:
    sta fSTATIC
    jmp step_next
_g28_setmo:
    lda sCNT
    beq _g28_nop
    lda #$00FF
    jsr rm_write8
    lda #$00FF
    sta lfR
    lda #LF_LOG8
    sta lfKIND
    jmp step_next

grp2_16:
    lda aluIDX
    cmp #12
    beq _g216_setmo
    lda sCNT
    beq _g216_nop
    jsr flags_norm
    lda fSTATIC
    and #$0001
    sta sCF
    stz sOF
    jsr rm_read16
    sta sVAL
    ldx aluIDX
    jsr (g2tab16,x)
    lda sVAL
    jsr rm_write16
    lda aluIDX
    cmp #8
    bcs _g216_shift
    lda fSTATIC
    and #$F7FE
    ora sCF
    ldx sOF
    beq _g216_rot_st
    ora #F_OF
_g216_rot_st:
    sta fSTATIC
_g216_nop:
    jmp step_next
_g216_shift:
    lda fSTATIC
    and #F_KEEP
    sta tmp2
    lda sVAL
    sta lfR
    jsr szp16_f
    lda tmp2
    ora sCF
    ldx sOF
    beq _g216_sh_st
    ora #F_OF
_g216_sh_st:
    sta fSTATIC
    jmp step_next
_g216_setmo:
    lda sCNT
    beq _g216_nop
    lda #$FFFF
    jsr rm_write16
    lda #$FFFF
    sta lfR
    lda #LF_LOG16
    sta lfKIND
    jmp step_next

g2tab8:
    .dw g2_rol8, g2_ror8, g2_rcl8, g2_rcr8
    .dw g2_shl8, g2_shr8, fn_ret, g2_sar8
g2tab16:
    .dw g2_rol16, g2_ror16, g2_rcl16, g2_rcr16
    .dw g2_shl16, g2_shr16, fn_ret, g2_sar16

; helpers: A = relevant bit of sVAL as 0/1
msb8v:
    lda sVAL
    and #$0080
    beq _m8z
    lda #1
    rts
_m8z:
    lda #0
    rts
msb16v:
    lda sVAL
    and #$8000
    beq _m16z
    lda #1
    rts
_m16z:
    lda #0
    rts

g2_rol8:
    ldx sCNT
_rol8_l:
    jsr msb8v
    sta sCF
    lda sVAL
    asl a
    ora sCF
    and #$00FF
    sta sVAL
    jsr msb8v
    eor sCF
    sta sOF
    dex
    bne _rol8_l
    rts

g2_ror8:
    ldx sCNT
_ror8_l:
    lda sVAL
    and #$0001
    sta sCF
    lda sVAL
    lsr a
    sta sVAL
    lda sCF
    beq _ror8_n
    lda sVAL
    ora #$0080
    sta sVAL
_ror8_n:
    lda sVAL
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    eor sVAL
    ; A bit6 ^ bit7 in bit6... compute OF = (v>>7 ^ v>>6)&1:
    lda sVAL
    and #$00C0               ; bits 7:6
    beq _ror8_z
    cmp #$00C0
    beq _ror8_z
    lda #1
    sta sOF
    bra _ror8_d
_ror8_z:
    stz sOF
_ror8_d:
    dex
    bne _ror8_l
    rts

g2_rcl8:
    ldx sCNT
_rcl8_l:
    jsr msb8v
    sta tmp0
    lda sVAL
    asl a
    ora sCF
    and #$00FF
    sta sVAL
    lda tmp0
    sta sCF
    jsr msb8v
    eor sCF
    sta sOF
    dex
    bne _rcl8_l
    rts

g2_rcr8:
    ldx sCNT
_rcr8_l:
    lda sVAL
    and #$0001
    sta tmp0
    lda sVAL
    lsr a
    sta sVAL
    lda sCF
    beq _rcr8_n
    lda sVAL
    ora #$0080
    sta sVAL
_rcr8_n:
    lda tmp0
    sta sCF
    lda sVAL
    and #$00C0
    beq _rcr8_z
    cmp #$00C0
    beq _rcr8_z
    lda #1
    sta sOF
    bra _rcr8_d
_rcr8_z:
    stz sOF
_rcr8_d:
    dex
    bne _rcr8_l
    rts

g2_shl8:
    ldx sCNT
_shl8_l:
    jsr msb8v
    sta sCF
    lda sVAL
    asl a
    and #$00FF
    sta sVAL
    jsr msb8v
    eor sCF
    sta sOF
    dex
    bne _shl8_l
    rts

g2_shr8:
    ldx sCNT
_shr8_l:
    jsr msb8v
    sta sOF                  ; OF = msb of value entering this step
    lda sVAL
    and #$0001
    sta sCF
    lda sVAL
    lsr a
    sta sVAL
    dex
    bne _shr8_l
    rts

g2_sar8:
    ldx sCNT
_sar8_l:
    lda sVAL
    and #$0001
    sta sCF
    lda sVAL
    and #$0080
    sta tmp0
    lda sVAL
    lsr a
    ora tmp0
    sta sVAL
    stz sOF
    dex
    bne _sar8_l
    rts

g2_rol16:
    ldx sCNT
_rol16_l:
    jsr msb16v
    sta sCF
    lda sVAL
    asl a
    ora sCF
    sta sVAL
    jsr msb16v
    eor sCF
    sta sOF
    dex
    bne _rol16_l
    rts

g2_ror16:
    ldx sCNT
_ror16_l:
    lda sVAL
    and #$0001
    sta sCF
    lda sVAL
    lsr a
    sta sVAL
    lda sCF
    beq _ror16_n
    lda sVAL
    ora #$8000
    sta sVAL
_ror16_n:
    lda sVAL
    and #$C000
    beq _ror16_z
    cmp #$C000
    beq _ror16_z
    lda #1
    sta sOF
    bra _ror16_d
_ror16_z:
    stz sOF
_ror16_d:
    dex
    bne _ror16_l
    rts

g2_rcl16:
    ldx sCNT
_rcl16_l:
    jsr msb16v
    sta tmp0
    lda sVAL
    asl a
    ora sCF
    sta sVAL
    lda tmp0
    sta sCF
    jsr msb16v
    eor sCF
    sta sOF
    dex
    bne _rcl16_l
    rts

g2_rcr16:
    ldx sCNT
_rcr16_l:
    lda sVAL
    and #$0001
    sta tmp0
    lda sVAL
    lsr a
    sta sVAL
    lda sCF
    beq _rcr16_n
    lda sVAL
    ora #$8000
    sta sVAL
_rcr16_n:
    lda tmp0
    sta sCF
    lda sVAL
    and #$C000
    beq _rcr16_z
    cmp #$C000
    beq _rcr16_z
    lda #1
    sta sOF
    bra _rcr16_d
_rcr16_z:
    stz sOF
_rcr16_d:
    dex
    bne _rcr16_l
    rts

g2_shl16:
    ldx sCNT
_shl16_l:
    jsr msb16v
    sta sCF
    lda sVAL
    asl a
    sta sVAL
    jsr msb16v
    eor sCF
    sta sOF
    dex
    bne _shl16_l
    rts

g2_shr16:
    ldx sCNT
_shr16_l:
    jsr msb16v
    sta sOF
    lda sVAL
    and #$0001
    sta sCF
    lda sVAL
    lsr a
    sta sVAL
    dex
    bne _shr16_l
    rts

g2_sar16:
    ldx sCNT
_sar16_l:
    lda sVAL
    and #$0001
    sta sCF
    lda sVAL
    and #$8000
    sta tmp0
    lda sVAL
    lsr a
    ora tmp0
    sta sVAL
    stz sOF
    dex
    bne _sar16_l
    rts

;----------------------------------------------------------------------
; grp3 (F6/F7): TEST/NOT/NEG/MUL/IMUL/DIV/IDIV
;----------------------------------------------------------------------
opF6:
    jsr decode_modrm
    ldx mREG
    stx aluIDX
    jsr fixup8
    ldx aluIDX
    jmp (g3tab8,x)

opF7:
    jsr decode_modrm
    ldx mREG
    stx aluIDX
    jmp (g3tab16,x)

g3tab8:
    .dw g3_test8, g3_test8, g3_not8, g3_neg8
    .dw g3_mul8, g3_imul8, g3_div8, g3_idiv8
g3tab16:
    .dw g3_test16, g3_test16, g3_not16, g3_neg16
    .dw g3_mul16, g3_imul16, g3_div16, g3_idiv16

g3_test8:
    jsr rm_read8
    sta lfA
    lda [bCS],y
    iny
    and #$00FF
    sta lfB
    jsr alu_and8
    jmp step_next

g3_test16:
    jsr rm_read16
    sta lfA
    lda [bCS],y
    iny
    iny
    sta lfB
    jsr alu_and16
    jmp step_next

g3_not8:
    jsr rm_read8
    eor #$00FF
    jsr rm_write8
    jmp step_next

g3_not16:
    jsr rm_read16
    eor #$FFFF
    jsr rm_write16
    jmp step_next

g3_neg8:
    jsr rm_read8
    sta lfB
    stz lfA
    jsr alu_sub8
    lda lfR
    jsr rm_write8
    jmp step_next

g3_neg16:
    jsr rm_read16
    sta lfB
    stz lfA
    jsr alu_sub16
    lda lfR
    jsr rm_write16
    jmp step_next

; unsigned 16x16 multiply: mA * mB -> mHI:mLO (clobbers mB)
mulu16:
    lda #0
    sta mLO
    ldx #16
_mu_l:
    lsr mB
    bcc _mu_n
    clc
    adc mA
_mu_n:
    ror a
    ror mLO
    dex
    bne _mu_l
    sta mHI
    rts

; set CF|OF (A nonzero) or clear both, preserving everything else
mulflags:
    sta dQ                   ; NOT in X: flags_norm clobbers X (ldx lfKIND)
    jsr flags_norm
    lda dQ
    beq _mf_clr
    lda fSTATIC
    ora #$0801
    sta fSTATIC
    rts
_mf_clr:
    lda fSTATIC
    and #$F7FE
    sta fSTATIC
    rts

g3_mul8:
    jsr rm_read8
    sta mB
    lda gAX
    and #$00FF
    sta mA
    jsr mulu16
    lda mLO
    sta gAX
    and #$FF00
    jsr mulflags
    jmp step_next

g3_mul16:
    jsr rm_read16
    sta mB
    lda gAX
    sta mA
    jsr mulu16
    lda mLO
    sta gAX
    lda mHI
    sta gDX
    jsr mulflags
    jmp step_next

sext8:                       ; A = byte -> sign-extended word
    and #$00FF
    cmp #$0080
    bcc _sx_p
    ora #$FF00
_sx_p:
    rts

g3_imul8:
    jsr rm_read8
    jsr sext8
    sta mB
    lda gAX
    jsr sext8
    sta mA
    jsr mulu16
    lda mLO
    sta gAX
    ; CF/OF = product != sext8(low byte)
    jsr sext8                ; A = sext of AL(result)
    eor mLO
    jsr mulflags
    jmp step_next

g3_imul16:
    jsr rm_read16
    sta mB
    sta dB2                  ; keep originals for sign correction
    lda gAX
    sta mA
    jsr mulu16
    lda mA
    and #$8000
    beq _im16_a
    lda mHI
    sec
    sbc dB2
    sta mHI
_im16_a:
    lda dB2
    and #$8000
    beq _im16_b
    lda mHI
    sec
    sbc mA
    sta mHI
_im16_b:
    lda mLO
    sta gAX
    lda mHI
    sta gDX
    ; CF/OF = DX != sign-extension of AX
    lda gAX
    and #$8000
    beq _im16_p
    lda gDX
    eor #$FFFF
    jsr mulflags
    jmp step_next
_im16_p:
    lda gDX
    jsr mulflags
    jmp step_next

;----------------------------------------------------------------------
; 8088-microcode division (port of core-c mc_div: CORD & friends).
; Values in dA (dividend hi / remainder), dC (dividend lo / ~quotient),
; dB (divisor), dCY, dNEG, dMSB ($80/$8000), dB2 (original hi).
; The mflags 'F' points reuse the lazy-flag machinery + flags_norm so
; the undefined-flag output matches the C core bit for bit.
;----------------------------------------------------------------------
mflags_sub16:                ; static <- flags(dA - dB), dCY <- borrow
    lda dA
    sec
    sbc dB
    sta lfR
    lda #0
    rol a
    eor #$0001
    sta lfCF
    sta dCY
    lda dA
    sta lfA
    lda dB
    sta lfB
    lda #LF_SUB16
    sta lfKIND
    jmp flags_norm

mflags_sub8:
    lda dB
    and #$00FF
    sta tmp1
    lda dA
    and #$00FF
    sec
    sbc tmp1
    and #$00FF
    sta lfR
    lda #0
    rol a
    eor #$0001
    sta lfCF
    sta dCY
    lda dA
    and #$00FF
    sta lfA
    lda dB
    and #$00FF
    sta lfB
    lda #LF_SUB8
    sta lfKIND
    jmp flags_norm

; wait — borrow sense: after SEC/SBC, C=1 means no borrow, so
; guest CF(borrow) = C eor 1; but CORD wants carry = borrow flag from
; alu_sub which is the same thing. (kept identical to the C port)

cord16:                      ; C set on divide error
    jsr mflags_sub16         ; 188/189: SUBT tmpa | F
    lda dCY
    bne _c16_ok
    sec
    rts
_c16_ok:
    ldx #16
_c16_loop:
    phx
    ; 18c: rcl tmpc
    lda dCY
    lsr a
    lda dC
    rol a
    sta dC
    lda #0
    rol a
    sta dCY
    ; 18d: rcl tmpa
    lda dCY
    lsr a
    lda dA
    rol a
    sta dA
    lda #0
    rol a
    sta dCY
    lda dCY
    beq _c16_nc
    ; carry out: 195/196: clear carry, tmpa -= tmpb (no flags)
    stz dCY
    lda dA
    sec
    sbc dB
    sta dA
    bra _c16_next
_c16_nc:
    jsr mflags_sub16         ; 18f: SUBT | F (also sets dCY)
    lda dCY
    bne _c16_next            ; 191: tmpa < tmpb, keep
    lda lfR                  ; 196: tmpa -= tmpb
    sta dA
_c16_next:
    plx
    dex
    bne _c16_loop
    ; 192/193: rcl tmpc
    lda dCY
    lsr a
    lda dC
    rol a
    sta dC
    lda #0
    rol a
    sta dCY
    ; 194: rcl tmpc, carry only
    lda dCY
    lsr a
    lda dC
    rol a
    lda #0
    rol a
    sta dCY
    ; CF <- dCY
    lda fSTATIC
    and #$FFFE
    ora dCY
    sta fSTATIC
    clc
    rts

cord8:
    lda dA
    and #$00FF
    sta dA
    lda dB
    and #$00FF
    sta dB
    lda dC
    and #$00FF
    sta dC
    jsr mflags_sub8
    lda dCY
    bne _c8_ok
    sec
    rts
_c8_ok:
    ldx #8
_c8_loop:
    phx
    ; rcl tmpc (byte)
    lda dC
    asl a
    ora dCY
    sta tmp0
    and #$00FF
    sta dC
    lda tmp0
    xba
    and #$0001
    sta dCY
    ; rcl tmpa (byte)
    lda dA
    asl a
    ora dCY
    sta tmp0
    and #$00FF
    sta dA
    lda tmp0
    xba
    and #$0001
    sta dCY
    lda dCY
    beq _c8_nc
    stz dCY
    lda dA
    sec
    sbc dB
    and #$00FF
    sta dA
    bra _c8_next
_c8_nc:
    jsr mflags_sub8
    lda dCY
    bne _c8_next
    lda lfR
    sta dA
_c8_next:
    plx
    dex
    bne _c8_loop
    ; final two rcls of tmpc
    lda dC
    asl a
    ora dCY
    sta tmp0
    and #$00FF
    sta dC
    lda tmp0
    xba
    and #$0001
    sta dCY
    lda dC
    asl a
    ora dCY
    sta tmp0
    lda tmp0
    xba
    and #$0001
    sta dCY
    lda fSTATIC
    and #$FFFE
    ora dCY
    sta fSTATIC
    clc
    rts

cor_negate:                  ; A = skip flag (nonzero: enter at LRCY tmpb)
    bne _cn_skip
    lda dC
    beq _cn_zc
    eor #$FFFF
    inc a
    sta dC
    lda dA
    eor #$FFFF
    sta dA
    bra _cn_f
_cn_zc:
    lda dA
    eor #$FFFF
    inc a
    sta dA
_cn_f:
    lda dNEG
    eor #$0001
    sta dNEG
_cn_skip:
    lda dB
    and dMSB
    beq _cn_pos
    lda fSTATIC
    ora #$0001
    sta fSTATIC
    lda dB
    eor #$FFFF
    inc a
    sta dB
    lda dNEG
    eor #$0001
    sta dNEG
    rts
_cn_pos:
    lda fSTATIC
    and #$FFFE
    sta fSTATIC
    rts

pre_idiv:
    lda dA
    and dMSB
    beq _pi_pos
    lda #0
    jmp cor_negate
_pi_pos:
    lda #1
    jmp cor_negate

post_idiv:                   ; C set on overflow; dQ = quotient
    lda dCY
    bne _po_ok
    sec
    rts
_po_ok:
    lda dB2
    and dMSB
    beq _po_p
    lda dA
    eor #$FFFF
    inc a
    sta dA
_po_p:
    lda dNEG
    beq _po_com
    lda dC
    inc a
    bra _po_s
_po_com:
    lda dC
    eor #$FFFF
_po_s:
    sta dQ
    lda fSTATIC
    and #$F7FE               ; CCOF
    sta fSTATIC
    clc
    rts

g3_div16:
    jsr rm_read16
    sta dB
    lda gDX
    sta dA
    lda gAX
    sta dC
    jsr cord16
    bcc +
    jmp _dv_err
+
    lda dC
    eor #$FFFF
    sta gAX
    lda dA
    sta gDX
    jmp step_next

g3_idiv16:
    jsr rm_read16
    sta dB
    lda gDX
    sta dA
    sta dB2
    lda gAX
    sta dC
    lda #$8000
    sta dMSB
    stz dNEG
    lda pREP
    beq _id16_n
    lda #1
    sta dNEG
_id16_n:
    jsr pre_idiv
    jsr cord16
    bcc +
    jmp _dv_err
+
    jsr post_idiv
    bcc +
    jmp _dv_err
+
    lda dQ
    sta gAX
    lda dA
    sta gDX
    jmp step_next

g3_div8:
    jsr rm_read8
    sta dB
    lda gAX
    xba
    and #$00FF
    sta dA
    lda gAX
    and #$00FF
    sta dC
    jsr cord8
    bcc +
    jmp _dv_err
+
    lda dC
    eor #$00FF
    and #$00FF
    sep #$20
    sta gAX
    rep #$20
    lda dA
    sep #$20
    sta gAX+1
    rep #$20
    jmp step_next

g3_idiv8:
    jsr rm_read8
    sta dB
    lda gAX
    xba
    and #$00FF
    sta dA
    sta dB2
    lda gAX
    and #$00FF
    sta dC
    lda #$0080
    sta dMSB
    stz dNEG
    lda pREP
    beq _id8_n
    lda #1
    sta dNEG
_id8_n:
    jsr pre_idiv
    jsr cord8
    bcc +
    jmp _dv_err
+
    jsr post_idiv
    bcc +
    jmp _dv_err
+
    lda dQ
    sep #$20
    sta gAX
    rep #$20
    lda dA
    sep #$20
    sta gAX+1
    rep #$20
    jmp step_next

_dv_err:
    lda #0
    jsr do_int
    jmp step_next

;----------------------------------------------------------------------
; BCD (hardware-exact, ported from core-c which passes the v2 vectors)
;----------------------------------------------------------------------
op27:                        ; DAA
    jsr flags_norm
    lda gAX
    and #$00FF
    sta dA                   ; old AL
    lda fSTATIC
    and #$0001
    sta dCY                  ; old CF
    lda fSTATIC
    and #F_AF
    sta dB2                  ; old AF (as bit 4)
    ; threshold: AF ? 0x9F : 0x99
    lda #$0099
    ldx dB2
    beq _daa_t
    lda #$009F
_daa_t:
    sta dB
    ; undefined OF ranges (hardware-captured)
    lda fSTATIC
    and #$F7FF
    sta fSTATIC
    ldx dCY
    beq _daa_of0
    lda dA
    cmp #$001A
    bcc _daa_ofd
    cmp #$0080
    bcs _daa_ofd
    bra _daa_ofset
_daa_of0:
    lda dA
    cmp #$007A
    bcc _daa_ofd
    cmp #$0080
    bcs _daa_ofd
_daa_ofset:
    lda fSTATIC
    ora #F_OF
    sta fSTATIC
_daa_ofd:
    ; low digit adjust
    lda dA
    sta dC                   ; working AL
    and #$000F
    cmp #$000A
    bcs _daa_lo
    ldx dB2
    bne _daa_lo
    lda fSTATIC
    and #$FFEF               ; AF = 0
    sta fSTATIC
    bra _daa_hi
_daa_lo:
    lda dC
    clc
    adc #6
    and #$00FF
    sta dC
    lda fSTATIC
    ora #F_AF
    sta fSTATIC
_daa_hi:
    ; high adjust: old_al > threshold || old CF
    ldx dCY
    bne _daa_do
    lda dA
    cmp dB
    beq _daa_no
    bcc _daa_no
_daa_do:
    lda dC
    clc
    adc #$0060
    and #$00FF
    sta dC
    lda fSTATIC
    ora #$0001
    sta fSTATIC
    bra _daa_fin
_daa_no:
    lda fSTATIC
    and #$FFFE
    sta fSTATIC
_daa_fin:
    lda dC
    sep #$20
    sta gAX
    rep #$20
    ; SZP of result
    lda fSTATIC
    and #$FF3B               ; clear SF,ZF,PF
    sta tmp2
    lda dC
    sta lfR
    jsr szp8_f
    lda tmp2
    sta fSTATIC
    jmp step_next

op2F:                        ; DAS
    jsr flags_norm
    lda gAX
    and #$00FF
    sta dA
    lda fSTATIC
    and #$0001
    sta dCY
    lda fSTATIC
    and #F_AF
    sta dB2
    lda #$0099
    ldx dB2
    beq _das_t
    lda #$009F
_das_t:
    sta dB
    ; undefined OF (four AF/CF cases)
    lda fSTATIC
    and #$F7FF
    sta fSTATIC
    ldx dB2
    bne _das_af1
    ldx dCY
    bne _das_a0c1
    lda dA                   ; AF=0 CF=0: 0x9A-0xDF
    cmp #$009A
    bcc _das_ofd
    cmp #$00E0
    bcs _das_ofd
    bra _das_ofset
_das_a0c1:
    lda dA                   ; AF=0 CF=1: 0x80-0xDF
    cmp #$0080
    bcc _das_ofd
    cmp #$00E0
    bcs _das_ofd
    bra _das_ofset
_das_af1:
    ldx dCY
    bne _das_a1c1
    lda dA                   ; AF=1 CF=0: 0x80-0x85 | 0xA0-0xE5
    cmp #$0080
    bcc _das_ofd
    cmp #$0086
    bcc _das_ofset
    cmp #$00A0
    bcc _das_ofd
    cmp #$00E6
    bcs _das_ofd
    bra _das_ofset
_das_a1c1:
    lda dA                   ; AF=1 CF=1: 0x80-0xE5
    cmp #$0080
    bcc _das_ofd
    cmp #$00E6
    bcs _das_ofd
_das_ofset:
    lda fSTATIC
    ora #F_OF
    sta fSTATIC
_das_ofd:
    lda dA
    sta dC
    and #$000F
    cmp #$000A
    bcs _das_lo
    ldx dB2
    bne _das_lo
    lda fSTATIC
    and #$FFEF
    sta fSTATIC
    bra _das_hi
_das_lo:
    lda dC
    sec
    sbc #6
    and #$00FF
    sta dC
    lda fSTATIC
    ora #F_AF
    sta fSTATIC
_das_hi:
    ldx dCY
    bne _das_do
    lda dA
    cmp dB
    beq _das_no
    bcc _das_no
_das_do:
    lda dC
    sec
    sbc #$0060
    and #$00FF
    sta dC
    lda fSTATIC
    ora #$0001
    sta fSTATIC
    bra _das_fin
_das_no:
    lda fSTATIC
    and #$FFFE
    sta fSTATIC
_das_fin:
    lda dC
    sep #$20
    sta gAX
    rep #$20
    lda fSTATIC
    and #$FF3B
    sta tmp2
    lda dC
    sta lfR
    jsr szp8_f
    lda tmp2
    sta fSTATIC
    jmp step_next

op37:                        ; AAA
    jsr flags_norm
    lda gAX
    and #$00FF
    sta dA                   ; old AL
    and #$000F
    cmp #$000A
    bcs _aaa_adj
    lda fSTATIC
    and #F_AF
    bne _aaa_adj
    lda dA
    sta dC                   ; new_al = old
    lda fSTATIC
    and #$FFEE               ; AF=CF=0
    sta fSTATIC
    bra _aaa_fl
_aaa_adj:
    sep #$20
    lda gAX+1
    inc a
    sta gAX+1                ; AH += 1 (no carry from AL)
    rep #$20
    lda dA
    clc
    adc #6
    and #$00FF
    sta dC
    lda fSTATIC
    ora #$0011               ; AF=CF=1
    sta fSTATIC
_aaa_fl:
    lda dC
    and #$000F
    sep #$20
    sta gAX
    rep #$20
    ; undefined flags from hardware: ZF/PF from pre-mask AL, SF/OF ranges
    lda fSTATIC
    and #$F73B               ; clear OF,SF,ZF,PF
    sta tmp2
    lda dC
    and #$00FF
    bne _aaa_nz
    lda tmp2
    ora #F_ZF
    sta tmp2
_aaa_nz:
    lda dC
    and #$00FF
    tax
    sep #$20
    lda.l pf_tab,x
    rep #$20
    and #$00FF
    ora tmp2
    sta tmp2
    lda dA
    cmp #$007A
    bcc _aaa_st
    cmp #$00FA
    bcs _aaa_st
    lda tmp2
    ora #F_SF
    sta tmp2
    lda dA
    cmp #$0080
    bcs _aaa_st
    lda tmp2
    ora #F_OF
    sta tmp2
_aaa_st:
    lda tmp2
    sta fSTATIC
    jmp step_next

op3F:                        ; AAS
    jsr flags_norm
    lda gAX
    and #$00FF
    sta dA
    lda fSTATIC
    and #F_AF
    sta dB2                  ; old AF
    lda dA
    and #$000F
    cmp #$000A
    bcs _aas_adj
    ldx dB2
    bne _aas_adj
    lda dA
    sta dC
    lda fSTATIC
    and #$FFEE
    sta fSTATIC
    bra _aas_fl
_aas_adj:
    sep #$20
    lda gAX+1
    dec a
    sta gAX+1
    rep #$20
    lda dA
    sec
    sbc #6
    and #$00FF
    sta dC
    lda fSTATIC
    ora #$0011
    sta fSTATIC
_aas_fl:
    lda dC
    and #$000F
    sep #$20
    sta gAX
    rep #$20
    lda fSTATIC
    and #$F73B
    sta tmp2
    lda dC
    and #$00FF
    bne _aas_nz
    lda tmp2
    ora #F_ZF
    sta tmp2
_aas_nz:
    lda dC
    and #$00FF
    tax
    sep #$20
    lda.l pf_tab,x
    rep #$20
    and #$00FF
    ora tmp2
    sta tmp2
    ; OF: old_af && 0x80-0x85 ; SF: (!af && >=0x80) || (af && (<=5 || >=0x86))
    ldx dB2
    beq _aas_noaf
    lda dA
    cmp #$0080
    bcc _aas_sf_lo
    cmp #$0086
    bcs _aas_sf_hi
    lda tmp2
    ora #F_OF
    sta tmp2
    bra _aas_st
_aas_sf_lo:
    lda dA
    cmp #$0006
    bcs _aas_st
    lda tmp2
    ora #F_SF
    sta tmp2
    bra _aas_st
_aas_sf_hi:
    lda tmp2
    ora #F_SF
    sta tmp2
    bra _aas_st
_aas_noaf:
    lda dA
    cmp #$0080
    bcc _aas_st
    lda tmp2
    ora #F_SF
    sta tmp2
_aas_st:
    lda tmp2
    sta fSTATIC
    jmp step_next

opD4:                        ; AAM imm8 — divides AL via CORD
    lda [bCS],y
    iny
    and #$00FF
    sta dB
    stz dA
    lda gAX
    and #$00FF
    sta dC
    jsr cord8
    bcs _aam_err
    lda dC
    eor #$00FF
    sep #$20
    sta gAX+1                ; AH = quotient
    rep #$20
    lda dA
    sep #$20
    sta gAX                  ; AL = remainder
    rep #$20
    lda dA
    and #$00FF
    sta lfR
    lda #LF_LOG8             ; SZP from AL, CF/AF/OF = 0
    sta lfKIND
    jmp step_next
_aam_err:
    stz lfR
    lda #LF_LOG8
    sta lfKIND
    lda #0
    jsr do_int
    jmp step_next

opD5:                        ; AAD imm8: AL = AH*imm + AL (add8 flags)
    lda [bCS],y
    iny
    and #$00FF
    sta mB
    lda gAX
    xba
    and #$00FF
    sta mA
    jsr mulu16
    lda mLO
    and #$00FF
    sta lfA
    lda gAX
    and #$00FF
    sta lfB
    jsr alu_add8
    lda lfR
    sep #$20
    sta gAX
    rep #$20
    sep #$20
    stz gAX+1
    rep #$20
    jmp step_next

;----------------------------------------------------------------------
; misc
;----------------------------------------------------------------------
op98:                        ; CBW
    lda gAX
    and #$0080
    beq _cbw_p
    sep #$20
    lda #$FF
    sta gAX+1
    rep #$20
    jmp step_next
_cbw_p:
    sep #$20
    stz gAX+1
    rep #$20
    jmp step_next

op99:                        ; CWD
    lda gAX
    and #$8000
    beq _cwd_p
    lda #$FFFF
    sta gDX
    jmp step_next
_cwd_p:
    stz gDX
    jmp step_next

op9B:                        ; WAIT
    jmp step_next

op9C:                        ; PUSHF
    jsr flags_norm
    lda fSTATIC
    jsr push16v
    jmp step_next

op9D:                        ; POPF
    jsr pop16v
    and #$0FD5
    ora #$F002
    sta fSTATIC
    stz lfKIND
    jmp step_next

op9E:                        ; SAHF
    jsr flags_norm
    lda gAX
    xba
    and #$00FF
    sta tmp0
    lda fSTATIC
    and #$FF00
    ora tmp0
    and #$0FD5
    ora #$F002
    sta fSTATIC
    jmp step_next

op9F:                        ; LAHF
    jsr flags_norm
    sep #$20
    lda fSTATIC
    sta gAX+1
    rep #$20
    jmp step_next

opD6:                        ; SALC (undocumented)
    jsr cf_to_carry
    bcs _salc_1
    sep #$20
    stz gAX
    rep #$20
    jmp step_next
_salc_1:
    sep #$20
    lda #$FF
    sta gAX
    rep #$20
    jmp step_next

opD7:                        ; XLAT
    jsr seg_src_x
    lda gAX
    and #$00FF
    clc
    adc gBX
    jsr mk_ptr
    sep #$20
    lda [mPTR]
    sta gAX
    rep #$20
    jmp step_next

opESC:                       ; D8-DF: decode ModRM, do nothing
    jsr decode_modrm
    jmp step_next

; IN/OUT: no real devices. Exception: the CGA/MDA status ports
; ($3DA/$3BA) must show toggling retrace bits, or programs that poll them
; for snow avoidance (WordStar, Multiplan) spin forever. Free-running
; toggle from ioTOG satisfies "wait for set" and "wait for clear".
io_in8:                      ; A = port(16b) -> A = byte (0-extended)
.IFDEF DOSBIOS
    cmp #$03DA
    beq _io_status
    cmp #$03BA
    beq _io_status
    cmp #$0060
    beq _io_kbd
    cmp #$0061
    beq _io_p61
    cmp #$0331
    beq _io_mst
.IFDEF ELKS
    cmp #$0064
    beq _io_p64
.ENDIF
.ENDIF
    lda #$00FF
    rts
.IFDEF ELKS
_io_p64:                     ; KBC status: idle. $FF reads as "always
    lda #$0000               ; busy" and ELKS's A20/8042 probe spins.
    rts
.ENDIF
.IFDEF DOSBIOS
_io_mst:
    jmp midi_stat            ; free packet slots (SNES-MIDI interface)
.ENDIF
.IFDEF DOSBIOS
_io_status:
    inc ioTOG
    lda ioTOG
    and #$000F               ; bit0=Hretrace, bit3=Vretrace both cycle
    rts
_io_kbd:                     ; port 60h: last scancode (INT9/raw readers)
    lda.w s60                ; .w! a forward ENUM ref assembles as DIRECT
    and #$00FF               ; PAGE otherwise (reads core DP scratch $BA)
    rts
_io_p61:                     ; 8255 port B
    lda #$0000
    rts
.ENDIF

; word IN: low from port, high from port+1 (both $FF with no device),
; matching the C core's two in8() calls.
io_in16:                     ; A = port -> A = word
    pha
    jsr io_in8
    sta tmp2
    pla
    inc a
    jsr io_in8
    xba
    and #$FF00
    ora tmp2
    rts

; IN/OUT: no devices — IN reads $FF, OUT is a byte sink (matches the
; C core with null io hooks, which is how x86trace runs)
opE4:                        ; IN AL, imm8
    lda [bCS],y
    iny
    and #$00FF
    jsr io_in8
    sep #$20
    sta gAX
    rep #$20
    jmp step_next
opE5:                        ; IN AX, imm8
    lda [bCS],y
    iny
    and #$00FF
    jsr io_in16
    sta gAX
    jmp step_next
opE6:                        ; OUT imm8, AL
    lda [bCS],y
    iny
    sty gIP
    and #$00FF
    tax
    lda gAX
    jsr io_out8
    jmp step_next
opE7:                        ; OUT imm8, AX
    lda [bCS],y
    iny
    sty gIP
    and #$00FF
    tax
    lda gAX
    jsr io_out16
    jmp step_next
opEC:                        ; IN AL, DX
    lda gDX
    jsr io_in8
    sep #$20
    sta gAX
    rep #$20
    jmp step_next
opED:
    lda gDX
    jsr io_in16
    sta gAX
    jmp step_next
opEE:                        ; OUT DX, AL
    sty gIP
    lda gDX
    tax
    lda gAX
    jsr io_out8
    jmp step_next
opEF:                        ; OUT DX, AX
    sty gIP
    lda gDX
    tax
    lda gAX
    jsr io_out16
    jmp step_next

io_out8:                     ; X = port, A = value (low byte); preserves Y
.IFDEF DOSBIOS
    jmp spk_out              ; PIT/speaker hooks live in dosboot.asm
.ELSE
    rts                      ; byte sink, matching the hookless C core
.ENDIF
io_out16:                    ; X = port, A = word: lo -> port, hi -> port+1
    pha
    jsr io_out8
    pla
    xba
    inx
    jmp io_out8

.ENDS
