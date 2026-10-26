#!/usr/bin/env python3
"""Reference model for tb_hdmi_encode.

Recomputes the TMDS words from the input sequence the testbench wrote out and
compares them against the words it captured.  The control, TERC4, video guard
and data guard words come from HDMI 1.4a sections 5.4.2, 5.4.3, 5.2.2.1 and
5.2.3.3.  A match means the encoder emits the specified symbol for those modes
and that the whole stream is unchanged from the earlier capture, which is the
property a pipelining change must not break.

One documented deviation keeps this from being a conformance check.  In the
balanced-disparity branch (section 5.4.4.1, the case where the accumulator is
zero or the two counts are equal) the module sends `q_m` uncomplemented when
`q_m[8]` is set and complemented when it is clear, with the accumulator delta
matched to whichever it sends.  That pairing is the inverse of the one a
transcription of Figure 5-7 gives, and both pairings keep the accumulator
tracking the true disparity of the emitted stream.  The file is byte-identical
to upstream hdl-util/hdmi, so this is upstream's convention rather than a
change made here, and it is recorded as an open question in
docs/integration-blocker.md.  This model reproduces the module's convention so
that the stream can be gated; it does not assert that the convention is
conformant.

Two module policies are mirrored because they are not in the coding equations:
the disparity accumulator resets whenever the channel is not in video mode, and
the channel's output register delays the selected word by an integer number of
pixels.  The checker discovers that delay by alignment instead of assuming it,
which is what lets a pipelined encoder be compared against a golden capture
taken from the earlier, unpipelined one.

Usage:
    tools/check_tmds.py [--dump PATH] [--golden PATH]

Exit 0 on an exact match, 1 otherwise.
"""
import argparse
import sys

# HDMI 1.4a section 5.4.2, control period coding, indexed by control_data.
CTRL_CODING = {
    0b00: 0b1101010100,
    0b01: 0b0010101011,
    0b10: 0b0101010100,
    0b11: 0b1010101011,
}

# HDMI 1.4a section 5.4.3, TERC4 coding, indexed by the four-bit symbol.
TERC4_CODING = {
    0x0: 0b1010011100, 0x1: 0b1001100011, 0x2: 0b1011100100, 0x3: 0b1011100010,
    0x4: 0b0101110001, 0x5: 0b0100011110, 0x6: 0b0110001110, 0x7: 0b0100111100,
    0x8: 0b1011001100, 0x9: 0b0100111001, 0xA: 0b0110011100, 0xB: 0b1011000110,
    0xC: 0b1010001110, 0xD: 0b1001110001, 0xE: 0b0101100011, 0xF: 0b1011000011,
}

# HDMI 1.4a section 5.2.2.1, video guard band, by channel.
VIDEO_GUARD = {0: 0b1011001100, 1: 0b0100110011, 2: 0b1011001100}

# HDMI 1.4a section 5.2.3.3: channels 1 and 2 carry the fixed code, channel 0
# carries the TERC4 code of the control word it is guarding, taken from the top
# of the TERC4 table (0xC through 0xF).
DATA_GUARD_CH12 = 0b0100110011
DATA_GUARD_CH0 = {0b00: 0b1010001110, 0b01: 0b1001110001,
                  0b10: 0b0101100011, 0b11: 0b1011000011}

MODE_CONTROL, MODE_VIDEO, MODE_VIDEO_GUARD, MODE_ISLAND, MODE_ISLAND_GUARD = range(5)


def video_word(d, acc):
    """HDMI 1.4a section 5.4.4.1 coding of one pixel; returns (q_out, acc_delta)."""
    n1d = bin(d & 0xFF).count("1")

    # q_m: the first bit is passed through, every later bit is the running XOR
    # of the input bits, complemented when the byte is majority zero.
    same = (n1d > 4) or (n1d == 4 and (d & 1) == 0)
    q_low = d & 1
    prev = d & 1
    for n in range(1, 8):
        cur = (prev ^ ((d >> n) & 1)) & 1
        if same:
            cur ^= 1
        q_low |= cur << n
        prev = cur
    q8 = 0 if same else 1

    n1q = bin(q_low).count("1")
    n0q = 8 - n1q

    if acc == 0 or n1q == n0q:
        # the module's pairing: q_m[8] set passes q_m through, clear complements it
        if q8 == 1:
            return ((0 << 9) | (1 << 8) | q_low, n1q - n0q)
        return ((1 << 9) | (0 << 8) | (~q_low & 0xFF), n0q - n1q)

    if (acc > 0 and n1q > n0q) or (acc < 0 and n1q < n0q):
        return ((1 << 9) | (q8 << 8) | (~q_low & 0xFF),
                (n0q - n1q) + (2 if q8 else 0))

    return ((0 << 9) | (q8 << 8) | q_low, (n1q - n0q) - (2 if q8 == 0 else 0))


def data_guard(cn, ctrl):
    return DATA_GUARD_CH12 if cn != 0 else DATA_GUARD_CH0[ctrl]


def encode(mode, vd, di, ctrl, cn, acc):
    """One channel's word for one cycle, with the accumulator it would leave."""
    if mode == MODE_VIDEO:
        word, delta = video_word(vd, acc)
        return word, acc + delta
    if mode == MODE_CONTROL:
        return CTRL_CODING[ctrl], 0
    if mode == MODE_VIDEO_GUARD:
        return VIDEO_GUARD[cn], 0
    if mode == MODE_ISLAND:
        return TERC4_CODING[di], 0
    if mode == MODE_ISLAND_GUARD:
        return data_guard(cn, ctrl), 0
    raise ValueError(f"mode {mode} is outside 0..4")


def read_dump(path):
    rows = []
    with open(path) as f:
        for line in f:
            f = line.split()
            if len(f) != 8:
                continue
            rows.append(tuple(int(v) for v in f))
    return rows


def model(rows):
    """The three expected words for every row, accumulator advanced per cycle."""
    accs = [0, 0, 0]           # one disparity accumulator per channel
    exp = []
    for _cyc, mode, vd, di, ctrl, _a, _b, _c in rows:
        words = []
        for cn in range(3):
            word, accs[cn] = encode(mode, vd, di, ctrl, cn, accs[cn])
            if not -16 <= accs[cn] <= 15:
                raise ValueError(f"channel {cn} accumulator left its five-bit "
                                 f"signed range at cycle {_cyc}: {accs[cn]}")
            words.append(word)
        exp.append(tuple(words))
    return exp


def align(rows, exp):
    """Find the output delay whose encoding matches the dump; returns (latency, bad)."""
    best = None
    for latency in range(0, 5):
        bad = 0
        for i in range(latency, len(rows)):
            if tuple(rows[i][5:8]) != exp[i - latency]:
                bad += 1
        if bad == 0:
            return latency, 0
        if best is None or bad < best[1]:
            best = (latency, bad)
    return best


def report(name, rows, exp):
    latency, bad = align(rows, exp)
    checked = max(0, len(rows) - latency)
    if bad:
        first = next(i for i in range(latency, len(rows))
                     if tuple(rows[i][5:8]) != exp[i - latency])
        print(f"  {name}: {bad} of {checked} rows differ at best delay {latency}; "
              f"first at cycle {rows[first][0]}: got "
              f"{rows[first][5:8]} want {exp[first - latency]}")
        return None
    print(f"  {name}: {checked} rows match the model at an output delay of {latency}")
    return latency


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", default="build/sim/tmds_dump.txt")
    ap.add_argument("--golden", default=None,
                    help="earlier capture to compare against, latency compensated")
    args = ap.parse_args()

    try:
        rows = read_dump(args.dump)
    except OSError as e:
        print(f"TMDS CHECK: FAIL (cannot read {args.dump}: {e})")
        return 1
    if not rows:
        print(f"TMDS CHECK: FAIL ({args.dump} is empty)")
        return 1

    exp = model(rows)
    lat = report("dump", rows, exp)
    ok = lat is not None

    if args.golden:
        try:
            gold = read_dump(args.golden)
        except OSError as e:
            print(f"  golden: cannot read {args.golden}: {e}")
            ok = False
            gold = None
        if gold is not None:
            if [(r[1], r[2], r[3], r[4]) for r in gold] != \
               [(r[1], r[2], r[3], r[4]) for r in rows]:
                print("  golden: input sequences differ, so no comparison is meaningful")
                ok = False
            else:
                gexp = model(gold)
                glat = report("golden", gold, gexp)
                if glat is None:
                    ok = False
                else:
                    # compare the two streams where each carries the same input
                    n = min(len(rows) - lat, len(gold) - glat)
                    differ = [i for i in range(n)
                              if tuple(rows[i + lat][5:8]) != tuple(gold[i + glat][5:8])]
                    if differ:
                        i = differ[0]
                        print(f"  golden: {len(differ)} of {n} rows differ from the "
                              f"earlier capture; first at cycle {i}: got "
                              f"{rows[i + lat][5:8]} want {gold[i + glat][5:8]}")
                        ok = False
                    else:
                        print(f"  golden: {n} rows identical to the earlier capture")

    print("TMDS CHECK:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
