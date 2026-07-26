#!/bin/sh
# `make apps` (root): the sources-don't-rot canary. No app binaries are
# committed except vi.exe (its Watcom toolchain fetch is too heavy for
# image builds) and gb.com + its carts (nasm/RGBDS aren't build
# prereqs) — every image build compiles the rest from source (see the
# per-tool Makefiles) — so this script FORCE-rebuilds every on-machine
# tool (TP3 inside runpc via ../tpcompile.sh, TURBO.COM fetched +
# cached by fetch_tp3.py; javac.exe via the Small-C kit committed in
# apps/cc; vi via fetch_watcom.py; gb via host nasm/RGBDS) and verifies:
#
#   * every TP3 tool must recompile cleanly (non-empty artifact);
#     behavioral checks live in `make test` (ted-host, java-host, ...)
#   * VIEW: the rebuilt viewer must render the generated test card
#     bit-identically to the pinned golden below (sha256 of the CGA
#     framebuffer dump — byte-compares of TP3 .COMs are meaningless,
#     the compiler stamps its load segment; renders are the truth)
#   * JAVAC: the rebuilt DOS javac.exe must compile Hello.java into
#     bytecode byte-identical to the clang build of the same source
#     (javac-dev) — one compiler, two toolchains, same bytes
#
# One PASS/FAIL line per artifact.
set -u
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
RUNPC="$ROOT/core-c/build/runpc"
[ -x "$RUNPC" ] || make -s -C "$ROOT/core-c" runpc
[ -x "$RUNPC" ] || { echo "build core-c first (runpc missing)"; exit 1; }
FAIL=
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# sha256 of the CGA dump of VIEW painting C:\VIEW\CARD.BMP (see render
# below). Refresh after an INTENTIONAL change to view.pas / mkcard.py:
# run this script, take the "got" hash from the FAIL line.
VIEW_GOLDEN=b5e992b86ebea7e8e230e83510a3aabc7cc0309c602ce8fde7366c96bdf89592

sha() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

step() {  # step <name> <log> <cmd...>
  name=$1; log=$2; shift 2
  if "$@" >"$log" 2>&1; then
    return 0
  else
    echo "---- $name (log tail) ----"; tail -15 "$log"
    return 1
  fi
}

# --- JAVAC first: force-rebuild with Small-C inside runpc (java's
# recompile below stages the tool, which wants javac.exe — building it
# here keeps that a plain copy) ---
if step javac "$W/javac.log" make -s -C java javac-dos && [ -s java/javac.exe ]; then
  echo "PASS javac (rebuilt)"
else
  echo "FAIL javac"; FAIL=1
fi

# --- force-recompile every TP3 tool from source (recompile also stages) ---
for spec in "view:view/view.com" "ted:ted/ted.com" \
            "midi:midi/midplay.com midi/midconv.com" \
            "sokoban:sokoban/sokoban.com" "bench:bench/sieve.com bench/hello.com" \
            "java:java/java.com"; do
  t=${spec%%:*}; arts=${spec#*:}
  ok=1
  step "$t" "$W/$t.log" make -s -C "$t" recompile || ok=
  for a in $arts; do [ -s "$a" ] || ok=; done
  if [ -n "$ok" ]; then echo "PASS $t (recompiled)"; else echo "FAIL $t"; FAIL=1; fi
done

# --- VI (levee, Open Watcom cross-build — the one committed binary:
# the toolchain fetch is ~a hundred MB, too heavy for image builds, and
# unlike TP3 the build is byte-reproducible, so the canary is exact) ---
cp vi/vi.exe "$W/vi.committed"
if step vi "$W/vi.log" make -s -C vi recompile \
   && cmp -s vi/vi.exe "$W/vi.committed"; then
  echo "PASS vi (byte-identical)"
else
  echo "FAIL vi (rebuild differs from committed vi.exe)"; FAIL=1
fi

# --- GB (committed like vi — nasm + RGBDS aren't build prereqs): host
# nasm (mksm83.py generates the SM83 handlers) is deterministic, so the
# rebuilt GB.COM must be byte-identical; the RGBDS homebrew carts are
# checked non-empty (RGBDS versions may stamp differently) ---
if command -v nasm >/dev/null 2>&1 && command -v rgbasm >/dev/null 2>&1; then
  cp gb/gb.com "$W/gb.committed"
  ok=1
  step gb "$W/gb.log" make -s -C gb recompile || ok=
  cmp -s gb/gb.com "$W/gb.committed" || ok=
  for a in gb/smoke.gb gb/gfx.gb gb/joy.gb; do [ -s "$a" ] || ok=; done
  if [ -n "$ok" ]; then echo "PASS gb (GB.COM byte-identical)"; else echo "FAIL gb"; FAIL=1; fi
else
  echo "SKIP gb (needs nasm + RGBDS: brew install nasm rgbds)"
fi

# everything is freshly staged now; pack the C: the verifies run against
(cd "$ROOT/snes" && make -s build/hd_free.img >/dev/null) \
  || { echo "FAIL hd_free.img"; exit 1; }

# --- VIEW render golden: boot a DOS work floppy carrying the rebuilt
# VIEW.COM (A:), paint C:\VIEW\CARD.BMP (the 300 KB card outgrows a
# floppy), dump the CGA framebuffer, compare against the pinned sha ---
python3 - "$ROOT" view/view.com "$W/card.img" <<'PY'
import sys
ROOT, view, out = sys.argv[1:4]
sys.path.insert(0, ROOT+"/apps"); import fatimg
f = fatimg.Floppy(ROOT+"/msdos/msdos.img")
f.replace("AUTOEXEC.BAT", b"PROMPT $p$g\r\n")
f.add("VIEW.COM", open(view, "rb").read())
f.save(out)
PY
printf 'view c:\\view\\card.bmp\rx\r' \
  | "$RUNPC" -m 108 -l 3000000000 -d "$ROOT/snes/build/hd_free.img" \
      -cga "$W/view.ppm" "$W/card.img" >/dev/null 2>&1
if [ -s "$W/view.ppm" ] && GOT=$(sha "$W/view.ppm") && [ "$GOT" = "$VIEW_GOLDEN" ]; then
  echo "PASS view-render (golden bit-identical)"
else
  echo "FAIL view-render (got ${GOT:-no render}, want $VIEW_GOLDEN)"; FAIL=1
fi

# --- JAVAC parity: the DOS build and the clang build of the same
# compiler source must emit byte-identical bytecode ---
if step javac-dev "$W/jdev.log" make -s -C java javac-dev \
   && java/hostbuild/javac-dev java/samples/Hello.java "$W/Hello.host.class" >/dev/null 2>&1; then
  python3 - "$ROOT" "$W/jc.img" <<'PY'
import sys
ROOT, out = sys.argv[1], sys.argv[2]
sys.path.insert(0, ROOT+"/apps"); import fatimg
f = fatimg.Floppy(ROOT+"/msdos/msdos.img")
f.replace("AUTOEXEC.BAT", b"PROMPT $p$g\r\n")
f.save(out)
PY
  printf 'path c:\\java\rjavac c:\\java\\hello.jav hi.cla\r' \
    | "$RUNPC" -m 108 -l 9000000000 -d "$ROOT/snes/build/hd_free.img" \
        -w "$W/jc.img" >/dev/null 2>&1
  python3 - "$ROOT" "$W/jc.img" "$W/Hello.dos.class" <<'PY' 2>/dev/null
import sys
ROOT, img, out = sys.argv[1:4]
sys.path.insert(0, ROOT+"/apps"); import fatimg
data = fatimg.read_img(img).get("HI.CLA")
if data is None: raise SystemExit("HI.CLA not on the work floppy")
open(out, "wb").write(data)
PY
  if [ -s "$W/Hello.dos.class" ] && cmp -s "$W/Hello.dos.class" "$W/Hello.host.class"; then
    echo "PASS javac-parity (DOS vs clang byte-identical)"
  else
    echo "FAIL javac-parity"; FAIL=1
  fi
else
  echo "FAIL javac-parity (javac-dev build)"; FAIL=1
fi

echo
if [ -z "$FAIL" ]; then
  echo "== APPS REBUILD ALL PASS =="
else
  echo "== APPS REBUILD FAILURES =="
  exit 1
fi
