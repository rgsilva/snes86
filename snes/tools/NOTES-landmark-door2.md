# Door 2: running Landmark on DOS 2.0 — investigation notes

**Status: DIAGNOSED, real fix SPECIFIED, implementation DEFERRED.**
Date: 2026-07-17.

## The goal

Landmark Speed Test 2.0 (`lm20.exe`) and SPEED600 are the classic CPU
speedometers we wanted alongside Norton SI. Both abort immediately on
our PC DOS 2.00 with:

    run-time error R6009
    - not enough space for environment

We do NOT want to switch the machine to DOS 3 (it costs ~13-31 KB of
RAM and would evict GW-BASIC — see project memory). "Door 2" was the
plan to fool Landmark into running on DOS 2.0.

## Root cause (PROVEN, not theorized)

R6009 comes from the Microsoft C runtime startup (`__setenvp`). Late
MSC runtimes assume the **DOS 3.0+ environment layout**: after the
environment block's terminating double-NUL, DOS 3+ appends

    dw <count of extra strings>      ; normally 0x0001
    "<full path to the EXE>\0"       ; argv[0] source

MSC's startup reads that count word and pathname. On DOS 2.0 there is
no trailer, so it reads whatever garbage follows the env block; the
computed environment size comes out huge, the near-heap copy `malloc`
fails, and you get R6009. (MSC programs that shipped for DOS 2.0 used
older runtimes with a DOS-2 fallback path; lm20's runtime has none.)

## Why the obvious fix (forge the trailer in the parent) FAILS

`tools/mklm.py` builds `LM.COM`: a hand-assembled launcher that
constructs a full DOS-3-shaped environment — trailer included — in its
own memory, shrinks its allocation (INT 21 AH=4A), and EXECs the child
(INT 21 AH=4B AL=00) pointing the parameter block's env field at the
forged block.

It EXECs fine, but the child still fails. Proof via `ENVDUMP.COM`
(prints the child's own environment byte-for-byte):

    forged parent env : COMSPEC=A:\COMMAND.COM.PATH=C:\;C:\BENCH..\x01\x00ENVDUMP.COM
    child receives    : COMSPEC=A:\COMMAND.COM.PATH=C:\;C:\BENCH..<GARBAGE>

The `..` is the double-NUL; after it, our `\x01\x00ENVDUMP.COM` is gone,
replaced by uninitialised segment memory ("1981...1983" fragments).

**DOS 2.0's EXEC copies the provided environment only up to and
including the double-NUL, into a fresh paragraph-rounded segment, and
does NOT zero the slack.** The trailer we forged is stripped by the
copy; the slack bytes are random. So no parent-side env content can
reach the child past the double-NUL. (DOS 3+ is exactly the version
that learned to append the trailer *itself* after this copy — which is
the whole reason the layout is version-gated.)

## The real fix (specified, deferred)

Bypass DOS's copy by loading the child WITHOUT executing it, fixing its
environment, then jumping in:

1. `LM.COM` calls INT 21 AH=4B **AL=01** (load, don't execute) on
   `LM20.EXE`. DOS builds the child PSP + (stripped) env and returns
   its initial SS:SP and CS:IP in the extended parameter block, WITHOUT
   running it.
2. Find the child's env segment (child PSP:2C). Allocate a fresh
   segment (AH=48), copy the stripped env, append `dw 1` + the child's
   full pathname + NUL, and write the new segment back to child PSP:2C.
3. Restore/repoint our own stack, set up registers, and far-JMP to the
   returned child CS:IP with SS:SP.

Hard parts (why it's deferred, not done):
- **Child PSP discovery under AL=01 for an EXE.** DOS returns the entry
  CS:IP and SS:SP but not the PSP segment directly; for an EXE the PSP
  is at the allocation base, which must be inferred (e.g. note the free
  arena before the call, or read the MCB chain). This is the crux.
- All of this is raw hand-assembled opcodes (no nasm/yasm on this box),
  with a stack switch and a far jump — high blind-error risk. Should be
  built and single-stepped under `runpc` before trusting it.

## Alternative worth trying first next time

Find **Landmark 1.x** (pre-2.0). The early versions were assembly, not
MSC-C, and have no environment-trailer dependency — they may just run
on DOS 2.0 with no launcher at all. Cheapest possible win.

## Artifacts (kept for the next attempt)

- `tools/mklm.py` — the AL=00 launcher (forges env; proven insufficient).
  Rework to AL=01 per "the real fix" above.
- `build/envdump.com` throwaway prober logic is inline in git history
  (a 27-byte COM: `mov es,[2C]` then print 320 env bytes, NUL->'.').
- These games are NOT on the C: image (they don't work yet); SI 4.5 is
  our working benchmark in the meantime.
