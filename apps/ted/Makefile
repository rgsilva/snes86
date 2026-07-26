# TED — the controller-first text editor. C:\TED is on the DOS PATH.
# ted.com is a BUILD PRODUCT (not committed): TP3 inside runpc.
B := build

stage: $(B)/TED.COM

ted.com: ted.pas ../tpcompile.sh
	sh ../tpcompile.sh ted ted

$(B)/TED.COM: ted.com
	@mkdir -p $(B)
	cp ted.com $@

recompile:
	sh ../tpcompile.sh ted ted
	$(MAKE) stage

clean:
	rm -rf $(B)

.PHONY: stage recompile clean
