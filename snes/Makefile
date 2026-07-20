PVBIN  := ../../pvsneslib/devkitsnes/bin
AS     := $(PVBIN)/wla-65816
AS_SPC := $(PVBIN)/wla-spc700
LD     := $(PVBIN)/wlalink

all: build/console.sfc

build/font_bg2.bin build/font_bg1.bin: tools/mkfont.py tools/font8x8_basic.h
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

.PHONY: all run test clean

# --- M6: DOS boot ROM
dos: build/dosboot.sfc

build/dosboot.o: dosboot.asm hdr_dos.asm cpu.asm cpu2.asm build/pf.bin build/bdisk.bin build/kbdlayout.asm build/font_bg2.bin build/font_bg1.bin ../disks/pcdos200-disk1.img build/adisk.img build/hd.img build/spc_midi64.bin build/cgalut.bin build/aluflat.asm
	$(AS) -o build/dosboot.o dosboot.asm

build/aluflat.asm: tools/mkaluflat.py
	python3 tools/mkaluflat.py build/aluflat.asm

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

build/dosboot_big.o: dosboot_big.asm dosboot.asm hdr_dos.asm cpu.asm cpu2.asm build/pf.bin build/bdisk.bin build/kbdlayout.asm build/font_bg2.bin build/font_bg1.bin build/adisk.img build/hd.img build/spc_midi64.bin build/cgalut.bin build/aluflat.asm
	$(AS) -o build/dosboot_big.o dosboot_big.asm

build/dosboot_big.sfc: build/dosboot_big.o linkfile_big
	$(LD) -d -s -v -c linkfile_big build/dosboot_big.sfc

# --- M16: MS-DOS 2.0 variant (MIT). A: is the MS-DOS boot floppy built by
# msdos/mkmsdos.py; C: is the same app library. build_io.sh needs ./jwasm +
# ../core-c/build/runpc (see BUILDING). Same as `dos` but with MSDOSA defined.
msdos: build/dosboot_msdos.sfc

../msdos/msdos.img: ../msdos/io.asm ../msdos/boot.asm ../msdos/mkmsdos.py ../msdos/MSDOS.SYS ../msdos/COMMAND.COM
	cd ../msdos && ./build_io.sh

build/msdos_a.img: ../msdos/msdos.img
	cp ../msdos/msdos.img build/msdos_a.img

build/dosboot_msdos.o: dosboot_msdos.asm dosboot.asm hdr_dos.asm cpu.asm cpu2.asm build/pf.bin build/bdisk.bin build/kbdlayout.asm build/font_bg2.bin build/font_bg1.bin build/msdos_a.img build/hd.img build/spc_midi64.bin build/cgalut.bin build/aluflat.asm
	$(AS) -o build/dosboot_msdos.o dosboot_msdos.asm

build/dosboot_msdos.sfc: build/dosboot_msdos.o linkfile_msdos
	$(LD) -d -s -v -c linkfile_msdos build/dosboot_msdos.sfc

# SRAM extent probe (M15): requests 128 KB, reports real banks -> WRAM $04.
# Run: Mesen --testrunner build/sramtest.sfc test/sram.lua
sramtest: build/sramtest.sfc
build/sramtest.sfc: sramtest.asm linkfile_sramtest
	$(AS) -o build/sramtest.o sramtest.asm
	$(LD) -d -s linkfile_sramtest build/sramtest.sfc

build/dosboot_fs.o: dosboot_fs.asm dosboot.asm hdr_dos.asm cpu.asm cpu2.asm build/pf.bin build/bdisk.bin build/kbdlayout.asm build/font_bg2.bin build/font_bg1.bin ../disks/fs1.img build/hd.img build/spc_midi64.bin build/cgalut.bin build/aluflat.asm
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
