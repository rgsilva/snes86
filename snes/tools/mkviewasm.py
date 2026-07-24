#!/usr/bin/env python3
"""VIEW inner loops, take 2. TP3 keeps SS<>DS, so [bp] is out: output
goes through ES:DI STOSB (ES set to DS on entry), thresholds walk a
per-phase row via BX. Two passes per row:

A: luma+DDA   src(SI) --xlat(BX=lut)--> LumTgt (ES:DI stosb), DDA in mem
B: pack       LumTgt(SI lodsb) vs ThrRow(BX) -> bits -> Row (ES:DI)

Globals: VSrc, VLut, VCnt, VSw, VTw, VErr, VDst, VThrRow, LumTgt.
"""
def mk(emit_fn):
    code, lab = [], {}
    def e(*bs): code.extend(bs)
    def var(n): code.append(("var", n))
    def label(n): lab[n] = pos()
    def rel8(n): code.append(("rel8", n, pos()))
    def pos():
        p = 0
        for it in code:
            p += 2 if isinstance(it, tuple) and it[0] == "var" else 1
        return p
    emit_fn(e, var, label, rel8, lab, pos)
    items = []
    for it in code:
        if isinstance(it, tuple) and it[0] == "rel8":
            d = lab[it[1]] - (it[2] + 1)
            assert -128 <= d <= 127, (it[1], d)
            items.append(f"${d & 0xFF:02X}")
        elif isinstance(it, tuple):
            items.append(it[1])
        else:
            items.append(f"${it:02X}")
    lines = []
    for i in range(0, len(items), 9):
        lines.append("    " + "/".join(items[i:i + 9]))
    return "    inline(\n" + "/\n".join(lines) + ");"

def passA(e, var, label, rel8, lab, pos):
    e(0x06)                      # push es
    e(0x1E, 0x07)                # push ds / pop es
    e(0x8B, 0x36); var("VSrc")   # mov si,[VSrc]
    e(0xBF); var("LumTgt")       # mov di,Ofs(LumTgt)
    e(0x8B, 0x1E); var("VLut")   # mov bx,[VLut]
    e(0x8B, 0x0E); var("VCnt")   # mov cx,[VCnt]
    e(0xFC)                      # cld
    label("a")
    e(0x8A, 0x04)                # mov al,[si]
    e(0xD7)                      # xlat
    e(0xAA)                      # stosb
    e(0x8B, 0x06); var("VSw")    # mov ax,[VSw]
    e(0x01, 0x06); var("VErr")   # add [VErr],ax
    label("adda")
    e(0x8B, 0x06); var("VErr")   # mov ax,[VErr]
    e(0x3B, 0x06); var("VTw")    # cmp ax,[VTw]
    e(0x72); rel8("anext")       # jb anext
    e(0x8B, 0x06); var("VTw")    # mov ax,[VTw]
    e(0x29, 0x06); var("VErr")   # sub [VErr],ax
    e(0x46)                      # inc si
    e(0xEB); rel8("adda")        # jmp adda
    label("anext")
    e(0xE2)                      # loop a  (rel8)
    d = lab["a"] - (pos() + 1)
    e(d & 0xFF)
    e(0x07)                      # pop es

def passB(e, var, label, rel8, lab, pos):
    e(0x06)                      # push es
    e(0x1E, 0x07)                # push ds / pop es
    e(0xBE); var("LumTgt")       # mov si,Ofs(LumTgt)
    e(0x8B, 0x1E); var("VThrRow")# mov bx,[VThrRow]
    e(0x8B, 0x3E); var("VDst")   # mov di,[VDst]
    e(0x8B, 0x0E); var("VCnt")   # mov cx,[VCnt]
    e(0xFC)                      # cld
    e(0x31, 0xD2)                # xor dx,dx
    label("b")
    e(0xAC)                      # lodsb        AL = luma
    e(0x38, 0x07)                # cmp [bx],al  CF = thr < L
    e(0xD0, 0xD2)                # rcl dl,1
    e(0x43)                      # inc bx
    e(0xFE, 0xC6)                # inc dh
    e(0x80, 0xFE, 0x08)          # cmp dh,8
    e(0x75); rel8("nb")          # jne nb
    e(0x8A, 0xC2)                # mov al,dl
    e(0xAA)                      # stosb
    e(0x31, 0xD2)                # xor dx,dx
    label("nb")
    e(0xE2)                      # loop b
    d = lab["b"] - (pos() + 1)
    e(d & 0xFF)
    e(0x80, 0xFE, 0x00)          # cmp dh,0     ragged tail
    e(0x74); rel8("bf")          # je bf
    label("bs")
    e(0xD0, 0xE2)                # shl dl,1
    e(0xFE, 0xC6)                # inc dh
    e(0x80, 0xFE, 0x08)          # cmp dh,8
    e(0x75); rel8("bs")          # jne bs
    e(0x8A, 0xC2)                # mov al,dl
    e(0xAA)                      # stosb
    label("bf")
    e(0x07)                      # pop es

print("{ pass A: luma + DDA }")
print(mk(passA))
print("{ pass B: dither + pack }")
print(mk(passB))
