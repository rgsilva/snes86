# BENCH — SIEVE/HELLO (TP3) plus the CGA test cards (Python-generated
# x86 machine code: mkcgatest.py, mkcga6test.py). sieve.com/hello.com
# are BUILD PRODUCTS (not committed): TP3 inside runpc. bench.pas is a
# source-only program; compile it the same way if you want BENCH.COM.
# .NOTPARALLEL: the two TP3 compiles share ../cache/tpc.img.
.NOTPARALLEL:
B := build

stage: $(B)/SIEVE.COM $(B)/HELLO.COM $(B)/CGATEST.COM $(B)/CGA6TST.COM

sieve.com: sieve.pas ../tpcompile.sh
	sh ../tpcompile.sh bench sieve

hello.com: hello.pas ../tpcompile.sh
	sh ../tpcompile.sh bench hello

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
