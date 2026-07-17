#!/usr/bin/env python3
"""Compare C-core and 65816-core lockstep traces; report first divergence."""
import sys

FIELDS = ["AX", "CX", "DX", "BX", "SP", "BP", "SI", "DI",
          "ES", "CS", "SS", "DS", "IP", "FL"]

exp_path, got_path = sys.argv[1], sys.argv[2]
lst_path = sys.argv[3] if len(sys.argv) > 3 else None

exp = [l.split() for l in open(exp_path) if l.strip()]
got = [l.split() for l in open(got_path) if l.strip()]
lst = open(lst_path).read().splitlines() if lst_path else []

n = min(len(exp), len(got))
for i in range(n):
    if exp[i] != got[i]:
        print(f"DIVERGENCE at instruction #{i}")
        if i < len(lst):
            lo = max(0, i - 3)
            for k in range(lo, min(len(lst), i + 2)):
                mark = ">>" if k == i else "  "
                print(f"  {mark} {lst[k]}")
        diffs = [f"{FIELDS[j]}: c-core={exp[i][j]} 65816={got[i][j]}"
                 for j in range(14) if exp[i][j] != got[i][j]]
        print("  " + "; ".join(diffs))
        if i > 0:
            print("  state before: " +
                  " ".join(f"{FIELDS[j]}={exp[i-1][j]}" for j in range(14)))
        sys.exit(1)

if len(exp) != len(got):
    print(f"length mismatch: c-core {len(exp)} lines, 65816 {len(got)} lines "
          f"(first {n} match)")
    sys.exit(1)

print(f"PARITY OK: {n} instructions, all 14 registers identical at every step")
