# MIDI — MIDPLAY/MIDCONV, the SNES-as-a-MIDI-synth tools, plus the
# generated CC0 demo tune (mkdemo.py: an original sequencing of Ode to
# Joy and its .SNM conversion).
B := build

stage: $(B)/MIDPLAY.COM $(B)/MIDCONV.COM $(B)/DEMO.SNM

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
