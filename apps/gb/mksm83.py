#!/usr/bin/env python3
"""Generate build/sm83.inc: the regular SM83 opcode handlers + dispatch tables
for GB.COM (see gb.asm for the machine model and register mapping).

Register mapping (fixed, everywhere):
    GB A  -> AL          GB F  -> AH, in 8086 LAHF format:
    GB BC -> CX                  Z=bit6, H=bit4(AF), C=bit0(CF),
    GB DE -> DX                  N=bit3 (a LAHF-reserved bit, always 0
    GB HL -> BX                  after LAHF on our cores - see x86.c canon())
    GB SP -> BP          GB PC -> SI
    DS=ES = the flat 64 KB GB address space; DI = scratch address reg.

Reads are direct ([bx]/[si]/[di]); every write goes through wr8 (DI=addr,
AL=value, preserves AH and all GB registers). Handlers end by jumping to a
shared epilogue epiN which charges N T-cycles and re-enters the dispatcher.

Irregular opcodes (NOP/HALT/EI/DAA/stack-of-AF/absolute jumps/...) live in
gb.asm; this generator emits everything that follows a family pattern, plus
the two 256-entry dispatch tables that reference both.
"""

R8 = ["ch", "cl", "dh", "dl", "bh", "bl", None, "al"]   # B C D E H L (HL) A
RNAME = ["b", "c", "d", "e", "h", "l", "hl", "a"]
R16 = ["cx", "dx", "bx", "bp"]                          # BC DE HL SP
R16NAME = ["bc", "de", "hl", "sp"]
# cc: (flags86 mask, jump-if-NOT-taken)
CC = [("0x40", "jnz"), ("0x40", "jz"), ("0x01", "jnz"), ("0x01", "jz")]
CCNAME = ["nz", "z", "nc", "c"]

out = []
handlers = {}       # opcode -> label, for the base table
cbhandlers = {}     # opcode -> label, for the CB table


def emit(op, label, lines, cb=False):
    (cbhandlers if cb else handlers)[op] = label
    out.append(f"{label}:")
    out.extend(f"    {l}" for l in lines)
    out.append("")


# --------------------------------------------------------------------------
# LD r,r'  (0x40-0x7F; 0x76 HALT is in gb.asm)
for d in range(8):
    for s in range(8):
        op = 0x40 + d * 8 + s
        if op == 0x76:
            continue
        lbl = f"o_ld_{RNAME[d]}_{RNAME[s]}"
        if d != 6 and s != 6:
            emit(op, lbl, [f"mov {R8[d]}, {R8[s]}", "jmp epi4"])
        elif d == 6:                                  # LD (HL),r
            if s == 7:
                emit(op, lbl, ["mov di, bx", "call wr8", "jmp epi8"])
            else:
                emit(op, lbl, ["push ax", f"mov al, {R8[s]}", "mov di, bx",
                               "call wr8", "pop ax", "jmp epi8"])
        else:                                         # LD r,(HL)
            emit(op, lbl, [f"mov {R8[d]}, [bx]", "jmp epi8"])

# --------------------------------------------------------------------------
# ALU A,r / A,(HL) (0x80-0xBF) and ALU A,d8 (0xC6,CE,D6,DE,E6,EE,F6,FE).
# LAHF captures Z(ZF), H(AF), C(CF); N goes in bit3 for subtract-class ops.
# AF is undefined on x86 for logicals, so those rebuild AH from scratch.
def alu(kind, src, imm=False):
    post = ["inc si"] if imm else []
    if kind == "add":
        return [f"add al, {src}", "lahf"] + post
    if kind == "adc":
        return ["sahf", f"adc al, {src}", "lahf"] + post
    if kind == "sub":
        return [f"sub al, {src}", "lahf", "or ah, 8"] + post
    if kind == "sbc":
        return ["sahf", f"sbb al, {src}", "lahf", "or ah, 8"] + post
    if kind == "and":
        return [f"and al, {src}", "lahf", "and ah, 0x40",
                "or ah, 0x10"] + post
    if kind == "xor":
        return [f"xor al, {src}", "lahf", "and ah, 0x40"] + post
    if kind == "or":
        return [f"or al, {src}", "lahf", "and ah, 0x40"] + post
    if kind == "cp":
        return [f"cmp al, {src}", "lahf", "or ah, 8"] + post


ALUOPS = ["add", "adc", "sub", "sbc", "and", "xor", "or", "cp"]
for k, kind in enumerate(ALUOPS):
    for s in range(8):
        op = 0x80 + k * 8 + s
        src = "[bx]" if s == 6 else R8[s]
        cyc = "epi8" if s == 6 else "epi4"
        emit(op, f"o_{kind}_{RNAME[s]}", alu(kind, src) + [f"jmp {cyc}"])
    emit(0xC6 + k * 8, f"o_{kind}_d8", alu(kind, "[si]", imm=True)
         + ["jmp epi8"])

# --------------------------------------------------------------------------
# INC r / DEC r (x86 INC/DEC preserve CF, same as GB; SAHF first so the
# preserved CF is the GB one from AH, then LAHF recaptures everything).
for i in range(8):
    inc_op, dec_op = 0x04 + i * 8, 0x05 + i * 8
    if i == 6:      # INC/DEC (HL): read direct, write through wr8
        for op, x86, extra, lbl in ((inc_op, "inc al", [], "o_inc_hlm"),
                                    (dec_op, "dec al", ["or ah, 8"],
                                     "o_dec_hlm")):
            emit(op, lbl, ["push ax", "mov al, [bx]", "sahf", x86, "lahf"]
                 + extra
                 + ["mov di, bx", "call wr8", "mov [cs:tmp8], ah", "pop ax",
                    "mov ah, [cs:tmp8]", "jmp epi12"])
    else:
        emit(inc_op, f"o_inc_{RNAME[i]}",
             ["sahf", f"inc {R8[i]}", "lahf", "jmp epi4"])
        emit(dec_op, f"o_dec_{RNAME[i]}",
             ["sahf", f"dec {R8[i]}", "lahf", "or ah, 8", "jmp epi4"])

# --------------------------------------------------------------------------
# LD r,d8 (06,0E,...,3E) and LD (HL),d8 (36)
for i in range(8):
    op = 0x06 + i * 8
    if i == 6:
        emit(op, "o_ld_hlm_d8",
             ["push ax", "mov al, [si]", "inc si", "mov di, bx", "call wr8",
              "pop ax", "jmp epi12"])
    else:
        emit(op, f"o_ld_{RNAME[i]}_d8",
             [f"mov {R8[i]}, [si]", "inc si", "jmp epi8"])

# --------------------------------------------------------------------------
# 16-bit: LD rr,d16 / INC rr / DEC rr / ADD HL,rr / PUSH / POP / RST
for i in range(4):
    emit(0x01 + i * 16, f"o_ld_{R16NAME[i]}_d16",
         [f"mov {R16[i]}, [si]", "inc si", "inc si", "jmp epi12"])
    emit(0x03 + i * 16, f"o_inc_{R16NAME[i]}", [f"inc {R16[i]}", "jmp epi8"])
    emit(0x0B + i * 16, f"o_dec_{R16NAME[i]}", [f"dec {R16[i]}", "jmp epi8"])

# ADD HL,rr: N=0, H=carry out of bit 11, C=carry out of bit 15, Z kept.
# Byte-wise add so LAHF's AF is the bit-11 carry (AF of the high-byte ADC).
def add_hl(lo, hi):
    return ["mov [cs:tmp8], ah", f"add bl, {lo}", f"adc bh, {hi}", "lahf",
            "and ah, 0x11", "test byte [cs:tmp8], 0x40", "jz %%nz",
            "or ah, 0x40", "%%nz:", "jmp epi8"]


def fix_local(lines, lbl):
    return [l.replace("%%", f"{lbl}_") for l in lines]


emit(0x09, "o_add_hl_bc", fix_local(add_hl("cl", "ch"), "o_add_hl_bc"))
emit(0x19, "o_add_hl_de", fix_local(add_hl("dl", "dh"), "o_add_hl_de"))
emit(0x29, "o_add_hl_hl", fix_local(add_hl("bl", "bh"), "o_add_hl_hl"))
emit(0x39, "o_add_hl_sp", ["push dx", "mov dx, bp"]
     + fix_local(add_hl("dl", "dh")[:-1], "o_add_hl_sp")
     + ["pop dx", "jmp epi8"])
# note: add_hl ends with jmp epi8; for SP we drop it, pop dx, then epi8 -- but
# the %%nz label lands before "jmp epi8", so the fallthrough still pops. Redo:
del out[out.index("o_add_hl_sp:"):]     # rebuild the SP variant cleanly
emit(0x39, "o_add_hl_sp",
     ["push dx", "mov dx, bp", "mov [cs:tmp8], ah", "add bl, dl",
      "adc bh, dh", "lahf", "and ah, 0x11", "test byte [cs:tmp8], 0x40",
      "jz o_add_hl_sp_nz", "or ah, 0x40", "o_add_hl_sp_nz:", "pop dx",
      "jmp epi8"])

# PUSH/POP BC,DE,HL (AF is irregular -> gb.asm)
for i in range(3):
    emit(0xC5 + i * 16, f"o_push_{R16NAME[i]}",
         ["dec bp", "dec bp", f"mov [ds:bp], {R16[i]}", "jmp epi16"])
    emit(0xC1 + i * 16, f"o_pop_{R16NAME[i]}",
         [f"mov {R16[i]}, [ds:bp]", "inc bp", "inc bp", "jmp epi12"])

for n in range(8):
    emit(0xC7 + n * 8, f"o_rst_{n * 8:02x}",
         ["dec bp", "dec bp", "mov [ds:bp], si", f"mov si, 0x{n * 8:04x}",
          "jmp epi16"])

# --------------------------------------------------------------------------
# Conditional JR/JP/CALL/RET
for i in range(4):
    mask, jnt = CC[i]
    cc = CCNAME[i]
    emit(0x20 + i * 8, f"o_jr_{cc}",
         [f"test ah, {mask}", f"{jnt} o_jr_{cc}_n", "xchg ax, di", "lodsb",
          "cbw", "add si, ax", "xchg ax, di", "jmp jr_taken",
          f"o_jr_{cc}_n:", "inc si", "jmp epi8"])
    emit(0xC2 + i * 8, f"o_jp_{cc}",
         [f"test ah, {mask}", f"{jnt} o_jp_{cc}_n", "mov si, [si]",
          "jmp epi16", f"o_jp_{cc}_n:", "inc si", "inc si", "jmp epi12"])
    emit(0xC4 + i * 8, f"o_call_{cc}",
         [f"test ah, {mask}", f"{jnt} o_call_{cc}_n", "mov di, [si]",
          "inc si", "inc si", "dec bp", "dec bp", "mov [ds:bp], si",
          "mov si, di", "jmp epi24",
          f"o_call_{cc}_n:", "inc si", "inc si", "jmp epi12"])
    emit(0xC0 + i * 8, f"o_ret_{cc}",
         [f"test ah, {mask}", f"{jnt} o_ret_{cc}_n", "mov si, [ds:bp]",
          "inc bp", "inc bp", "jmp epi20", f"o_ret_{cc}_n:", "jmp epi8"])

# --------------------------------------------------------------------------
# LD (BC)/(DE),A ; LD A,(BC)/(DE) ; LDI/LDD
emit(0x02, "o_ld_bcm_a", ["mov di, cx", "call wr8", "jmp epi8"])
emit(0x12, "o_ld_dem_a", ["mov di, dx", "call wr8", "jmp epi8"])
emit(0x0A, "o_ld_a_bcm", ["mov di, cx", "mov al, [di]", "jmp epi8"])
emit(0x1A, "o_ld_a_dem", ["mov di, dx", "mov al, [di]", "jmp epi8"])
emit(0x22, "o_ldi_hlm_a", ["mov di, bx", "call wr8", "inc bx", "jmp epi8"])
emit(0x32, "o_ldd_hlm_a", ["mov di, bx", "call wr8", "dec bx", "jmp epi8"])
emit(0x2A, "o_ldi_a_hlm", ["mov al, [bx]", "inc bx", "jmp epi8"])
emit(0x3A, "o_ldd_a_hlm", ["mov al, [bx]", "dec bx", "jmp epi8"])

# Rotate-A quartet: Z=N=H=0, C=rotated-out bit
emit(0x07, "o_rlca", ["rol al, 1", "mov ah, 0", "adc ah, 0", "jmp epi4"])
emit(0x0F, "o_rrca", ["ror al, 1", "mov ah, 0", "adc ah, 0", "jmp epi4"])
emit(0x17, "o_rla", ["sahf", "rcl al, 1", "mov ah, 0", "adc ah, 0",
                     "jmp epi4"])
emit(0x1F, "o_rra", ["sahf", "rcr al, 1", "mov ah, 0", "adc ah, 0",
                     "jmp epi4"])

# ==========================================================================
# CB-prefixed page. Shift/rotate handlers set Z from the result and C from
# the shifted-out bit; x86 rotates don't set ZF, so Z is tested explicitly.
def cb_shift(op8, reg, lbl, carry_in=False, force_c0=False):
    body = ["sahf"] if carry_in else []
    body += [f"{op8} {reg}, 1", "mov ah, 0"]
    body += [] if force_c0 else ["adc ah, 0"]
    body += [f"or {reg}, {reg}", f"jnz {lbl}_nz", "or ah, 0x40",
             f"{lbl}_nz:", "jmp epi8"]
    return body


CBSHIFT = [("rlc", "rol", False), ("rrc", "ror", False),
           ("rl", "rcl", True), ("rr", "rcr", True),
           ("sla", "shl", False), ("sra", "sar", False),
           ("swap", None, False), ("srl", "shr", False)]

for k, (name, x86, cin) in enumerate(CBSHIFT):
    for s in range(8):
        op = k * 8 + s
        lbl = f"c_{name}_{RNAME[s]}"
        if s == 6:      # (HL) read-modify-write via wr8
            if name == "swap":
                core = ["rol al, 1", "rol al, 1", "rol al, 1", "rol al, 1",
                        "mov ah, 0"]
            else:
                core = (["sahf"] if cin else []) + [f"{x86} al, 1",
                                                    "mov ah, 0", "adc ah, 0"]
            emit(op, lbl,
                 ["push ax", "mov al, [bx]"] + core
                 + ["or al, al", f"jnz {lbl}_nz", "or ah, 0x40", f"{lbl}_nz:",
                    "mov di, bx", "call wr8", "mov [cs:tmp8], ah", "pop ax",
                    "mov ah, [cs:tmp8]", "jmp epi16"], cb=True)
        elif name == "swap":
            emit(op, lbl,
                 [f"rol {R8[s]}, 1"] * 4
                 + ["mov ah, 0", f"or {R8[s]}, {R8[s]}", f"jnz {lbl}_nz",
                    "or ah, 0x40", f"{lbl}_nz:", "jmp epi8"], cb=True)
        else:
            emit(op, lbl, cb_shift(x86, R8[s], lbl, cin), cb=True)

# BIT n,r: Z=!bit, N=0, H=1, C preserved
for n in range(8):
    for s in range(8):
        op = 0x40 + n * 8 + s
        lbl = f"c_bit{n}_{RNAME[s]}"
        tgt = "byte [bx]" if s == 6 else R8[s]
        cyc = "epi12" if s == 6 else "epi8"
        emit(op, lbl,
             ["and ah, 1", "or ah, 0x10", f"test {tgt}, 0x{1 << n:02x}",
              f"jnz {lbl}_nz", "or ah, 0x40", f"{lbl}_nz:", f"jmp {cyc}"],
             cb=True)

# RES/SET n,r: no flags. (HL) goes through wr8 (could target an IO reg).
for setop in (0, 1):
    for n in range(8):
        for s in range(8):
            op = (0x80 if not setop else 0xC0) + n * 8 + s
            name = "set" if setop else "res"
            lbl = f"c_{name}{n}_{RNAME[s]}"
            x86 = (f"or al, 0x{1 << n:02x}" if setop
                   else f"and al, 0x{~(1 << n) & 0xFF:02x}")
            if s == 6:
                emit(op, lbl,
                     ["push ax", "mov al, [bx]", x86, "mov di, bx",
                      "call wr8", "pop ax", "jmp epi16"], cb=True)
            else:
                x86r = (f"or {R8[s]}, 0x{1 << n:02x}" if setop
                        else f"and {R8[s]}, 0x{~(1 << n) & 0xFF:02x}")
                emit(op, lbl, [x86r, "jmp epi8"], cb=True)

# ==========================================================================
# Irregular opcodes implemented in gb.asm
IRREG = {
    0x00: "o_nop", 0x10: "o_stop", 0x76: "o_halt", 0xF3: "o_di",
    0xFB: "o_ei", 0x27: "o_daa", 0x2F: "o_cpl", 0x37: "o_scf",
    0x3F: "o_ccf", 0x08: "o_ld_a16_sp", 0xE8: "o_add_sp_r8",
    0xF8: "o_ld_hl_spr8", 0xF9: "o_ld_sp_hl", 0xE9: "o_jp_hl",
    0xEA: "o_ld_a16_a", 0xFA: "o_ld_a_a16", 0xE0: "o_ldh_a8_a",
    0xF0: "o_ldh_a_a8", 0xE2: "o_ldh_c_a", 0xF2: "o_ldh_a_c",
    0xC3: "o_jp", 0x18: "o_jr", 0xCD: "o_call", 0xC9: "o_ret",
    0xD9: "o_reti", 0xCB: "o_cb", 0xF5: "o_push_af", 0xF1: "o_pop_af",
}
for op in (0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, 0xFC, 0xFD):
    IRREG[op] = "o_illegal"
handlers.update(IRREG)

# --------------------------------------------------------------------------
lines = ["; sm83.inc - generated by mksm83.py. Do not edit.", ""]
lines += out
lines.append("align 2")
lines.append("optab:")
for op in range(256):
    lines.append(f"    dw {handlers[op]}    ; {op:02x}")
lines.append("cbtab:")
for op in range(256):
    lines.append(f"    dw {cbhandlers[op]}    ; cb {op:02x}")

# Pixel-spread tables for the renderer: a GB tile-row plane byte expands to
# a 16-bit word of 2-bit CGA pixel fields (low word byte = pixels 0-3,
# leftmost pixel in bits 7-6). plane0 feeds the low bit of each field,
# plane1 the high bit; OR the two lookups to get packed colour indices.
for plane in (0, 1):
    lines.append("align 2")
    lines.append(f"spread{plane}:")
    for base in range(0, 256, 8):
        ws = []
        for b in range(base, base + 8):
            w = 0
            for x in range(8):
                bit = (b >> (7 - x)) & 1
                w |= bit << ((6 - 2 * (x & 3)) + plane + (0 if x < 4 else 8))
            ws.append(f"0x{w:04X}")
        lines.append(f"    dw {', '.join(ws)}")

# Byte bit-reversal, for X-flipped sprites (flip the plane bytes, then the
# normal pixel-extraction order comes out mirrored).
lines.append("bitrev:")
for base in range(0, 256, 16):
    bs = []
    for b in range(base, base + 16):
        r = int(f"{b:08b}"[::-1], 2)
        bs.append(f"0x{r:02X}")
    lines.append(f"    db {', '.join(bs)}")
print("\n".join(lines))
