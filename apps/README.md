# Apps

This folder contains all of our custom tools for this project. This is just a bunch of random, funny stuff, that we created to demo and/or evaluate the capabilities of our emulator. Some of them (like the Java one) came up as a joke between friends, but some were actually a necessity, like our text editor (`EDLIN` sucks).

> Please note that all tools are shipped with the normal project build, but not everything works without a `B:` drive. For example, you can't build Java or C code without a writeable disk.. obviously.

## MIDI

This is our MIDI playback pair, and the reason the SNES is your sound card: the SPC-700 audio chip runs an 8-voice General MIDI synth, and the guest sees a small MIDI card. It works in two steps because 1980s math was expensive: `MIDCONV` converts a Standard MIDI File (format 0) into a `.SNM` packet stream (doing the slow real-number timing math once) so `MIDPLAY` can be a fast dumb loop that streams packets to the synth. It ain't perfect, but works. You can test it as such:

```
C:\> CD MIDI
C:\MIDI> MIDCONV YOURS.MID YOURS.SNM      (converts the MID file into our SNM format)
C:\MIDI> MIDPLAY DEMO.SNM                 (plays the SNM format)
```

[▶ Watch the demo tune](../docs/assets/mididemo.mp4). We used Beethoven's "Ode to Joy", sequenced as a CC0 MIDI, played through the SPC-700. Even the PC speaker routes to the synth, so programs that beep make sound.

## VIEW

This is a picture viewer we created: it decodes BMP (8/24/32-bit uncompressed) and PCX (8-bit RLE) files pixel-by-pixel *on the emulated 8086* and dithers them onto the CGA screen — 640×200 halftone by default, 320×200 four-colour if you ask. A full paint takes a few minutes of the image crawling up the screen, exactly as the eighties intended. L/R pan the 512-pixel window across the 640. You can test it as such:

```
C:\> CD VIEW
C:\VIEW> VIEW CARD.BMP        (the generated test card)
C:\VIEW> VIEW CARD.PCX        (same pixels, PCX decoder)
C:\VIEW> VIEW CARD.BMP 4      (320x200 four-colour mode)
C:\VIEW> VIEW *.BMP           (slideshow: any key = next, ESC = quit)
```

![VIEW halftoning the MS-DOS logo](../docs/assets/view.png)

Your own images: any uncompressed BMP up to 2048 pixels wide (convert with `sips -s format bmp in.jpg --out out.bmp` on macOS), dropped into `user/` → `C:\USER`.

## TED

This is a visual text editor we created in Turbo Pascal, built to be driven with a game pad: the d-pad moves the cursor, SELECT opens the on-screen keyboard for typing, START is Enter, and **Y opens the menu** (Save / Save As / Load / Search / Goto / Quit) so commands cost zero keyboard trips. Keystrokes land in ~50 ms — live typing, no interpreter tricks, it's compiled Pascal. You can test it as such:

```
C:\> TED B:NOTE.TXT
```

> Note: TED is on the PATH, so it works from anywhere.

Save to `B:` and the file lives in battery-backed cartridge SRAM: power off, power on, it's still there, like a game save.

![TED mid-edit on B:NOTE.TXT](../docs/assets/ted.png)

## JAVA + JAVAC

Yes, this is a Java runtime (-ish) running inside a 8086 emulator running MS-DOS inside a Super Nintendo videogame console. Don't ask how we got here. It's the "Write once, run anywhere", but taken literally.

`JAVA.COM` interprets real `javac` bytecode (shipped as `.CLA`, because DOS 8.3 can't spell `.class`), and `JAVAC.EXE` is our Java compiler *running on the 8086 machine* — so the SNES compiles Java and then runs it. Compiling takes a couple of seconds; *running* is the slow part (the sieve interprets ~330K bytecodes in about 3½ minutes and prints its own tick count). You can test it as such:

```
C:\> CD JAVA
C:\JAVA> JAVA HELLO                      run the shipped bytecode
C:\JAVA> JAVA SIEVE                      1899 primes, timed in BIOS ticks
C:\JAVA> JAVAC HELLO.JAV B:HELLO.CLA     compile Java on a SNES
C:\JAVA> JAVA B:HELLO
```

> Note: `C:` is read-only, so JAVAC's output must go to the writable `B:`.

![Java running on the SNES](../docs/assets/java.png)

Details and the supported subset: [java/README.md](java/README.md). How a 1988 C compiler ended up building JAVAC inside our own emulator: [docs/notes/javac-porting.md](../docs/notes/javac-porting.md).

## SOKOBAN

Our CGA puzzle game, with source — push the crates onto their targets, d-pad to move. You can test it as such:

```
C:\> CD SOKOBAN
C:\SOKOBAN> SOKOBAN
```

![Sokoban](../docs/assets/sokoban.png)

## BENCH

The benchmarks and test cards, mostly useful for regression hunting and bragging: `SIEVE` (the BYTE sieve, ten iterations), `HELLO`, and the two CGA test cards `CGATEST` (320×200 mode 4) and `CGA6TST` (true 640×200 mode 6 — any key exits back to DOS).

```
C:\> CD BENCH
C:\BENCH> SIEVE
C:\BENCH> CGA6TST
```

## C compiler

We provide the Small-C toolchain (public-domain compiler + assembler, the MIT MS-DOS linker, runtime, samples) → `C:\CC`. Compiles and runs C entirely inside the emulated machine at the stock 108 KB. You can use it like this:

```
C:\> B:
B:\> COPY C:\CC\HELLO.C
B:\> CC HELLO                  (this may take over 10 minutes)
B:\> HELLO                     (run compiled binary)
Hello from Small-C inside snes86!
```

The pipeline, called by `CC.BAT`, is three real programs (`SCC`, `ASM` and `LINK`). Two samples ship **with source** in `C:\CC`: `HELLO.C` and `SIEVE.C`.

Some extra technical details are provided [here](cc/README.md).

--

# Building them

`make apps` from the repo root runs the whole loop: rebuild every tool from source and verify (see [TESTING.md](../docs/TESTING.md)).

Each tool folder holds its own source, the committed `.COM` binary, any generators it owns, and a Makefile with two targets:

- `make stage` — populate `<tool>/build/` with **exactly** what ships on the C: drive as `C:\<TOOL>`. Binaries and sample files are provided as part of the image. Source code is only added to the final image if we can build it inside the emulator, otherwise it's unnecessary.
- `make recompile` — rebuild the `.COM` from source by driving the compilers inside `runpc`, our own emulated MS-DOS 2.0. External tools such as Turbo Pascal 3 are fetched, but not committed. This is mostly due to licensing - for example, Borland/Embarcadero retain all rights to TP3, so we can't really redistribute it here.
