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
#      shoots the screen once the picture stops changing (~32k frames,
#      about nine emulated minutes, a couple of host minutes).
#
# Windows 1.01 needs 237 KB free (measured: 236 KB fails with "Program
# too big to fit in memory"), so this is an SA-1-machine-only build.
set -e
cd "$(dirname "$0")/.."
HD=$1
OUT=${2:-win_snes.png}
MESEN="${MESEN:-/Applications/Mesen.app/Contents/MacOS/Mesen}"
[ -n "$HD" ] && [ -f "$HD" ] || { echo "usage: winsnes.sh path/to/windows-hd.img [out.png]"; exit 1; }
HD=$(cd "$(dirname "$HD")" && pwd)/$(basename "$HD")

echo "== build: SA-1 ROM + $HD as an overlay"
make -s msdos_sa1 OVERLAYS="$HD"

echo "== stage 1: runpc (300 KB), the reference"
make -s -C ../core-c runpc
printf 'CD \\WINDOWS\nWIN\n' | ../core-c/build/runpc -m 300 \
    -d build/hd_overlay.img -cga build/win_runpc.ppm -l 40000000 \
    build/msdos_a.img 2>&1 | sed -n '/^Microsoft Windows/,$p' | head -2
[ -s build/win_runpc.ppm ] || { echo "FAIL: runpc never reached CGA mode 6"; exit 1; }
echo "  wrote build/win_runpc.ppm"

[ -x "$MESEN" ] || { echo "== stage 2 skipped (no Mesen)"; exit 0; }
echo "== stage 2: Mesen, headless, on build/msdos_sa1_overlay.sfc"
cat > build/winsnes.lua <<'LUA'
local frame, t, stage, injf, last, stable = 0, 0, 0, 0, -1, 0
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
    inject("cd \\windows\r"); stage = 1; injf = frame
  elseif stage == 1 and frame == injf + 240 then
    inject("win\r"); stage = 2
  elseif stage == 2 and frame % 300 == 0 then
    local f = fbsum()
    if f == last then stable = stable + 1 else stable = 0 end
    last = f
    print("PROGRESS frame=" .. frame .. " sum=" .. f)
    if frame > 26000 and stable >= 10 then
      local png = emu.takeScreenshot()
      print("SHOT " .. png:gsub(".", function(c) return string.format("%02x", c:byte()) end))
      print("SETTLED frame=" .. frame)
      emu.stop(0)
    end
  end
  if frame >= 80000 then print("TIMEOUT stage=" .. stage); emu.stop(0) end
end, emu.eventType.endFrame)
LUA
"$MESEN" --testrunner "$(pwd)/build/msdos_sa1_overlay.sfc" "$(pwd)/build/winsnes.lua" \
         --timeout=3600 2>/dev/null | tee build/winsnes.log | grep -a "SETTLED\|TIMEOUT"
grep -a '^SHOT ' build/winsnes.log | tail -1 | cut -d' ' -f2 | python3 -c "
import sys
d = sys.stdin.read().strip()
if len(d) > 100:
    open('$OUT', 'wb').write(bytes.fromhex(d)); print('  wrote $OUT')
else:
    print('  !! no screenshot'); sys.exit(1)"
