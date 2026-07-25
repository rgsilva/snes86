# Java on snes86

JAVA.COM is a Java class-file interpreter that runs real `javac`
bytecode on the emulated 8086 (and therefore on a SNES). Because DOS
8.3 names cannot hold `.class`, class files travel as `.CLA`.

    C:\JAVA> JAVA HELLO
    Hello from Java on a SNES!

**JAVAC.EXE ships too** — a Java compiler that runs on the machine
itself, so the SNES compiles Java and then runs it (C: is read-only,
so output goes to A:):

    C:\JAVA> JAVAC HELLO.JAV A:HELLO.CLA
    ok: A:HELLO.CLA
    C:\JAVA> JAVA A:HELLO
    Hello from Java on a SNES!

The sample sources ship as `.JAV` for exactly this. JAVAC is written
in C (`javac.c`) and built by the 1988 Small-C toolchain running on
MS-DOS 2.0 *inside our own emulator* (`make javac-dos`, deterministic);
the same source built with clang (`make javac-dev`) emits byte-identical
class files, which also pass a modern JVM's verifier. The port war
story — three vintage-toolchain walls and a silent-miscompile hunt —
is in [JAVAC-PORTING.md](JAVAC-PORTING.md).

## Building the samples

On any machine with a JDK:

    ./mkjava.sh          # javac --release 8 *.java; renames to .CLA

`--release 8` matters: newer targets emit `invokedynamic` string
concatenation, which is out of scope here. The compiled `.CLA` files
are committed so the repo builds without a JDK.

## What the interpreter supports

Static methods of a single class, 32-bit `int` arithmetic (as hi/lo
16-bit pairs - the hot ops are hand-written 8086), `boolean[]`/`int[]`
arrays, `String` literals, `StringBuilder` concatenation (what javac
emits for `"a" + i`), `System.out.println/print`, `System.in.read()`.
No long/float/double, no user objects, no exceptions, no GC (nothing
lives long enough to need one). Unsupported bytecode fails with a
clean message naming the opcode. The interpreter prints elapsed BIOS
ticks on exit (18.2 Hz) - the benchmark currency of the house.
