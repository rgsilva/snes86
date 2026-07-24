# JAVA — the class-file interpreter. Ships the interpreter plus the
# sample bytecode as .CLA (8.3 has no room for .class). The .java
# sources stay in samples/ in the repo: the image cannot compile Java,
# so it does not ship sources (see samples/mkjava.sh to regenerate).
B := build
CLASSES := Hello Fib Sieve Concat Guess

stage: $(B)/JAVA.COM $(foreach c,$(CLASSES),$(B)/$(shell echo $(c) | tr a-z A-Z).CLA)

$(B)/JAVA.COM: java.com
	@mkdir -p $(B)
	cp java.com $@

define CLA_template
$(B)/$(shell echo $(1) | tr a-z A-Z).CLA: samples/$(1).class
	@mkdir -p $(B)
	cp $$< $$@
endef
$(foreach c,$(CLASSES),$(eval $(call CLA_template,$(c))))

recompile:
	sh ../tpcompile.sh java java
	$(MAKE) stage

clean:
	rm -rf $(B)

.PHONY: stage recompile clean
