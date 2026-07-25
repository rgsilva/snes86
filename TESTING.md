# Testing snes86

Three tiers, one command each, all from the repo root. The suite always
tests the **exact artifact that ships** (`snes/build/msdos.sfc`), plus
the ELKS and FreeDOS ROMs.

Two ground rules the suite enforces itself: it **refuses to run while a
Mesen GUI window is open** (testrunner and GUI collide), and it
**deletes `msdos.srm`** — the battery-backed B: drive of any same-named
ROM in your Mesen saves — because the TED leg needs fresh SRAM. Suite
runs are destructive to B: by design.

## Quick — `make test QUICK=1` (~3 minutes)

The while-hacking loop. Builds the public ROM, then runs:

- **CPU parity** — a random 8086 instruction stream through the C
  reference core and the 65816 core in lockstep, all 14 guest registers
  compared after every instruction (needs Mesen).
- **All the host smokes** (below — they're fast on the desktop core).
- Two Mesen legs: boot to `C:\>` and the CGA mode-4 card.

## Normal — `make test` (~15–20 min with Mesen; ~2–3 min without)

Everything free and shipped. This is also **exactly what CI runs** — on
a machine with no Mesen, the Mesen legs and parity self-skip with one
loud line (`the 65816 core was NOT exercised`) and the host legs still
gate the result.

**Host smokes** (`runpc`, the C reference PC — same 8086 core, desktop
speed):

| leg | what it proves |
|---|---|
| `host-smoke` | MS-DOS 2.0 boots and reads the C: drive |
| `elks-host` | ELKS 0.9.1 (Linux) boots to `login:` |
| `freedos-host` | FreeDOS 1.3 boots to FreeCOM |
| `cga6-host` | CGA mode 6 renders true 640×200 (1-px stripes survive) |
| `view-host` | VIEW paints both test cards; the BMP and PCX renders are bit-identical |
| `ted-host` | TED types, menu-saves, and the file round-trips byte-exact |
| `java-host` | JAVA.COM runs real javac bytecode (Hello + the 32-bit Fib) |
| `cc-host` | Small-C compiles, links and runs HELLO.C and SIEVE.C in-machine |
| `jc-host` | JAVAC compiles Java *on the machine*, JAVA runs the result |
| `jc-desktop` | the same compiler's output runs on a real desktop JVM (skips without a JDK) |

**Mesen legs** (the real 65816 core executing the real ROM): boot,
console/`DIR`, keyboard scancodes, the CGA mode-4 and mode-6 cards, the
MIDI driver, TED end-to-end on the SNES (types with the controller,
saves to battery SRAM, `TYPE`s it back), and the two big ones — ELKS
boot-to-login and FreeDOS boot, each on its own ROM and timeout.

## Full regression — `make test && make test-extra` (local only)

`test-extra` drives the **copyrighted app matrix** — commercial 1980s
software that cannot ship in this repo and lives only in a developer's
local `disks/` folder. There is no guessing about what it needs:

```sh
python3 disks/mkappmatrix.py --check   # the manifest: present / missing
make test-extra                        # refuses to run if incomplete
```

When the manifest is complete it builds a private fixture ROM (the
public machine + `disks/appmatrix` overlaid — never shipped) and runs
five Mesen legs: **Zork I**, **GW-BASIC 3.23**, **WordStar 3.31**,
**Multiplan**, and the 40/80-column **MODE** switch. These exist
because free software can't regression-test FCB overlay loading,
Z-machine memory patterns, or GW-BASIC's interrupt habits — the messy
1982 behaviors that have historically caught real core bugs.

## Deep cuts

- `make homebrew` — rebuilds **every homebrew tool from source**: Turbo
  Pascal 3 is fetched (pinned + sha256-checked) and driven inside the
  emulator to recompile each `.pas`; `javac.exe` is rebuilt by the
  Small-C toolchain the same way. Each tool verifies (VIEW by render
  bit-compare, javac byte-identical) and reports PASS/FAIL. This is the
  sources-don't-rot canary. Note it rebuilds the committed binaries in
  place — `git checkout` restores them.
- **The 8088 vector suite** — the C core against all 3,007,000
  [SingleStepTests 8088 v2](https://github.com/SingleStepTests/8088)
  vectors, including undocumented opcodes and microcode-exact flags:

  ```sh
  cd core-c && make && tests/vectors/fetch.sh   # one-time, ~760 MB
  make test
  ```

Where the machinery lives: `snes/test/suite.sh` (the legs),
`snes/test/*.lua` (the Mesen drivers), `snes/test/parity.sh` (lockstep),
`disks/mkappmatrix.py` (the fixture manifest). Build documentation:
[docs/BUILDING.md](docs/BUILDING.md).
