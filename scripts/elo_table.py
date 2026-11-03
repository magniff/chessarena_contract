"""Expected-score table for the on-chain Elo update: FIDE Rating Regulations (Handbook B.02), table 8.1.2.

    python scripts/elo_table.py           # print the Solidity hex literal
    python scripts/elo_table.py --check   # verify the constant in src/ChessArena.sol against the FIDE table

FIDE gives, for ranges of the rating difference D, the expected score H of the higher-rated player in hundredths
(the lower-rated player expects L = 1 - H). The contract stores one byte per D = 0..735, H x 100; beyond 735
H is 1.00. ROWS below is the FIDE table as published (upper end of each D range, H).

--check also guards the transcription: FIDE's table is Elo's normal curve, H = Phi(D / (2000/7)) rounded to two
decimals, and every D must agree with that curve except the handful of points where FIDE's published table
itself departs from it (KNOWN_DEPARTURES, each within 0.08 of a rounding boundary or a long-standing quirk of the
official table). A mistyped row shows up as a new departure.
"""
import re
import sys
from math import erf, floor, sqrt
from pathlib import Path

# (last D of the range, H x 100), FIDE B.02 8.1.2. D above 735: H = 100.
ROWS = [
    (3, 50), (10, 51), (17, 52), (25, 53), (32, 54), (39, 55), (46, 56), (53, 57), (61, 58), (68, 59),
    (76, 60), (83, 61), (91, 62), (98, 63), (106, 64), (113, 65), (121, 66), (129, 67), (137, 68), (145, 69),
    (153, 70), (162, 71), (170, 72), (179, 73), (188, 74), (197, 75), (206, 76), (215, 77), (225, 78), (235, 79),
    (245, 80), (256, 81), (267, 82), (278, 83), (290, 84), (302, 85), (315, 86), (328, 87), (344, 88), (357, 89),
    (374, 90), (391, 91), (411, 92), (432, 93), (456, 94), (484, 95), (517, 96), (559, 97), (619, 98), (735, 99),
]
MAX_D = ROWS[-1][0]
KNOWN_DEPARTURES = {54, 343, 344, 358, 392, 620}


def fide(d: int) -> int:
    """H x 100 for a rating difference d >= 0, straight from ROWS."""
    for hi, h in ROWS:
        if d <= hi:
            return h
    return 100


def normal_curve(d: int) -> int:
    return min(100, floor(50 * (1 + erf(d / (2000 / 7) / sqrt(2))) + 0.5))


TABLE = [fide(d) for d in range(MAX_D + 1)]
HEX = "".join(f"{v:02x}" for v in TABLE)


def check() -> None:
    hs = [h for _, h in ROWS]
    assert hs == list(range(50, 100)), "one row per hundredth, .50 to .99"
    assert all(a[0] < b[0] for a, b in zip(ROWS, ROWS[1:])), "ranges increasing"
    departures = {d for d in range(MAX_D + 100) if fide(d) != normal_curve(d)}
    assert departures == KNOWN_DEPARTURES, f"transcription differs from the curve at {sorted(departures)}"
    src = (Path(__file__).resolve().parents[1] / "src/ChessArena.sol").read_text()
    m = re.search(r'EXPECTED_SCORE\s*=\s*hex"([0-9a-f]+)"', src)
    if not m or m.group(1) != HEX:
        sys.exit("EXPECTED_SCORE in src/ChessArena.sol does not match the FIDE table")
    print(f"EXPECTED_SCORE matches FIDE table 8.1.2 ({len(TABLE)} entries, D 0..{MAX_D}, H .{TABLE[0]}..{TABLE[-1]})")


if __name__ == "__main__":
    if "--check" in sys.argv:
        check()
    else:
        print(HEX)
