#!/bin/sh
# winmouse.sh HDIMG SETUPDISK1 [OUT.png] — a mouse for Windows 1.01, driven
# by the SNES d-pad.
#
# Bring-your-own media, twice over: HDIMG is a C: image carrying an
# installed Windows in \WINDOWS, SETUPDISK1 is that Windows' own SETUP
# floppy (MOUSE.DRV is lifted out of it). Nothing here ships, and the
# input image is never modified — the patched copy is build/win_mouse.img.
#
#   ./test/winmouse.sh ../disks/windows.img \
#                      ../disks/windows101/DISK1-SETUP.IMG win_mouse.png
#
# Three stages:
#   0. tools/winmouse.py relinks WIN100.BIN, swapping SETUP's NOMOUSE.DRV
#      stub for the real "Microsoft Mouse (Bus/Serial)" driver. That
#      driver ends up on COM2, speaking the 3-byte Microsoft protocol at
#      the 8250 both cores emulate.
#   1. runpc (the oracle, seconds): boot, park the pointer at the top
#      left, walk it onto the File menu, press — the menu must drop.
#   2. Mesen headless on the SA-1 ROM: boot Windows, then drive the real
#      d-pad. With the on-screen keyboard closed and a guest mouse driver
#      holding COM2, the d-pad is the pointer and A is the left button.
#      The pointer must leave its starting place, and the click must
#      select the A: drive button.
set -e
HD=$1
D1=$2
OUT=${3:-win_mouse.png}
MESEN="${MESEN:-/Applications/Mesen.app/Contents/MacOS/Mesen}"
[ -n "$HD" ] && [ -f "$HD" ] && [ -n "$D1" ] && [ -f "$D1" ] || {
    echo "usage: winmouse.sh windows-hd.img DISK1-SETUP.IMG [out.png]"; exit 1; }
HD=$(cd "$(dirname "$HD")" && pwd)/$(basename "$HD")
D1=$(cd "$(dirname "$D1")" && pwd)/$(basename "$D1")
case $OUT in /*) ;; *) OUT=$PWD/$OUT ;; esac
cd "$(dirname "$0")/.."
mkdir -p build

echo "== stage 0: relink WIN100.BIN with a real mouse driver"
python3 tools/winmouse.py "$HD" build/win_mouse.img "$D1"

echo "== build: SA-1 ROM + the patched C: as an overlay"
make -s msdos_sa1 OVERLAYS="$(pwd)/build/win_mouse.img"

echo "== stage 1: runpc (300 KB), the reference"
make -s -C ../core-c runpc
win() {   # win OUT.ppm STEPS MOUSE-SCRIPT
    rm -f "$1"
    printf 'CD \\WINDOWS\nWIN\n' | ../core-c/build/runpc -m 300 \
        -d build/hd_overlay.img -cga "$1" -l "$2" -mouse "$3" \
        build/msdos_a.img > build/win_runpc.log 2>&1 || true
    [ -s "$1" ] || { echo "FAIL: runpc never reached CGA mode 6"; exit 1; }
}
# 20M: Windows is up and idle (the Executive lands under 3M). Park the
# pointer in the top-left corner, walk it onto File, hold the button.
win build/wm_idle.ppm  29000000 ""
win build/wm_move.ppm  27000000 "20000000:-1000:-1000:0"
win build/wm_click.ppm 29000000 "20000000:-1000:-1000:0,24000000:20:6:0,28000000:0:0:1"
python3 - <<'PY' || exit 1
def ppm(p):
    d = open(p, 'rb').read()
    h = d.split(b'\n', 3)
    w, ht = map(int, h[1].split())
    px = h[3]
    return w, ht, [1 if px[(y*w+x)*3] > 127 else 0
                   for y in range(ht) for x in range(w)]
w, h, idle = ppm('build/wm_idle.ppm')
_, _, move = ppm('build/wm_move.ppm')
_, _, clk  = ppm('build/wm_click.ppm')
def box(a, b):
    p = [(i % w, i // w) for i in range(len(a)) if a[i] != b[i]]
    return p and (len(p), min(x for x, y in p), min(y for x, y in p),
                  max(x for x, y in p), max(y for x, y in p))
mv = box(idle, move)
ck = box(idle, clk)
ok = True
if not mv or mv[1] > 40 or mv[3] < 300:
    print('  FAIL: the pointer did not travel from (320,100) to the corner:', mv)
    ok = False
else:
    print('  pointer moved: %d pixels differ, bbox x %d-%d y %d-%d'
          % (mv[0], mv[1], mv[3], mv[2], mv[4]))
if not ck or ck[0] < 1000 or ck[4] < 60:
    print('  FAIL: pressing on File did not drop a menu:', ck)
    ok = False
else:
    print('  File menu dropped: %d pixels differ down to row %d' % (ck[0], ck[4]))
raise SystemExit(0 if ok else 1)
PY
echo "  stage 1 PASS"

[ -x "$MESEN" ] || { echo "== stage 2 skipped (no Mesen)"; exit 0; }
echo "== stage 2: Mesen, headless, d-pad on build/msdos_sa1_overlay.sfc"
# Two things the Lua needs from outside: the mouse state addresses (read
# out of the assembler source, so they can never drift) and the checksum
# of the settled Executive (taken from runpc's render, so "Windows has
# finished painting" is an exact match against the oracle instead of a
# guess — the desktop alone is stable for thousands of frames while the
# driver runs its 65536-iteration probe, and a stability test latches
# onto that).
python3 - > build/wm_addr.lua <<'PY'
import re
s = open('dosboot.asm').read()
for m in re.finditer(r'\.ENUM \$([0-9A-F]+)(.*?)\.ENDE', s, re.S):
    base = int(m.group(1), 16)
    for i, n in enumerate(re.findall(r'^(\w+)\s+dw', m.group(2), re.M)):
        if n[0] == 'z':
            print('local A_%s = 0x7E%04X' % (n, base + 2 * i))
d = open('build/wm_idle.ppm', 'rb').read()
h = d.split(b'\n', 3)
w, ht = map(int, h[1].split())
px = h[3]
fb = bytearray(16000)
for y in range(ht):
    row = (0 if y % 2 == 0 else 8000) + (y // 2) * 80
    for xb in range(w // 8):
        b = 0
        for i in range(8):
            if px[(y * w + xb * 8 + i) * 3] > 127:
                b |= 0x80 >> i
        fb[row + xb] = b
print('local FBTARGET = %d' % (sum(fb[i] for i in range(0, 8000, 11))
                               + sum(fb[8000 + i] for i in range(0, 8000, 11))))
PY
cat > build/wm_body.lua <<'LUA'
local M = emu.memType.snesMemory
local frame, t, stage, mark, last, stable, shots = 0, 0, 0, 0, -1, 0, 0
local hold = {}
local function inject(keys)
  t = emu.read16(0x7E00D8, M)
  for i = 1, #keys do
    emu.write16(0x7E0700 + t, 0x1000 + keys:byte(i), M)
    t = (t + 2) % 64
  end
  emu.write16(0x7E00D8, t, M)
end
local function bufhas(str)
  for r = 0, 24 do
    local s = ""
    for c = 0, 79 do
      local ch = emu.read(0x7E1000 + r*160 + c*2, M)
      if ch < 32 or ch > 126 then ch = 32 end
      s = s .. string.char(ch)
    end
    if s:find(str, 1, true) then return true end
  end
  return false
end
local function fbsum()
  local n = 0
  for a = 0x7E1000, 0x7E2F3F, 11 do n = n + emu.read(a, M) end
  for a = 0x7E3000, 0x7E4F3F, 11 do n = n + emu.read(a, M) end
  return n
end
local function dumpfb(tag)                     -- 16000 bytes, both fields
  local fb = {}
  for a = 0x7E1000, 0x7E1000 + 7999 do fb[#fb+1] = string.format("%02x", emu.read(a, M)) end
  for a = 0x7E3000, 0x7E3000 + 7999 do fb[#fb+1] = string.format("%02x", emu.read(a, M)) end
  print("FB " .. tag .. " " .. table.concat(fb))
  local png = emu.takeScreenshot()
  print("SHOT " .. tag .. " " .. png:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
local function s16(a) local v = emu.read16(a, M); if v > 32767 then v = v - 65536 end; return v end
local function drained()                       -- intent spent AND queue empty
  return s16(A_zDX) == 0 and s16(A_zDY) == 0
         and emu.read16(A_zQH, M) == emu.read16(A_zQT, M)
end
-- wait for the picture to stop moving, then run f(). The deadline is the
-- safety: a picture that never goes perfectly still must not hang the run.
local function settle(f, period, need, deadline)
  if frame > deadline then stable = 0; last = -1; f(); return end
  if frame % period ~= 0 then return end
  local v = fbsum()
  if v == last then stable = stable + 1 else stable = 0 end
  last = v
  if stable >= need then stable = 0; last = -1; f() end
end
local function trace()                         -- where the pointer intent is
  if frame % 600 == 0 then
    print(string.format("MOUSE stage=%d frame=%d dx=%d dy=%d q=%d/%d btn=%d",
          stage, frame, s16(A_zDX), s16(A_zDY),
          emu.read16(A_zQH, M), emu.read16(A_zQT, M), emu.read16(A_zBTN, M)))
  end
end
-- setInput only lands from an inputPolled callback (an endFrame one is
-- silently ignored) — the d-pad has to be re-asserted on every poll
emu.addEventCallback(function()
  if next(hold) then emu.setInput(hold, 0) end
end, emu.eventType.inputPolled)
emu.addEventCallback(function()
  frame = frame + 1
  if stage >= 2 then trace() end
  if stage == 0 then
    if frame > 1100 and frame % 10 == 0 and bufhas("C:\\>") then
      inject("CD \\WINDOWS\r"); stage = 1; mark = frame
    end
  elseif stage == 1 then
    if frame == mark + 240 then inject("WIN\r"); stage = 2 end
  elseif stage == 2 then                       -- the settled Executive,
    if frame % 60 == 0 then                    -- pixel-identical to runpc's
      local v = fbsum()
      if frame % 1800 == 0 then print("PROGRESS frame=" .. frame .. " sum=" .. v
                                      .. " want=" .. FBTARGET) end
      if v == FBTARGET then
        print("MOUSE armed=" .. emu.read16(A_zON, M) .. " frame=" .. frame)
        dumpfb("idle"); hold = { up = true, left = true }
        stage = 3; mark = frame
      end
    end
  elseif stage == 3 then                       -- park in the top-left corner
    if frame > mark + 90 then hold = {}; stage = 4; mark = frame end
  elseif stage == 4 then
    if (frame > mark + 60 and drained()) or frame > mark + 6000 then settle(function()
      dumpfb("corner"); hold = { down = true, right = true }
      stage = 5; mark = frame
    end, 180, 4, mark + 9000) end
  elseif stage == 5 then                       -- 12 frames -> (24,24): A:
    if frame > mark + 12 then hold = {}; stage = 6; mark = frame end
  elseif stage == 6 then
    if (frame > mark + 60 and drained()) or frame > mark + 6000 then settle(function()
      dumpfb("onbutton"); hold = { a = true }
      stage = 7; mark = frame
    end, 180, 4, mark + 9000) end
  elseif stage == 7 then                       -- A = left button
    if frame > mark + 20 then hold = {}; stage = 8; mark = frame end
  elseif stage == 8 then
    if frame > mark + 60 then settle(function()
      dumpfb("clicked"); print("DONE frame=" .. frame); emu.stop(0)
    end, 180, 4, mark + 9000) end
  end
  if frame >= 130000 then print("TIMEOUT stage=" .. stage); emu.stop(0) end
end, emu.eventType.endFrame)
LUA
cat build/wm_addr.lua build/wm_body.lua > build/winmouse.lua
"$MESEN" --testrunner "$(pwd)/build/msdos_sa1_overlay.sfc" "$(pwd)/build/winmouse.lua" \
         --timeout=7200 2>/dev/null | tee build/winmouse.log \
    | grep -a "MOUSE\|DONE\|TIMEOUT"
python3 - "$OUT" <<'PY'
import sys
out = sys.argv[1]
fb, shot = {}, {}
for line in open('build/winmouse.log', 'rb').read().decode('latin1').splitlines():
    p = line.split(' ', 2)
    if len(p) == 3 and p[0] == 'FB':   fb[p[1]] = bytes.fromhex(p[2])
    if len(p) == 3 and p[0] == 'SHOT': shot[p[1]] = bytes.fromhex(p[2])
need = ['idle', 'corner', 'onbutton', 'clicked']
missing = [n for n in need if n not in fb]
if missing:
    print('  FAIL: the run never reached', missing); sys.exit(1)
if 'clicked' in shot:
    open(out, 'wb').write(shot['clicked']); print('  wrote', out)

def px(b):                                 # 16000 CGA bytes -> 640x200 bits
    return [(b[(0 if y % 2 == 0 else 8000) + (y // 2) * 80 + (x >> 3)]
             >> (7 - (x & 7))) & 1 for y in range(200) for x in range(640)]

def box(a, b):
    a, b = px(a), px(b)
    p = [(i % 640, i // 640) for i in range(len(a)) if a[i] != b[i]]
    return p and (len(p), min(x for x, y in p), min(y for x, y in p),
                  max(x for x, y in p), max(y for x, y in p))

ok = True
mv = box(fb['idle'], fb['corner'])
if not mv or mv[1] > 40 or mv[3] < 300:
    print('  FAIL: the d-pad did not walk the pointer to the corner:', mv); ok = False
else:
    print('  d-pad moved the pointer: %d pixels differ, x %d-%d y %d-%d'
          % (mv[0], mv[1], mv[3], mv[2], mv[4]))
# clicking a drive button selects it AND lists that drive, so the change
# has to start on the button row and then run down the file list
ck = box(fb['onbutton'], fb['clicked'])
if not ck or ck[0] < 1000 or ck[1] > 40 or ck[2] > 33 or ck[4] < 60:
    print('  FAIL: the A button did not click the A: drive button:', ck); ok = False
else:
    print('  A clicked the A: drive button (Windows listed A:): %d pixels '
          'differ, x %d-%d y %d-%d' % (ck[0], ck[1], ck[3], ck[2], ck[4]))
sys.exit(0 if ok else 1)
PY
echo "== winmouse PASS"
