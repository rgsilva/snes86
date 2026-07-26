# snes86

An actual 8086 IBM PC emulator for the Super Nintendo. No, you are not drunk.

The snes86 is an 8086 PC emulator written from scratch in 65C816 assembly. It boots real MS-DOS 2.0 from a ROM "disk", renders CGA/MDA text and graphics, turns the SNES sound chip into a MIDI synth, and runs period DOS software.

<p align="center">
  <img src="docs/assets/boot.png" width="480" alt="MS-DOS 2.0 booting on snes86"><br>
  <sub>MS-DOS 2.0</sub>
</p>

And, yes, it even boots Linux:

<p align="center">
  <img src="docs/assets/elks.png" width="480" alt="ELKS 0.9.1 booting to a root shell on snes86"><br>
  <sub>ELKS 0.9.1</sub>
</p>

## Why?

There is no good reason why, and the proper answer to this question is: _why not?_

A Super Nintendo's CPU is a 16-bit 65C816 running around 3.5 MHz. This project makes it impersonate an Intel 8086. This is basically an emulator: it loads the 8086 code into RAM and execute it - fetching and decoding instruction as they come along. Refer to [INTERNALS](docs/INTERNALS.md) for how it all actually works behind the scenes (disclaimer: it's messy).

## Try it

Since this project generates a ROM file (.sfc) for you to use, there are a few build targets you can use:

| Target | Output file | Remarks |
|---|---|---|
| `make msdos` | `build/msdos.sfc` | |
| `make msdos_sa1` | `build/msdos_sa1.sfc` | A 300 KB machine instead of the usual 108 KB. Asks for an SA-1 cartridge, so read the note below. |
| `make freedos` | `build/freedos.sfc` | Boots on that same 300 KB SA-1 machine, so the same note applies. |
| `make elks` | `build/elks.sfc` | Linux, on that same 300 KB SA-1 machine. The extra RAM is what finally lets it fork its own boot scripts. |
| `make boot DISK=floppy.img` | `build/boot.sfc` | Needs to have a boot disk parameter, so pass it as the `DISK` parameter. This is useful when booting, for example, Flight Simulator 1.0. |

> Note: every DOS image has a writeable `B:` drive, and it should be kept between power cycles as it has a battery backup in most SNES cartridges. Your milage may vary though. On `msdos` that's 32 KB of plain cartridge SRAM; on `msdos_sa1` and `freedos` it's a 64 KB slice of the coprocessor's own RAM.

> Note: `msdos_sa1`, `freedos` and `elks` ask for an SA-1 cartridge board, and we do the rudest possible thing with it: we never start its 10 MHz CPU at all, and use the chip purely as a RAM stick. That means those three ROMs only run where SA-1 is actually implemented. Mesen is fine, and so is the FXPak Pro (it's the same support that runs Super Mario RPG). Simpler flash carts may not be, and if yours isn't, `msdos.sfc` is the one to flash.

Prerequisites, the other build targets, and the self-hosted MS-DOS toolchain are in [BUILDING](docs/BUILDING.md).

## Available software

The public ROM ships only free software - all of it ours, public domain or MIT:

* A simple nano-like text editor
* A VI port (yes!)
* A terrible image viewer
* A very simple compiler and runtime for Java applications
* A MIDI player that uses the SNES APU for playing songs
* A very simple Sokoban game
* Some very simple benchmark utilities
* A very slow and crappy Gameboy emulator
* A C compiler

For all of the apps, you can check details and examples in our [apps/README](apps/README.md). All tools are available in the MS-DOS image, and the big SA-1 image has them too — with a writeable `B:` of its own, so they're just as usable there.

There's also a bunch of other tests I've done, mostly with shareware/licensed/weird software, and you can find them documented in [COMPATIBILITY](docs/COMPATIBILITY.md).

Oh, and if you are curious of what can we do with it, here's a whole dev-workstation demo, 8086 on a SNES style: [video](docs/assets/devstation.mp4) ([mirror](https://youtu.be/L4caINpE8gE)).


## Legal & credits

MS-DOS 2.0 is MIT-licensed ([microsoft/MS-DOS](https://github.com/microsoft/MS-DOS)). The public ROM contains only freely redistributable software — no copyrighted DOS applications. Our own tools live in `apps/` with source; Turbo Pascal 3, which compiles them *inside the emulator*, is fetched at build time and never redistributed (Borland retains all rights). The ELKS ROM bundles the unmodified official [ELKS](https://github.com/ghaerr/elks) release images (GPL-2.0), fetched at build time rather than committed here; ELKS's source lives upstream.

- Test vectors: [SingleStepTests/8088](https://github.com/SingleStepTests/8088) v2 by Daniel Balsom, captured from a real AMD D8088.
- The microcode division routines and the undefined-flag behavior of the BCD instructions in `core-c/src/x86.c` are ported from [MartyPC](https://github.com/dbalsom/martypc) (MIT, © 2022–2026 Daniel Balsom), which derives from reenigne's 8086 microcode disassembly.
- Inspired by Daniel Palmer's LinuxMD (Linux on the Mega Drive).

## Disclaimer

snes86 was built for fun and is provided **AS IS** - no warranty of any kind, express or implied; no guarantee it is correct, complete, or fit for any purpose. If you flash it, run it, or build on top of it, whatever happens — to your cartridge, your console, your save files, or your weekend — is on you.

This project was built heavily on top of AI to simplify coding and make things move faster. As a software engineer myself, I have my own opinions on the matter, but this saved me months (possibly years) of working on a _fun vacation project_. That said, you can expect the classic crappy/weird coding from AI itself, and that's ok.

> PS: this was also a great experiment of how much crazy stuff I can throw at AI... and turns out it's _a lot_.

As a final disclaimer, this has yet to be tested on real hardware. This was current testing in Mesen and snes9x emulators as unfortunately my console is out for repairs (yey). Once this has been tested on the real deal, this will be definitely updated. Feel free to test it yourself in your console though, just don't blame me if it catches on fire!

Have fun!
