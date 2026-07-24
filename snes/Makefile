PVBIN  := ../../pvsneslib/devkitsnes/bin
AS     := $(PVBIN)/wla-65816
AS_SPC := $(PVBIN)/wla-spc700
LD     := $(PVBIN)/wlalink

all: build/console.sfc

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

test: build/console.sfc
	/Applications/Mesen.app/Contents/MacOS/Mesen --testrunner build/console.sfc test/console.lua

clean:
	rm -rf build

.PHONY: all run test clean msdos apps big fs freedos io homebrew-stage

# --- DOS boot ROM.  `make msdos` = the PUBLIC build: MS-DOS 2.0 (MIT) + a
# free C: (tools/mkhd_free.py; no copyrighted software).  `make apps` is the
# same machine with the copyrighted app-matrix fixture overlaid (for the
# compatibility suite legs).  See docs/BUILDING.md.
msdos: build/msdos.sfc

build/msdos.o: msdos.asm dosboot.asm hdr_dos.asm cpu.asm cpu2.asm build/pf.bin build/bdisk.bin build/kbdlayout.asm build/font_bg2.bin build/font_bg1.bin build/msdos_a.img build/hd_free.img build/spc_midi64.bin build/cgalut.bin build/aluflat.asm build/cgafont.bin build/trace_meta.asm
	$(AS) -o build/msdos.o msdos.asm

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

build/msdos.sfc: build/msdos.o linkfile_msdos
	$(LD) -d -s -v -c linkfile_msdos build/msdos.sfc

fs: build/dosboot_fs.sfc

big: build/msdos_big.sfc

build/msdos_big.o: msdos_big.asm dosboot.asm hdr_dos.asm cpu.asm cpu2.asm build/pf.bin build/bdisk.bin build/kbdlayout.asm build/font_bg2.bin build/font_bg1.bin build/msdos_a.img build/hd_apps.img build/spc_midi64.bin build/cgalut.bin build/aluflat.asm build/cgafont.bin build/trace_meta.asm
	$(AS) -o build/msdos_big.o msdos_big.asm

build/msdos_big.sfc: build/msdos_big.o linkfile_big
	$(LD) -d -s -v -c linkfile_big build/msdos_big.sfc

# --- FreeDOS 1.3: GPL, fetched at build time like ELKS (freedos/mkfreedos.py
# downloads the official FD 1.3 floppy release, extracts KERNEL.SYS + FreeCOM
# and assembles a 360 KB boot floppy — nothing copyrighted-in-the-bad-way is
# committed).  Runs on the BIGMEM machine: FreeDOS needs the full 172 KB
# (108 KB dies in kernel init).  Same free C: as the public build.
freedos: build/freedos.sfc

build/freedos_a.img: ../freedos/mkfreedos.py
	python3 ../freedos/mkfreedos.py build/freedos_a.img

build/freedos.o: freedos.asm dosboot.asm hdr_dos.asm cpu.asm cpu2.asm build/pf.bin build/bdisk.bin build/kbdlayout.asm build/font_bg2.bin build/font_bg1.bin build/freedos_a.img build/hd_free.img build/spc_midi64.bin build/cgalut.bin build/aluflat.asm build/cgafont.bin build/trace_meta.asm
	$(AS) -o build/freedos.o freedos.asm

build/freedos.sfc: build/freedos.o linkfile_freedos
	$(LD) -d -s -v -c linkfile_freedos build/freedos.sfc

# sneslinux: ELKS ROM-XIP variant (not a DOS boot, hence no dosboot_ prefix).
# build/elks_rom.bin + build/elks_romfs.bin are the kernel + ROMFS images:
# auto-fetched from the official ELKS v0.9.1 release (GPL - fetched, not
# committed) unless already present; a tuned local build (sneslinux tree)
# can be copied over them and wins.
elks: build/elks.sfc

build/elks_rom.bin build/elks_romfs.bin:
	./test/fetch_elks.sh

build/elks.o: elks.asm dosboot.asm hdr_dos.asm cpu.asm cpu2.asm build/pf.bin build/bdisk.bin build/kbdlayout.asm build/font_bg2.bin build/font_bg1.bin build/spc_midi64.bin build/cgalut.bin build/aluflat.asm build/cgafont.bin build/trace_meta.asm build/elks_rom.bin build/elks_romfs.bin
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
# homebrew/<tool>/build/ becomes C:\<TOOL>, msdos/bin/ becomes C:\DOS,
# user/ becomes C:\USER. OVERLAYS (dirs or floppy images) merge on top.
HBTOOLS := view ted java midi sokoban bench

homebrew-stage:
	@for t in $(HBTOOLS); do $(MAKE) -s -C ../homebrew/$$t stage || exit 1; done

build/hd_free.img: tools/mkhd_free.py ../msdos/autoexec.bat homebrew-stage $(wildcard ../user/*) $(wildcard ../msdos/bin/*)
	@mkdir -p build
	python3 tools/mkhd_free.py build

# --- APPS build: the public machine + the copyrighted app-matrix fixture
# (disks/appmatrix, generated once by disks/mkappmatrix.py on machines
# with the local software). Exists for the compatibility suite legs.
apps: build/msdos_apps.sfc

build/hd_apps.img: tools/mkhd_free.py ../msdos/autoexec.bat homebrew-stage $(wildcard ../disks/appmatrix/*) $(wildcard ../msdos/bin/*)
	@mkdir -p build
	OVERLAYS=../disks/appmatrix python3 tools/mkhd_free.py build hd_apps.img

build/msdos_apps.o: msdos_apps.asm dosboot.asm hdr_dos.asm cpu.asm cpu2.asm build/pf.bin build/bdisk.bin build/kbdlayout.asm build/font_bg2.bin build/font_bg1.bin build/msdos_a.img build/hd_apps.img build/spc_midi64.bin build/cgalut.bin build/aluflat.asm build/cgafont.bin build/trace_meta.asm
	$(AS) -o build/msdos_apps.o msdos_apps.asm

build/msdos_apps.sfc: build/msdos_apps.o linkfile_apps
	$(LD) -d -s -v -c linkfile_apps build/msdos_apps.sfc

# SRAM extent probe (M15): requests 128 KB, reports real banks -> WRAM $04.
# Run: Mesen --testrunner build/sramtest.sfc test/sram.lua
sramtest: build/sramtest.sfc
build/sramtest.sfc: sramtest.asm linkfile_sramtest
	$(AS) -o build/sramtest.o sramtest.asm
	$(LD) -d -s linkfile_sramtest build/sramtest.sfc

build/dosboot_fs.o: dosboot_fs.asm dosboot.asm hdr_dos.asm cpu.asm cpu2.asm build/pf.bin build/bdisk.bin build/kbdlayout.asm build/font_bg2.bin build/font_bg1.bin ../disks/fs1.img build/hd_apps.img build/spc_midi64.bin build/cgalut.bin build/aluflat.asm build/cgafont.bin build/trace_meta.asm
	$(AS) -o build/dosboot_fs.o dosboot_fs.asm

build/dosboot_fs.sfc: build/dosboot_fs.o linkfile_fs
	$(LD) -d -s -v -c linkfile_fs build/dosboot_fs.sfc

build/bdisk.bin: tools/mkbdisk.py
	python3 tools/mkbdisk.py build

build/kbdlayout.asm: tools/mkkbd.py
	python3 tools/mkkbd.py build

build/cgalut.bin: tools/mkcgalut.py
	python3 tools/mkcgalut.py build/cgalut.bin
