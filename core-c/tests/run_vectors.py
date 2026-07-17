#!/usr/bin/env python3
"""Run the SingleStepTests/8088 v2 vectors against the C core (ctypes).

Usage:
  run_vectors.py                    # full sweep, all downloaded files
  run_vectors.py --files 00 F6.4    # only these opcodes
  run_vectors.py --limit 500        # first N tests per file
  run_vectors.py --fails 3          # print up to N failure details per file
"""
import argparse
import ctypes
import glob
import gzip
import json
import os
import sys
from multiprocessing import Pool, cpu_count

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "build", "libem86.dylib")
VEC = os.path.join(HERE, "vectors")

REGS16 = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di"]
SREGS = ["es", "cs", "ss", "ds"]
PREFIXES = {0x26, 0x2E, 0x36, 0x3E, 0xF0, 0xF1, 0xF2, 0xF3}


class X86(ctypes.Structure):
    _fields_ = [
        ("r", ctypes.c_uint16 * 8),
        ("sr", ctypes.c_uint16 * 4),
        ("ip", ctypes.c_uint16),
        ("flags", ctypes.c_uint16),
        ("halted", ctypes.c_uint8),
        ("_pad", ctypes.c_uint8 * 3),
        ("mem", ctypes.POINTER(ctypes.c_uint8)),
        ("in8", ctypes.c_void_p),
        ("out8", ctypes.c_void_p),
        ("int_hook", ctypes.c_void_p),
        ("ctx", ctypes.c_void_p),
    ]


_dll = None
_cpu = None
_meta = None


def _init_worker():
    global _dll, _cpu, _meta
    _dll = ctypes.CDLL(LIB)
    _dll.x86_new.restype = ctypes.POINTER(X86)
    _cpu = _dll.x86_new()
    with open(os.path.join(VEC, "metadata.json")) as f:
        _meta = json.load(f)["opcodes"]


def flags_mask(instr_bytes):
    """Undefined-flag mask for this instruction, from metadata.json."""
    i = 0
    while i < len(instr_bytes) and instr_bytes[i] in PREFIXES:
        i += 1
    if i >= len(instr_bytes):
        return 0xFFFF
    ent = _meta.get("%02X" % instr_bytes[i], {})
    if "reg" in ent and i + 1 < len(instr_bytes):
        reg = (instr_bytes[i + 1] >> 3) & 7
        ent = ent["reg"].get(str(reg), ent)
    return ent.get("flags-mask", 0xFFFF)


def run_test(t):
    """Returns list of diff strings, empty if pass."""
    c = _cpu.contents
    ctypes.memset(c.mem, 0, 1 << 20)

    init = t["initial"]
    ir = init["regs"]
    for i, n in enumerate(REGS16):
        c.r[i] = ir[n]
    for i, n in enumerate(SREGS):
        c.sr[i] = ir[n]
    c.ip = ir["ip"]
    c.flags = ir["flags"]
    c.halted = 0
    for addr, val in init["ram"]:
        c.mem[addr] = val

    _dll.x86_step(_cpu)

    fr = t["final"]["regs"]
    diffs = []
    for i, n in enumerate(REGS16):
        exp = fr.get(n, ir[n])
        if c.r[i] != exp:
            diffs.append(f"{n}: got {c.r[i]:04X} want {exp:04X}")
    for i, n in enumerate(SREGS):
        exp = fr.get(n, ir[n])
        if c.sr[i] != exp:
            diffs.append(f"{n}: got {c.sr[i]:04X} want {exp:04X}")
    exp = fr.get("ip", ir["ip"])
    if c.ip != exp:
        diffs.append(f"ip: got {c.ip:04X} want {exp:04X}")

    mask = flags_mask(t["bytes"])
    exp = fr.get("flags", ir["flags"])
    if (c.flags & mask) != (exp & mask):
        diffs.append(
            f"flags: got {c.flags:04X} want {exp:04X} (mask {mask:04X}, "
            f"diff bits {((c.flags ^ exp) & mask):04X})"
        )

    fram = t["final"].get("ram", [])
    faddrs = set()
    for addr, val in fram:
        faddrs.add(addr)
        if c.mem[addr] != val:
            diffs.append(f"mem[{addr:05X}]: got {c.mem[addr]:02X} want {val:02X}")
    for addr, val in init["ram"]:
        if addr not in faddrs and c.mem[addr] != val:
            diffs.append(
                f"mem[{addr:05X}]: got {c.mem[addr]:02X} want {val:02X} (clobbered)"
            )
    return diffs


def run_file(args):
    path, limit, nfails = args
    if _dll is None:
        _init_worker()
    name = os.path.basename(path)
    try:
        tests = json.loads(gzip.open(path).read())
    except Exception as ex:  # noqa: BLE001
        return (name, 0, 0, [f"LOAD ERROR: {ex}"])
    if limit:
        tests = tests[:limit]
    npass = 0
    fails = []
    for t in tests:
        diffs = run_test(t)
        if not diffs:
            npass += 1
        elif len(fails) < nfails:
            fails.append(
                f"  [{t['idx']}] {t['name']}  bytes={bytes(t['bytes']).hex(' ')}\n"
                + "".join(f"      {d}\n" for d in diffs)
            )
    return (name, len(tests), npass, fails)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--files", nargs="*", help="opcode file stems, e.g. 00 F6.4")
    ap.add_argument("--limit", type=int, default=0, help="max tests per file")
    ap.add_argument("--fails", type=int, default=1, help="failure details per file")
    ap.add_argument("-j", type=int, default=cpu_count(), help="worker processes")
    args = ap.parse_args()

    if args.files:
        paths = [os.path.join(VEC, f"{f}.json.gz") for f in args.files]
        missing = [p for p in paths if not os.path.exists(p)]
        if missing:
            sys.exit(f"missing vector files: {missing}")
    else:
        paths = sorted(glob.glob(os.path.join(VEC, "*.json.gz")))
    if not paths:
        sys.exit("no vector files found — run tests/vectors/fetch.sh first")

    work = [(p, args.limit, args.fails) for p in paths]
    results = []
    if args.j > 1 and len(paths) > 1:
        with Pool(args.j, initializer=_init_worker) as pool:
            for res in pool.imap_unordered(run_file, work):
                results.append(res)
                n, tot, ok = res[0], res[1], res[2]
                status = "ok" if ok == tot else f"FAIL {tot - ok}"
                print(f"{n:<18} {ok:>6}/{tot:<6} {status}", flush=True)
    else:
        _init_worker()
        for w in work:
            res = run_file(w)
            results.append(res)
            n, tot, ok = res[0], res[1], res[2]
            status = "ok" if ok == tot else f"FAIL {tot - ok}"
            print(f"{n:<18} {ok:>6}/{tot:<6} {status}", flush=True)

    results.sort()
    tot = sum(r[1] for r in results)
    ok = sum(r[2] for r in results)
    bad = [r for r in results if r[2] != r[1]]
    print(f"\ntotal: {ok}/{tot} passed, {len(bad)}/{len(results)} files with failures")
    for name, ntests, npass, fails in bad:
        print(f"\n=== {name} ({ntests - npass} failed) ===")
        for f in fails:
            print(f, end="")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
