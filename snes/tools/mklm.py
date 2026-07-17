#!/usr/bin/env python3
"""Build LM.COM — the "Door 2" DOS-3-environment-forging launcher.

WHY THIS EXISTS (documented per Ricardo's request, 2026-07-17):

Landmark Speed Test 2.0 (LM20.EXE) aborts on PC DOS 2.0 with the
Microsoft C runtime error "R6009 - not enough space for environment".
The real cause is a convention change, not memory: starting with DOS
3.0, EXEC appends extra data after the environment block's terminating
double-NUL:

    VAR=VALUE\\0 ... VAR=VALUE\\0 \\0     <- classic env, double-NUL end
    dw 1                                <- DOS 3+: count of extra strings
    "C:\\FULL\\PATH\\TO\\PROGRAM.EXE\\0"    <- DOS 3+: argv[0] pathname

MSC's startup code walks past the double-NUL expecting that trailer;
under DOS 2.0 it finds arbitrary garbage and bails with R6009.

THE TRICK: a parent program may pass ANY environment segment to DOS
EXEC (INT 21h AH=4Bh). DOS does not inspect it. So this launcher
builds a DOS-3-shaped environment block — trailer included — inside
its own memory image, shrinks its allocation so the child fits, and
EXECs LM20.EXE with that forged environment. The C runtime finds the
pathname trailer it wanted and never learns it is living in 1983.

This is the same idea SETVER made official years later.

8086 details worth remembering:
  - A .COM program owns ALL free memory at startup; EXEC would fail
    with "not enough memory" unless we first shrink via AH=4Ah. Our
    stack must be moved into the kept region BEFORE shrinking.
  - DOS 2.x EXEC destroys ALL registers including SS:SP; they must be
    saved in code-relative memory and restored with interrupts off.
  - The environment segment must be paragraph-aligned; we pad the
    .COM image so the env block lands on a 16-byte boundary (memory
    offset 0x100 + file offset, and 0x100 is already aligned).

usage:
    mklm.py OUT.COM [CHILDPATH]
CHILDPATH defaults to C:\\BENCH\\LM20.EXE (the shipped location); host
tests pass a bare "LM20.EXE" so it resolves on runpc's A: drive.
"""
import sys

out_path = sys.argv[1]
child = sys.argv[2] if len(sys.argv) > 2 else "C:\\BENCH\\LM20.EXE"
child_b = child.encode("ascii") + b"\x00"

ORG = 0x100


def le16(v):
    return bytes((v & 0xFF, (v >> 8) & 0xFF))


# ---- fixed-size code layout: compute every label first ----------------
# Code is a fixed instruction sequence; sizes never vary, so one pass of
# arithmetic gives every offset. All addresses are memory offsets
# (file offset + 0x100).
code_len = 0x4F                       # 0x100..0x14E inclusive, see below
save_ss = ORG + code_len              # dw
save_sp = save_ss + 2                 # dw
pblk = save_sp + 2                    # EXEC parameter block, 14 bytes:
#   +0  dw env segment   (filled at runtime: CS + ENV_PARA)
#   +2  dd far ptr command tail -> PSP:0080 (offset word, seg filled runtime)
#   +6  dd far ptr FCB1         -> PSP:005C
#   +10 dd far ptr FCB2         -> PSP:006C
path = pblk + 14
path_b = child_b
errmsg = path + len(path_b)
errmsg_b = b"LM20 exec failed\r\n$"
env_start_unaligned = errmsg + len(errmsg_b)
env = (env_start_unaligned + 15) & ~15          # paragraph align
ENV_PARA = env // 16                             # add to CS at runtime

env_b = (b"COMSPEC=A:\\COMMAND.COM\x00"
         b"PATH=C:\\;C:\\BENCH\x00"
         b"\x00"                                 # double-NUL: env ends
         + le16(1)                               # DOS 3 trailer: 1 string
         + child_b)                              # argv[0] the runtime wants
stack_bot = ((env + len(env_b) + 15) & ~15)
stack_top = stack_bot + 64                       # 64-byte private stack
keep_paras = (stack_top + 15) // 16 + 0x10       # + PSP; a little slack
keep_paras += 2

# ---- assemble ---------------------------------------------------------
c = bytearray()


def emit(bs):
    c.extend(bs)


# save SS:SP (DOS 2 EXEC trashes them)
emit(b"\x8C\x16" + le16(save_ss))     # 0100  mov [save_ss], ss
emit(b"\x89\x26" + le16(save_sp))     # 0104  mov [save_sp], sp
# private stack inside the region we are about to keep
emit(b"\x8C\xC8")                     # 0108  mov ax, cs
emit(b"\x8E\xD0")                     # 010A  mov ss, ax   (sti-shadowed)
emit(b"\xBC" + le16(stack_top))       # 010C  mov sp, stack_top
# shrink our allocation so the child has somewhere to live (ES = PSP)
emit(b"\xBB" + le16(keep_paras))      # 010F  mov bx, keep_paras
emit(b"\xB4\x4A")                     # 0112  mov ah, 4Ah (SETBLOCK)
emit(b"\xCD\x21")                     # 0114  int 21h
emit(b"\x72\x2B")                     # 0116  jc fail (0143)
# parameter block: forged env segment = CS + ENV_PARA
emit(b"\x8C\xC8")                     # 0118  mov ax, cs
emit(b"\x05" + le16(ENV_PARA))        # 011A  add ax, ENV_PARA
emit(b"\xA3" + le16(pblk))            # 011D  mov [pblk], ax
# far pointers: tail/FCB1/FCB2 all in OUR PSP (inherited by value)
emit(b"\x8C\x0E" + le16(pblk + 4))    # 0120  mov [pblk+4], cs
emit(b"\x8C\x0E" + le16(pblk + 8))    # 0124  mov [pblk+8], cs
emit(b"\x8C\x0E" + le16(pblk + 12))   # 0128  mov [pblk+12], cs
# EXEC
emit(b"\xBA" + le16(path))            # 012C  mov dx, path
emit(b"\xBB" + le16(pblk))            # 012F  mov bx, pblk
emit(b"\xB8\x00\x4B")                 # 0132  mov ax, 4B00h
emit(b"\xCD\x21")                     # 0135  int 21h
# child finished (or EXEC failed, CF set): rebuild our stack
emit(b"\xFA")                         # 0137  cli
emit(b"\x8E\x16" + le16(save_ss))     # 0138  mov ss, [save_ss]
emit(b"\x8B\x26" + le16(save_sp))     # 013C  mov sp, [save_sp]
emit(b"\xFB")                         # 0140  sti
emit(b"\x73\x07")                     # 0141  jnc done (014A)
emit(b"\xBA" + le16(errmsg))          # 0143  fail: mov dx, errmsg
emit(b"\xB4\x09")                     # 0146  mov ah, 9 (print $-string)
emit(b"\xCD\x21")                     # 0148  int 21h
emit(b"\xB8\x00\x4C")                 # 014A  done: mov ax, 4C00h
emit(b"\xCD\x21")                     # 014D  int 21h
assert len(c) == code_len, (len(c), code_len)

# ---- data -------------------------------------------------------------
c += b"\x00\x00"                      # save_ss
c += b"\x00\x00"                      # save_sp
c += le16(0)                          # pblk+0: env seg (runtime)
c += le16(0x0080) + le16(0)           # pblk+2: command tail -> PSP:0080
c += le16(0x005C) + le16(0)           # pblk+6: FCB1 -> PSP:005C
c += le16(0x006C) + le16(0)           # pblk+10: FCB2 -> PSP:006C
c += path_b
c += errmsg_b
c += b"\x00" * (env - ORG - len(c))   # align env to a paragraph
assert (ORG + len(c)) % 16 == 0
c += env_b
open(out_path, "wb").write(bytes(c))
print(f"{out_path}: {len(c)} bytes, child={child}, env@{env:04X} "
      f"(para {ENV_PARA:02X}), keep {keep_paras:02X}0h bytes")
