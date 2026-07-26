# MIDI — MIDPLAY/MIDCONV, the SNES-as-a-MIDI-synth tools, plus the
# generated CC0 demo tune (mkdemo.py: an original sequencing of Ode to
# Joy and its .SNM conversion).
# The .COMs are BUILD PRODUCTS (not committed): TP3 inside runpc.
# .NOTPARALLEL: the two TP3 compiles share ../cache/tpc.img.
.NOTPARALLEL:
B := build

stage: $(B)/MIDPLAY.COM $(B)/MIDCONV.COM $(B)/DEMO.SNM

midplay.com: midplay.pas ../tpcompile.sh
	sh ../tpcompile.sh midi midplay

midconv.com: midconv.pas ../tpcompile.sh
	sh ../tpcompile.sh midi midconv

$(B)/MIDPLAY.COM: midplay.com
	@mkdir -p $(B)
	cp midplay.com $@

$(B)/MIDCONV.COM: midconv.com
	@mkdir -p $(B)
	cp midconv.com $@

$(B)/DEMO.SNM: mkdemo.py
	@mkdir -p $(B)
	python3 mkdemo.py $(B)

recompile:
	sh ../tpcompile.sh midi midplay
	sh ../tpcompile.sh midi midconv
	$(MAKE) stage

clean:
	rm -rf $(B)

.PHONY: stage recompile clean
