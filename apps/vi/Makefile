# VI — levee, a real vi clone, cross-compiled for MS-DOS 2.0 with
# Open Watcom v2. vi.exe is a BUILD PRODUCT (no binary is committed):
# `make stage` fetches the pinned Watcom snapshot into ../cache/watcom/
# (fetch_watcom.py, ~151 MB one-time, cached) and cross-compiles the
# vendored levee source + snescall.c. The host bin dir (armo64 on macOS
# arm64, binl64 on Linux x64, ...) is resolved by fetch_watcom.py
# --bindir, so the same Makefile builds on both.
B := build
W := ../cache/watcom

LEVEE_SRC = levee/blockio.c levee/display.c levee/editcor.c levee/exec.c \
    levee/find.c levee/globals.c levee/insert.c levee/main.c levee/misc.c \
    levee/modify.c levee/move.c levee/ucsd.c levee/undo.c levee/home.c \
    levee/tag.c

stage: $(B)/VI.EXE

# version.c is what levee's mkversio would generate from levee/VERSION
version.c: levee/VERSION
	awk '{ printf "char codeversion[] = \"%s\";\nchar codecomment[] = \"", $$1; \
	       for (i = 2; i <= NF; i++) printf "%s%s", $$i, (i < NF ? " " : ""); \
	       print "\";" }' levee/VERSION > $@

vi.exe: version.c $(LEVEE_SRC) snescall.c config.h fetch_watcom.py
	python3 fetch_watcom.py
	WBIN=$$(python3 fetch_watcom.py --bindir); \
	env "WATCOM=$(abspath $(W))" \
	    "PATH=$$WBIN:$$PATH" \
	    "INCLUDE=$(abspath $(W))/h" \
	    wcl -q -bcl=dos -ms -0 -os -k4096 -I. -Ilevee \
	        -fe=vi.exe $(LEVEE_SRC) snescall.c version.c
	rm -f *.o levee/*.o *.err levee/*.err

$(B)/VI.EXE: vi.exe
	@mkdir -p $(B)
	cp vi.exe $@

recompile:
	rm -f vi.exe version.c
	$(MAKE) stage

clean:
	rm -rf $(B) vi.exe version.c *.o levee/*.o *.err levee/*.err

.PHONY: stage recompile clean
