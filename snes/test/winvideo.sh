#!/bin/sh
# winvideo.sh HDIMG [OUT.mp4] — the Windows 1.01 demo reel, filmed on the SNES.
#
# wincalc.sh proves the thing works; this films it. Same ROM, same
# choreography, same closed-loop drive off the emulator's own variables —
# the only addition is that Mesen hands back a screenshot every few
# frames and ffmpeg glues them into a video host-side. Nothing is
# re-enacted and nothing is sped up in the guest: what you see is the
# SA-1 machine running at its own pace, sampled at different strides so
# the boring parts are a timelapse and the interesting parts are not.
#
# The cut:
#   1. boot      MS-DOS 2.0 prompt, CD \WINDOWS, WIN, the long crawl to
#                the MS-DOS Executive (~38 000 frames — heavy timelapse)
#   2. select    one d-pad Down onto CALC.EXE, START to run it (real time)
#   3. load      Windows reads CALC.EXE off the fixed disk behind an
#                hourglass, thousands of frames of a still screen
#                (timelapse)
#   4. type      SELECT raises the on-screen keyboard, A presses keys,
#                8086 lands in the Calculator's readout (real time)
#   5. pan       L/R pan the 640x200 mode-6 picture across the SNES's
#                512-pixel window, revealing the 128 px it cannot show
#   6. hold      the final frame, held
#
# Bring-your-own media: HDIMG is a C: image carrying an installed
# Windows in \WINDOWS. Nothing here ships and the input image is never
# modified; the video is a screen recording, on the same footing as the
# Windows stills already in docs/assets.
#
#   ./test/winvideo.sh ../disks/windows.img ../docs/assets/windows_demo.mp4
#
# Mesen's Lua sandbox has no `io`, so each screenshot comes back as a
# hex line on stdout and Python cuts the log back up into PNGs. That
# makes the log big (tens of MB) but it keeps the capture in one pass:
# the whole run is ~4 host minutes and re-cutting the video afterwards
# costs nothing, because the frames are still sitting in build/winvid.
set -e
HD=$1
OUT=${2:-windows_demo.mp4}
MESEN="${MESEN:-/Applications/Mesen.app/Contents/MacOS/Mesen}"
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
[ -n "$HD" ] && [ -f "$HD" ] || {
    echo "usage: winvideo.sh path/to/windows-hd.img [out.mp4]"; exit 1; }
HD=$(cd "$(dirname "$HD")" && pwd)/$(basename "$HD")
case $OUT in /*) ;; *) OUT=$PWD/$OUT ;; esac
cd "$(dirname "$0")/.."
mkdir -p build

# CAPTURE=0 re-cuts the video from the frames of the previous run, which
# is the whole point of keeping them: the encode is a second, the
# capture is four minutes.
if [ "${CAPTURE:-1}" = 1 ]; then

echo "== build: SA-1 ROM + $HD as an overlay"
make -s msdos_sa1 OVERLAYS="$HD"

echo "== the oracle: runpc renders the three waypoints"
# The video's own waits are the same exact-match waits wincalc.sh uses,
# for the same reason: while Windows loads CALC.EXE the screen sits
# perfectly still for thousands of frames, so every "wait until it stops
# changing" heuristic fires early. Waiting for the framebuffer to *be*
# what the C core rendered is the only honest signal.
make -s -C ../core-c runpc
python3 - <<'PY'
import sys
sys.path.insert(0, '../apps')
import fatimg
f = fatimg.Floppy('build/msdos_a.img')
old = fatimg.read_img('build/msdos_a.img')['AUTOEXEC.BAT']
f.replace('AUTOEXEC.BAT', old + b'CD \\WINDOWS\r\nWIN\r\n')
f.save('build/wc_a.img')
PY
win() {   # win OUT.ppm STEPS KEYS
    rm -f "$1"
    printf '%b' "$3" | ../core-c/build/runpc -m 300 \
        -d build/hd_overlay.img -cga "$1" -l "$2" \
        -kdelay 20000000 -krate 2000000 build/wc_a.img \
        > build/wv_runpc.log 2>&1 || true
    [ -s "$1" ] || { echo "FAIL: runpc never reached CGA mode 6"; exit 1; }
}
win build/wc_idle.ppm 20500000 ''
win build/wc_open.ppm 26000000 '\033[B\r'
win build/wc_done.ppm 32000000 '\033[B\r8086'
echo "  three waypoints rendered"

python3 - > build/wv_addr.lua <<'PY'
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
print('local FBTARGET = %d' % cksum('build/wc_idle.ppm'))
print('local FBOPEN = %d' % cksum('build/wc_open.ppm'))
print('local FBDONE = %d' % cksum('build/wc_done.ppm'))
PY

cat > build/wv_body.lua <<'LUA'
local M = emu.memType.snesMemory
local frame, t, boot, mark = 0, 0, 0, 0
local hold = {}
local shots, tag, stride = 0, "boot", 12
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
-- one frame of film. Mesen's sandbox has no io, so the PNG goes out as
-- hex on stdout and the host cuts the log back up.
local function shoot()
  local png = emu.takeScreenshot()
  shots = shots + 1
  print(string.format("SHOT %05d %d %s %s", shots, frame, tag,
        png:gsub(".", function(c) return string.format("%02x", c:byte()) end)))
end
local function kbidle()                        -- every scancode delivered
  return emu.read16(A_s9H, M) == emu.read16(A_s9T, M)
end

-- ---- the choreography (wincalc.sh's, with a camera bolted on) --------
local plan = {}
local function add(s) plan[#plan + 1] = s end
-- 6 frames is one keypress: the d-pad autorepeat delay is 15 frames, so
-- a short hold moves the selection exactly once.
local function tap(btn, n)
  add{ hold = { [btn] = true }, frames = n or 6 }
  add{ hold = {}, frames = 6 }
end
local function quiet()
  add{ settle = 1200, need = 4, period = 30 }
end
-- `film` switches the segment the next frames are filed under and how
-- often they are sampled. Everything downstream of here is host-side
-- editing, so the strides only have to be *fine enough*.
local function film(t, s) add{ film = t, stride = s } end

film("sel", 3)
add{ pause = 60 }                                  -- a beat on the Executive
tap("down");  quiet()                              -- ABC.TXT -> CALC.EXE
add{ pause = 45 }
tap("start")                                       -- START is Enter
film("load", 120)
add{ waitsum = FBOPEN, deadline = 90000 }
film("type", 3)
add{ pause = 60 }
tap("select"); add{ vis = 1 }                      -- raise the keyboard
-- row 0 of the layout is "1234567890-=", so these are 8, 0, 8, 6
for _, k in ipairs{ 7, 9, 7, 5 } do
  add{ navto = k }; add{ hold = {}, frames = 6 }
  tap("a"); add{ kbdrain = 600 }; quiet()
end
add{ pause = 90 }
tap("select"); add{ vis = 0 }                      -- put the keyboard away
add{ waitsum = FBDONE, deadline = 12000 }
add{ dump = "d8086" }                              -- the frame wincalc checks
add{ pause = 90 }
-- The reveal: mode 6 is 640x200 and the SNES window shows 512 of it.
-- L/R pan, and gfx_scan6 repaints one row per frame, so each step needs
-- ~25 frames to finish drawing before the next one.
film("pan", 3)
add{ panto = 8 };  add{ pause = 40 }
add{ panto = 16 }; add{ pause = 120 }
add{ panto = 8 };  add{ pause = 40 }
add{ panto = 0 };  add{ pause = 90 }
add{ done = true }

-- ---- the sequencer ---------------------------------------------------
local pi, st = 1, nil
local function nextStep()
  pi = pi + 1; st = nil
end
local function runPlan()
  local s = plan[pi]
  if s == nil then return end
  if s.film then
    tag = s.film; stride = s.stride
    print(string.format("SEG %s stride=%d frame=%d", tag, stride, frame))
    nextStep()
  elseif s.hold then
    if st == nil then st = 0; hold = s.hold end
    st = st + 1
    if st >= s.frames then hold = {}; nextStep() end
  elseif s.pause then
    if st == nil then st = 0 end
    st = st + 1
    if st >= s.pause then nextStep() end
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
  elseif s.panto then
    -- same closed loop, on kPAN: L/R are edge-triggered and step by 8,
    -- so a press has to be released before the next one counts
    if st == nil then st = { n = 0, phase = 0 } end
    local p = emu.read16(A_kPAN, M)
    if p == s.panto then hold = {}; nextStep(); return end
    st.n = st.n + 1
    if st.n > 600 then
      print("PAN STUCK want=" .. s.panto .. " kPAN=" .. p); hold = {}; nextStep(); return
    end
    st.phase = (st.phase + 1) % 16
    if st.phase < 6 then hold = { [p < s.panto and "r" or "l"] = true }
    else hold = {} end
  elseif s.dump then
    local fb = {}
    for a = 0x7E1000, 0x7E1000 + 7999 do fb[#fb+1] = string.format("%02x", emu.read(a, M)) end
    for a = 0x7E3000, 0x7E3000 + 7999 do fb[#fb+1] = string.format("%02x", emu.read(a, M)) end
    print("FB " .. s.dump .. " " .. table.concat(fb))
    nextStep()
  elseif s.done then
    print("DONE frame=" .. frame .. " shots=" .. shots); emu.stop(0)
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
    if frame == mark + 240 then
      inject("WIN\r"); boot = 2
      tag = "boot"; stride = 120           -- the long crawl: sample it thin
      print("SEG boot2 stride=120 frame=" .. frame)
    end
  elseif boot == 2 then                        -- the settled Executive,
    if frame % 60 == 0 then                    -- pixel-identical to runpc's
      local v = fbsum()
      if frame % 1800 == 0 then print("PROGRESS frame=" .. frame .. " sum=" .. v
                                      .. " want=" .. FBTARGET) end
      if v == FBTARGET then
        print("READY frame=" .. frame .. " shots=" .. shots); boot = 3
      end
    end
  else
    runPlan()
    if frame % 3600 == 0 then
      print(string.format("PROGRESS frame=%d step=%d shots=%d kSEL=%d kPAN=%d",
            frame, pi, shots, emu.read16(A_kSEL, M), emu.read16(A_kPAN, M)))
    end
  end
  if frame % stride == 0 then shoot() end
  if frame >= 140000 then print("TIMEOUT step=" .. pi); emu.stop(0) end
end, emu.eventType.endFrame)
LUA
cat build/wv_addr.lua build/wv_body.lua > build/winvideo.lua

echo "== filming: Mesen, headless, on build/msdos_sa1_overlay.sfc (~4 min)"
rm -rf build/winvid; mkdir -p build/winvid
"$MESEN" --testrunner "$(pwd)/build/msdos_sa1_overlay.sfc" "$(pwd)/build/winvideo.lua" \
         --timeout=9000 2>/dev/null > build/winvideo.log
grep -a "SEG\|READY\|PROGRESS\|NAV\|PAN\|WAITSUM\|DONE\|TIMEOUT" build/winvideo.log || true

echo "== cutting the log back into PNGs"
python3 - <<'PY'
import os
seg = {}
n = 0
with open('build/winvideo.log', 'rb') as fh:
    for line in fh:
        if not line.startswith(b'SHOT '):
            continue
        p = line.split(b' ', 4)
        tag = p[3].decode()
        i = seg.get(tag, 0)
        seg[tag] = i + 1
        open('build/winvid/%s_%05d.png' % (tag, i), 'wb').write(
            bytes.fromhex(p[4].strip().decode()))
        n += 1
print('  %d frames: %s' % (n, ', '.join('%s=%d' % kv for kv in seg.items())))
PY

fi   # CAPTURE

echo "== assembling with ffmpeg"
python3 - "$OUT" "$FFMPEG" <<'PY'
import os, subprocess, sys, struct, hashlib
out, ffmpeg = sys.argv[1], sys.argv[2]
D = 'build/winvid'

def dims(p):
    with open(p, 'rb') as f:
        f.seek(16)
        return struct.unpack('>II', f.read(8))

# The cut. `stride` is a *second* subsample on top of the one the
# emulator already did and `fps` is how fast the segment plays, so the
# pacing can be retuned without refilming (CAPTURE=0). `cap` is the
# interesting one: it is the longest run of *byte-identical* frames the
# segment may hold on to.
#
# The SNES spends most of this demo not changing the screen at all —
# 1412 of the typing leg's frames are only 128 distinct pictures,
# because the on-screen keyboard's closed-loop navigation waits on the
# guest between presses. Capping the still runs keeps the rhythm of
# "press, readout changes, press" and throws away the dead air, without
# ever speeding up something that actually moves. The hourglass leg is
# deliberately left uncapped: there, the waiting *is* the point.
#   boot  ~38 000 frames of crawl, sampled 1:120 -> ~10 s
#   sel   the moment of intent
#   load  the hourglass, ~19 500 frames of it
#   type  the payoff: 8086 going in a key at a time
#   pan   the 128 px the SNES window cannot show, revealed
CUT = [('boot', 2, 24, None), ('sel', 1, 20, 25), ('load', 1, 24, None),
       ('type', 1, 20, 4), ('pan', 1, 20, 20)]
HOLD = 3.0                       # seconds to hold the last frame

inputs, filt, labels, k = [], [], [], 0
for tag, stride, fps, cap in CUT:
    files = sorted(f for f in os.listdir(D) if f.startswith(tag + '_'))
    files = files[::stride]
    if cap:
        kept, run, prev = [], 0, None
        for f in files:
            h = hashlib.md5(open(os.path.join(D, f), 'rb').read()).hexdigest()
            run = run + 1 if h == prev else 1
            prev = h
            if run <= cap: kept.append(f)
        files = kept
    if not files:
        print('  (no %s frames)' % tag); continue
    # a segment whose picture changes size has to be split, because the
    # image2 demuxer wants one geometry per input
    runs, cur, d0 = [], [], None
    for f in files:
        d = dims(os.path.join(D, f))
        if d != d0:
            if cur: runs.append((d0, cur))
            cur, d0 = [], d
        cur.append(f)
    if cur: runs.append((d0, cur))
    for d, run in runs:
        # image2 wants a contiguous %05d sequence, so each run gets a
        # directory of symlinks; the PNGs themselves are written once
        sub = os.path.join(D, 'in_%02d' % k)
        os.makedirs(sub, exist_ok=True)
        for old in os.listdir(sub):      # a shorter re-cut must not leave
            os.unlink(os.path.join(sub, old))   # the last one's tail behind
        for i, f in enumerate(run):
            os.symlink(os.path.join('..', f), os.path.join(sub, '%05d.png' % i))
        inputs += ['-framerate', str(fps), '-start_number', '0',
                   '-i', os.path.join(sub, '%05d.png')]
        filt.append('[%d:v]fps=60,scale=512:448:flags=neighbor,setsar=1[v%d]'
                    % (k, k))
        labels.append('[v%d]' % k)
        print('  %-5s %4d frames @ %d fps  %dx%d -> %.1f s'
              % (tag, len(run), fps, d[0], d[1], len(run) / fps))
        k += 1

# hold the final frame: a one-image input, looped for HOLD seconds
last = sorted(f for f in os.listdir(D) if f.startswith('pan_')) or \
       sorted(f for f in os.listdir(D) if f.startswith('type_'))
inputs += ['-loop', '1', '-framerate', '60', '-t', '%.3f' % HOLD,
           '-i', os.path.join(D, last[-1])]
filt.append('[%d:v]fps=60,scale=512:448:flags=neighbor,setsar=1[v%d]' % (k, k))
labels.append('[v%d]' % k)
print('  hold  %.1f s' % HOLD)
k += 1

# the concat FILTER, not the demuxer: the demuxer mangles segments that
# were shot at different rates, the filter renormalises each to 60 fps
fc = ';'.join(filt) + ';' + ''.join(labels) + 'concat=n=%d:v=1:a=0[o]' % k
cmd = [ffmpeg, '-y'] + inputs + ['-filter_complex', fc, '-map', '[o]',
       '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '20',
       '-preset', 'slow', '-movflags', '+faststart', '-r', '60', out]
subprocess.run(cmd, check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print('  wrote %s (%d bytes)' % (out, os.path.getsize(out)))
PY
"${FFMPEG%ffmpeg}ffprobe" -v error -show_entries \
    format=duration,size:stream=codec_name,width,height,r_frame_rate,pix_fmt \
    -of default=nw=1 "$OUT" || true
echo "== winvideo done"
