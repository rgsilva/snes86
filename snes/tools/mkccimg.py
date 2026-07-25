#!/usr/bin/env python3
"""Build build/cctest.img — the cc-host suite leg's writable work floppy.

A copy of the boot floppy (A:) carrying the two sample sources and a
batch that drives the full Small-C cycle twice: compile, assemble, link
and run HELLO.C and SIEVE.C, with the toolchain on read-only C:\\CC and
every intermediate landing on the writable work drive (the same shape as
B: on the SNES). DOS 2.x note: batch-to-batch calls chain (no CALL until
3.3), so the pipeline is inlined here instead of invoking CC.BAT.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "homebrew"))
from fatimg import Floppy                        # noqa: E402

BUILD = os.path.join(HERE, "..", "build")
CC = os.path.join(HERE, "..", "..", "freeware", "cc")

GO = ("path c:\\;c:\\dos;c:\\cc\r\n"
      "copy c:\\cc\\stdio.h stdio.h\r\n"
      "scc hello -m\r\n"
      "asm hello -S200 -NM\r\n"
      "ren hello.obj prog.obj\r\n"
      "link @c:\\cc\\clib.rsp\r\n"
      "ren prog.exe hello.exe\r\n"
      "hello\r\n"
      "copy c:\\cc\\sieve.c sieve.c\r\n"
      "scc sieve -m\r\n"
      "asm sieve -S200 -NM\r\n"
      "del prog.obj\r\n"
      "ren sieve.obj prog.obj\r\n"
      "link @c:\\cc\\clib.rsp\r\n"
      "ren prog.exe sieve.exe\r\n"
      "sieve\r\n"
      "echo CC-CYCLE-DONE\r\n")

src = os.path.join(BUILD, "msdos_a.img")
dst = os.path.join(BUILD, "cctest.img")
open(dst, "wb").write(open(src, "rb").read())
f = Floppy(dst)
f.add("HELLO.C", open(os.path.join(CC, "samples", "HELLO.C"), "rb").read())
f.add("GO.BAT", GO.encode())
f.save(dst)
print("cctest.img: work floppy for the cc-host leg")
