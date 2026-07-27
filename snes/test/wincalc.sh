#!/bin/sh
# wincalc.sh HDIMG [OUT.png] — a Windows 1.01 application, launched and
# used on the SNES with nothing but the controller.
#
# winsnes.sh proved Windows boots and takes keystrokes. This one spends
# them: from the MS-DOS Executive one d-pad Down walks the selection off
# ABC.TXT and onto CALC.EXE, START opens it, and then the on-screen
# keyboard types 8086 into the Calculator. The frame that comes out is a
# real 1985 application window with 8086 in its readout, which is the
# whole joke.
#
# Bring-your-own media: HDIMG is a C: image carrying an installed
# Windows in \WINDOWS. Nothing here ships and the input image is never
# modified.
#
#   ./test/wincalc.sh ../disks/windows.img ../docs/assets/windows_calc.png
#
# Two stages, oracle first:
#   1. runpc (the C core, a second): the same keys, at 300 KB, dumping
#      three CGA renders — the settled Executive, the Calculator as it
#      opens, the Calculator after the four digits. A window must appear
#      and then *only the readout* may change. runpc paces piped keys off
#      the step counter rather than off the guest, so it gets its own
#      copy of the boot floppy with WIN in AUTOEXEC.BAT (build/wc_a.img)
#      and -kdelay holds the four digits back until Windows is up. The
#      ROM's own floppy is untouched.
#   2. Mesen headless on the SA-1 ROM (~40 000 frames to the Executive,
#      a couple of host minutes): boot Windows, then drive the real
#      d-pad. With no mouse driver in this install the d-pad is the
#      arrow keys and START is Enter, so CALC.EXE opens the same way a
#      person would open it; SELECT then raises the on-screen keyboard
#      and A presses the highlighted key, straight into the INT 9
#      handler Windows installs for itself. The SNES framebuffer must
#      come out byte-identical to what runpc rendered.
#
# The typing is closed-loop rather than timed: the on-screen keyboard's
# selected-key index lives in kSEL, so the script presses Right (or
# Left) and re-reads kSEL until it is on the key it wants. Row 0 of the
# layout is "1234567890-=", which puts 8 at index 7, 0 at 9 and 6 at 5 —
# no pixel geometry anywhere.
set -e
HD=$1
OUT=${2:-win_calc.png}
MESEN="${MESEN:-/Applications/Mesen.app/Contents/MacOS/Mesen}"
[ -n "$HD" ] && [ -f "$HD" ] || {
    echo "usage: wincalc.sh path/to/windows-hd.img [out.png]"; exit 1; }
HD=$(cd "$(dirname "$HD")" && pwd)/$(basename "$HD")
case $OUT in /*) ;; *) OUT=$PWD/$OUT ;; esac
cd "$(dirname "$0")/.."
mkdir -p build

echo "== build: SA-1 ROM + $HD as an overlay"
make -s msdos_sa1 OVERLAYS="$HD"

echo "== stage 1: runpc (300 KB), the reference"
make -s -C ../core-c runpc
python3 - <<'PY'
import sys
sys.path.insert(0, '../apps')
import fatimg
f = fatimg.Floppy('build/msdos_a.img')
old = fatimg.read_img('build/msdos_a.img')['AUTOEXEC.BAT']
f.replace('AUTOEXEC.BAT', old + b'CD \\WINDOWS\r\nWIN\r\n')
f.save('build/wc_a.img')
print('  build/wc_a.img: the boot floppy with WIN appended to AUTOEXEC.BAT')
PY
win() {   # win OUT.ppm STEPS KEYS
    rm -f "$1"
    printf '%b' "$3" | ../core-c/build/runpc -m 300 \
        -d build/hd_overlay.img -cga "$1" -l "$2" \
        -kdelay 20000000 -krate 2000000 build/wc_a.img \
        > build/wc_runpc.log 2>&1 || true
    [ -s "$1" ] || { echo "FAIL: runpc never reached CGA mode 6"; exit 1; }
}
# \033[B is Down (runpc turns ANSI arrows into XT scancodes, which is what
# a guest INT 9 hook sees); \r is Enter. -kdelay parks the whole stream
# until step 20M, by which time the Executive is up and idle.
win build/wc_idle.ppm 20500000 ''
win build/wc_open.ppm 26000000 '\033[B\r'
win build/wc_done.ppm 32000000 '\033[B\r8086'
python3 - <<'PY' || exit 1
def ppm(p):
    d = open(p, 'rb').read()
    h = d.split(b'\n', 3)
    w, ht = map(int, h[1].split())
    px = h[3]
    return w, ht, [1 if px[(y*w+x)*3] > 127 else 0
                   for y in range(ht) for x in range(w)]
W, H, idle = ppm('build/wc_idle.ppm')
_, _, opn  = ppm('build/wc_open.ppm')
_, _, done = ppm('build/wc_done.ppm')
def diff(a, b, x0, y0, x1, y1):
    return sum(1 for y in range(y0, y1) for x in range(x0, x1)
               if a[y*W+x] != b[y*W+x])
ok = True
# a whole window's worth of screen has to change when CALC.EXE opens
n = diff(idle, opn, 0, 0, W, H)
if n < 20000:
    print('  FAIL: Down + Enter did not open CALC.EXE:', n); ok = False
else:
    print('  CALC.EXE opened: %d of %d pixels repainted' % (n, W*H))
# and then only the readout may change
n = diff(opn, done, 210, 56, 345, 78)
if n < 100:
    print('  FAIL: typing 8086 left the readout alone:', n); ok = False
else:
    print('  the readout changed: %d pixels inside the display box' % n)
n = diff(opn, done, 0, 80, 640, 200)
if n > 100:
    print('  FAIL: something other than the readout moved:', n); ok = False
else:
    print('  the rest of the Calculator is untouched: %d pixels' % n)
raise SystemExit(0 if ok else 1)
PY
echo "  stage 1 PASS"

[ -x "$MESEN" ] || { echo "== stage 2 skipped (no Mesen)"; exit 0; }
echo "== stage 2: Mesen, headless, d-pad on build/msdos_sa1_overlay.sfc"
# Two things the Lua needs from outside: the emulator's own variable
# addresses (read out of the assembler source, so they can never drift)
# and a checksum for each of the three waypoints runpc rendered, so
# "Windows has finished this step" is an exact match against the oracle
# rather than a guess.
python3 - > build/wc_addr.lua <<'PY'
import re
s = open('dosboot.asm').read()
for m in re.finditer(r'\.ENUM \$([0-9A-F]+)(.*?)\.ENDE', s, re.S):
    base = int(m.group(1), 16)
    for i, n in enumerate(re.findall(r'^(\w+)\s+dw', m.group(2), re.M)):
        print('local A_%s = 0x7E%04X' % (n, base + 2 * i))
def cksum(path):
    d = open(path, 'rb').read()
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
    return (sum(fb[i] for i in range(0, 8000, 11))
            + sum(fb[8000 + i] for i in range(0, 8000, 11)))
# three waypoints, all of them runpc's: the settled Executive, the
# Calculator once it has finished opening, and the finished picture.
# Waiting on an exact checksum is the only reliable "it is done" signal
# here — while Windows loads CALC.EXE off the fixed disk the screen sits
# perfectly still for thousands of frames, so any stability test calls
# the load finished before it has started painting.
print('local FBTARGET = %d' % cksum('build/wc_idle.ppm'))
print('local FBOPEN = %d' % cksum('build/wc_open.ppm'))
print('local FBDONE = %d' % cksum('build/wc_done.ppm'))
PY
cat > build/wc_body.lua <<'LUA'
local M = emu.memType.snesMemory
local frame, t, boot, mark = 0, 0, 0, 0
local hold = {}
local function inject(keys)                    -- pre-Windows: the INT16 ring
  t = emu.read16(A_cKbT, M)
  for i = 1, #keys do
    emu.write16(0x7E0700 + t, 0x1000 + keys:byte(i), M)
    t = (t + 2) % 64
  end
  emu.write16(A_cKbT, t, M)
end
local function bufhas(str)                     -- text shadow at $7E1000
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
local function fbsum()                         -- mode 6: both interlace fields
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
local function kbidle()                        -- every scancode delivered
  return emu.read16(A_s9H, M) == emu.read16(A_s9T, M)
end

-- ---- the choreography, as a list of steps the sequencer walks ---------
local plan = {}
local function add(s) plan[#plan + 1] = s end
-- 6 frames is one keypress: the d-pad autorepeat delay is 15 frames, so
-- a short hold moves the selection exactly once. The release afterwards
-- is what makes the *next* hold read as a fresh press rather than a
-- repeat of this one.
local function tap(btn, n)
  add{ hold = { [btn] = true }, frames = n or 6 }
  add{ hold = {}, frames = 6 }
end
-- a plain "stopped moving" wait, which is all the small repaints need:
-- the two places where stillness lies about progress (loading CALC.EXE,
-- and putting the on-screen keyboard away) use waitsum instead
local function quiet()
  add{ settle = 1200, need = 4, period = 30 }
end
add{ dump = "idle" }
tap("down");  quiet(); add{ dump = "oncalc" }      -- ABC.TXT -> CALC.EXE
-- START is Enter, which runs the selection. Windows then spends several
-- thousand frames reading CALC.EXE off the fixed disk behind an
-- hourglass, so wait for the picture to *be* runpc's, not merely to
-- stop moving.
tap("start"); add{ waitsum = FBOPEN, deadline = 90000 }
add{ dump = "calcopen" }
tap("select"); add{ vis = 1 }                      -- raise the keyboard
-- row 0 of the layout is "1234567890-=", so these are 8, 0, 8, 6
for _, k in ipairs{ 7, 9, 7, 5 } do
  add{ navto = k }; add{ hold = {}, frames = 6 }
  tap("a"); add{ kbdrain = 600 }; quiet()
end
add{ dump = "typed" }
tap("select"); add{ vis = 0 }                      -- and put it away again
add{ waitsum = FBDONE, deadline = 12000 }
add{ dump = "d8086" }
add{ done = true }

-- ---- the sequencer ---------------------------------------------------
local pi, st = 1, nil
local function nextStep()
  print(string.format("STEP %d done at frame %d kSEL=%d kVIS=%d", pi, frame,
        emu.read16(A_kSEL, M), emu.read16(A_kVIS, M)))
  pi = pi + 1; st = nil
end
local function runPlan()
  local s = plan[pi]
  if s == nil then return end
  if s.hold then
    if st == nil then st = 0; hold = s.hold end
    st = st + 1
    if st >= s.frames then hold = {}; nextStep() end
  elseif s.settle then
    if st == nil then st = { n = 0, last = -1, stab = 0 } end
    st.n = st.n + 1
    if st.n % s.period == 0 then
      local v = fbsum()
      if v == st.last then st.stab = st.stab + 1 else st.stab = 0 end
      st.last = v
      if st.stab >= s.need or st.n > s.settle then nextStep() end
    end
  elseif s.waitsum then
    if st == nil then st = 0 end
    st = st + 1
    if st % 60 == 0 and fbsum() == s.waitsum then nextStep(); return end
    if st > s.deadline then
      print("WAITSUM MISS want=" .. s.waitsum .. " got=" .. fbsum()); nextStep()
    end
  elseif s.vis then
    if st == nil then st = 0 end
    st = st + 1
    if emu.read16(A_kVIS, M) == s.vis or st > 600 then nextStep() end
  elseif s.kbdrain then
    if st == nil then st = 0 end
    st = st + 1
    if (st > 30 and kbidle()) or st > s.kbdrain then nextStep() end
  elseif s.navto then
    -- closed loop: tap towards the key and re-read kSEL, so a dropped
    -- press costs a frame rather than the whole shot
    if st == nil then st = { n = 0, phase = 0 } end
    local sel = emu.read16(A_kSEL, M)
    if sel == s.navto then hold = {}; nextStep(); return end
    st.n = st.n + 1
    if st.n > 3000 then
      print("NAV STUCK want=" .. s.navto .. " kSEL=" .. sel); hold = {}; nextStep(); return
    end
    st.phase = (st.phase + 1) % 12
    if st.phase < 6 then hold = { [sel < s.navto and "right" or "left"] = true }
    else hold = {} end
  elseif s.dump then
    dumpfb(s.dump); nextStep()
  elseif s.done then
    print("DONE frame=" .. frame); emu.stop(0)
  end
end

-- setInput only lands from an inputPolled callback (an endFrame one is
-- silently ignored) — the d-pad has to be re-asserted on every poll
emu.addEventCallback(function()
  if next(hold) then emu.setInput(hold, 0) end
end, emu.eventType.inputPolled)
emu.addEventCallback(function()
  frame = frame + 1
  if boot == 0 then
    if frame > 1100 and frame % 10 == 0 and bufhas("C:\\>") then
      inject("CD \\WINDOWS\r"); boot = 1; mark = frame
    end
  elseif boot == 1 then
    if frame == mark + 240 then inject("WIN\r"); boot = 2 end
  elseif boot == 2 then                        -- the settled Executive,
    if frame % 60 == 0 then                    -- pixel-identical to runpc's
      local v = fbsum()
      if frame % 1800 == 0 then print("PROGRESS frame=" .. frame .. " sum=" .. v
                                      .. " want=" .. FBTARGET) end
      if v == FBTARGET then
        print("READY frame=" .. frame); boot = 3
      end
    end
  else
    runPlan()
    if frame % 1800 == 0 then
      print(string.format("PROGRESS frame=%d step=%d kSEL=%d kVIS=%d q=%d/%d",
            frame, pi, emu.read16(A_kSEL, M), emu.read16(A_kVIS, M),
            emu.read16(A_s9H, M), emu.read16(A_s9T, M)))
    end
  end
  if frame >= 140000 then print("TIMEOUT step=" .. pi); emu.stop(0) end
end, emu.eventType.endFrame)
LUA
cat build/wc_addr.lua build/wc_body.lua > build/wincalc.lua
"$MESEN" --testrunner "$(pwd)/build/msdos_sa1_overlay.sfc" "$(pwd)/build/wincalc.lua" \
         --timeout=9000 2>/dev/null | tee build/wincalc.log \
    | grep -a "READY\|STEP\|PROGRESS\|NAV\|WAITSUM\|DONE\|TIMEOUT"
python3 - "$OUT" <<'PY'
import sys
out = sys.argv[1]
fb, shot = {}, {}
for line in open('build/wincalc.log', 'rb').read().decode('latin1').splitlines():
    p = line.split(' ', 2)
    if len(p) == 3 and p[0] == 'FB':   fb[p[1]] = bytes.fromhex(p[2])
    if len(p) == 3 and p[0] == 'SHOT': shot[p[1]] = bytes.fromhex(p[2])
need = ['idle', 'oncalc', 'calcopen', 'typed', 'd8086']
missing = [n for n in need if n not in fb]
if missing:
    print('  FAIL: the run never reached', missing); sys.exit(1)
if 'd8086' in shot:
    open(out, 'wb').write(shot['d8086']); print('  wrote', out)

def px(b):                                 # 16000 CGA bytes -> 640x200 bits
    return [(b[(0 if y % 2 == 0 else 8000) + (y // 2) * 80 + (x >> 3)]
             >> (7 - (x & 7))) & 1 for y in range(200) for x in range(640)]

def diff(a, b, x0, y0, x1, y1):
    a, b = px(a), px(b)
    return sum(1 for y in range(y0, y1) for x in range(x0, x1)
               if a[y*640+x] != b[y*640+x])

ok = True
n = diff(fb['idle'], fb['calcopen'], 0, 0, 640, 200)
if n < 20000:
    print('  FAIL: the d-pad did not open CALC.EXE:', n); ok = False
else:
    print('  the d-pad opened CALC.EXE: %d of 128000 pixels repainted' % n)
n = diff(fb['calcopen'], fb['d8086'], 210, 56, 345, 78)
if n < 100:
    print('  FAIL: the on-screen keyboard left the readout alone:', n); ok = False
else:
    print('  the readout changed: %d pixels inside the display box' % n)

# and the real check: the SNES CGA bytes must equal what runpc rendered
d = open('build/wc_done.ppm', 'rb').read().split(b'\n', 3)
w, h = map(int, d[1].split())
rp = d[3]
ref = bytearray(16000)
for y in range(h):
    row = (0 if y % 2 == 0 else 8000) + (y // 2) * 80
    for xb in range(w // 8):
        b = 0
        for i in range(8):
            if rp[(y * w + xb * 8 + i) * 3] > 127:
                b |= 0x80 >> i
        ref[row + xb] = b
snes = fb['d8086']
bad = [i for i in range(16000) if ref[i] != snes[i]]
print('  framebuffer vs runpc: %d of 16000 bytes differ' % len(bad))
if bad:
    print('  FAIL: the SNES did not render what runpc rendered'); ok = False
sys.exit(0 if ok else 1)
PY
echo "== wincalc PASS"
