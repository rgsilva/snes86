# SOKOBAN — our CGA-graphics game.
# sokoban.com is a BUILD PRODUCT (not committed): TP3 inside runpc.
B := build

stage: $(B)/SOKOBAN.COM

sokoban.com: sokoban.pas ../tpcompile.sh
	sh ../tpcompile.sh sokoban sokoban

$(B)/SOKOBAN.COM: sokoban.com
	@mkdir -p $(B)
	cp sokoban.com $@

recompile:
	sh ../tpcompile.sh sokoban sokoban
	$(MAKE) stage

clean:
	rm -rf $(B)

.PHONY: stage recompile clean
