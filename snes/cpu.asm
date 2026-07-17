; snes86 — 8086 CPU core in 65816 assembly (M4 skeleton).
;
; Execution model:
;   - native mode, A/X/Y 16-bit unless noted, D=$0000, DBR=$7E
;   - guest memory: linear 0x00000-0x0DFFF lives at $7E:2000-$7E:FFFF
;     (M4 constraint: guests must stay under 56 KB linear; the $7F spill
;     for the full ~90 KB arrives with M5)
;   - guest registers live in direct page, 8086 register order, gAX at
;     DP $00 so a ModRM reg field *2 IS the DP offset
;   - cached segment bases: bXX = $2000 + seg*16 = the 16-bit SNES address
;     of the segment start inside bank $7E; memory access is one 16-bit
;     add + a (dp) indirect. Rewritten whenever a segment register loads.
;   - Y holds the guest IP from fetch to handler end (sty gIP; rts)
;   - dispatch: opcode*2 -> jmp (optable,x), table in the code bank
;
; Lazy flags: ALU handlers store operands/result/carry-out + a kind code;
; flags_norm materializes the full 8086 FLAGS word into fSTATIC on demand
; (Jcc, PUSHF-of-the-future, snapshots). CF alone has a fast path since
; ADC/SBB/INC/DEC need it constantly. Formulas match core-c/src/x86.c
; bit for bit — that C core is the oracle this port is diffed against.

.DEFINE GUEST_BASE $2000     ; SNES addr of guest linear 0 in bank $7E

; lazy-flag kinds (word values, double as norm_tab jump index)
.DEFINE LF_NONE  0
.DEFINE LF_ADD8  2
.DEFINE LF_ADD16 4
.DEFINE LF_SUB8  6
.DEFINE LF_SUB16 8
.DEFINE LF_LOG8  10
.DEFINE LF_LOG16 12

; 8086 FLAGS bits
.DEFINE F_CF $0001
.DEFINE F_PF $0004
.DEFINE F_AF $0010
.DEFINE F_ZF $0040
.DEFINE F_SF $0080
.DEFINE F_IF $0200
.DEFINE F_DF $0400
.DEFINE F_OF $0800
.DEFINE F_KEEP $F72A         ; bits not produced by the ALU (IF,DF,TF,fixed)

.ENUM $0000
gAX      dw                  ; 8086 order — reg field *2 = DP offset
gCX      dw
gDX      dw
gBX      dw
gSP      dw
gBP      dw
gSI      dw
gDI      dw
gES      dw                  ; seg field *2 + 16 = DP offset
gCS      dw
gSS      dw
gDS      dw
bES      ds 3                ; cached 24-bit bases: $7E2000 + seg*16
bCS      ds 3                ; (base DP off = 24 + (segoff-16)/2*3)
bSS      ds 3
bDS      ds 3
gIP      dw
gHALT    dw
fSTATIC  dw                  ; full FLAGS; arith bits valid when LF_NONE
lfKIND   dw
lfA      dw
lfB      dw
lfR      dw
lfCF     dw                  ; carry-out of last ALU op (bit 0)
aluIDX   dw                  ; alu op *2 for grouped handlers
mISREG   dw                  ; ModRM: rm is a register
mREG     dw                  ; DP offset of reg operand
mRM      dw                  ; DP offset of rm operand (when mISREG)
mOFF     dw                  ; raw 16-bit EA offset (LEA)
mPTR     ds 3                ; 24-bit SNES pointer to the EA
tmp0     dw
tmp1     dw
tmp2     dw
snapPTR  dw
stepCNT  dw
ioTOG    dw                  ; free-running CGA/MDA retrace toggle
ovSEG    dw                  ; seg override: 0 or DP offset of base (bXX)
pREP     dw                  ; REP prefix: 0 none, 1 F3, 2 F2
mPTR2    ds 3                ; second 24-bit pointer (string destination)
sCNT     dw                  ; grp2 state
sVAL     dw
sCF      dw
sOF      dw
mA       dw                  ; multiply state
mB       dw
mLO      dw
mHI      dw
dA       dw                  ; divide state (CORD)
dB       dw
dC       dw
dCY      dw
dNEG     dw
dMSB     dw
dB2      dw
dQ       dw
dINT     dw
.ENDE

;======================================================================
.BANK 0 SLOT 0
.ORG 0
.SECTION "CpuCore" SEMIFREE

.ACCU 16
.INDEX 16

;----------------------------------------------------------------------
; one guest instruction. entry: A/X/Y 16-bit.
;----------------------------------------------------------------------
x86step:                     ; single-step entry (trace/parity harness)
    lda gHALT
    bne _step_halted
    ldy gIP
step_lean:                   ; hot entry: Y = IP, maintained by handlers
    stz ovSEG                ; (every handler ends sty gIP with Y intact,
    stz pREP                 ; so the run loop skips the reload+halt check)
step_fetch:
    lda [bCS],y
    iny
    and #$00FF
    asl a
    tax
    jmp (optable,x)
_step_halted:
    rts

op_bad:
    ; unimplemented opcode: flag it for the harness and freeze
    dey
    sty gIP
    lda [bCS],y
    and #$00FF
    sta.l $7FFFFE
    lda #$0BAD
    sta.l $7FFFFC
_op_bad_hang:
    bra _op_bad_hang

;----------------------------------------------------------------------
; instruction stream fetch helpers (Y = IP)
;----------------------------------------------------------------------
fetch_d8s:                   ; A = sign-extended byte
    lda [bCS],y
    iny
    and #$00FF
    cmp #$0080
    bcc _fd8_pos
    ora #$FF00
_fd8_pos:
    rts

;----------------------------------------------------------------------
; ModRM decode. entry: Y at modrm byte. exit: Y past displacement,
; mREG = reg*2, and either mISREG=1/mRM=rm*2 or mISREG=0/mOFF/mPTR.
;----------------------------------------------------------------------
decode_modrm:
    lda [bCS],y
    iny
    and #$00FF
    sta tmp0
    and #$0038
    lsr a
    lsr a
    sta mREG
    lda tmp0
    and #$00C0
    lsr a
    lsr a
    lsr a                    ; mod << 3
    sta tmp1
    lda tmp0
    and #$0007
    ora tmp1
    asl a
    tax
    jmp (ea_tab,x)

; --- mod=3: register operand
_ea_reg:
    lda #1
    sta mISREG
    lda tmp0
    and #$0007
    asl a
    sta mRM
    rts

; --- shared EA tails
_ea_fin_ds:                  ; A = offset, DS segment (overridable)
    sta mOFF
    ldx ovSEG
    bne _ea_fin_go
    ldx #33                  ; bDS
_ea_fin_go:
    jsr mk_ptr
    stz mISREG
    rts
_ea_fin_ss:                  ; A = offset, SS segment (overridable)
    sta mOFF
    ldx ovSEG
    bne _ea_fin_go
    ldx #30                  ; bSS
    bra _ea_fin_go

; A = 16-bit offset, X = DP offset of a 3-byte base -> mPTR (24-bit)
mk_ptr:
    clc
    adc.b 0,x
    sta mPTR
    sep #$20
    lda.b 2,x
    adc #0
    sta mPTR+2
    rep #$20
    rts

mk_ptr2:
    clc
    adc.b 0,x
    sta mPTR2
    sep #$20
    lda.b 2,x
    adc #0
    sta mPTR2+2
    rep #$20
    rts

; --- mod=0
_ea00_0:                     ; [BX+SI]
    lda gBX
    clc
    adc gSI
    jmp _ea_fin_ds
_ea00_1:                     ; [BX+DI]
    lda gBX
    clc
    adc gDI
    jmp _ea_fin_ds
_ea00_2:                     ; [BP+SI]
    lda gBP
    clc
    adc gSI
    jmp _ea_fin_ss
_ea00_3:                     ; [BP+DI]
    lda gBP
    clc
    adc gDI
    jmp _ea_fin_ss
_ea00_4:                     ; [SI]
    lda gSI
    jmp _ea_fin_ds
_ea00_5:                     ; [DI]
    lda gDI
    jmp _ea_fin_ds
_ea00_6:                     ; [disp16]
    lda [bCS],y
    iny
    iny
    jmp _ea_fin_ds
_ea00_7:                     ; [BX]
    lda gBX
    jmp _ea_fin_ds

; --- mod=1: +disp8 (sign-extended)
_ea01_0:
    jsr fetch_d8s
    clc
    adc gBX
    clc
    adc gSI
    jmp _ea_fin_ds
_ea01_1:
    jsr fetch_d8s
    clc
    adc gBX
    clc
    adc gDI
    jmp _ea_fin_ds
_ea01_2:
    jsr fetch_d8s
    clc
    adc gBP
    clc
    adc gSI
    jmp _ea_fin_ss
_ea01_3:
    jsr fetch_d8s
    clc
    adc gBP
    clc
    adc gDI
    jmp _ea_fin_ss
_ea01_4:
    jsr fetch_d8s
    clc
    adc gSI
    jmp _ea_fin_ds
_ea01_5:
    jsr fetch_d8s
    clc
    adc gDI
    jmp _ea_fin_ds
_ea01_6:                     ; [BP+disp8]
    jsr fetch_d8s
    clc
    adc gBP
    jmp _ea_fin_ss
_ea01_7:
    jsr fetch_d8s
    clc
    adc gBX
    jmp _ea_fin_ds

; --- mod=2: +disp16
_ea10_0:
    lda [bCS],y
    iny
    iny
    clc
    adc gBX
    clc
    adc gSI
    jmp _ea_fin_ds
_ea10_1:
    lda [bCS],y
    iny
    iny
    clc
    adc gBX
    clc
    adc gDI
    jmp _ea_fin_ds
_ea10_2:
    lda [bCS],y
    iny
    iny
    clc
    adc gBP
    clc
    adc gSI
    jmp _ea_fin_ss
_ea10_3:
    lda [bCS],y
    iny
    iny
    clc
    adc gBP
    clc
    adc gDI
    jmp _ea_fin_ss
_ea10_4:
    lda [bCS],y
    iny
    iny
    clc
    adc gSI
    jmp _ea_fin_ds
_ea10_5:
    lda [bCS],y
    iny
    iny
    clc
    adc gDI
    jmp _ea_fin_ds
_ea10_6:
    lda [bCS],y
    iny
    iny
    clc
    adc gBP
    jmp _ea_fin_ss
_ea10_7:
    lda [bCS],y
    iny
    iny
    clc
    adc gBX
    jmp _ea_fin_ds

ea_tab:
    .dw _ea00_0, _ea00_1, _ea00_2, _ea00_3, _ea00_4, _ea00_5, _ea00_6, _ea00_7
    .dw _ea01_0, _ea01_1, _ea01_2, _ea01_3, _ea01_4, _ea01_5, _ea01_6, _ea01_7
    .dw _ea10_0, _ea10_1, _ea10_2, _ea10_3, _ea10_4, _ea10_5, _ea10_6, _ea10_7
    .dw _ea_reg, _ea_reg, _ea_reg, _ea_reg, _ea_reg, _ea_reg, _ea_reg, _ea_reg

; remap a reg*2 word offset to the byte-register DP offset
; (AL CL DL BL AH CH DH BH -> 0 2 4 6 1 3 5 7)
fixup8:
    ldx mREG
    lda.l regoff8w,x
    sta mREG
    lda mISREG
    beq _f8_done
    ldx mRM
    lda.l regoff8w,x
    sta mRM
_f8_done:
    rts

regoff8w:
    .dw 0, 2, 4, 6, 1, 3, 5, 7

;----------------------------------------------------------------------
; rm operand access
;----------------------------------------------------------------------
rm_read16:
    lda mISREG
    bne _rr16_reg
    lda [mPTR]
    rts
_rr16_reg:
    ldx mRM
    lda.b 0,x
    rts

rm_write16:                  ; A = value
    ldx mISREG
    bne _rw16_reg
    sta [mPTR]
    rts
_rw16_reg:
    ldx mRM
    sta.b 0,x
    rts

rm_read8:                    ; A = zero-extended byte
    lda mISREG
    bne _rr8_reg
    lda [mPTR]
    and #$00FF
    rts
_rr8_reg:
    ldx mRM
    lda.b 0,x
    and #$00FF
    rts

rm_write8:                   ; A = byte value (low 8 bits)
    ldx mISREG
    bne _rw8_reg
    sep #$20
    sta [mPTR]
    rep #$20
    rts
_rw8_reg:
    ldx mRM
    sep #$20
    sta.b 0,x
    rep #$20
    rts

;----------------------------------------------------------------------
; flags
;----------------------------------------------------------------------
; set 65816 carry = guest CF (A clobbered)
cf_to_carry:
    lda lfKIND
    beq _cfc_static
    cmp #LF_LOG8
    bcs _cfc_zero
    lda lfCF
    lsr a
    rts
_cfc_static:
    lda fSTATIC
    lsr a
    rts
_cfc_zero:
    clc
    rts

; set 65816 carry = NOT guest CF (for SBB borrow seeding)
cf_to_carry_inv:
    jsr cf_to_carry
    rol a                    ; put CF back in bit 0 of A
    eor #$0001
    lsr a
    rts

; make lfCF hold the current guest CF without full materialization
; (INC/DEC preserve CF across a new ADD/SUB kind). A clobbered, X safe.
save_cf:
    lda lfKIND
    beq _scf_static
    cmp #LF_LOG8
    bcs _scf_zero
    rts                      ; ADD/SUB kinds: lfCF already correct
_scf_static:
    lda fSTATIC
    and #$0001
    sta lfCF
    rts
_scf_zero:
    stz lfCF
    rts

; materialize FLAGS into fSTATIC, set kind = NONE
flags_norm:
    ldx lfKIND
    bne _fn_go
    rts
_fn_go:
    lda fSTATIC
    and #F_KEEP
    sta tmp2
    jmp (norm_tab,x)

norm_tab:
    .dw fn_ret              ; LF_NONE (unreachable)
    .dw norm_add8
    .dw norm_add16
    .dw norm_sub8
    .dw norm_sub16
    .dw norm_log8
    .dw norm_log16

fn_ret:
    rts

; --- shared: SZP for 8/16-bit results, OR'd into tmp2
szp8_f:
    lda lfR
    and #$00FF
    bne _szp8_nz
    lda tmp2
    ora #F_ZF
    sta tmp2
_szp8_nz:
    lda lfR
    and #$0080
    beq _szp8_np
    lda tmp2
    ora #F_SF
    sta tmp2
_szp8_np:
    bra pf_common
szp16_f:
    lda lfR
    bne _szp16_nz
    lda tmp2
    ora #F_ZF
    sta tmp2
_szp16_nz:
    lda lfR
    and #$8000
    beq pf_common
    lda tmp2
    ora #F_SF
    sta tmp2
pf_common:
    lda lfR
    and #$00FF
    tax
    sep #$20
    lda.l pf_tab,x
    rep #$20
    and #$00FF
    ora tmp2
    sta tmp2
    rts

; --- CF + AF, OR'd into tmp2 (add/sub kinds)
cf_af_f:
    lda lfCF
    and #$0001
    ora tmp2
    sta tmp2
    lda lfA
    eor lfB
    eor lfR
    and #F_AF
    ora tmp2
    sta tmp2
    rts

norm_add8:
    jsr szp8_f
    jsr cf_af_f
    lda lfA
    eor lfB
    eor #$FFFF
    sta tmp1
    lda lfA
    eor lfR
    and tmp1
    and #$0080
    beq _na8_done
    lda tmp2
    ora #F_OF
    sta tmp2
_na8_done:
    jmp fn_commit

norm_add16:
    jsr szp16_f
    jsr cf_af_f
    lda lfA
    eor lfB
    eor #$FFFF
    sta tmp1
    lda lfA
    eor lfR
    and tmp1
    and #$8000
    beq _na16_done
    lda tmp2
    ora #F_OF
    sta tmp2
_na16_done:
    jmp fn_commit

norm_sub8:
    jsr szp8_f
    jsr cf_af_f
    lda lfA
    eor lfB
    sta tmp1
    lda lfA
    eor lfR
    and tmp1
    and #$0080
    beq _ns8_done
    lda tmp2
    ora #F_OF
    sta tmp2
_ns8_done:
    jmp fn_commit

norm_sub16:
    jsr szp16_f
    jsr cf_af_f
    lda lfA
    eor lfB
    sta tmp1
    lda lfA
    eor lfR
    and tmp1
    and #$8000
    beq _ns16_done
    lda tmp2
    ora #F_OF
    sta tmp2
_ns16_done:
    jmp fn_commit

norm_log8:
    jsr szp8_f
    jmp fn_commit
norm_log16:
    jsr szp16_f
    jmp fn_commit

fn_commit:
    lda tmp2
    sta fSTATIC
    stz lfKIND
    rts

;----------------------------------------------------------------------
; ALU executors: lfA/lfB set by caller; produce lfR/lfCF/lfKIND.
; index: (aluop)*2 -> ADD OR ADC SBB AND SUB XOR CMP
;----------------------------------------------------------------------
alu16_tab:
    .dw alu_add16, alu_or16, alu_adc16, alu_sbb16
    .dw alu_and16, alu_sub16, alu_xor16, alu_sub16   ; CMP shares SUB
alu8_tab:
    .dw alu_add8, alu_or8, alu_adc8, alu_sbb8
    .dw alu_and8, alu_sub8, alu_xor8, alu_sub8

alu_add16:
    clc
    bra a16_add
alu_adc16:
    jsr cf_to_carry
a16_add:
    lda lfA
    adc lfB
    sta lfR
    lda #0
    rol a
    sta lfCF
    lda #LF_ADD16
    sta lfKIND
    rts

alu_sub16:
    sec
    bra a16_sub
alu_sbb16:
    jsr cf_to_carry_inv
a16_sub:
    lda lfA
    sbc lfB
    sta lfR
    lda #0
    rol a
    eor #$0001               ; 65816 C=1 means no borrow; guest CF = borrow
    sta lfCF
    lda #LF_SUB16
    sta lfKIND
    rts

alu_or16:
    lda lfA
    ora lfB
    bra a16_log
alu_and16:
    lda lfA
    and lfB
    bra a16_log
alu_xor16:
    lda lfA
    eor lfB
a16_log:
    sta lfR
    lda #LF_LOG16
    sta lfKIND
    rts

alu_add8:
    clc
    bra a8_add
alu_adc8:
    jsr cf_to_carry
a8_add:
    lda lfA
    adc lfB                  ; operands are masked; bit 8 = carry out
    sta lfR
    and #$0100
    beq _a8a_nc
    lda #1
_a8a_nc:
    sta lfCF
    lda lfR
    and #$00FF
    sta lfR
    lda #LF_ADD8
    sta lfKIND
    rts

alu_sub8:
    sec
    bra a8_sub
alu_sbb8:
    jsr cf_to_carry_inv
a8_sub:
    lda lfA
    sbc lfB
    sta lfR
    lda #0
    rol a
    eor #$0001
    sta lfCF
    lda lfR
    and #$00FF
    sta lfR
    lda #LF_SUB8
    sta lfKIND
    rts

alu_or8:
    lda lfA
    ora lfB
    bra a8_log
alu_and8:
    lda lfA
    and lfB
    bra a8_log
alu_xor8:
    lda lfA
    eor lfB
a8_log:
    sta lfR
    lda #LF_LOG8
    sta lfKIND
    rts

;----------------------------------------------------------------------
; grouped ALU forms (aluIDX = op*2, set by dispatch stubs)
;----------------------------------------------------------------------
form_rmr16:                  ; op rm16, r16
    jsr decode_modrm
    jsr rm_read16
    sta lfA
    ldx mREG
    lda.b 0,x
    sta lfB
    ldx aluIDX
    jsr (alu16_tab,x)
    lda aluIDX
    cmp #14                  ; CMP: no writeback
    beq _frmr16_done
    lda lfR
    jsr rm_write16
_frmr16_done:
    sty gIP
    rts

form_rrm16:                  ; op r16, rm16
    jsr decode_modrm
    jsr rm_read16
    sta lfB
    ldx mREG
    lda.b 0,x
    sta lfA
    ldx aluIDX
    jsr (alu16_tab,x)
    lda aluIDX
    cmp #14
    beq _frrm16_done
    ldx mREG
    lda lfR
    sta.b 0,x
_frrm16_done:
    sty gIP
    rts

form_rmr8:                   ; op rm8, r8
    jsr decode_modrm
    jsr fixup8
    jsr rm_read8
    sta lfA
    ldx mREG
    lda.b 0,x
    and #$00FF
    sta lfB
    ldx aluIDX
    jsr (alu8_tab,x)
    lda aluIDX
    cmp #14
    beq _frmr8_done
    lda lfR
    jsr rm_write8
_frmr8_done:
    sty gIP
    rts

form_rrm8:                   ; op r8, rm8
    jsr decode_modrm
    jsr fixup8
    jsr rm_read8
    sta lfB
    ldx mREG
    lda.b 0,x
    and #$00FF
    sta lfA
    ldx aluIDX
    jsr (alu8_tab,x)
    lda aluIDX
    cmp #14
    beq _frrm8_done
    ldx mREG
    lda lfR
    sep #$20
    sta.b 0,x
    rep #$20
_frrm8_done:
    sty gIP
    rts

form_ali8:                   ; op AL, imm8
    lda [bCS],y
    iny
    and #$00FF
    sta lfB
    lda gAX
    and #$00FF
    sta lfA
    ldx aluIDX
    jsr (alu8_tab,x)
    lda aluIDX
    cmp #14
    beq _fali8_done
    lda lfR
    sep #$20
    sta gAX
    rep #$20
_fali8_done:
    sty gIP
    rts

form_axi16:                  ; op AX, imm16
    lda [bCS],y
    iny
    iny
    sta lfB
    lda gAX
    sta lfA
    ldx aluIDX
    jsr (alu16_tab,x)
    lda aluIDX
    cmp #14
    beq _faxi16_done
    lda lfR
    sta gAX
_faxi16_done:
    sty gIP
    rts

;----------------------------------------------------------------------
; ALU dispatch stubs: 00-3D block
;----------------------------------------------------------------------

op00: ldx #0
      stx aluIDX
      jmp form_rmr8
op01: ldx #0
      stx aluIDX
      jmp form_rmr16
op02: ldx #0
      stx aluIDX
      jmp form_rrm8
op03: ldx #0
      stx aluIDX
      jmp form_rrm16
op04: ldx #0
      stx aluIDX
      jmp form_ali8
op05: ldx #0
      stx aluIDX
      jmp form_axi16

op08: ldx #2
      stx aluIDX
      jmp form_rmr8
op09: ldx #2
      stx aluIDX
      jmp form_rmr16
op0A: ldx #2
      stx aluIDX
      jmp form_rrm8
op0B: ldx #2
      stx aluIDX
      jmp form_rrm16
op0C: ldx #2
      stx aluIDX
      jmp form_ali8
op0D: ldx #2
      stx aluIDX
      jmp form_axi16

op10: ldx #4
      stx aluIDX
      jmp form_rmr8
op11: ldx #4
      stx aluIDX
      jmp form_rmr16
op12: ldx #4
      stx aluIDX
      jmp form_rrm8
op13: ldx #4
      stx aluIDX
      jmp form_rrm16
op14: ldx #4
      stx aluIDX
      jmp form_ali8
op15: ldx #4
      stx aluIDX
      jmp form_axi16

op18: ldx #6
      stx aluIDX
      jmp form_rmr8
op19: ldx #6
      stx aluIDX
      jmp form_rmr16
op1A: ldx #6
      stx aluIDX
      jmp form_rrm8
op1B: ldx #6
      stx aluIDX
      jmp form_rrm16
op1C: ldx #6
      stx aluIDX
      jmp form_ali8
op1D: ldx #6
      stx aluIDX
      jmp form_axi16

op20: ldx #8
      stx aluIDX
      jmp form_rmr8
op21: ldx #8
      stx aluIDX
      jmp form_rmr16
op22: ldx #8
      stx aluIDX
      jmp form_rrm8
op23: ldx #8
      stx aluIDX
      jmp form_rrm16
op24: ldx #8
      stx aluIDX
      jmp form_ali8
op25: ldx #8
      stx aluIDX
      jmp form_axi16

op28: ldx #10
      stx aluIDX
      jmp form_rmr8
op29: ldx #10
      stx aluIDX
      jmp form_rmr16
op2A: ldx #10
      stx aluIDX
      jmp form_rrm8
op2B: ldx #10
      stx aluIDX
      jmp form_rrm16
op2C: ldx #10
      stx aluIDX
      jmp form_ali8
op2D: ldx #10
      stx aluIDX
      jmp form_axi16

op30: ldx #12
      stx aluIDX
      jmp form_rmr8
op31: ldx #12
      stx aluIDX
      jmp form_rmr16
op32: ldx #12
      stx aluIDX
      jmp form_rrm8
op33: ldx #12
      stx aluIDX
      jmp form_rrm16
op34: ldx #12
      stx aluIDX
      jmp form_ali8
op35: ldx #12
      stx aluIDX
      jmp form_axi16

op38: ldx #14
      stx aluIDX
      jmp form_rmr8
op39: ldx #14
      stx aluIDX
      jmp form_rmr16
op3A: ldx #14
      stx aluIDX
      jmp form_rrm8
op3B: ldx #14
      stx aluIDX
      jmp form_rrm16
op3C: ldx #14
      stx aluIDX
      jmp form_ali8
op3D: ldx #14
      stx aluIDX
      jmp form_axi16

;----------------------------------------------------------------------
; grp1: 80/82 rm8,imm8 — 81 rm16,imm16 — 83 rm16,imm8sx
;----------------------------------------------------------------------
op80:
    jsr decode_modrm
    ldx mREG                 ; reg*2 = aluop*2 — grab BEFORE fixup8
    stx aluIDX               ; rewrites mREG into a byte-reg offset
    jsr fixup8
    jsr rm_read8
    sta lfA
    lda [bCS],y
    iny
    and #$00FF
    sta lfB
    ldx aluIDX
    jsr (alu8_tab,x)
    lda aluIDX
    cmp #14
    beq _g80_done
    lda lfR
    jsr rm_write8
_g80_done:
    sty gIP
    rts

op81:
    jsr decode_modrm
    jsr rm_read16
    sta lfA
    lda [bCS],y
    iny
    iny
    sta lfB
    ldx mREG
    stx aluIDX
    jsr (alu16_tab,x)
    lda aluIDX
    cmp #14
    beq _g81_done
    lda lfR
    jsr rm_write16
_g81_done:
    sty gIP
    rts

op83:
    jsr decode_modrm
    jsr rm_read16
    sta lfA
    jsr fetch_d8s
    sta lfB
    ldx mREG
    stx aluIDX
    jsr (alu16_tab,x)
    lda aluIDX
    cmp #14
    beq _g83_done
    lda lfR
    jsr rm_write16
_g83_done:
    sty gIP
    rts

;----------------------------------------------------------------------
; TEST
;----------------------------------------------------------------------
op84:                        ; TEST rm8, r8
    jsr decode_modrm
    jsr fixup8
    jsr rm_read8
    sta lfA
    ldx mREG
    lda.b 0,x
    and #$00FF
    sta lfB
    ldx #8                   ; AND executor
    jsr (alu8_tab,x)
    sty gIP
    rts

op85:                        ; TEST rm16, r16
    jsr decode_modrm
    jsr rm_read16
    sta lfA
    ldx mREG
    lda.b 0,x
    sta lfB
    ldx #8
    jsr (alu16_tab,x)
    sty gIP
    rts

opA8:                        ; TEST AL, imm8
    lda [bCS],y
    iny
    and #$00FF
    sta lfB
    lda gAX
    and #$00FF
    sta lfA
    ldx #8
    jsr (alu8_tab,x)
    sty gIP
    rts

opA9:                        ; TEST AX, imm16
    lda [bCS],y
    iny
    iny
    sta lfB
    lda gAX
    sta lfA
    ldx #8
    jsr (alu16_tab,x)
    sty gIP
    rts

;----------------------------------------------------------------------
; XCHG
;----------------------------------------------------------------------
op86:                        ; XCHG r8, rm8
    jsr decode_modrm
    jsr fixup8
    jsr rm_read8
    sta tmp0
    ldx mREG
    lda.b 0,x
    jsr rm_write8
    ldx mREG
    lda tmp0
    sep #$20
    sta.b 0,x
    rep #$20
    sty gIP
    rts

op87:                        ; XCHG r16, rm16
    jsr decode_modrm
    jsr rm_read16
    sta tmp0
    ldx mREG
    lda.b 0,x
    jsr rm_write16
    ldx mREG
    lda tmp0
    sta.b 0,x
    sty gIP
    rts

op90:                        ; NOP (XCHG AX,AX)
    sty gIP
    rts
op91:
    lda gAX
    ldx gCX
    stx gAX
    sta gCX
    sty gIP
    rts
op92:
    lda gAX
    ldx gDX
    stx gAX
    sta gDX
    sty gIP
    rts
op93:
    lda gAX
    ldx gBX
    stx gAX
    sta gBX
    sty gIP
    rts
op94:
    lda gAX
    ldx gSP
    stx gAX
    sta gSP
    sty gIP
    rts
op95:
    lda gAX
    ldx gBP
    stx gAX
    sta gBP
    sty gIP
    rts
op96:
    lda gAX
    ldx gSI
    stx gAX
    sta gSI
    sty gIP
    rts
op97:
    lda gAX
    ldx gDI
    stx gAX
    sta gDI
    sty gIP
    rts

;----------------------------------------------------------------------
; MOV
;----------------------------------------------------------------------
op88:                        ; MOV rm8, r8
    jsr decode_modrm
    jsr fixup8
    ldx mREG
    lda.b 0,x
    jsr rm_write8
    sty gIP
    rts

op89:                        ; MOV rm16, r16
    jsr decode_modrm
    ldx mREG
    lda.b 0,x
    jsr rm_write16
    sty gIP
    rts

op8A:                        ; MOV r8, rm8
    jsr decode_modrm
    jsr fixup8
    jsr rm_read8
    ldx mREG
    sep #$20
    sta.b 0,x
    rep #$20
    sty gIP
    rts

op8B:                        ; MOV r16, rm16
    jsr decode_modrm
    jsr rm_read16
    ldx mREG
    sta.b 0,x
    sty gIP
    rts

op8D:                        ; LEA r16, m
    jsr decode_modrm
    ldx mREG
    lda mOFF
    sta.b 0,x
    sty gIP
    rts

opA0:                        ; MOV AL, [moffs16]
    lda [bCS],y
    iny
    iny
    sta tmp0
    jsr seg_src_x
    lda tmp0
    jsr mk_ptr
    lda [mPTR]
    sep #$20
    sta gAX
    rep #$20
    sty gIP
    rts

opA1:                        ; MOV AX, [moffs16]
    lda [bCS],y
    iny
    iny
    sta tmp0
    jsr seg_src_x
    lda tmp0
    jsr mk_ptr
    lda [mPTR]
    sta gAX
    sty gIP
    rts

opA2:                        ; MOV [moffs16], AL
    lda [bCS],y
    iny
    iny
    sta tmp0
    jsr seg_src_x
    lda tmp0
    jsr mk_ptr
    lda gAX
    sep #$20
    sta [mPTR]
    rep #$20
    sty gIP
    rts

opA3:                        ; MOV [moffs16], AX
    lda [bCS],y
    iny
    iny
    sta tmp0
    jsr seg_src_x
    lda tmp0
    jsr mk_ptr
    lda gAX
    sta [mPTR]
    sty gIP
    rts

; MOV r8, imm8 (byte fetch, byte store — 16-bit read then 8-bit store)
op_B0:
    lda [bCS],y
    iny
    sep #$20
    sta gAX
    rep #$20
    sty gIP
    rts
op_B1:
    lda [bCS],y
    iny
    sep #$20
    sta gCX
    rep #$20
    sty gIP
    rts
op_B2:
    lda [bCS],y
    iny
    sep #$20
    sta gDX
    rep #$20
    sty gIP
    rts
op_B3:
    lda [bCS],y
    iny
    sep #$20
    sta gBX
    rep #$20
    sty gIP
    rts
op_B4:
    lda [bCS],y
    iny
    sep #$20
    sta gAX+1
    rep #$20
    sty gIP
    rts
op_B5:
    lda [bCS],y
    iny
    sep #$20
    sta gCX+1
    rep #$20
    sty gIP
    rts
op_B6:
    lda [bCS],y
    iny
    sep #$20
    sta gDX+1
    rep #$20
    sty gIP
    rts
op_B7:
    lda [bCS],y
    iny
    sep #$20
    sta gBX+1
    rep #$20
    sty gIP
    rts

.MACRO MOVI16 ARGS DST
    lda [bCS],y
    iny
    iny
    sta DST
    sty gIP
    rts
.ENDM

op_B8: MOVI16 gAX
op_B9: MOVI16 gCX
op_BA: MOVI16 gDX
op_BB: MOVI16 gBX
op_BC: MOVI16 gSP
op_BD: MOVI16 gBP
op_BE: MOVI16 gSI
op_BF: MOVI16 gDI

opC6:                        ; MOV rm8, imm8
    jsr decode_modrm
    jsr fixup8
    lda [bCS],y
    iny
    and #$00FF
    jsr rm_write8
    sty gIP
    rts

opC7:                        ; MOV rm16, imm16
    jsr decode_modrm
    lda [bCS],y
    iny
    iny
    jsr rm_write16
    sty gIP
    rts

;----------------------------------------------------------------------
; INC/DEC r16
;----------------------------------------------------------------------
.MACRO INC16S ARGS REGO
    ldx #REGO
    jmp inc16_common
.ENDM
.MACRO DEC16S ARGS REGO
    ldx #REGO
    jmp dec16_common
.ENDM

op40: INC16S 0
op41: INC16S 2
op42: INC16S 4
op43: INC16S 6
op44: INC16S 8
op45: INC16S 10
op46: INC16S 12
op47: INC16S 14
op48: DEC16S 0
op49: DEC16S 2
op4A: DEC16S 4
op4B: DEC16S 6
op4C: DEC16S 8
op4D: DEC16S 10
op4E: DEC16S 12
op4F: DEC16S 14

inc16_common:
    jsr save_cf
    lda.b 0,x
    sta lfA
    inc a
    sta.b 0,x
    sta lfR
    lda #1
    sta lfB
    lda #LF_ADD16
    sta lfKIND
    sty gIP
    rts

dec16_common:
    jsr save_cf
    lda.b 0,x
    sta lfA
    dec a
    sta.b 0,x
    sta lfR
    lda #1
    sta lfB
    lda #LF_SUB16
    sta lfKIND
    sty gIP
    rts

;----------------------------------------------------------------------
; PUSH/POP r16 (8086 PUSH SP pushes the decremented value)
;----------------------------------------------------------------------
.MACRO PUSHR ARGS SRC
    lda SRC
    jmp push_common
.ENDM

op50: PUSHR gAX
op51: PUSHR gCX
op52: PUSHR gDX
op53: PUSHR gBX
op54:
    lda gSP
    dec a
    dec a
    jmp push_common
op55: PUSHR gBP
op56: PUSHR gSI
op57: PUSHR gDI

push_common:                 ; A = value to push
    sta tmp0
    lda gSP
    dec a
    dec a
    sta gSP
    ldx #30                  ; bSS
    jsr mk_ptr
    lda tmp0
    sta [mPTR]
    sty gIP
    rts

pop_common:                  ; A <- popped value
    ldx #30
    lda gSP
    jsr mk_ptr
    lda gSP
    inc a
    inc a
    sta gSP
    lda [mPTR]
    rts

op58:
    jsr pop_common
    sta gAX
    sty gIP
    rts
op59:
    jsr pop_common
    sta gCX
    sty gIP
    rts
op5A:
    jsr pop_common
    sta gDX
    sty gIP
    rts
op5B:
    jsr pop_common
    sta gBX
    sty gIP
    rts
op5C:
    jsr pop_common
    sta gSP
    sty gIP
    rts
op5D:
    jsr pop_common
    sta gBP
    sty gIP
    rts
op5E:
    jsr pop_common
    sta gSI
    sty gIP
    rts
op5F:
    jsr pop_common
    sta gDI
    sty gIP
    rts

;----------------------------------------------------------------------
; jumps
;----------------------------------------------------------------------
.MACRO JCCSTUB ARGS CIDX, INV
    ldx #CIDX
    lda #INV
    jmp jcc_common
.ENDM

op70: JCCSTUB 0, 0
op71: JCCSTUB 0, 1
op72: JCCSTUB 2, 0
op73: JCCSTUB 2, 1
op74: JCCSTUB 4, 0
op75: JCCSTUB 4, 1
op76: JCCSTUB 6, 0
op77: JCCSTUB 6, 1
op78: JCCSTUB 8, 0
op79: JCCSTUB 8, 1
op7A: JCCSTUB 10, 0
op7B: JCCSTUB 10, 1
op7C: JCCSTUB 12, 0
op7D: JCCSTUB 12, 1
op7E: JCCSTUB 14, 0
op7F: JCCSTUB 14, 1

jcc_common:                  ; X = cond*2, A = invert
    pha
    phx
    jsr flags_norm
    jsr fetch_d8s
    sta tmp0
    plx
    jsr (cond_tab,x)         ; A = 0/1
    sta tmp1
    pla
    eor tmp1
    beq _jcc_not_taken
    tya
    clc
    adc tmp0
    tay
_jcc_not_taken:
    sty gIP
    rts

cond_tab:
    .dw c_o, c_b, c_z, c_be, c_s, c_p, c_l, c_le

c_ret1:
    lda #1
    rts
c_ret0:
    lda #0
    rts

c_o:
    lda fSTATIC
    and #F_OF
    bne c_ret1
    bra c_ret0
c_b:
    lda fSTATIC
    and #F_CF
    bne c_ret1
    bra c_ret0
c_z:
    lda fSTATIC
    and #F_ZF
    bne c_ret1
    bra c_ret0
c_be:
    lda fSTATIC
    and #(F_CF|F_ZF)
    bne c_ret1
    bra c_ret0
c_s:
    lda fSTATIC
    and #F_SF
    bne c_ret1
    bra c_ret0
c_p:
    lda fSTATIC
    and #F_PF
    bne c_ret1
    bra c_ret0
c_l:                         ; SF != OF
    lda fSTATIC
    and #F_SF
    asl a
    asl a
    asl a
    asl a                    ; SF -> bit 11
    eor fSTATIC
    and #F_OF
    bne c_ret1
    bra c_ret0
c_le:                        ; (SF != OF) or ZF
    lda fSTATIC
    and #F_ZF
    bne c_ret1
    bra c_l

opE9:                        ; JMP rel16
    lda [bCS],y
    iny
    iny
    sta tmp0
    tya
    clc
    adc tmp0
    tay
    sty gIP
    rts

opEB:                        ; JMP rel8
    jsr fetch_d8s
    sta tmp0
    tya
    clc
    adc tmp0
    tay
    sty gIP
    rts

;----------------------------------------------------------------------
; flag instructions + HLT
;----------------------------------------------------------------------
opF4:                        ; HLT
    lda #1
    sta gHALT
    sty gIP
    rts

opF5:                        ; CMC
    jsr flags_norm
    lda fSTATIC
    eor #F_CF
    sta fSTATIC
    sty gIP
    rts

.MACRO FLAGAND ARGS MASK
    jsr flags_norm
    lda fSTATIC
    and #MASK
    sta fSTATIC
    sty gIP
    rts
.ENDM
.MACRO FLAGOR ARGS BITS
    jsr flags_norm
    lda fSTATIC
    ora #BITS
    sta fSTATIC
    sty gIP
    rts
.ENDM

opF8: FLAGAND $FFFE
opF9: FLAGOR  $0001
opFA: FLAGAND $FDFF
opFB: FLAGOR  $0200
opFC: FLAGAND $FBFF
opFD: FLAGOR  $0400

;----------------------------------------------------------------------
; parity table: value = F_PF ($04) when even parity, else 0
;----------------------------------------------------------------------
pf_tab:
    .INCBIN "build/pf.bin"

;----------------------------------------------------------------------
; opcode dispatch table
;----------------------------------------------------------------------
optable:
    .dw op00, op01, op02, op03, op04, op05, op06, op07              ; 00
    .dw op08, op09, op0A, op0B, op0C, op0D, op0E, op0F              ; 08
    .dw op10, op11, op12, op13, op14, op15, op16, op17              ; 10
    .dw op18, op19, op1A, op1B, op1C, op1D, op1E, op1F              ; 18
    .dw op20, op21, op22, op23, op24, op25, opP26, op27             ; 20
    .dw op28, op29, op2A, op2B, op2C, op2D, opP2E, op2F             ; 28
    .dw op30, op31, op32, op33, op34, op35, opP36, op37             ; 30
    .dw op38, op39, op3A, op3B, op3C, op3D, opP3E, op3F             ; 38
    .dw op40, op41, op42, op43, op44, op45, op46, op47              ; 40
    .dw op48, op49, op4A, op4B, op4C, op4D, op4E, op4F              ; 48
    .dw op50, op51, op52, op53, op54, op55, op56, op57              ; 50
    .dw op58, op59, op5A, op5B, op5C, op5D, op5E, op5F              ; 58
    .dw op70, op71, op72, op73, op74, op75, op76, op77              ; 60 (alias)
    .dw op78, op79, op7A, op7B, op7C, op7D, op7E, op7F              ; 68 (alias)
    .dw op70, op71, op72, op73, op74, op75, op76, op77              ; 70
    .dw op78, op79, op7A, op7B, op7C, op7D, op7E, op7F              ; 78
    .dw op80, op81, op80, op83, op84, op85, op86, op87              ; 80 (82=80)
    .dw op88, op89, op8A, op8B, op8C, op8D, op8E, op8F              ; 88
    .dw op90, op91, op92, op93, op94, op95, op96, op97              ; 90
    .dw op98, op99, op9A, op9B, op9C, op9D, op9E, op9F              ; 98
    .dw opA0, opA1, opA2, opA3, op_A4, op_A5, op_A6, op_A7          ; A0
    .dw opA8, opA9, op_AA, op_AB, op_AC, op_AD, op_AE, op_AF        ; A8
    .dw op_B0, op_B1, op_B2, op_B3, op_B4, op_B5, op_B6, op_B7      ; B0
    .dw op_B8, op_B9, op_BA, op_BB, op_BC, op_BD, op_BE, op_BF      ; B8
    .dw opC2, opC3, opC2, opC3, opC4, opC5, opC6, opC7              ; C0 (aliases)
    .dw opCA, opCB, opCA, opCB, opCC, opCD, opCE, opCF              ; C8 (aliases)
    .dw opD0, opD1, opD2, opD3, opD4, opD5, opD6, opD7              ; D0
    .dw opESC, opESC, opESC, opESC, opESC, opESC, opESC, opESC      ; D8
    .dw opE0, opE1, opE2, opE3, opE4, opE5, opE6, opE7              ; E0
    .dw opE8, opE9, opEA, opEB, opEC, opED, opEE, opEF              ; E8
    .dw opPF0, opPF0, opPF2, opPF3, opF4, opF5, opF6, opF7          ; F0
    .dw opF8, opF9, opFA, opFB, opFC, opFD, opFE, opFF              ; F8

.ENDS
