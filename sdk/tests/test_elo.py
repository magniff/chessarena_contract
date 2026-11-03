"""On-chain Elo against an independent reference of the FIDE Rating Regulations (B.02): table 8.1.2 written as range
lower bounds (not the contract's byte table nor scripts/elo_table.py), the 400/2650 rule, K-factors and rounding
in Decimal arithmetic, played through real games on a live chain from random rating states."""
import bisect
import random
import subprocess
import sys
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

from web3 import Web3

from chessarena import RatingsUpdated
from chessarena.monitor import Monitor

ROOT = Path(__file__).resolve().parents[2]
RATINGS_SLOT = 7  # `ratings` mapping in ChessArena (pinned by test/Elo.t.sol test_layout)
STALEMATE = "e2e3 a7a5 d1h5 a8a6 h5a5 h7h5 h2h4 a6h6 a5c7 f7f6 c7d7 e8f7 d7b7 d8d3 b7b8 d3h7 b8c8 f7g6 c8e6".split()


# FIDE 8.1.2: first rating difference of each expected score .50, .51, ..., .99, 1.00
FIDE_LO = [0, 4, 11, 18, 26, 33, 40, 47, 54, 62, 69, 77, 84, 92, 99, 107, 114, 122, 130, 138, 146, 154, 163, 171,
           180, 189, 198, 207, 216, 226, 236, 246, 257, 268, 279, 291, 303, 316, 329, 345, 358, 375, 392, 412, 433,
           457, 485, 518, 560, 620, 736]


def expected(r, opp):
    """FIDE 8.1.2 and 8.3.1: a difference above 400 counts as 400 below 2650, in full from 2650."""
    d = abs(r - opp)
    if d > 400 and r < 2650:
        d = 400
    h = Decimal(49 + bisect.bisect_right(FIDE_LO, d)) / 100
    return h if r >= opp else 1 - h


def reference(r, games, peaked, score, opp):
    """FIDE update: change K*(S-E) rounded half away from zero; K 40 / 20 / 10; floor 100 (ours)."""
    e = expected(r, opp)
    k = 40 if games < 30 else (10 if peaked else 20)
    delta = k * (Decimal(str(score)) - e)
    step = int(abs(delta).quantize(Decimal(1), rounding=ROUND_HALF_UP))
    return max(100, r + step) if delta >= 0 else max(100, r - step)


def _set_rating(client, addr, rating, games, peaked):
    slot = Web3.keccak(bytes.fromhex(addr[2:].lower().rjust(64, "0")) + RATINGS_SLOT.to_bytes(32, "big"))
    value = rating | (games << 32) | (int(peaked) << 64)
    client.w3.provider.make_request("anvil_setStorageAt",
                                    [client.contract.address, "0x" + slot.hex().removeprefix("0x"),
                                     "0x" + value.to_bytes(32, "big").hex()])


def _play(a, b, outcome):
    """a is white. outcome: 1 white wins (black resigns), 0 black wins, 0.5 draw (stalemate)."""
    ga = a.create_game("0.001", colour="white")
    gb = b.join_game(ga.id)
    if outcome == 0.5:
        for i, uci in enumerate(STALEMATE):
            (ga if i % 2 == 0 else gb).move(uci)
    else:
        ga.move("e2e4")
        gb.move("e7e5")
        (gb if outcome == 1 else ga).resign()
    return ga


def test_expected_score_table_matches_the_formula():
    r = subprocess.run([sys.executable, str(ROOT / "scripts/elo_table.py"), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_new_players_and_the_event(make_client):
    a, b = make_client(), make_client()
    assert (a.rating().rating, a.rating().games, a.rating().k, a.rating().provisional) == (1500, 0, 40, True)
    g = _play(a, b, 1)
    assert (a.rating().rating, b.rating().rating) == (1520, 1480)
    ev = [e for e in a.events(g.id, from_block=0).poll() if isinstance(e, RatingsUpdated)]
    assert len(ev) == 1
    e = ev[0]
    assert (e.white, e.white_before, e.white_after) == (a.address, 1500, 1520)
    assert (e.black, e.black_before, e.black_after) == (b.address, 1500, 1480)


def test_matches_independent_reference_from_random_states(make_client):
    rng = random.Random(20261101)
    for trial in range(16):
        a, b = make_client(), make_client()
        states = []
        for c in (a, b):
            rating = rng.choice([rng.randint(100, 3000), rng.randint(100, 130), rng.randint(2380, 2420),
                                 rng.randint(2640, 2900)])
            games = rng.choice([rng.randint(1, 29), rng.randint(30, 500)])
            peaked = rng.random() < 0.3 and games >= 30
            _set_rating(a, c.address, rating, games, peaked)
            states.append((rating, games, peaked))
        outcome = 0.5 if trial % 4 == 3 else rng.choice([0, 1])
        _play(a, b, outcome)
        (rw, gw, pw), (rb, gb, pb) = states
        want_w = reference(rw, gw, pw, outcome, rb)
        want_b = reference(rb, gb, pb, 1 - outcome, rw)
        got_w, got_b = a.rating(), b.rating()
        assert (got_w.rating, got_b.rating) == (want_w, want_b), (states, outcome)
        assert (got_w.games, got_b.games) == (gw + 1, gb + 1)


def test_monitor_tracks_ratings(make_client):
    a, b = make_client(), make_client()
    mon = Monitor(make_client(), {a.address: "a", b.address: "b"}, from_block=a.w3.eth.block_number)
    assert mon.agents[a.address.lower()].rating == 1500
    _play(a, b, 0)  # black (b) wins
    mon.refresh()
    assert mon.agents[a.address.lower()].rating == 1480
    assert mon.agents[b.address.lower()].rating == 1520
    assert mon.agents[b.address.lower()].rated_games == 1
