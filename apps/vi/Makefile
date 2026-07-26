# VI — levee, a real vi clone, cross-compiled for MS-DOS 2.0 with
# Open Watcom v2 (fetched at build time, see fetch_watcom.py).
# The committed vi.exe keeps the ROM buildable from a clean checkout.
B := build
W := ../cache/watcom

LEVEE_SRC = levee/blockio.c levee/display.c levee/editcor.c levee/exec.c \
    levee/find.c levee/globals.c levee/insert.c levee/main.c levee/misc.c \
    levee/modify.c levee/move.c levee/ucsd.c levee/undo.c levee/home.c \
    levee/tag.c

stage: $(B)/VI.EXE

$(B)/VI.EXE: vi.exe
	@mkdir -p $(B)
	cp vi.exe $@

# version.c is what levee's mkversio would generate from levee/VERSION
version.c: levee/VERSION
	awk '{ printf "char codeversion[] = \"%s\";\nchar codecomment[] = \"", $$1; \
	       for (i = 2; i <= NF; i++) printf "%s%s", $$i, (i < NF ? " " : ""); \
	       print "\";" }' levee/VERSION > $@

recompile: version.c
	python3 fetch_watcom.py
	@mkdir -p $(B)
	env "WATCOM=$(abspath $(W))" \
	    "PATH=$(abspath $(W))/armo64:$$PATH" \
	    "INCLUDE=$(abspath $(W))/h" \
	    wcl -q -bcl=dos -ms -0 -os -k4096 -I. -Ilevee \
	        -fe=vi.exe $(LEVEE_SRC) snescall.c version.c
	rm -f *.o levee/*.o
	$(MAKE) stage

clean:
	rm -rf $(B) *.o levee/*.o

.PHONY: stage recompile clean
