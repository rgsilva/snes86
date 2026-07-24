#!/usr/bin/env python3
"""VIEW inner loops. TP3 keeps SS<>DS, so [bp] is out: output goes
through ES:DI STOSB (ES set to DS on entry), thresholds walk a
per-phase row via BX. The row pipeline:

A: luma+DDA   src(SI) --xlat(BX=lut)--> LumTgt (ES:DI stosb), DDA in mem
B: pack       LumTgt(SI lodsb) vs ThrRow(BX) -> bits -> Row (ES:DI)
blit          Row -> B800:[VBlt], 40 words, REP MOVSW
rle           PCX decode: Buf window (SI) -> row buffer (DI), runs via
              REP STOSB, run state carried across rows AND across buffer
              refills (PRun/PVal); stops on row-full or buffer-empty

Globals: VSrc, VLut, VCnt, VSw, VTw, VErr, VDst, VThrRow, VBlt, LumTgt,
Row, PSrc, PSrcEnd, PDst, PDstEnd, PRun, PVal.
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

def passBlit(e, var, label, rel8, lab, pos):
    e(0x06)                      # push es
    e(0xB8, 0x00, 0xB8)          # mov ax,$B800
    e(0x8E, 0xC0)                # mov es,ax
    e(0xBE); var("Row")          # mov si,Ofs(Row)
    e(0x8B, 0x3E); var("VBlt")   # mov di,[VBlt]
    e(0xFC)                      # cld
    e(0xB9, 0x28, 0x00)          # mov cx,40
    e(0xF3, 0xA5)                # rep movsw
    e(0x07)                      # pop es

def passRle(e, var, label, rel8, lab, pos):
    e(0x06)                      # push es
    e(0x1E, 0x07)                # push ds / pop es
    e(0xFC)                      # cld
    e(0x8B, 0x36); var("PSrc")   # mov si,[PSrc]
    e(0x8B, 0x3E); var("PDst")   # mov di,[PDst]
    label("flush")
    e(0x8B, 0x0E); var("PRun")   # mov cx,[PRun]
    e(0xE3); rel8("readl")       # jcxz readl
    e(0xA1); var("PDstEnd")      # mov ax,[PDstEnd]
    e(0x2B, 0xC7)                # sub ax,di      room left in the row
    e(0x74); rel8("done")        # jz done        row full, run pends
    e(0x3B, 0xC8)                # cmp cx,ax
    e(0x76); rel8("f2")          # jbe f2
    e(0x8B, 0xC8)                # mov cx,ax      clamp run to room
    label("f2")
    e(0x29, 0x0E); var("PRun")   # sub [PRun],cx
    e(0xA0); var("PVal")         # mov al,[PVal]
    e(0xF3, 0xAA)                # rep stosb
    label("readl")
    e(0x3B, 0x3E); var("PDstEnd")# cmp di,[PDstEnd]
    e(0x73); rel8("done")        # jae done       row complete
    e(0x3B, 0x36); var("PSrcEnd")# cmp si,[PSrcEnd]
    e(0x73); rel8("done")        # jae done       need a refill
    e(0xAC)                      # lodsb
    e(0x8A, 0xE0)                # mov ah,al
    e(0x80, 0xE4, 0xC0)          # and ah,$C0
    e(0x80, 0xFC, 0xC0)          # cmp ah,$C0
    e(0x75); rel8("lit")         # jne lit
    e(0x3B, 0x36); var("PSrcEnd")# cmp si,[PSrcEnd]  value byte in buf?
    e(0x72); rel8("hv")          # jb hv
    e(0x4E)                      # dec si         un-read the count byte
    e(0xEB); rel8("done")        # jmp done       refill mid-pair
    label("hv")
    e(0x24, 0x3F)                # and al,$3F
    e(0x98)                      # cbw            AL<64 so AH=0
    e(0xA3); var("PRun")         # mov [PRun],ax
    e(0xAC)                      # lodsb
    e(0xA2); var("PVal")         # mov [PVal],al
    e(0xEB); rel8("flush")       # jmp flush
    label("lit")
    e(0xAA)                      # stosb
    e(0xEB); rel8("readl")       # jmp readl
    label("done")
    e(0x89, 0x36); var("PSrc")   # mov [PSrc],si
    e(0x89, 0x3E); var("PDst")   # mov [PDst],di
    e(0x07)                      # pop es

print("{ pass A: luma + DDA }")
print(mk(passA))
print("{ pass B: dither + pack }")
print(mk(passB))
print("{ blit: Row -> B800 }")
print(mk(passBlit))
print("{ rle: PCX decode step }")
print(mk(passRle))
