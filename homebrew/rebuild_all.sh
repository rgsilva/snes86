#!/bin/sh
# `make homebrew` (root): rebuild every on-machine tool FROM SOURCE and
# verify — the CI canary for the whole software stack. The TP3 tools
# recompile via ../tpcompile.sh (TURBO.COM fetched + cached by
# fetch_tp3.py); javac.exe rebuilds with the Small-C kit committed in
# freeware/cc and must come out byte-identical. One PASS/FAIL line per
# artifact.
#
# NOTE: recompiles overwrite the committed binaries in place (TP3 stamps
# its load segment, so a rebuilt .com can differ by a few inert bytes) —
# `git diff` after a run shows what moved; behavior is what the verifies
# and `make test` check.
set -u
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
RUNPC="$ROOT/core-c/build/runpc"
[ -x "$RUNPC" ] || { echo "build core-c first (runpc missing)"; exit 1; }
FAIL=
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

step() {  # step <name> <log> <cmd...>
  name=$1; log=$2; shift 2
  if "$@" >"$log" 2>&1; then
    return 0
  else
    echo "---- $name (log tail) ----"; tail -15 "$log"
    return 1
  fi
}

# render <view.com> <out.ppm>: boot a DOS work floppy carrying the given
# VIEW.COM (A:), paint C:\VIEW\CARD.BMP (the 300 KB card outgrows a
# floppy), dump the CGA framebuffer.
render() {
  python3 - "$ROOT" "$1" "$W/card.img" <<'PY'
import sys
ROOT, view, out = sys.argv[1:4]
sys.path.insert(0, ROOT+"/homebrew"); import fatimg
f = fatimg.Floppy(ROOT+"/msdos/msdos.img")
f.replace("AUTOEXEC.BAT", b"PROMPT $p$g\r\n")
f.add("VIEW.COM", open(view, "rb").read())
f.save(out)
PY
  printf 'view c:\\view\\card.bmp\rx\r' \
    | "$RUNPC" -m 108 -l 3000000000 -d "$ROOT/snes/build/hd_free.img" \
        -cga "$2" "$W/card.img" >/dev/null 2>&1
}

# --- VIEW: recompile, then the rebuilt binary must render the test
# card bit-identically to the committed one ---
(cd "$ROOT/snes" && make -s build/hd_free.img >/dev/null)
render view/view.com "$W/view_ref.ppm"
if [ -s "$W/view_ref.ppm" ] \
   && step view "$W/view.log" make -s -C view recompile \
   && render view/view.com "$W/view_new.ppm" \
   && cmp -s "$W/view_ref.ppm" "$W/view_new.ppm"; then
  echo "PASS view (render bit-identical)"
else
  echo "FAIL view"; FAIL=1
fi

# --- the other TP3 tools: rebuilt from .pas; behavioral checks live in
# `make test` (ted-host/t_ted, java-host, t_midi ...) ---
for spec in "ted:ted/ted.com" "midi:midi/midplay.com midi/midconv.com" \
            "sokoban:sokoban/sokoban.com" "bench:bench/sieve.com bench/hello.com" \
            "java:java/java.com"; do
  t=${spec%%:*}; arts=${spec#*:}
  ok=1
  step "$t" "$W/$t.log" make -s -C "$t" recompile || ok=
  for a in $arts; do [ -s "$a" ] || ok=; done
  if [ -n "$ok" ]; then echo "PASS $t"; else echo "FAIL $t"; FAIL=1; fi
done

# --- JAVAC: Small-C toolchain inside runpc; deterministic, so the
# rebuild must be byte-identical to the committed javac.exe ---
cp java/javac.exe "$W/javac.committed"
if step javac "$W/javac.log" make -s -C java javac-dos \
   && cmp -s java/javac.exe "$W/javac.committed"; then
  echo "PASS javac (byte-identical)"
else
  echo "FAIL javac"; FAIL=1
fi

echo
if [ -z "$FAIL" ]; then
  echo "== HOMEBREW REBUILD ALL PASS =="
else
  echo "== HOMEBREW REBUILD FAILURES =="
  exit 1
fi
