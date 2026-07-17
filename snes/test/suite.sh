#!/bin/sh
# snes86 regression suite: parity + host smoke + Mesen end-to-end tests.
#
#   test/suite.sh          full run (~10 min)
#   test/suite.sh quick    parity + boot + zork (~3 min)
#
# Each Mesen test prints exactly one "RESULT PASS/FAIL name" line.
cd "$(dirname "$0")/.."
MESEN=/Applications/Mesen.app/Contents/MacOS/Mesen
ROM="$(pwd)/build/dosboot.sfc"
FAIL=

echo "== build =="
make -s dos || { echo "FAIL build"; exit 1; }

echo "== parity (C core vs 65816 lockstep) =="
if ./test/parity.sh 2>&1 | grep -q "PARITY OK"; then
  echo "PASS parity"
else
  echo "FAIL parity"
  FAIL=1
fi

echo "== host smoke (runpc boots DOS, reads C:) =="
if printf 'type c:\\autoexec.bat\r' \
     | ../core-c/build/runpc -m 108 -l 1500000000 -d build/hd.img build/adisk.img 2>/dev/null \
     | grep -q "PATH A:"; then
  echo "PASS host-smoke"
else
  echo "FAIL host-smoke"
  FAIL=1
fi

TESTS="t_boot t_dirb t_zork t_gwb t_ws t_mp t_m40 t_kbd"
[ "$1" = "quick" ] && TESTS="t_boot t_zork"

for t in $TESTS; do
  r=$("$MESEN" --testrunner "$ROM" "$(pwd)/test/$t.lua" 2>/dev/null | grep '^RESULT' | head -1)
  echo "${r:-RESULT FAIL $t (no output)}"
  case "$r" in
    *PASS*) ;;
    *) FAIL=1 ;;
  esac
done

echo
if [ -z "$FAIL" ]; then
  echo "== ALL PASS =="
else
  echo "== FAILURES PRESENT =="
  exit 1
fi
