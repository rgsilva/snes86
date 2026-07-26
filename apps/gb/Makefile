# GB — a Game Boy (DMG) emulator as a 15 KB DOS .COM (pure 8086, CGA).
# `make stage` fills build/ with exactly what ships on C:\GB: the
# committed gb.com plus the homebrew test carts. `make recompile`
# rebuilds everything from source on the host: gb.com needs nasm
# (mksm83.py generates the 512 SM83 opcode handlers into
# hostbuild/sm83.inc), the .gb carts need RGBDS (rgbasm/rgblink/rgbfix).
# macOS: brew install nasm rgbds.
B := build
H := hostbuild

stage: $(B)/GB.COM $(B)/SMOKE.GB $(B)/GFX.GB $(B)/JOY.GB

$(B)/GB.COM: gb.com
	@mkdir -p $(B)
	cp gb.com $@

$(B)/SMOKE.GB: smoke.gb
	@mkdir -p $(B)
	cp smoke.gb $@

$(B)/GFX.GB: gfx.gb
	@mkdir -p $(B)
	cp gfx.gb $@

$(B)/JOY.GB: joy.gb
	@mkdir -p $(B)
	cp joy.gb $@

recompile:
	@mkdir -p $(H)
	python3 mksm83.py > $(H)/sm83.inc
	nasm -f bin -I$(H)/ -o gb.com gb.asm
	rgbasm -o $(H)/smoke.o smoke.asm
	rgblink -o smoke.gb $(H)/smoke.o
	rgbfix -v -p 0xFF smoke.gb
	rgbasm -o $(H)/gfx.o gfx.asm
	rgblink -o gfx.gb $(H)/gfx.o
	rgbfix -v -p 0xFF gfx.gb
	rgbasm -o $(H)/joy.o joy.asm
	rgblink -o joy.gb $(H)/joy.o
	rgbfix -v -p 0xFF joy.gb
	$(MAKE) stage

clean:
	rm -rf $(B) $(H)

.PHONY: stage recompile clean
