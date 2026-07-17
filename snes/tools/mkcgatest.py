#!/usr/bin/env python3
"""Build CGATEST.COM — deterministic CGA mode-4 test card.

Sequence: INT10 mode 4, palette 1 bright + blue background (AH=0B),
direct B800 band fill (top half color 2, bottom half color 1 via the
odd/even line interleave), a 100-step color-3 diagonal drawn with the
INT10 AH=0C pixel service, then block on INT16 for a key and restore
mode 3 before exiting.  Every byte is deterministic — the host PPM dump
and the future SNES t_cga screenshot both assert against it.

usage: mkcgatest.py OUT.COM
"""
import sys

c = bytearray()
e = c.extend

e(b"\xB8\x04\x00")          # mov ax,0004  ; mode 4 (320x200x4)
e(b"\xCD\x10")              # int 10h
e(b"\xB4\x0B\xBB\x01\x01")  # mov ah,0Bh; mov bx,0101  ; palette 1
e(b"\xCD\x10")              # int 10h
e(b"\xB4\x0B\xBB\x01\x00")  # mov ah,0Bh; mov bx,0001  ; bg/border blue
e(b"\xCD\x10")              # int 10h
e(b"\xB8\x00\xB8")          # mov ax,B800
e(b"\x8E\xC0")              # mov es,ax
# even-scanline bank: 8 KB of AA (color 2,2,2,2)
e(b"\x31\xFF")              # xor di,di
e(b"\xB9\x00\x10")          # mov cx,1000h  ; 4096 words
e(b"\xB8\xAA\xAA")          # mov ax,AAAA
e(b"\xF3\xAB")              # rep stosw
# odd-scanline bank: 8 KB of 55 (color 1,1,1,1)
e(b"\xBF\x00\x20")          # mov di,2000h
e(b"\xB9\x00\x10")          # mov cx,1000h
e(b"\xB8\x55\x55")          # mov ax,5555
e(b"\xF3\xAB")              # rep stosw
# diagonal via INT10 AH=0C: x=2y, y=0..99, color 3
e(b"\x31\xC9")              # xor cx,cx     ; x
e(b"\x31\xD2")              # xor dx,dx     ; y
loop_at = len(c)
e(b"\xB4\x0C\xB0\x03")      # mov ah,0Ch; mov al,3
e(b"\xCD\x10")              # int 10h
e(b"\x41\x41")              # inc cx; inc cx
e(b"\x42")                  # inc dx
e(b"\x83\xFA\x64")          # cmp dx,100
rel = loop_at - (len(c) + 2)
e(bytes((0x72, rel & 0xFF)))  # jb loop
# wait for a key, restore text mode, exit
e(b"\xB4\x00\xCD\x16")      # mov ah,0; int 16h
e(b"\xB8\x03\x00\xCD\x10")  # mov ax,0003; int 10h
e(b"\xCD\x20")              # int 20h

open(sys.argv[1], "wb").write(bytes(c))
print(f"{sys.argv[1]}: {len(c)} bytes")
