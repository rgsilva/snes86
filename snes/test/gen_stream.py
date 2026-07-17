#!/usr/bin/env python3
"""Generate a constrained random 8086 instruction stream for the M4
lockstep parity harness.

Constraints (so both cores stay inside the M4 guest memory window and
never leave the implemented opcode slice):
  - segments are all 0x0100 and never change
  - EA base registers (BX/SI/DI/BP) are periodically re-pinned into the
    data region offsets 0x2000-0x2EFF so memory EAs stay in bounds
  - SP is never a destination; PUSH/POP kept balanced-ish with a floor
  - Jcc/JMP are forward-only, skipping 1-2 whole instructions
  - immediates for EA regs stay in the data region

usage: gen_stream.py [seed] [count] [outdir]
"""
import random
import sys
import os

seed_arg = sys.argv[1] if len(sys.argv) > 1 else "1"

def build_directed(name):
    """Hand-built streams for paths the random generator can't safely emit:
    software interrupts, far control flow, LES/LDS, divide errors."""
    e = bytearray()
    marks = {}
    fix = []
    def emit(bs): e.extend(bs)
    def mark(l): marks[l] = len(e)
    def ref(bs, label, at):
        fix.append((len(e) + at, label)); e.extend(bs)
    if name == "d1":
        emit(b"\x31\xC0\x8E\xC0")                       # ES=0
        ref(b"\x26\xC7\x06\x84\x00\x00\x00", "h21", 5)  # IVT[21h] off
        emit(b"\x26\xC7\x06\x86\x00\x00\x01")          # IVT[21h] seg
        emit(b"\xB8\x00\x01\x8E\xC0")                    # ES=0x100
        emit(b"\xCD\x21\x42\xCD\x21")                    # int/inc dx/int
        ref(b"\x9A\x00\x00\x00\x01", "ffar", 1)          # call far
        emit(b"\x41")                                        # inc cx
        ref(b"\xEA\x00\x00\x00\x01", "land", 1)          # jmp far
        mark("ffar")
        emit(b"\x43\xCB")                                   # inc bx; retf
        mark("land")
        emit(b"\x42")                                        # inc dx
        emit(b"\xC7\x06\x00\x21\x45\x23")               # [2100]=2345
        emit(b"\xC7\x06\x02\x21\x40\x01")               # [2102]=0140
        emit(b"\xC4\x1E\x00\x21")                         # les bx,[2100]
        emit(b"\x26\x8B\x0E\x00\x20")                    # mov cx,es:[2000]
        emit(b"\xC5\x36\x00\x21")                         # lds si,[2100]
        emit(b"\x8B\x04")                                   # mov ax,[si]
        emit(b"\xB8\x00\x01\x8E\xD8")                    # DS=0x100
        emit(b"\xBB\x40\x20\xBE\x40\x21")               # re-pin bx,si
        emit(b"\x9C\x58\x25\xFF\xFE\x50\x9D")          # pushf dance
        emit(b"\xCC")                                        # int3 (IVT 3 = IRET stub? zero -> 0:0!)
        emit(b"\xF4")                                        # hlt
        mark("h21")
        emit(b"\x40\xCF")                                   # inc ax; iret
    if name == "d3":
        emit(b"\x31\xC0\x8E\xC0")
        ref(b"\x26\xC7\x06\x00\x00\x00\x00", "h0", 5)
        emit(b"\x26\xC7\x06\x02\x00\x00\x01")
        emit(b"\xB8\x00\x01\x8E\xC0")
        emit(b"\xB1\x00\xB8\x34\x12\xF6\xF1")          # div cl, cl=0
        emit(b"\xB1\x01\xB8\x00\x02\xF6\xF1")          # 0x200/1 ovf
        emit(b"\xB8\x80\xFF\xB1\x01\xF6\xF9")          # idiv -128 trap
        emit(b"\xB8\x9C\xFF\xB1\x03\xF6\xF9")          # idiv -100/3
        emit(b"\xB8\x9C\xFF\xB1\x03\xF3\xF6\xF9")     # rep idiv quirk
        emit(b"\xB9\x00\x00\xB8\x22\x11\xBA\x00\x00\xF7\xF1")
        emit(b"\xBA\x01\x00\xB9\x01\x00\xF7\xF1")     # div16 ovf
        emit(b"\xBA\xFF\xFF\xB8\x00\x80\xB9\x01\x00\xF7\xF9")
        emit(b"\xBA\x00\x00\xB8\x64\x00\xB9\x0A\x00\xF7\xF9")
        emit(b"\xB0\x7B\xD4\x0A")                         # aam 10
        emit(b"\xD4\x00")                                   # aam 0 -> #DE
        emit(b"\xD5\x07")                                   # aad 7
        emit(b"\x27\x2F\x37\x3F")                         # bcd sweep
        emit(b"\xF4")
        mark("h0")
        emit(b"\x47\xCF")                                   # inc di; iret
    for pos, label in fix:
        e[pos:pos + 2] = marks[label].to_bytes(2, "little")
    return bytes(e)

if not seed_arg.isdigit():
    outdir = sys.argv[3] if len(sys.argv) > 3 else "build"
    stream = bytearray(build_directed(seed_arg))
    if len(stream) % 2:
        stream += b"\x90"
    count = 200
    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, "stream.bin"), "wb").write(stream)
    open(os.path.join(outdir, "stream.lst"), "w").write(
        f"directed {seed_arg}: {stream.hex(' ')}\n")
    open(os.path.join(outdir, "stream_meta.asm"), "w").write(
        f".DEFINE STREAM_COUNT {count}\n.DEFINE STREAM_BYTES {len(stream)}\n")
    open(os.path.join(outdir, "stream.count"), "w").write(str(count))
    print(f"directed stream {seed_arg}: {len(stream)} bytes, {count} steps")
    sys.exit(0)

seed = int(seed_arg)
count = int(sys.argv[2]) if len(sys.argv) > 2 else 1200
outdir = sys.argv[3] if len(sys.argv) > 3 else "build"
rng = random.Random(seed)

R16 = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di"]
EA_SAFE = {3: "bx", 5: "bp", 6: "si", 7: "di"}   # reg index -> name

def data_off():
    return 0x2000 + rng.randrange(0x0F00)

def imm16():
    return rng.randrange(0x10000)

def imm8():
    return rng.randrange(0x100)

def modrm_mem(reg):
    """Random memory ModRM using safe base regs; returns encoded bytes."""
    rm = rng.choice([0, 1, 2, 3, 4, 5, 6, 7])
    mod = rng.choice([0, 1, 2])
    if rm == 6 and mod == 0:
        # [disp16]: direct address into the data region
        return bytes([(0 << 6) | (reg << 3) | 6]) + data_off().to_bytes(2, "little")
    if mod == 0:
        return bytes([(reg << 3) | rm])
    if mod == 1:
        d = rng.randrange(-0x60, 0x60) & 0xFF
        return bytes([(1 << 6) | (reg << 3) | rm, d])
    d = rng.randrange(-0x300, 0x300) & 0xFFFF
    return bytes([(2 << 6) | (reg << 3) | rm]) + d.to_bytes(2, "little")

def modrm_reg(reg, rm):
    return bytes([(3 << 6) | (reg << 3) | rm])

def pick_reg(exclude_sp=True):
    r = rng.randrange(8)
    while exclude_sp and r == 4:
        r = rng.randrange(8)
    return r

# Destination pools: EA base regs (BX/BP/SI/DI) and SP may only be written
# by pin-MOVs (safe values), INC/DEC (bounded drift) and LEA — otherwise a
# random value in them drags memory EAs out of the M4 56KB guest window.
def dst16():
    return rng.choice([0, 1, 2])          # AX CX DX

def dst8():
    return rng.choice([0, 1, 2, 4, 5, 6])  # AL CL DL AH CH DH

instrs = []          # list of (bytes, text, in_unit)
push_depth = 0

def pin_ea_regs():
    """MOV the EA base registers back into the data region."""
    out = []
    for enc, name in ((0xBB, "bx"), (0xBE, "si"), (0xBF, "di"), (0xBD, "bp")):
        v = data_off() & 0xFF00 | 0x40
        out.append((bytes([enc]) + v.to_bytes(2, "little"),
                    f"mov {name}, {v:#06x}", False))
    return out

SREG = {0: "es", 3: "ds"}

def gen_unit():
    """Multi-instruction units; returns a list of entries (in_unit=True)."""
    u = rng.choices(
        ["sreg_set", "sreg_stack", "mov_from_sreg", "misc1", "pushf",
         "string", "shift", "grp3", "callret", "loop", "bcd", "fe",
         "poprm", "pfx_mem"],
        weights=[3, 3, 2, 6, 2, 8, 8, 8, 4, 3, 5, 3, 2, 5])[0]

    if u == "sreg_set":
        sr = rng.choice([0, 3])
        v = 0x100 + 8 * rng.randrange(16)      # 0x100-0x178
        return [(bytes([0xB8]) + v.to_bytes(2, "little"), f"mov ax,{v:#x}", True),
                (bytes([0x8E, 0xC0 | (sr << 3)]), f"mov {SREG[sr]},ax", True)]

    if u == "sreg_stack":
        sr = rng.choice([0x06, 0x0E, 0x16, 0x1E])
        if rng.random() < 0.5 and sr != 0x0E and sr != 0x16:
            return [(bytes([sr]), "push sreg", True),
                    (bytes([sr + 1]), "pop sreg", True)]
        return [(bytes([sr]), "push sreg", True),
                (bytes([0x58 + dst16()]), "pop r16", True)]

    if u == "mov_from_sreg":
        sr = rng.randrange(4)
        if rng.random() < 0.5:
            return [(bytes([0x8C]) + modrm_mem(sr), "mov m16,sreg", True)]
        return [(bytes([0x8C, 0xC0 | (sr << 3) | dst16()]), "mov r16,sreg", True)]

    if u == "misc1":
        op = rng.choice([0x98, 0x99, 0x9E, 0x9F, 0xD6, 0xD7,
                         0xEC, 0xED, 0xEE, 0xEF])
        if op == 0xD7:
            return [(bytes([op]), "xlat", True)]
        return [(bytes([op]), f"misc {op:02x}", True)]

    if u == "pushf":
        return [(b"\x9c", "pushf", True),
                (b"\x58", "pop ax", True),
                (b"\x25\xff\xfe", "and ax,0xfeff (clear TF)", True),
                (b"\x50", "push ax", True),
                (b"\x9d", "popf", True)]

    if u == "string":
        out = [(bytes([0xB9]) + rng.randrange(13).to_bytes(2, "little"),
                "mov cx,n", True),
               (bytes([rng.choice([0xFC, 0xFD])]), "cld/std", True)]
        sop = rng.choice([0xA4, 0xA5, 0xA6, 0xA7, 0xAA, 0xAB,
                          0xAC, 0xAD, 0xAE, 0xAF])
        b = bytes([sop])
        if rng.random() < 0.7:
            pfx = 0xF3 if sop in (0xA6, 0xA7, 0xAE, 0xAF) and rng.random() < 0.5 else                   rng.choice([0xF2, 0xF3])
            b = bytes([pfx]) + b
        out.append((b, f"string {b.hex()}", True))
        out.append((bytes([0xFC]), "cld (restore)", True))
        return out

    if u == "shift":
        cnt = rng.choice([0, 1, 2, 5, 8, 15, 16, 17, 31, 40])
        sub = rng.randrange(8)
        wide = rng.random() < 0.5
        op = rng.choice([0xD0, 0xD1]) if rng.random() < 0.4 else              rng.choice([0xD2, 0xD3])
        op = (op & 0xFE) | (1 if wide else 0)
        if rng.random() < 0.5:
            mrm = modrm_mem(sub)
        else:
            mrm = modrm_reg(sub, dst16() if wide else dst8())
        return [(bytes([0xB1, cnt & 0xFF]), f"mov cl,{cnt}", True),
                (bytes([op]) + mrm, f"grp2.{sub} w={wide}", True)]

    if u == "grp3":
        which = rng.choice(["test", "not", "neg", "mul", "imul",
                            "div8", "div16", "idiv8", "idiv16"])
        wide = rng.random() < 0.5
        opb = 0xF7 if wide else 0xF6
        if which == "test":
            mrm = modrm_mem(0) if rng.random() < 0.5 else modrm_reg(0, pick_reg(False))
            imm = imm16().to_bytes(2, "little") if wide else bytes([imm8()])
            return [(bytes([opb]) + mrm + imm, "grp3 test", True)]
        if which in ("not", "neg"):
            reg = 2 if which == "not" else 3
            mrm = modrm_mem(reg) if rng.random() < 0.5 else                   modrm_reg(reg, dst16() if wide else dst8())
            return [(bytes([opb]) + mrm, f"grp3 {which}", True)]
        if which in ("mul", "imul"):
            reg = 4 if which == "mul" else 5
            mrm = modrm_mem(reg) if rng.random() < 0.5 else                   modrm_reg(reg, pick_reg(False))
            return [(bytes([opb]) + mrm, f"grp3 {which}", True)]
        if which == "div8":
            return [(bytes([0xB4, 0x00]), "mov ah,0", True),
                    (bytes([0xB1, rng.randrange(1, 256)]), "mov cl,d", True),
                    (bytes([0xF6, 0xF1]), "div cl", True)]
        if which == "div16":
            return [(bytes([0xBA, 0x00, 0x00]), "mov dx,0", True),
                    (bytes([0xB9]) + rng.randrange(1, 0x10000).to_bytes(2, "little"),
                     "mov cx,d", True),
                    (bytes([0xF7, 0xF1]), "div cx", True)]
        if which == "idiv8":
            pre = bytes([0xF3]) if rng.random() < 0.3 else b""
            return [(bytes([0xB4, 0x00]), "mov ah,0", True),
                    (bytes([0x24, 0x7F]), "and al,0x7f", True),
                    (bytes([0xB1, rng.randrange(1, 128)]), "mov cl,d", True),
                    (pre + bytes([0xF6, 0xF9]), "idiv cl (maybe rep)", True)]
        pre = bytes([0xF3]) if rng.random() < 0.3 else b""
        return [(bytes([0xBA, 0x00, 0x00]), "mov dx,0", True),
                (bytes([0x25, 0xFF, 0x7F]), "and ax,0x7fff", True),
                (bytes([0xB9]) + rng.randrange(1, 0x8000).to_bytes(2, "little"),
                 "mov cx,d", True),
                (pre + bytes([0xF7, 0xF9]), "idiv cx (maybe rep)", True)]

    if u == "callret":
        nbody = rng.randrange(1, 3)
        body = []
        for _ in range(nbody):
            body.append((bytes([(rng.randrange(8) << 3) | 4, imm8()]),
                         "alu al,imm8 (fn body)", True))
        blen = sum(len(b[0]) for b in body) + 1
        return ([(b"\xe8\x02\x00", "call +2", True),
                 (bytes([0xEB, blen]), f"jmp +{blen}", True)] +
                body + [(b"\xc3", "ret", True)])

    if u == "loop":
        k = rng.randrange(2, 5)
        body = [(bytes([(rng.randrange(8) << 3) | 4, imm8()]),
                 "alu al,imm8 (loop body)", True)]
        if rng.random() < 0.5:
            body.append((bytes([0x40 + rng.choice([0, 2])]), "inc r", True))
        blen = sum(len(b[0]) for b in body)
        lop = rng.choice([0xE0, 0xE1, 0xE2])
        return ([(bytes([0xB9, k, 0x00]), f"mov cx,{k}", True)] + body +
                [(bytes([lop, (-(blen + 2)) & 0xFF]), f"loop{lop:02x} back", True)])

    if u == "bcd":
        op = rng.choice([0x27, 0x2F, 0x37, 0x3F, 0xD4, 0xD5])
        if op in (0xD4, 0xD5):
            return [(bytes([op, rng.randrange(1, 256)]), f"aam/aad", True)]
        return [(bytes([op]), f"bcd {op:02x}", True)]

    if u == "fe":
        reg = rng.choice([0, 1])
        mrm = modrm_mem(reg) if rng.random() < 0.5 else modrm_reg(reg, dst8())
        return [(bytes([0xFE]) + mrm, "inc/dec rm8", True)]

    if u == "poprm":
        mrm = modrm_mem(0) if rng.random() < 0.5 else modrm_reg(0, dst16())
        return [(bytes([0x50 + pick_reg(False)]), "push r", True),
                (bytes([0x8F]) + mrm, "pop rm16", True)]

    if u == "pfx_mem":
        pfx = rng.choice([0x26, 0x2E, 0x36, 0x3E])
        aluop = rng.randrange(8)
        wide = rng.random() < 0.5
        base = (aluop << 3) | (3 if wide else 2)
        reg = dst16() if wide else dst8()
        return [(bytes([pfx, base]) + modrm_mem(reg), "seg-prefixed alu", True)]

    raise AssertionError

def gen_one():
    global push_depth
    kind = rng.choices(
        ["alu_rm_r", "alu_r_rm", "alu_acc_imm", "grp1", "mov_ri", "mov_rm",
         "inc_dec", "push_pop", "xchg", "test", "jcc", "jmp", "flags", "lea",
         "moffs"],
        weights=[14, 14, 8, 12, 10, 12, 6, 6, 4, 4, 6, 2, 3, 3, 3])[0]
    aluop = rng.randrange(8)

    if kind == "alu_rm_r":
        wide = rng.random() < 0.6
        base = (aluop << 3) | (1 if wide else 0)
        reg = pick_reg(False)              # source: anything
        if rng.random() < 0.5:
            mrm = modrm_mem(reg)
            return bytes([base]) + mrm, f"alu{aluop} rm{16 if wide else 8}, r (mem)"
        rm = dst16() if wide else dst8()   # rm is the destination
        return bytes([base]) + modrm_reg(reg, rm), f"alu{aluop} rm, r (reg)"

    if kind == "alu_r_rm":
        wide = rng.random() < 0.6
        base = (aluop << 3) | (3 if wide else 2)
        reg = dst16() if wide else dst8()  # reg is the destination
        if rng.random() < 0.5:
            mrm = modrm_mem(reg)
            return bytes([base]) + mrm, f"alu{aluop} r, rm (mem)"
        rm = pick_reg(False)
        return bytes([base]) + modrm_reg(reg, rm), f"alu{aluop} r, rm (reg)"

    if kind == "alu_acc_imm":
        if rng.random() < 0.5:
            return bytes([(aluop << 3) | 4, imm8()]), f"alu{aluop} al, imm8"
        return bytes([(aluop << 3) | 5]) + imm16().to_bytes(2, "little"), \
               f"alu{aluop} ax, imm16"

    if kind == "grp1":
        w = rng.choice([0x80, 0x81, 0x83])
        reg = aluop
        mem = rng.random() < 0.5
        rmdst = dst16() if w != 0x80 else dst8()
        mrm = modrm_mem(reg) if mem else modrm_reg(reg, rmdst)
        if w == 0x80:
            return bytes([w]) + mrm + bytes([imm8()]), f"grp1.{aluop} rm8, imm8"
        if w == 0x81:
            return bytes([w]) + mrm + imm16().to_bytes(2, "little"), \
                   f"grp1.{aluop} rm16, imm16"
        return bytes([w]) + mrm + bytes([imm8()]), f"grp1.{aluop} rm16, imm8sx"

    if kind == "mov_ri":
        if rng.random() < 0.4:
            r = dst8()
            return bytes([0xB0 + r, imm8()]), f"mov r8({r}), imm8"
        r = pick_reg()
        v = imm16()
        if r in EA_SAFE:
            v = data_off()                 # EA regs only get safe values
        elif r == 4:
            r = 0
        return bytes([0xB8 + r]) + v.to_bytes(2, "little"), f"mov {R16[r]}, imm16"

    if kind == "mov_rm":
        op = rng.choice([0x88, 0x89, 0x8A, 0x8B, 0xC6, 0xC7])
        wide = op in (0x89, 0x8B, 0xC7)
        if op in (0x8A, 0x8B):
            reg = dst16() if wide else dst8()   # reg is destination
        else:
            reg = pick_reg(False) if op < 0xC0 else 0
        mem = rng.random() < 0.5
        if op in (0x88, 0x89, 0xC6, 0xC7):
            rmpick = dst16() if wide else dst8()  # rm is destination
        else:
            rmpick = pick_reg(False)
        mrm = modrm_mem(reg) if mem else modrm_reg(reg, rmpick)
        b = bytes([op]) + mrm
        if op == 0xC6:
            b += bytes([imm8()])
        elif op == 0xC7:
            b += imm16().to_bytes(2, "little")
        return b, f"mov form {op:02x}"

    if kind == "inc_dec":
        r = pick_reg()                     # bounded drift: EA regs OK
        return bytes([(0x40 if rng.random() < 0.5 else 0x48) + r]), f"inc/dec {R16[r]}"

    if kind == "push_pop":
        global push_depth
        if push_depth > 0 and rng.random() < 0.5:
            push_depth -= 1
            return bytes([0x58 + dst16()]), "pop r"
        if push_depth < 24:
            push_depth += 1
            return bytes([0x50 + pick_reg(False)]), "push r"
        push_depth -= 1
        return bytes([0x58 + dst16()]), "pop r"

    if kind == "xchg":
        if rng.random() < 0.4:
            r = rng.choice([1, 2])         # both sides are destinations
            return bytes([0x90 + r]), f"xchg ax, {R16[r]}"
        op = rng.choice([0x86, 0x87])
        wide = op == 0x87
        reg = dst16() if wide else dst8()
        mem = rng.random() < 0.5
        mrm = modrm_mem(reg) if mem else \
              modrm_reg(reg, dst16() if wide else dst8())
        return bytes([op]) + mrm, "xchg rm"

    if kind == "test":
        op = rng.choice([0x84, 0x85, 0xA8, 0xA9])
        if op in (0x84, 0x85):
            reg = pick_reg()
            mem = rng.random() < 0.5
            mrm = modrm_mem(reg) if mem else modrm_reg(reg, pick_reg())
            return bytes([op]) + mrm, "test rm"
        if op == 0xA8:
            return bytes([op, imm8()]), "test al, imm8"
        return bytes([op]) + imm16().to_bytes(2, "little"), "test ax, imm16"

    if kind == "jcc":
        return ("JCC", rng.randrange(16)), "jcc (patched)"

    if kind == "jmp":
        return ("JMP", None), "jmp (patched)"

    if kind == "flags":
        return bytes([rng.choice([0xF5, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD])]), "flagop"

    if kind == "lea":
        reg = dst16()   # never into EA base regs: [BX+DI] sums escalate
        return bytes([0x8D]) + modrm_mem(reg), "lea"

    if kind == "moffs":
        op = rng.choice([0xA0, 0xA1, 0xA2, 0xA3])
        return bytes([op]) + data_off().to_bytes(2, "little"), f"moffs {op:02x}"

    raise AssertionError

# generate with periodic EA-register re-pinning and jump patching
pending_jumps = []   # (index in instrs, kind, cc, skip_n)
i = 0
for it in pin_ea_regs():
    instrs.append(it)
while len(instrs) < count:
    if len(instrs) % 40 == 20:
        for it in pin_ea_regs():
            instrs.append(it)
        continue
    if rng.random() < 0.45:
        for it in gen_unit():
            instrs.append(it)
        continue
    b, txt = gen_one()
    if isinstance(b, tuple):
        skip = rng.choice([1, 2])
        pending_jumps.append((len(instrs), b[0], b[1], skip))
        instrs.append((b"\x90\x90", txt, False))
    else:
        instrs.append((b, txt, False))
instrs = instrs[:count]

# patch jumps: replace placeholder with Jcc/JMP over the next `skip`
# instructions (their encoded byte length is known now)
out = []
lst = []
sizes = [len(e[0]) for e in instrs]
enc = [e[0] for e in instrs]
for idx, jkind, cc, skip in pending_jumps:
    if idx >= len(instrs):
        continue
    # never jump into or over unit fragments (a skipped CALL etc. would
    # leave its RET executing with an unbalanced stack)
    if any(e[2] for e in instrs[idx + 1: idx + 1 + skip]):
        skip = 0
    span = sum(sizes[idx + 1: idx + 1 + skip])
    if span > 120:
        span = 0
    if jkind == "JCC":
        enc[idx] = bytes([0x70 + cc, span & 0xFF])
    else:
        enc[idx] = bytes([0xEB, span & 0xFF])
    sizes[idx] = 2

stream = bytearray()
for k, b in enumerate(enc):
    lst.append(f"{k:5d}  {stream.__len__():04x}  {b.hex(' '):24s}  {instrs[k][1]}")
    stream += b

if len(stream) % 2:
    stream += b"\x90"        # even padding for the 16-bit ROM copy loop

os.makedirs(outdir, exist_ok=True)
open(os.path.join(outdir, "stream.bin"), "wb").write(stream)
open(os.path.join(outdir, "stream.lst"), "w").write("\n".join(lst) + "\n")
open(os.path.join(outdir, "stream_meta.asm"), "w").write(
    f".DEFINE STREAM_COUNT {len(enc)}\n.DEFINE STREAM_BYTES {len(stream)}\n")
open(os.path.join(outdir, "stream.count"), "w").write(str(len(enc)))
print(f"stream: {len(enc)} instructions, {len(stream)} bytes, seed {seed}")
