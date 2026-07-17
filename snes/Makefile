PVBIN := ../../pvsneslib/devkitsnes/bin
AS    := $(PVBIN)/wla-65816
LD    := $(PVBIN)/wlalink

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

build/cputest.o: cputest.asm cpu.asm hdr.asm build/pf.bin build/stream.bin build/stream_meta.asm
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

build/dosboot.o: dosboot.asm hdr_dos.asm cpu.asm cpu2.asm build/pf.bin build/bdisk.bin build/kbdlayout.asm build/font_bg2.bin build/font_bg1.bin ../disks/pcdos200-disk1.img build/adisk.img build/hd.img build/spc_beep64.bin
	$(AS) -o build/dosboot.o dosboot.asm

build/spc_beep64.bin: spc_beep.asm linkfile_spc
	$(AS_SPC) -o build/spc_beep.o spc_beep.asm
	$(LD) -d -s linkfile_spc build/spc_beep64.bin

build/dosboot.sfc: build/dosboot.o linkfile_dos
	$(LD) -d -s -v -c linkfile_dos build/dosboot.sfc

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
