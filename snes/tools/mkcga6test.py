#!/usr/bin/env python3
"""CGA6TST.COM: CGA mode 6 (640x200x1) test card for the M10p6 renderer.

Exercises all three VRAM char bands plus the BIOS glyph and pixel services:
  - whole screen: vertical 1px stripes ($AA fill, both interleave banks) --
    squash-proof: rendered through the old mode-4 path these collapse into
    solid color-2 blocks, at true 640 they are alternating hairlines
  - scanlines 96-111: a solid white band (tile rows 12-13, band-1 chars)
  - tile row 0 -> stripes at VRAM $5000 (band 1), tile row 16 (scanlines
    128-135) -> $7000 (band 2), tile row 24 (192-199) -> $2C00 (band 3)
  - glyphs 'L' (1,0), 'R' (1,79), '6' (14,40) via INT 10h AH=0Eh -- 'R'
    sits at the far right edge, visible only after panning
  - a pset diagonal x=3y via INT 10h AH=0Ch (the 1bpp pixel path)
Any key -> mode 3 -> exit.

M6IDLE=1 in the environment builds a mode-6-and-idle variant instead
(mode set, wait key, exit) — a minimal guest for renderer debugging.
"""
import os
import sys

out = bytearray()
def e(b): out.extend(b)

e(b"\xB8\x06\x00\xCD\x10")              # mov ax,0006 / int 10h (640x200x1)
if os.environ.get("M6IDLE"):            # debug: mode 6 + idle only
    e(b"\xB4\x00\xCD\x16")              # int 16h (wait key)
    e(b"\xB8\x03\x00\xCD\x10\xCD\x20")  # text mode, exit
    open(sys.argv[1], "wb").write(bytes(out)); sys.exit(0)
e(b"\xB8\x00\xB8\x8E\xC0")              # mov ax,B800 / mov es,ax
e(b"\x31\xFF")                          # xor di,di
e(b"\xB0\xAA")                          # mov al,AAh (1px vertical stripes)
e(b"\xB9\x00\x40")                      # mov cx,4000h (both banks + gaps)
e(b"\xF3\xAA")                          # rep stosb
# solid white band, scanlines 96-111 = lines 48-55 of each bank
e(b"\xBF\x00\x0F")                      # mov di,0F00h (48*80)
e(b"\xB0\xFF\xB9\x80\x02\xF3\xAA")      # mov al,FF / mov cx,280h / rep stosb
e(b"\xBF\x00\x2F")                      # mov di,2F00h (bank 2 + 48*80)
e(b"\xB0\xFF\xB9\x80\x02\xF3\xAA")

def glyph(row, col, ch):
    e(b"\xB4\x02\xB7\x00")              # mov ah,02 / mov bh,0
    e(bytes([0xBA, col, row]))          # mov dx,(row<<8)|col
    e(b"\xCD\x10")                      # int 10h (set cursor)
    e(bytes([0xB0, ord(ch)]))           # mov al,ch
    e(b"\xB4\x0E\xB3\x01\xCD\x10")      # mov ah,0E / mov bl,1 / int 10h

glyph(1, 0, "L")
glyph(1, 79, "R")
glyph(14, 40, "6")

# diagonal x=3y, y=0..199, via AH=0Ch AL=1 (max x = 597 < 640)
e(b"\xBE\x00\x00")                      # mov si,0   (y)
e(b"\xBD\x00\x00")                      # mov bp,0   (x)
loop = len(out)
e(b"\x89\xF2")                          # mov dx,si
e(b"\x89\xE9")                          # mov cx,bp
e(b"\xB8\x01\x0C")                      # mov ax,0C01h
e(b"\x31\xDB")                          # xor bx,bx
e(b"\xCD\x10")                          # int 10h
e(b"\x46")                              # inc si
e(b"\x83\xC5\x03")                      # add bp,3
e(b"\x81\xFE\xC8\x00")                  # cmp si,200
disp = loop - (len(out) + 2)
e(bytes([0x72, disp & 0xFF]))           # jb loop

e(b"\xB4\x00\xCD\x16")                  # mov ah,0 / int 16h (wait key)
e(b"\xB8\x03\x00\xCD\x10")              # mov ax,0003 / int 10h (text)
e(b"\xCD\x20")                          # int 20h

open(sys.argv[1], "wb").write(bytes(out))
print(f"cga6tst.com: {len(out)} bytes")
