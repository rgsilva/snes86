# SOKOBAN — our CGA-graphics game.
B := build

stage: $(B)/SOKOBAN.COM

$(B)/SOKOBAN.COM: sokoban.com
	@mkdir -p $(B)
	cp sokoban.com $@

recompile:
	sh ../tpcompile.sh sokoban sokoban
	$(MAKE) stage

clean:
	rm -rf $(B)

.PHONY: stage recompile clean
