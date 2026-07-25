#!/usr/bin/env python3
"""Generate the CC0 demo tune: DEMO.MID (an original sequencing of
Beethoven's "Ode to Joy", 1824, public domain) and DEMO.SNM (its
MIDPLAY packet-stream conversion, a port of MIDCONV.PAS).

  mkdemo.py <outdir>     writes <outdir>/DEMO.MID + <outdir>/DEMO.SNM
"""
import os
import struct
import sys

# ---- generate the CC0 demo: "Ode to Joy" (Beethoven, 1824, public domain) ----
def gen_demo_mid():
    """Return a format-0 Standard MIDI File of the Ode to Joy melody."""
    DIV = 480
    Q = DIV                      # quarter note
    H = DIV * 2                  # half note
    DQ = DIV * 3 // 2            # dotted quarter
    E = DIV // 2                 # eighth
    # (semitone, duration) - E4=64 F4=65 G4=67 A4=69 D4=62 C4=60
    melody = [
        (64, Q), (64, Q), (65, Q), (67, Q),
        (67, Q), (65, Q), (64, Q), (62, Q),
        (60, Q), (60, Q), (62, Q), (64, Q),
        (64, DQ), (62, E), (62, H),
        (64, Q), (64, Q), (65, Q), (67, Q),
        (67, Q), (65, Q), (64, Q), (62, Q),
        (60, Q), (60, Q), (62, Q), (64, Q),
        (62, DQ), (60, E), (60, H),
    ]

    def vlq(n):
        out = bytearray([n & 0x7F])
        n >>= 7
        while n:
            out.insert(0, (n & 0x7F) | 0x80)
            n >>= 7
        return bytes(out)

    trk = bytearray()
    trk += vlq(0) + bytes([0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20])   # 500000 us/qn
    for note, dur in melody:
        trk += vlq(0) + bytes([0x90, note, 100])    # note on
        trk += vlq(dur) + bytes([0x80, note, 0])    # note off
    trk += vlq(0) + bytes([0xFF, 0x2F, 0x00])       # end of track

    hdr = b"MThd" + struct.pack(">IHHH", 6, 0, 1, DIV)
    return hdr + b"MTrk" + struct.pack(">I", len(trk)) + bytes(trk)


def mid_to_snm(mid):
    """Port of MIDCONV.PAS: format-0 SMF -> .SNM 4-byte packet stream."""
    p = [0]

    def nb():
        b = mid[p[0]] if p[0] < len(mid) else 0xFF
        p[0] += 1
        return b

    def readvar():
        v = 0
        for _ in range(4):
            b = nb()
            v = v * 128 + (b & 0x7F)
            if b < 0x80:
                break
        return v

    # header
    for _ in range(8):
        nb()                                    # MThd + length
    nb(); nb()                                  # format (0)
    nb(); nb()                                  # ntrks
    division = nb() * 256 + nb()
    for _ in range(8):
        nb()                                    # MTrk + length

    out = bytearray()
    npk = [0]

    def sendpk(d, s, d1, d2):
        out.extend([d & 0xFF, s & 0xFF, d1 & 0xFF, d2 & 0xFF])
        npk[0] += 1

    scale = [500000.0 / (division * 16667.0)]
    pending = [0]
    carry = [0.0]

    def emit(s, d1, d2):
        while pending[0] > 255:
            sendpk(255, 0, 0, 0)
            pending[0] -= 255
        sendpk(pending[0], s, d1, d2)
        pending[0] = 0

    def adddelta(ticks):
        fd = ticks * scale[0] + carry[0]
        pending[0] += int(fd)
        carry[0] = fd - int(fd)

    rstatus = 0
    while True:
        adddelta(readvar())
        if p[0] > len(mid):
            break
        b = nb()
        if b >= 0x80:
            if b < 0xF0:
                rstatus = b
                b = nb()
            elif b == 0xFF:
                mt = nb()
                ln = readvar()
                if mt == 0x2F:
                    break
                if mt == 0x51:
                    tmp = 0
                    for _ in range(ln):
                        tmp = tmp * 256 + nb()
                    scale[0] = tmp / (division * 16667.0)
                else:
                    for _ in range(ln):
                        nb()
                rstatus = 0
                continue
            else:
                ln = readvar()
                for _ in range(ln):
                    nb()
                rstatus = 0
                continue
        if rstatus >= 0x80:
            hi = rstatus >> 4
            if hi in (0x8, 0x9, 0xA, 0xB, 0xE):
                d1 = b
                b = nb()
                if hi in (0x8, 0x9):
                    emit(rstatus, d1, b)
            elif hi in (0xC, 0xD):
                if hi == 0xC:
                    emit(rstatus, b, 0)

    sendpk(0, 0xFF, 0, 0)                        # all notes off
    while (len(out) // 4) % 32:                  # pad to a 128-byte block
        sendpk(0, 0, 0, 0)
    return bytes(out)


if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    mid = gen_demo_mid()
    snm = mid_to_snm(mid)
    open(os.path.join(out, "DEMO.MID"), "wb").write(mid)
    open(os.path.join(out, "DEMO.SNM"), "wb").write(snm)
    print(f"DEMO.MID {len(mid)}B / DEMO.SNM {len(snm)}B")
