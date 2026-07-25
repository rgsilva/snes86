# Small-C staging: flatten the kit into build/ -> C:\CC on the ROM.
# The compiler ships as SCC.EXE so the CC.BAT driver owns the CC name
# (DOS resolves .EXE before .BAT). One flat DOS dir: tools, header,
# driver + link response, the runtime as loose .OBJ modules, and the
# sample programs WITH source - the machine can build them (the
# ship-source-only-if-buildable rule, first passer).
BUILD := build

stage:
	@mkdir -p $(BUILD)
	@cp CC.EXE $(BUILD)/SCC.EXE
	@cp ASM.EXE LINK.EXE STDIO.H CC.BAT CLIB.RSP $(BUILD)/
	@cp lib/*.OBJ $(BUILD)/
	@cp samples/*.C $(BUILD)/
	@echo "freeware/cc: staged $$(ls $(BUILD) | wc -l | tr -d ' ') files -> C:\\CC"

clean:
	rm -rf $(BUILD)

.PHONY: stage clean
