CC     ?= cc
CFLAGS  = -O2 -std=c11 -Wall -Wextra -fPIC

all: lib runpc

lib: build/libem86.dylib

runpc: build/runpc

build:
	mkdir -p build

build/libem86.dylib: src/x86.c src/x86.h | build
	$(CC) $(CFLAGS) -shared -o $@ src/x86.c

build/runpc: src/runpc.c src/x86.c src/x86.h src/cgafont.h | build
	$(CC) $(CFLAGS) -o $@ src/runpc.c src/x86.c

x86trace: build/x86trace

build/x86trace: src/x86trace.c src/x86.c src/x86.h | build
	$(CC) $(CFLAGS) -o $@ src/x86trace.c src/x86.c

test: lib
	python3 tests/run_vectors.py

clean:
	rm -rf build

.PHONY: all lib runpc test clean
