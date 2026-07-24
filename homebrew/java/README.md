# Java on snes86

JAVA.COM is a Java class-file interpreter that runs real `javac`
bytecode on the emulated 8086 (and therefore on a SNES). Because DOS
8.3 names cannot hold `.class`, class files travel as `.CLA`.

    C:\JAVA> JAVA HELLO
    Hello from Java on a SNES!

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
