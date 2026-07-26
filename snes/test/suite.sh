#!/bin/sh
# snes86 regression suite.
#
#   test/suite.sh free           public legs: parity + host smokes + Mesen
#   test/suite.sh free quick     parity + boot + cga (~3 min)
#   test/suite.sh extra          ONLY the copyrighted app-matrix legs
#
# `make test` / `make test-extra` (root or snes/) are the front doors.
#
# free: everything runs against the PUBLIC ROM (build/msdos.sfc) — the
# exact artifact that ships. Mesen legs (and parity, which drives the
# 65816 core through Mesen) self-SKIP with one loud line when Mesen is
# absent (e.g. CI); the host legs still gate the run.
#
# extra: the copyrighted app legs (t_zork t_gwb t_ws t_mp t_m40) against
# a private fixture ROM — the public machine + disks/appmatrix overlaid
# via OVERLAYS (build/msdos_overlay.sfc, never shipped). Refuses to run
# with an incomplete disks/ (disks/mkappmatrix.py --check says what's
# missing); needs Mesen.
cd "$(dirname "$0")/.."
MODE="${1:-free}"
[ "$MODE" = "quick" ] && { MODE=free; set -- free quick; }   # legacy spelling
QUICK=; [ "$2" = "quick" ] && QUICK=1
MESEN="${MESEN:-/Applications/Mesen.app/Contents/MacOS/Mesen}"
HAVE_MESEN=; [ -x "$MESEN" ] && HAVE_MESEN=1
ROM="$(pwd)/build/msdos.sfc"
APPSROM="$(pwd)/build/msdos_overlay.sfc"
FAIL=

# the host legs all drive runpc
[ -x ../core-c/build/runpc ] || make -s -C ../core-c runpc \
  || { echo "suite needs core-c/build/runpc"; exit 1; }

# Mesen is effectively single-instance: a --testrunner launch against a
# running GUI can hand off, hang, or fail silently — and this suite
# deletes msdos*.srm (see the t_ted leg), which would clobber a live
# session's B: drive. Refuse to run while a GUI instance is open
# (a Mesen process whose command line has no --testrunner).
if [ -n "$HAVE_MESEN" ]; then
  GUI=$(pgrep -f 'MacOS/Mesen' 2>/dev/null | while read -r p; do
          ps -p "$p" -o args= 2>/dev/null | grep -q -- '--testrunner' || echo "$p"
        done)
  if [ -n "$GUI" ]; then
    echo "close the Mesen GUI first — testrunner and GUI collide (pid: $GUI)"
    exit 1
  fi
fi

# one Mesen leg = one "RESULT PASS/FAIL name" line
mesen_leg() {  # mesen_leg <rom> <test> [extra testrunner args]
  _rom=$1; _t=$2; shift 2
  r=$("$MESEN" --testrunner "$@" "$_rom" "$(pwd)/test/$_t.lua" 2>/dev/null \
      | grep '^RESULT' | head -1)
  echo "${r:-RESULT FAIL $_t (no output)}"
  case "$r" in
    *PASS*) ;;
    *) FAIL=1 ;;
  esac
}

# --- extra mode: the app-matrix legs, nothing else -------------------
if [ "$MODE" = "extra" ]; then
  python3 ../disks/mkappmatrix.py --check || {
    echo "test-extra: disks/ is incomplete (list above) — no legs run"
    exit 1
  }
  [ -n "$HAVE_MESEN" ] || { echo "test-extra needs Mesen ($MESEN)"; exit 1; }
  echo "== build (fixture: public machine + disks/appmatrix) =="
  python3 ../disks/mkappmatrix.py || exit 1
  make -s msdos OVERLAYS=../disks/appmatrix || { echo "FAIL fixture build"; exit 1; }
  for t in t_zork t_gwb t_ws t_mp t_m40; do
    mesen_leg "$APPSROM" "$t"
  done
  echo
  if [ -z "$FAIL" ]; then echo "== ALL PASS =="; else echo "== FAILURES PRESENT =="; exit 1; fi
  exit 0
fi

# --- free mode --------------------------------------------------------
echo "== build =="
make -s msdos || { echo "FAIL build"; exit 1; }

if [ -n "$HAVE_MESEN" ]; then
  echo "== parity (C core vs 65816 lockstep) =="
  if ./test/parity.sh 2>&1 | grep -q "PARITY OK"; then
    echo "PASS parity"
  else
    echo "FAIL parity"
    FAIL=1
  fi
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
     | ../core-c/build/runpc -m 300 -l 100000000 \
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

echo "== host smoke (TED direct Ctrl-key bindings on runpc) =="
# Keyboard-only path: ^S save, ^A save-as, ^L/^O load, ^F search,
# ^G goto, ^U undo, ^Q quit — no Esc-menu trips. Three sessions against
# one fresh image; each marker letter lands only if the binding that
# positioned/saved it worked. (F-keys can't ride runpc stdin — AH comes
# from AL there — so the F-key aliases are t_ted.lua's job under Mesen.)
python3 tools/mktedimg.py >/dev/null
# 1: ^G 1, ^F two -> X before the match, ^S, ^A -> u.txt, ^Q
printf 'ted t.txt\rline one\rline two\rline three\0071\r\006two\rX\023\001\010\010\010\010\010u.txt\r\021\r' \
  | ../core-c/build/runpc -m 108 -l 900000000 -w build/tedtest.img >/dev/null 2>&1
# 2: ^G 2 -> Q, ^G 3 -> AB then ^U undoes it, ^S, ^Q
printf 'ted t.txt\r\0072\rQ\0073\rAB\025\023\021\r' \
  | ../core-c/build/runpc -m 108 -l 900000000 -w build/tedtest.img >/dev/null 2>&1
# 3: ^O loads t.txt into an empty TED -> W, ^S, ^L u.txt -> E, ^S, ^Q
printf 'ted\r\017t.txt\rW\023\014\010\010\010\010\010u.txt\rE\023\021\r' \
  | ../core-c/build/runpc -m 108 -l 900000000 -w build/tedtest.img >/dev/null 2>&1
python3 tools/mktedimg.py --extract T.TXT build/ted_keys_t.txt >/dev/null 2>&1
python3 tools/mktedimg.py --extract U.TXT build/ted_keys_u.txt >/dev/null 2>&1
if python3 -c '
import sys
wt = b"Wline one\r\nQline Xtwo\r\nline three\r\n"
wu = b"Eline one\r\nline Xtwo\r\nline three\r\n"
try:
    ok = open("build/ted_keys_t.txt","rb").read() == wt \
     and open("build/ted_keys_u.txt","rb").read() == wu
    sys.exit(0 if ok else 1)
except Exception:
    sys.exit(1)'; then
  echo "PASS ted-host-keys"
else
  echo "FAIL ted-host-keys"
  FAIL=1
fi

echo "== host smoke (VI - levee - edits a file on runpc) =="
# a real vi (levee 4.0b, BIOS INT10 screen layer) on the 108 KB machine:
# insert two lines, 1G dd p swaps them, :wq writes CRLF to A: (C: is
# read-only), TYPE proves the round trip inside the same session.
printf 'cd vi\rvi a:v.txt\rivi on a SNES, line one\rand line two\0331Gddp:wq\rtype a:v.txt\r' \
  | ../core-c/build/runpc -m 108 -l 1500000000 -d build/hd_free.img build/msdos_a.img 2>/dev/null \
  | tr -d '\r' > build/vi_host.log
if grep -A1 "^and line two" build/vi_host.log | grep -q "^vi on a SNES, line one"; then
  echo "PASS vi-host"
else
  echo "FAIL vi-host"
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
if grep -q "SNES emulating" build/java_host.log \
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

echo "== host smoke (JAVAC compiles Java ON the machine, JAVA runs it) =="
# The whole loop inside one DOS session: JAVAC.EXE (C:\JAVA, built by
# Small-C under runpc) compiles HELLO.JAV; the .CLA lands on A: because
# C: is read-only; JAVA interprets it. One session — A: writes are
# in-memory only without -w.
printf 'a:\rpath c:\\java\rjavac c:\\java\\hello.jav hi.cla\rjava hi\r' \
  | ../core-c/build/runpc -m 108 -l 9000000000 -d build/hd_free.img build/msdos_a.img 2>/dev/null \
  | tr -d '\r' > build/jc_host.log
if grep -q "^ok: " build/jc_host.log \
   && grep -q "SNES emulating" build/jc_host.log; then
  echo "PASS jc-host"
else
  echo "FAIL jc-host"
  FAIL=1
fi

# Desktop cross-check: the host build of the same compiler must emit a
# class a real JVM runs (skips cleanly without a JDK).
if command -v java >/dev/null 2>&1; then
  make -C ../apps/java javac-dev >/dev/null 2>&1
  rm -rf build/jcx && mkdir -p build/jcx
  if ../apps/java/hostbuild/javac-dev ../apps/java/samples/Hello.java build/jcx/Hello.class >/dev/null 2>&1 \
     && (cd build/jcx && java Hello 2>/dev/null | grep -q "SNES emulating"); then
    echo "PASS jc-desktop"
  else
    echo "FAIL jc-desktop"
    FAIL=1
  fi
else
  echo "SKIP jc-desktop (no JDK on host)"
fi

echo "== host smoke (GB.COM runs a Game Boy: homebrew cart + Blargg) =="
# GB.COM ships on C:\GB with its homebrew carts. Leg 1 is the shipped
# experience: the smoke cart prints over the GB serial port (-t wires
# it to the console) and STOPs — a clean exit back to DOS. Leg 2 runs
# Blargg's "06-ld r,r" cpu_instrs ROM (fetched + cached with a pinned
# sha256, never committed; upstream GB.COM passes all 11 — one ROM is
# the suite-budget compromise) from a staged work floppy. Blargg ROMs
# spin forever after the verdict, so that run rides the -l limit.
printf 'cd gb\rgb -t smoke.gb\r' \
  | ../core-c/build/runpc -m 108 -l 1500000000 -d build/hd_free.img build/msdos_a.img 2>/dev/null \
  | tr -d '\r' > build/gb_host.log
if python3 ../apps/gb/fetch_blargg.py >/dev/null 2>&1; then
  python3 - <<'PY'
import sys
sys.path.insert(0, "../apps"); import fatimg
f = fatimg.Floppy("build/msdos_a.img")
f.add("GB.COM", open("../apps/gb/gb.com", "rb").read())
f.add("T06.GB", open("../apps/cache/blargg06.gb", "rb").read())
f.save("build/gbtest.img")
PY
  printf 'a:\rgb -t t06.gb\r' \
    | ../core-c/build/runpc -m 108 -l 3000000000 -d build/hd_free.img \
        build/gbtest.img 2>/dev/null \
    | tr -d '\r' >> build/gb_host.log
else
  echo "gb-host: Blargg fetch failed (offline?)" >> build/gb_host.log
fi
if grep -q "SM83 ALIVE C=1" build/gb_host.log \
   && grep -q "^Passed" build/gb_host.log; then
  echo "PASS gb-host"
else
  echo "FAIL gb-host"
  FAIL=1
fi

# --- Mesen legs: generic tests drive the PUBLIC ROM ---
if [ -z "$HAVE_MESEN" ]; then
  echo "SKIP Mesen legs + parity (no Mesen at $MESEN) — the 65816 core was NOT exercised"
else
  TESTS="t_boot t_dirb t_kbd t_kbdfn t_cga t_cga6 t_midi t_ted t_tedfk t_vi"
  [ -n "$QUICK" ] && TESTS="t_boot t_cga"

  for t in $TESTS; do
    if [ "$t" = "t_ted" ] || [ "$t" = "t_tedfk" ] || [ "$t" = "t_vi" ]; then
      # the TED legs save to B:; Mesen keys .srm files by ROM name, and stale B:
      # contents from an earlier run would leak into the assertion.
      # NOTE: this DELETES the user's B: drive for any same-named ROM
      # (msdos.srm) — suite runs are destructive to B:, by design.
      rm -f "$HOME/Library/Application Support/Mesen2/Saves/msdos.srm"
    fi
    mesen_leg "$ROM" "$t"
  done

  # ELKS end-to-end (own ROM, own timeout: boot to login is ~2 emulated
  # minutes; Mesen's default 100 s testrunner limit would kill it).
  [ -z "$QUICK" ] && mesen_leg "$(pwd)/build/elks.sfc" t_elks --timeout=1500

  # FreeDOS end-to-end (own ROM, own timeout: the kernel init is the
  # slowest boot in the fleet — and it executes code straight across the
  # WRAM->BW-RAM seam, which regression-guards the fetch bounce). Own
  # .srm namespace, and the leg never touches B:, so freedos.srm survives.
  [ -z "$QUICK" ] && mesen_leg "$(pwd)/build/freedos.sfc" t_fdos --timeout=1800

  # SA-1 variant end-to-end (own ROM, own .srm namespace — these legs
  # never touch msdos.srm). t_sa1boot is the plain boot; t_sa1mem proves
  # the machine really is 300 KB by round-tripping a pattern through
  # guest RAM at 256 KB and reading it back out of SA-1 BW-RAM. Neither
  # leg depends on B:, so the user's msdos_sa1.srm is left alone.
  if [ -z "$QUICK" ]; then
    make -s msdos_sa1 >/dev/null || { echo "FAIL sa1-build"; FAIL=1; }
    mesen_leg "$(pwd)/build/msdos_sa1.sfc" t_sa1boot
    mesen_leg "$(pwd)/build/msdos_sa1.sfc" t_sa1mem
  fi
fi

echo
if [ -z "$FAIL" ]; then
  echo "== ALL PASS =="
else
  echo "== FAILURES PRESENT =="
  exit 1
fi
