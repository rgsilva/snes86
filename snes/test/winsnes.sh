#!/bin/sh
# winsnes.sh HDIMG [OUT.png] — Microsoft Windows 1.01/1.04 on the SNES.
#
# Bring-your-own media: HDIMG is a C: image (this repo's fixed-disk shape)
# carrying an installed Windows in \WINDOWS. Nothing here ships — the
# overlay build writes build/msdos_sa1_overlay.sfc and the clean ROM is
# never touched.
#
#   ./test/winsnes.sh ../disks/windows.img win_snes.png
#
# Two stages, oracle first:
#   1. runpc (the C core) boots the exact A:/C: pair at 300 KB and dumps
#      the CGA mode-6 screen to a PPM — seconds, and it is the reference.
#   2. Mesen runs the SA-1 ROM headless, types CD \WINDOWS + WIN, and
#      shoots the screen the moment it is pixel-identical to stage 1's
#      (~32k frames, about nine emulated minutes, a couple of host
#      minutes; the bare desktop lands thousands of frames earlier and
#      sits perfectly still, so "it stopped changing" is not the test).
#      It then proves INPUT: eight d-pad Downs walk the selection and
#      START opens it, into <out>_input.png.
#
# Windows 1.01 needs 237 KB free (measured: 236 KB fails with "Program
# too big to fit in memory"), so this is an SA-1-machine-only build.
set -e
HD=$1
OUT=${2:-win_snes.png}
MESEN="${MESEN:-/Applications/Mesen.app/Contents/MacOS/Mesen}"
[ -n "$HD" ] && [ -f "$HD" ] || { echo "usage: winsnes.sh path/to/windows-hd.img [out.png]"; exit 1; }
# both paths are the caller's, but the build has to run in snes/
HD=$(cd "$(dirname "$HD")" && pwd)/$(basename "$HD")
case $OUT in /*) ;; *) OUT=$PWD/$OUT ;; esac
cd "$(dirname "$0")/.."

echo "== build: SA-1 ROM + $HD as an overlay"
make -s msdos_sa1 OVERLAYS="$HD"

echo "== stage 1: runpc (300 KB), the reference"
make -s -C ../core-c runpc
rm -f build/win_runpc.ppm
printf 'CD \\WINDOWS\nWIN\n' | ../core-c/build/runpc -m 300 \
    -d build/hd_overlay.img -cga build/win_runpc.ppm -l 40000000 \
    build/msdos_a.img > build/win_runpc.log 2>&1 || true
grep -a "^Microsoft Windows" build/win_runpc.log | cut -c1-60
if grep -qa "too big to fit" build/win_runpc.log; then
    echo "FAIL: WIN ran out of memory (the floor is 237 KB)"; exit 1
fi
[ -s build/win_runpc.ppm ] || { echo "FAIL: runpc never reached CGA mode 6"; exit 1; }
echo "  wrote build/win_runpc.ppm (compare it against $OUT)"

[ -x "$MESEN" ] || { echo "== stage 2 skipped (no Mesen)"; exit 0; }
echo "== stage 2: Mesen, headless, on build/msdos_sa1_overlay.sfc"
# "Windows has finished painting" is an exact match against the oracle,
# not a stability test: the bare desktop is pixel-stable for *thousands*
# of frames before the Executive window lands (frame ~32 100), so a
# plain "the sum stopped changing" latches onto the dithered wallpaper
# and shoots the wrong screen. Fold runpc's PPM down to the same
# sampled checksum the Lua computes and wait for that number.
python3 - > build/ws_target.lua <<'PY'
d = open('build/win_runpc.ppm', 'rb').read()
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
cat > build/ws_body.lua <<'LUA'
local frame, t, stage, injf = 0, 0, 0, 0
local downs, wantdown, wantstart = 0, false, false
local function inject(keys)
  t = emu.read16(0x7E00D8, emu.memType.snesMemory)
  for i = 1, #keys do
    emu.write16(0x7E0700 + t, 0x1000 + keys:byte(i), emu.memType.snesMemory)
    t = (t + 2) % 64
  end
  emu.write16(0x7E00D8, t, emu.memType.snesMemory)
end
local function bufhas(str)                     -- text shadow at $7E1000
  for r = 0, 24 do
    local s = ""
    for c = 0, 79 do
      local ch = emu.read(0x7E1000 + r*160 + c*2, emu.memType.snesMemory)
      if ch < 32 or ch > 126 then ch = 32 end
      s = s .. string.char(ch)
    end
    if s:find(str, 1, true) then return true end
  end
  return false
end
local function fbsum()                         -- mode 6: both interlace fields
  local n = 0
  for a = 0x7E1000, 0x7E2F3F, 11 do n = n + emu.read(a, emu.memType.snesMemory) end
  for a = 0x7E3000, 0x7E4F3F, 11 do n = n + emu.read(a, emu.memType.snesMemory) end
  return n
end
emu.addEventCallback(function()
  frame = frame + 1
  if stage == 0 and frame > 1100 and frame % 10 == 0 and bufhas("C:\\>") then
    inject("CD \\WINDOWS\r"); stage = 1; injf = frame
  elseif stage == 1 and frame == injf + 240 then
    inject("WIN\r"); stage = 2
  elseif stage == 2 and frame % 60 == 0 then
    local f = fbsum()
    if frame % 300 == 0 then
      print("PROGRESS frame=" .. frame .. " sum=" .. f .. " want=" .. FBTARGET)
    end
    if f == FBTARGET then
      local png = emu.takeScreenshot()
      print("SHOT " .. png:gsub(".", function(c) return string.format("%02x", c:byte()) end))
      -- and the raw CGA bytes, so the render can be diffed against runpc's:
      -- mode 6 is 80 bytes/row, even rows at $7E1000, odd rows at $7E3000
      local fb = {}
      for a = 0x7E1000, 0x7E1000 + 7999 do
        fb[#fb+1] = string.format("%02x", emu.read(a, emu.memType.snesMemory))
      end
      for a = 0x7E3000, 0x7E3000 + 7999 do
        fb[#fb+1] = string.format("%02x", emu.read(a, emu.memType.snesMemory))
      end
      print("FB " .. table.concat(fb))
      print("SETTLED frame=" .. frame)
      stage = 3; injf = frame        -- the picture is proven; now the keyboard
    end
  elseif stage == 3 then
    -- Windows 1.01 installs its own INT 9 handler, so this exercises the
    -- whole raw path: d-pad -> kb_push -> the scancode queue -> IRQ1 ->
    -- 0EAB:0199. Hold 6 frames (the autorepeat delay is 15) every 60.
    local d, p = frame - injf, (frame - injf) % 60
    wantdown = (p < 6 and downs < 8)
    if p == 59 then
      downs = downs + 1
      if downs >= 8 then stage = 4; injf = frame end
    end
  elseif stage == 4 then                        -- START = Enter on the pick
    local d = frame - injf
    wantstart = (d >= 600 and d < 606)
    if d == 8000 then
      local png = emu.takeScreenshot()
      print("SHOT2 " .. png:gsub(".", function(c) return string.format("%02x", c:byte()) end))
      print("INPUT frame=" .. frame .. " downs=" .. downs)
      emu.stop(0)
    end
  end
  if frame >= 80000 then print("TIMEOUT stage=" .. stage); emu.stop(0) end
end, emu.eventType.endFrame)
emu.addEventCallback(function()
  if wantdown  then emu.setInput({ down  = true }, 0) end
  if wantstart then emu.setInput({ start = true }, 0) end
end, emu.eventType.inputPolled)
LUA
cat build/ws_target.lua build/ws_body.lua > build/winsnes.lua
"$MESEN" --testrunner "$(pwd)/build/msdos_sa1_overlay.sfc" "$(pwd)/build/winsnes.lua" \
         --timeout=3600 2>/dev/null | tee build/winsnes.log | grep -a "SETTLED\|INPUT\|TIMEOUT"
grep -a '^SHOT ' build/winsnes.log | tail -1 | cut -d' ' -f2 | python3 -c "
import sys
d = sys.stdin.read().strip()
if len(d) > 100:
    open('$OUT', 'wb').write(bytes.fromhex(d)); print('  wrote $OUT')
else:
    print('  !! no screenshot'); sys.exit(1)"

# the real check: the SNES CGA bytes must equal what runpc rendered. The
# PPM is 1bpp mode 6 blown up to RGB, so fold it back down and compare.
grep -a '^FB ' build/winsnes.log | tail -1 | cut -d' ' -f2 | python3 -c "
import sys
snes = bytes.fromhex(sys.stdin.read().strip())
assert len(snes) == 16000, len(snes)
d = open('build/win_runpc.ppm', 'rb').read()
hdr = d.split(b'\n', 3)
w, h = map(int, hdr[1].split())
px = hdr[3]
ref = bytearray(16000)
for y in range(h):
    row = (0 if y % 2 == 0 else 8000) + (y // 2) * 80
    for xb in range(w // 8):
        b = 0
        for i in range(8):
            if px[(y * w + xb * 8 + i) * 3] > 127:
                b |= 0x80 >> i
        ref[row + xb] = b
bad = [i for i in range(16000) if ref[i] != snes[i]]
print('  framebuffer vs runpc: %d of 16000 bytes differ' % len(bad))
sys.exit(1 if bad else 0)"

# and the input proof: the same screen after eight d-pad Downs + START
OUT2=$(echo "$OUT" | sed 's/\.png$//')_input.png
grep -a '^SHOT2 ' build/winsnes.log | tail -1 | cut -d' ' -f2 | python3 -c "
import sys
d = sys.stdin.read().strip()
if len(d) > 100:
    open('$OUT2', 'wb').write(bytes.fromhex(d)); print('  wrote $OUT2 (selection moved, START opened it)')
else:
    print('  !! Windows took no keyboard input'); sys.exit(1)"
