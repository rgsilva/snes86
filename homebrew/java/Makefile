# JAVA — the class-file interpreter, and JAVAC — the Java compiler.
#
# JAVA.COM (interpreter) ships in the image; sample bytecode travels as
# .CLA (8.3 has no room for .class). The .java sources stay in samples/.
#
# JAVAC compiles a Java subset straight to class files the interpreter
# (and a desktop JVM) run. Its source is polyglot C: it builds under
# clang for the host reference compiler (`make javac-dev`), and under
# the Small-C toolchain for a DOS-native binary (`make javac-dos`, see
# the caveat there). See README.md and JAVAC-PORTING.md.
B := build
CLASSES := Hello Fib Sieve Concat Guess

stage: $(B)/JAVA.COM $(foreach c,$(CLASSES),$(B)/$(shell echo $(c) | tr a-z A-Z).CLA)

$(B)/JAVA.COM: java.com
	@mkdir -p $(B)
	cp java.com $@

define CLA_template
$(B)/$(shell echo $(1) | tr a-z A-Z).CLA: samples/$(1).class
	@mkdir -p $(B)
	cp $$< $$@
endef
$(foreach c,$(CLASSES),$(eval $(call CLA_template,$(c))))

recompile:
	sh ../tpcompile.sh java java
	$(MAKE) stage

# --- JAVAC, the compiler ---------------------------------------------
# javac.c is the platform-independent compiler; ccmain.c / scmain.c are
# the host / DOS drivers. Concatenation (not #include) keeps it Small-C
# clean: Small-C cannot #include mid-file.

# Host reference compiler (clang). Verified: its output runs on a
# desktop JVM AND on JAVA.COM. Use it to (re)generate samples/*.class.
javac-dev: $(B)/javac-dev
$(B)/javac-dev: javac.c ccmain.c
	@mkdir -p $(B)
	cat javac.c ccmain.c | cc -std=c89 -w -x c - -o $@

# Regenerate the committed sample class files WITH our own compiler
# (proof the compiler reproduces javac's behaviour for the subset).
samples-ours: javac-dev
	for f in $(CLASSES); do $(B)/javac-dev samples/$$f.java $(B)/$$f.class; done

# DOS-native JAVAC via the Small-C toolchain (fetched separately, see
# JAVAC-PORTING.md). cc and asm succeed; the 1982 LINK.EXE overflows on
# the assembler's name table for a program this large — the one open
# step. tools/mkjavac_dos.sh drives cc -> merge-segments -> asm -> link
# under runpc and documents where it stops.
javac-dos:
	@echo "See JAVAC-PORTING.md: cc + asm succeed; link is the open step."

clean:
	rm -rf $(B)

.PHONY: stage recompile javac-dev samples-ours javac-dos clean
