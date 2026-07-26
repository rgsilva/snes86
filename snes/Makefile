PVBIN  := ../../pvsneslib/devkitsnes/bin
AS     := $(PVBIN)/wla-65816
AS_SPC := $(PVBIN)/wla-spc700
LD     := $(PVBIN)/wlalink

all: build/console.sfc

# --- OVERLAYS: a uniform optional flag on every DOS-booting target
# (msdos, msdos_big, freedos, boot). OVERLAYS="dir-or-img ..." merges
# extra content onto the free C: (tools/mkhd_free.py) and switches the
# output to build/<target>_overlay.sfc — an overlay build never
# clobbers the clean artifact. Nothing copyrighted is ever baked into
# a default build; the suite's app fixture is just OVERLAYS too.
ifneq ($(strip $(OVERLAYS)),)
OVSUF := _overlay
OVDEF := -D OVERLAYHD
HDC   := build/hd_overlay.img
else
OVSUF :=
OVDEF :=
HDC   := build/hd_free.img
endif

# every DOS-boot variant assembles dosboot.asm via a stub + these
DOSDEPS := dosboot.asm hdr_dos.asm cpu.asm cpu2.asm build/pf.bin \
           build/bdisk.bin build/kbdlayout.asm build/font_bg2.bin \
           build/font_bg1.bin build/spc_midi64.bin build/cgalut.bin \
           build/aluflat.asm build/cgafont.bin build/trace_meta.asm

# wlalink linkfiles are two generated lines — build/<stem>.link
build/%.link:
	@mkdir -p build
	@printf '[objects]\nbuild/%s.o\n' '$*' > $@

build/font_bg2.bin build/font_bg1.bin build/cgafont.bin: tools/mkfont.py tools/font8x8_basic.h
	python3 tools/mkfont.py build

build/pf.bin: tools/mkpf.py
	python3 tools/mkpf.py build

build/main.o: main.asm hdr.asm build/font_bg2.bin build/font_bg1.bin
	$(AS) -o build/main.o main.asm

build/console.sfc: build/main.o linkfile
	$(LD) -d -s -v -c linkfile build/console.sfc

# --- M4 parity-test ROM (stream.bin/stream_meta.asm from gen_stream.py)
cputest: build/cputest.sfc

build/cputest.o: cputest.asm cpu.asm hdr.asm build/pf.bin build/stream.bin build/stream_meta.asm build/aluflat.asm
	$(AS) -o build/cputest.o cputest.asm

build/cputest.sfc: build/cputest.o linkfile_cputest
	$(LD) -d -s -v -c linkfile_cputest build/cputest.sfc

parity:
	./test/parity.sh

run: build/console.sfc
	open -a Mesen build/console.sfc

# --- the suite: `make test` = the public legs (parity + host smokes +
# Mesen; Mesen legs self-skip when Mesen is absent, e.g. CI). QUICK=1
# trims to parity + boot + cga. `make test-extra` = only the
# copyrighted app-matrix legs (local machines with disks/).
test:
	./test/suite.sh free $(if $(QUICK),quick)

test-extra:
	./test/suite.sh extra

console-test: build/console.sfc
	/Applications/Mesen.app/Contents/MacOS/Mesen --testrunner build/console.sfc test/console.lua

clean:
	rm -rf build

.PHONY: all run test test-extra console-test clean msdos msdos_big boot freedos elks io apps-stage parity cputest sramtest

# --- DOS boot ROM.  `make msdos` = the PUBLIC build: MS-DOS 2.0 (MIT) +
# a free C: (tools/mkhd_free.py; no copyrighted software).  See
# docs/BUILDING.md.
msdos: build/msdos$(OVSUF).sfc

build/msdos$(OVSUF).o: msdos.asm $(DOSDEPS) build/msdos_a.img $(HDC)
	$(AS) $(OVDEF) -o $@ msdos.asm

build/aluflat.asm: tools/mkaluflat.py
	python3 tools/mkaluflat.py build/aluflat.asm

# trace_meta.asm is empty for normal builds; test/tracewin.sh overwrites it to
# turn on the lockstep-trace build. Create the empty default so a clean checkout
# (e.g. CI) assembles — dosboot.asm (the shared machine) .INCLUDEs it always.
build/trace_meta.asm:
	@mkdir -p build && printf '' > build/trace_meta.asm

build/spc_midi64.bin: spc_midi.asm linkfile_spc_midi build/midi_tables.asm
	$(AS_SPC) -o build/spc_midi.o spc_midi.asm
	$(LD) -d -s linkfile_spc_midi build/spc_midi64.bin

build/midi_tables.asm: tools/mkmiditab.py
	python3 tools/mkmiditab.py build/midi_tables.asm

build/spc_beep64.bin: spc_beep.asm linkfile_spc
	$(AS_SPC) -o build/spc_beep.o spc_beep.asm
	$(LD) -d -s linkfile_spc build/spc_beep64.bin

build/msdos$(OVSUF).sfc: build/msdos$(OVSUF).o build/msdos$(OVSUF).link
	$(LD) -d -s -v -c build/msdos$(OVSUF).link $@

msdos_big: build/msdos_big$(OVSUF).sfc

build/msdos_big$(OVSUF).o: msdos_big.asm $(DOSDEPS) build/msdos_a.img $(HDC)
	$(AS) $(OVDEF) -o $@ msdos_big.asm

build/msdos_big$(OVSUF).sfc: build/msdos_big$(OVSUF).o build/msdos_big$(OVSUF).link
	$(LD) -d -s -v -c build/msdos_big$(OVSUF).link $@

# --- FreeDOS 1.3: GPL, fetched at build time like ELKS (freedos/mkfreedos.py
# downloads the official FD 1.3 floppy release, extracts KERNEL.SYS + FreeCOM
# and assembles a 360 KB boot floppy — nothing copyrighted-in-the-bad-way is
# committed).  Runs on the BIGMEM machine: FreeDOS needs the full 172 KB
# (108 KB dies in kernel init).  Same free C: as the public build.
freedos: build/freedos$(OVSUF).sfc

build/freedos_a.img: ../freedos/mkfreedos.py
	python3 ../freedos/mkfreedos.py build/freedos_a.img

build/freedos$(OVSUF).o: freedos.asm $(DOSDEPS) build/freedos_a.img $(HDC)
	$(AS) $(OVDEF) -o $@ freedos.asm

build/freedos$(OVSUF).sfc: build/freedos$(OVSUF).o build/freedos$(OVSUF).link
	$(LD) -d -s -v -c build/freedos$(OVSUF).link $@

# sneslinux: ELKS ROM-XIP variant (not a DOS boot, hence no dosboot_ prefix).
# build/elks_rom.bin + build/elks_romfs.bin are the kernel + ROMFS images:
# auto-fetched from the official ELKS v0.9.1 release (GPL - fetched, not
# committed) unless already present; a tuned local build (sneslinux tree)
# can be copied over them and wins.
elks: build/elks.sfc

build/elks_rom.bin build/elks_romfs.bin:
	./test/fetch_elks.sh

build/elks.o: elks.asm $(DOSDEPS) build/elks_rom.bin build/elks_romfs.bin
	$(AS) -o build/elks.o elks.asm

build/elks.sfc: build/elks.o linkfile_elks
	$(LD) -d -s -v -c linkfile_elks build/elks.sfc

# --- MS-DOS boot floppy (A:).  msdos/msdos.img is a COMMITTED, free prebuilt
# floppy: our IO.SYS + the MIT MSDOS.SYS/COMMAND.COM + AUTOEXEC.BAT.  The public
# build just copies it.  Regenerating IO.SYS from io.asm is a developer step
# (`make io`): it runs the 1982 LINK/EXE2BIN inside runpc and needs a local DOS
# host image, so it is deliberately NOT part of the default/public build.
build/msdos_a.img: ../msdos/msdos.img
	cp ../msdos/msdos.img build/msdos_a.img

# Developer-only: regenerate msdos/IO.SYS + msdos/msdos.img, then commit the img.
# Needs msdos/jwasm, core-c/build/runpc and a local DOS host (see docs/BUILDING.md).
io:
	cd ../msdos && ./build_io.sh

# --- the C: drive. One packer (tools/mkhd_free.py): every staged
# apps/<tool>/build/ becomes C:\<TOOL>, msdos/bin/ becomes C:\DOS,
# user/ becomes C:\USER. OVERLAYS (dirs or floppy images) merge on top.
APPSTOOLS := view ted java midi sokoban bench cc gb

apps-stage:
	@for t in $(APPSTOOLS); do $(MAKE) -s -C ../apps/$$t stage || exit 1; done

build/hd_free.img: tools/mkhd_free.py ../msdos/autoexec.bat apps-stage $(wildcard ../user/*) $(wildcard ../msdos/bin/*) $(wildcard ../apps/cc/*)
	@mkdir -p build
	python3 tools/mkhd_free.py build

build/hd_overlay.img: tools/mkhd_free.py ../msdos/autoexec.bat apps-stage $(wildcard ../user/*) $(wildcard ../msdos/bin/*) $(wildcard ../apps/cc/*)
	@mkdir -p build
	OVERLAYS="$(OVERLAYS)" python3 tools/mkhd_free.py build hd_overlay.img

# --- Self-booting disk: `make boot DISK=path/to/disk.img` replaces DOS
# with the disk — the BIOS boots its sector 0. Two geometries are wired:
# 160 KB / 163840 bytes (40x1x8; e.g. disks/fs1.img — MS Flight
# Simulator 1.0) and 360 KB / 368640 bytes (40x2x9, the standard A:
# shape). Output: build/boot.sfc (build/boot_overlay.sfc with OVERLAYS).
boot:
	@test -n "$(DISK)" || { echo "usage: make boot DISK=path/to/disk.img (a 160 KB or 360 KB self-booting image)"; exit 1; }
	@mkdir -p build && cp "$(DISK)" build/bootdisk.img
	@size=$$(wc -c < build/bootdisk.img | tr -d ' '); \
	case $$size in \
	  163840) $(MAKE) -s build/boot160$(OVSUF).sfc && cp build/boot160$(OVSUF).sfc build/boot$(OVSUF).sfc ;; \
	  368640) $(MAKE) -s build/boot360$(OVSUF).sfc && cp build/boot360$(OVSUF).sfc build/boot$(OVSUF).sfc ;; \
	  *) echo "make boot: $(DISK) is $$size bytes - need 163840 (160 KB, 40x1x8) or 368640 (360 KB, 40x2x9)"; rm -f build/bootdisk.img; exit 1 ;; \
	esac
	@echo "build/boot$(OVSUF).sfc <- $(DISK)"

build/boot160$(OVSUF).o: boot160.asm $(DOSDEPS) build/bootdisk.img $(HDC)
	$(AS) $(OVDEF) -o $@ boot160.asm

build/boot160$(OVSUF).sfc: build/boot160$(OVSUF).o build/boot160$(OVSUF).link
	$(LD) -d -s -v -c build/boot160$(OVSUF).link $@

build/boot360$(OVSUF).o: boot360.asm $(DOSDEPS) build/bootdisk.img $(HDC)
	$(AS) $(OVDEF) -o $@ boot360.asm

build/boot360$(OVSUF).sfc: build/boot360$(OVSUF).o build/boot360$(OVSUF).link
	$(LD) -d -s -v -c build/boot360$(OVSUF).link $@

# SRAM extent probe (M15): requests 128 KB, reports real banks -> WRAM $04.
# Run: Mesen --testrunner build/sramtest.sfc test/sram.lua
sramtest: build/sramtest.sfc
build/sramtest.sfc: sramtest.asm linkfile_sramtest
	$(AS) -o build/sramtest.o sramtest.asm
	$(LD) -d -s linkfile_sramtest build/sramtest.sfc

build/bdisk.bin: tools/mkbdisk.py
	python3 tools/mkbdisk.py build

build/kbdlayout.asm: tools/mkkbd.py
	python3 tools/mkkbd.py build

build/cgalut.bin: tools/mkcgalut.py
	python3 tools/mkcgalut.py build/cgalut.bin
