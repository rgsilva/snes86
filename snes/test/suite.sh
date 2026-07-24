#!/bin/sh
# snes86 regression suite: parity + host smoke + Mesen end-to-end tests.
#
#   test/suite.sh          full run (~10 min)
#   test/suite.sh quick    parity + boot + zork (~3 min)
#
# Each Mesen test prints exactly one "RESULT PASS/FAIL name" line.
#
# Uses the DEV build (MS-DOS 2.0 + the full local C:): the app tests drive
# GW-BASIC / WordStar / Multiplan / Zork, which live only on the dev C:
# (build/hd.img via tools/mkhd.py). So this needs your local disks/ software.
cd "$(dirname "$0")/.."
MESEN="${MESEN:-/Applications/Mesen.app/Contents/MacOS/Mesen}"
ROM="$(pwd)/build/msdos_dev.sfc"
FAIL=

echo "== build =="
make -s dev || { echo "FAIL build"; exit 1; }

echo "== parity (C core vs 65816 lockstep) =="
if ./test/parity.sh 2>&1 | grep -q "PARITY OK"; then
  echo "PASS parity"
else
  echo "FAIL parity"
  FAIL=1
fi

echo "== host smoke (ELKS boots to login on runpc) =="
make -s elks >/dev/null || { echo "FAIL elks-build"; FAIL=1; }
if printf '' \
     | ../core-c/build/runpc -m 172 -l 100000000 \
         -rom build/elks_rom.bin@e000 -rom build/elks_romfs.bin@8000 \
         -entry e000:0014 2>/dev/null \
     | grep -qE "login:|# "; then
  echo "PASS elks-host"
else
  echo "FAIL elks-host"
  FAIL=1
fi

echo "== host smoke (FreeDOS boots to FreeCOM on runpc) =="
make -s freedos >/dev/null || { echo "FAIL freedos-build"; FAIL=1; }
if printf '' \
     | ../core-c/build/runpc -m 172 -l 100000000 \
         -d build/hd_free.img build/freedos_a.img 2>/dev/null \
     | grep -q "FreeDOS on a SNES"; then
  echo "PASS freedos-host"
else
  echo "FAIL freedos-host"
  FAIL=1
fi

echo "== host smoke (runpc boots DOS, reads C:) =="
if printf 'type c:\\autoexec.bat\r' \
     | ../core-c/build/runpc -m 108 -l 1500000000 -d build/hd.img build/msdos_a.img 2>/dev/null \
     | grep -q "PATH A:"; then
  echo "PASS host-smoke"
else
  echo "FAIL host-smoke"
  FAIL=1
fi

echo "== host smoke (CGA mode 6 renders true 640x200 on runpc) =="
printf 'cga6tst\rx\r' \
  | ../core-c/build/runpc -m 108 -l 1500000000 -d build/hd.img \
      -cga build/cga6_host.ppm build/msdos_a.img >/dev/null 2>&1
if python3 -c '
import sys
d = open("build/cga6_host.ppm","rb").read().split(b"\n",3)
w,h = map(int, d[1].split()); p = d[3]
ok = (w,h) == (640,200)                                # true 640-wide
ok = ok and all(p[x*3] == (255,0)[x%2] for x in range(8))   # 1px stripes
ok = ok and p[96*640*3] == 255                         # white band
sys.exit(0 if ok else 1)' 2>/dev/null; then
  echo "PASS cga6-host"
else
  echo "FAIL cga6-host"
  FAIL=1
fi

echo "== host smoke (VIEW.COM paints the test cards on runpc) =="
# (the SNES-side render path is t_cga6's job; a full paint at SNES speed
# is ~5 emulated minutes, so the Mesen leg - test/t_view.lua - is manual.
# CARD.PCX carries the same pixels as CARD.BMP, so the two renders must
# be bit-identical - one check covers the PCX decoder end to end.)
printf 'cd pics\rview card.bmp\rx\r' \
  | ../core-c/build/runpc -m 108 -l 3000000000 -d build/hd.img \
      -cga build/view_host.ppm build/msdos_a.img >/dev/null 2>&1
printf 'cd pics\rview card.pcx\rx\r' \
  | ../core-c/build/runpc -m 108 -l 3000000000 -d build/hd.img \
      -cga build/view_host2.ppm build/msdos_a.img >/dev/null 2>&1
if python3 -c '
import sys
d = open("build/view_host.ppm","rb").read().split(b"\n",3)
w,h = map(int, d[1].split()); p = d[3]
ok = (w,h) == (640,200)
row = lambda y: [p[(y*640+x)*3] for x in range(0,640,7)]
ok = ok and max(row(5)) == 0                 # letterbox: 480-tall fits 160
ok = ok and 0 in row(100) and 255 in row(100)   # dithered content
ok = ok and open("build/view_host2.ppm","rb").read() == open("build/view_host.ppm","rb").read()
sys.exit(0 if ok else 1)' 2>/dev/null; then
  echo "PASS view-host"
else
  echo "FAIL view-host"
  FAIL=1
fi

echo "== host smoke (TED round-trips a file on runpc) =="
python3 tools/mktedimg.py >/dev/null
printf '\r\rted t.txt\rHello from TED on a SNES!\rline two here\033S\033Q\r' \
  | ../core-c/build/runpc -m 108 -l 900000000 -w build/tedtest.img >/dev/null 2>&1
python3 tools/mktedimg.py --extract T.TXT build/ted_host.txt >/dev/null 2>&1
if python3 -c '
import sys
want = b"Hello from TED on a SNES!\r\nline two here\r\n"
try:
    sys.exit(0 if open("build/ted_host.txt","rb").read() == want else 1)
except Exception:
    sys.exit(1)'; then
  echo "PASS ted-host"
else
  echo "FAIL ted-host"
  FAIL=1
fi

TESTS="t_boot t_dirb t_zork t_gwb t_ws t_mp t_m40 t_kbd t_cga t_cga6 t_midi"
[ "$1" = "quick" ] && TESTS="t_boot t_zork t_cga"

for t in $TESTS; do
  r=$("$MESEN" --testrunner "$ROM" "$(pwd)/test/$t.lua" 2>/dev/null | grep '^RESULT' | head -1)
  echo "${r:-RESULT FAIL $t (no output)}"
  case "$r" in
    *PASS*) ;;
    *) FAIL=1 ;;
  esac
done

# TED end-to-end: type into the editor on the SNES, cursor with arrow
# scancodes, menu-save to B: (the battery-backed SRAM drive), quit, and
# TYPE the file back. Starts from fresh SRAM: Mesen keys .srm files by
# ROM name, so stale B: contents from any earlier run would leak in.
if [ "$1" != "quick" ]; then
  rm -f "$HOME/Library/Application Support/Mesen2/Saves/msdos_dev.srm"
  r=$("$MESEN" --testrunner --timeout=300 "$ROM" \
      "$(pwd)/test/t_ted.lua" 2>/dev/null | grep '^RESULT' | head -1)
  echo "${r:-RESULT FAIL t_ted (no output)}"
  case "$r" in
    *PASS*) ;;
    *) FAIL=1 ;;
  esac
fi

# ELKS end-to-end (own ROM, own timeout: boot to login is ~2 emulated
# minutes; Mesen's default 100 s testrunner limit would kill it).
if [ "$1" != "quick" ]; then
  r=$("$MESEN" --testrunner --timeout=1500 "$(pwd)/build/elks.sfc" \
      "$(pwd)/test/t_elks.lua" 2>/dev/null | grep '^RESULT' | head -1)
  echo "${r:-RESULT FAIL t_elks (no output)}"
  case "$r" in
    *PASS*) ;;
    *) FAIL=1 ;;
  esac
fi

# FreeDOS end-to-end (own ROM, own timeout: BIGMEM kernel init is the
# slowest boot in the fleet — and it executes code straight across the
# WRAM->SRAM seam, which regression-guards the fetch bounce).
if [ "$1" != "quick" ]; then
  r=$("$MESEN" --testrunner --timeout=1800 "$(pwd)/build/freedos.sfc" \
      "$(pwd)/test/t_fdos.lua" 2>/dev/null | grep '^RESULT' | head -1)
  echo "${r:-RESULT FAIL t_fdos (no output)}"
  case "$r" in
    *PASS*) ;;
    *) FAIL=1 ;;
  esac
fi

echo
if [ -z "$FAIL" ]; then
  echo "== ALL PASS =="
else
  echo "== FAILURES PRESENT =="
  exit 1
fi
