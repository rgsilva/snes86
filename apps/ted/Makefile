# TED — the controller-first text editor. C:\TED is on the DOS PATH.
B := build

stage: $(B)/TED.COM

$(B)/TED.COM: ted.com
	@mkdir -p $(B)
	cp ted.com $@

recompile:
	sh ../tpcompile.sh ted ted
	$(MAKE) stage

clean:
	rm -rf $(B)

.PHONY: stage recompile clean
