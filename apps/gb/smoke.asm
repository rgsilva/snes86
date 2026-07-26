; smoke.asm - minimal homebrew ROM: prints over the serial port (which
; GB.COM wires to the DOS console), does one carry-flag sanity check,
; then STOPs (which GB.COM treats as a clean exit).
; Build: rgbasm -o smoke.o smoke.asm && rgblink -o smoke.gb smoke.o
;        && rgbfix -v -p 0xFF smoke.gb

SECTION "entry", ROM0[$100]
    nop
    jp start

SECTION "main", ROM0[$150]
start:
    ld sp, $FFFE
    ld hl, msg
.loop:
    ld a, [hli]
    or a
    jr z, .done
    call putc
    jr .loop
.done:
    ld a, 250           ; 250+6 wraps: expect carry
    add a, 6
    jr c, .carry
    ld a, "0"
    jr .print
.carry:
    ld a, "1"
.print:
    call putc
    ld a, "\n"
    call putc
    stop

putc:
    ldh [$FF01], a
    ld a, $81
    ldh [$FF02], a
    ret

msg: db "SM83 ALIVE C=", 0
