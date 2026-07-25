# JAVA — the class-file interpreter, and JAVAC — the Java compiler.
#
# C:\JAVA ships the whole story: JAVA.COM (interpreter), JAVAC.EXE (the
# compiler, a DOS binary built from javac.c), the sample bytecode as
# .CLA (8.3 has no room for .class), and the sample SOURCES as .JAV —
# they ship because the machine can now compile them itself:
#
#     C:\JAVA> JAVAC HELLO.JAV A:HELLO.CLA        (C: is read-only)
#     C:\JAVA> JAVA A:HELLO
#
# javac.c stays repo-only: a 40 KB C source with no on-image C compiler
# is dead weight there. The committed .CLAs remain real `javac
# --release 8` output (the "genuine javac bytecode" claim); JAVAC.EXE
# reproduces them byte-for-byte from the .JAVs.
#
# build/ is what the image packer stages (8.3 names only!) — host-side
# artifacts (javac-dev, *.class) go to hostbuild/, never build/.
B := build
HB := hostbuild
CLASSES := Hello Fib Sieve Concat Guess

UPPER = $(shell echo $(1) | tr a-z A-Z)

stage: $(B)/JAVA.COM $(B)/JAVAC.EXE \
       $(foreach c,$(CLASSES),$(B)/$(call UPPER,$(c)).CLA) \
       $(foreach c,$(CLASSES),$(B)/$(call UPPER,$(c)).JAV)

$(B)/JAVA.COM: java.com
	@mkdir -p $(B)
	cp java.com $@

$(B)/JAVAC.EXE: javac.exe
	@mkdir -p $(B)
	cp javac.exe $@

define CLA_template
$(B)/$(call UPPER,$(1)).CLA: samples/$(1).class
	@mkdir -p $(B)
	cp $$< $$@
$(B)/$(call UPPER,$(1)).JAV: samples/$(1).java
	@mkdir -p $(B)
	perl -pe 's/\r?\n/\r\n/' $$< > $$@
endef
$(foreach c,$(CLASSES),$(eval $(call CLA_template,$(c))))

recompile:
	sh ../tpcompile.sh java java
	$(MAKE) stage

# --- JAVAC, the compiler ---------------------------------------------
# javac.c is the platform-independent compiler; ccmain.c / scmain.c are
# the host / DOS drivers (concatenation, not #include: the DOS dialect
# cannot #include mid-file). See JAVAC-PORTING.md for the full story.

# Host reference build (clang). Same compiler, byte-identical output.
javac-dev: $(HB)/javac-dev
$(HB)/javac-dev: javac.c ccmain.c
	@mkdir -p $(HB)
	cat javac.c ccmain.c | cc -std=c89 -w -x c - -o $@

# Compile every sample with the host build (outputs in hostbuild/) —
# diff against samples/*.class or the DOS compiler's output at will.
parity: javac-dev
	@for f in $(CLASSES); do \
	  $(HB)/javac-dev samples/$$f.java $(HB)/$$f.class || exit 1; \
	done; echo "host-compiled classes in $(HB)/"

# Rebuild the committed javac.exe: the Small-C toolchain running under
# runpc on MS-DOS 2.0 (needs the public-domain Small-C kit; see the
# script header). Deterministic — rebuilds byte-identical.
javac-dos:
	KIT=$(KIT) sh tools/mkjavac_dos.sh

clean:
	rm -rf $(B) $(HB)

.PHONY: stage recompile javac-dev parity javac-dos clean
