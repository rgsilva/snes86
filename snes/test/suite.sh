#!/bin/sh
# snes86 regression suite: parity + host smoke + Mesen end-to-end tests.
#
#   test/suite.sh          full run
#   test/suite.sh quick    parity + boot + cga (~3 min)
#
# Each Mesen test prints exactly one "RESULT PASS/FAIL name" line.
#
# Generic legs run against the PUBLIC ROM (build/msdos.sfc) — the exact
# artifact that ships. The copyrighted app-matrix legs (t_zork t_gwb
# t_ws t_mp t_m40) run against build/msdos_apps.sfc, and are SKIPPED
# with a warning unless disks/appmatrix/ exists (generate it once with
# disks/mkappmatrix.py on a machine that has the local software).
cd "$(dirname "$0")/.."
MESEN="${MESEN:-/Applications/Mesen.app/Contents/MacOS/Mesen}"
ROM="$(pwd)/build/msdos.sfc"
APPSROM="$(pwd)/build/msdos_apps.sfc"
FAIL=

# Mesen is effectively single-instance: a --testrunner launch against a
# running GUI can hand off, hang, or fail silently — and this suite
# deletes msdos*.srm (see the t_ted leg), which would clobber a live
# session's B: drive. Refuse to run while a GUI instance is open
# (a Mesen process whose command line has no --testrunner).
GUI=$(pgrep -f 'MacOS/Mesen' 2>/dev/null | while read -r p; do
        ps -p "$p" -o args= 2>/dev/null | grep -q -- '--testrunner' || echo "$p"
      done)
if [ -n "$GUI" ]; then
  echo "close the Mesen GUI first — testrunner and GUI collide (pid: $GUI)"
  exit 1
fi

echo "== build =="
make -s msdos || { echo "FAIL build"; exit 1; }
HAVE_APPS=
if [ -d ../disks/appmatrix ]; then
  make -s apps || { echo "FAIL apps build"; exit 1; }
  HAVE_APPS=1
fi

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
     | ../core-c/build/runpc -m 108 -l 1500000000 -d build/hd_free.img build/msdos_a.img 2>/dev/null \
     | grep -q "PATH C:"; then
  echo "PASS host-smoke"
else
  echo "FAIL host-smoke"
  FAIL=1
fi

echo "== host smoke (CGA mode 6 renders true 640x200 on runpc) =="
printf 'cd bench\rcga6tst\rx\r' \
  | ../core-c/build/runpc -m 108 -l 1500000000 -d build/hd_free.img \
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
printf 'cd view\rview card.bmp\rx\r' \
  | ../core-c/build/runpc -m 108 -l 3000000000 -d build/hd_free.img \
      -cga build/view_host.ppm build/msdos_a.img >/dev/null 2>&1
printf 'cd view\rview card.pcx\rx\r' \
  | ../core-c/build/runpc -m 108 -l 3000000000 -d build/hd_free.img \
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
printf 'ted t.txt\rHello from TED on a SNES!\rline two here\033S\033Q\r' \
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

echo "== host smoke (JAVA runs javac bytecode on runpc) =="
# HELLO.CLA is real javac --release 8 output; JAVA.COM interprets it.
# FIB.CLA exercises the 32-bit int core + branches + a static method.
printf 'cd java\rjava hello\r' \
  | ../core-c/build/runpc -m 108 -l 3000000000 -d build/hd_free.img build/msdos_a.img 2>/dev/null \
  | tr -d '\r' > build/java_host.log
printf 'cd java\rjava fib\r' \
  | ../core-c/build/runpc -m 108 -l 3000000000 -d build/hd_free.img build/msdos_a.img 2>/dev/null \
  | tr -d '\r' >> build/java_host.log
if grep -q "Hello from Java on a SNES" build/java_host.log \
   && grep -q "112358132134" build/java_host.log; then
  echo "PASS java-host"
else
  echo "FAIL java-host"
  FAIL=1
fi

echo "== host smoke (Small-C compiles and runs C on runpc) =="
# The full workstation shape at 108 KB: toolchain on read-only C:\CC
# (found via PATH - DOS 2.x cannot exec by explicit path), sources and
# every intermediate on the writable work floppy (the SNES's B: role),
# batch-driven. LINK spills VM.TMP to the work drive; that is normal.
python3 tools/mkccimg.py >/dev/null
printf 'a:\rgo\r' \
  | ../core-c/build/runpc -m 108 -l 9000000000 -w build/cctest.img \
      -d build/hd_free.img 2>/dev/null | tr -d '\r' > build/cc_host.log
if grep -q "Hello from Small-C inside snes86!" build/cc_host.log \
   && grep -q "1899 primes (expect 1899)" build/cc_host.log; then
  echo "PASS cc-host"
else
  echo "FAIL cc-host"
  FAIL=1
fi

# --- Mesen legs: generic tests drive the PUBLIC ROM ---
TESTS="t_boot t_dirb t_kbd t_cga t_cga6 t_midi t_ted"
[ "$1" = "quick" ] && TESTS="t_boot t_cga"

for t in $TESTS; do
  if [ "$t" = "t_ted" ]; then
    # t_ted saves to B:; Mesen keys .srm files by ROM name, and stale B:
    # contents from an earlier run would leak into the assertion.
    # NOTE: this DELETES the user's B: drive for any same-named ROM
    # (msdos.srm) — suite runs are destructive to B:, by design.
    rm -f "$HOME/Library/Application Support/Mesen2/Saves/msdos.srm"
  fi
  r=$("$MESEN" --testrunner "$ROM" "$(pwd)/test/$t.lua" 2>/dev/null | grep '^RESULT' | head -1)
  echo "${r:-RESULT FAIL $t (no output)}"
  case "$r" in
    *PASS*) ;;
    *) FAIL=1 ;;
  esac
done

# --- app-matrix legs: copyrighted software, local machines only ---
APPTESTS="t_zork t_gwb t_ws t_mp t_m40"
if [ "$1" != "quick" ]; then
  if [ -n "$HAVE_APPS" ]; then
    for t in $APPTESTS; do
      r=$("$MESEN" --testrunner "$APPSROM" "$(pwd)/test/$t.lua" 2>/dev/null | grep '^RESULT' | head -1)
      echo "${r:-RESULT FAIL $t (no output)}"
      case "$r" in
        *PASS*) ;;
        *) FAIL=1 ;;
      esac
    done
  else
    echo "SKIP app-matrix legs ($APPTESTS): no disks/appmatrix/ -" \
         "run disks/mkappmatrix.py on a machine with the local software"
  fi
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
