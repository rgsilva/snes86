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

.PHONY: all run test clean dosboot dev big fs io

# --- DOS boot ROM.  `make dosboot` = the PUBLIC build: MS-DOS 2.0 (MIT) + a
# free C: (tools/mkhd_free.py; no copyrighted software).  `make dev` is the
# same machine with the full local C: app library.  See docs/BUILDING.md.
dosboot: build/dosboot.sfc

build/dosboot.o: dosboot.asm hdr_dos.asm cpu.asm cpu2.asm build/pf.bin build/bdisk.bin build/kbdlayout.asm build/font_bg2.bin build/font_bg1.bin build/msdos_a.img build/hd_free.img build/spc_midi64.bin build/cgalut.bin build/aluflat.asm build/cgafont.bin build/trace_meta.asm
	$(AS) -o build/dosboot.o dosboot.asm

build/aluflat.asm: tools/mkaluflat.py
	python3 tools/mkaluflat.py build/aluflat.asm

# trace_meta.asm is empty for normal builds; test/tracewin.sh overwrites it to
# turn on the lockstep-trace build. Create the empty default so a clean checkout
# (e.g. CI) assembles — dosboot.asm .INCLUDEs it unconditionally.
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

build/dosboot.sfc: build/dosboot.o linkfile_dos
	$(LD) -d -s -v -c linkfile_dos build/dosboot.sfc

fs: build/dosboot_fs.sfc

big: build/dosboot_big.sfc

build/dosboot_big.o: dosboot_big.asm dosboot.asm hdr_dos.asm cpu.asm cpu2.asm build/pf.bin build/bdisk.bin build/kbdlayout.asm build/font_bg2.bin build/font_bg1.bin build/msdos_a.img build/hd.img build/spc_midi64.bin build/cgalut.bin build/aluflat.asm build/cgafont.bin build/trace_meta.asm
	$(AS) -o build/dosboot_big.o dosboot_big.asm

build/dosboot_big.sfc: build/dosboot_big.o linkfile_big
	$(LD) -d -s -v -c linkfile_big build/dosboot_big.sfc

# sneslinux: ELKS ROM-XIP variant (not a DOS boot, hence no dosboot_ prefix).
# build/elks_rom.bin + build/elks_romfs.bin are local artifacts (the official
# ELKS release ROM images, or our own build) dropped in by the sneslinux
# tree — deliberately not fetched here.
elks: build/elks.sfc

build/elks.o: elks.asm dosboot.asm hdr_dos.asm cpu.asm cpu2.asm build/pf.bin build/bdisk.bin build/kbdlayout.asm build/font_bg2.bin build/font_bg1.bin build/msdos_a.img build/spc_midi64.bin build/cgalut.bin build/aluflat.asm build/cgafont.bin build/trace_meta.asm build/elks_rom.bin build/elks_romfs.bin
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

# --- free C: (public): our tools + Turbo Pascal source + a generated CC0 demo
# + anything in userware/.  Built from committed files only.
build/hd_free.img: tools/mkhd_free.py build/cgatest.com ../disks/midplay.com ../disks/midconv.com ../disks/sokoban.com ../disks/hello.com ../disks/sieve.com ../disks/midplay.pas ../disks/midconv.pas ../disks/sokoban.pas ../disks/HELLO.pas $(wildcard userware/*)
	python3 tools/mkhd_free.py build

# --- DEVELOPER build: MS-DOS + the FULL local C: app library (tools/mkhd.py,
# which pulls in copyrighted software present only on the dev machine).
dev: build/dosboot_dev.sfc

build/dosboot_dev.o: dosboot_dev.asm dosboot.asm hdr_dos.asm cpu.asm cpu2.asm build/pf.bin build/bdisk.bin build/kbdlayout.asm build/font_bg2.bin build/font_bg1.bin build/msdos_a.img build/hd.img build/spc_midi64.bin build/cgalut.bin build/aluflat.asm build/cgafont.bin build/trace_meta.asm
	$(AS) -o build/dosboot_dev.o dosboot_dev.asm

build/dosboot_dev.sfc: build/dosboot_dev.o linkfile_dev
	$(LD) -d -s -v -c linkfile_dev build/dosboot_dev.sfc

# SRAM extent probe (M15): requests 128 KB, reports real banks -> WRAM $04.
# Run: Mesen --testrunner build/sramtest.sfc test/sram.lua
sramtest: build/sramtest.sfc
build/sramtest.sfc: sramtest.asm linkfile_sramtest
	$(AS) -o build/sramtest.o sramtest.asm
	$(LD) -d -s linkfile_sramtest build/sramtest.sfc

build/dosboot_fs.o: dosboot_fs.asm dosboot.asm hdr_dos.asm cpu.asm cpu2.asm build/pf.bin build/bdisk.bin build/kbdlayout.asm build/font_bg2.bin build/font_bg1.bin ../disks/fs1.img build/hd.img build/spc_midi64.bin build/cgalut.bin build/aluflat.asm build/cgafont.bin build/trace_meta.asm
	$(AS) -o build/dosboot_fs.o dosboot_fs.asm

build/dosboot_fs.sfc: build/dosboot_fs.o linkfile_fs
	$(LD) -d -s -v -c linkfile_fs build/dosboot_fs.sfc

build/bdisk.bin: tools/mkbdisk.py
	python3 tools/mkbdisk.py build

build/kbdlayout.asm: tools/mkkbd.py
	python3 tools/mkkbd.py build

build/adisk.img: tools/mkadisk.py tools/autoexec.bat ../disks/pcdos200-disk1.img ../disks/pcdos200-disk2.img
	python3 tools/mkadisk.py build

build/hd.img: tools/mkhd.py tools/autoexec.bat ../disks/gwbasic.exe ../disks/zork1_snes.com ../disks/ws_installed.com ../disks/mp_com_compaq.bin ../disks/tp301.img build/cgatest.com
	python3 tools/mkhd.py build

build/cgatest.com: tools/mkcgatest.py
	python3 tools/mkcgatest.py build/cgatest.com

build/cgalut.bin: tools/mkcgalut.py
	python3 tools/mkcgalut.py build/cgalut.bin
