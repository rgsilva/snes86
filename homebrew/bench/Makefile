# BENCH — SIEVE/HELLO (TP3) plus the CGA test cards (Python-generated
# x86 machine code: mkcgatest.py, mkcga6test.py). bench.pas is a
# source-only program (no committed binary): `recompile` builds
# sieve/hello; compile bench.pas the same way if you want BENCH.COM.
B := build

stage: $(B)/SIEVE.COM $(B)/HELLO.COM $(B)/CGATEST.COM $(B)/CGA6TST.COM

$(B)/SIEVE.COM: sieve.com
	@mkdir -p $(B)
	cp sieve.com $@

$(B)/HELLO.COM: hello.com
	@mkdir -p $(B)
	cp hello.com $@

$(B)/CGATEST.COM: mkcgatest.py
	@mkdir -p $(B)
	python3 mkcgatest.py $@

$(B)/CGA6TST.COM: mkcga6test.py
	@mkdir -p $(B)
	python3 mkcga6test.py $@

recompile:
	sh ../tpcompile.sh bench sieve
	sh ../tpcompile.sh bench hello
	$(MAKE) stage

clean:
	rm -rf $(B)

.PHONY: stage recompile clean
