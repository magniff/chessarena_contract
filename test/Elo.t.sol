// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChessArena} from "../src/ChessArena.sol";
import {FenLib} from "./FenLib.sol";
import {ChessArenaHarness} from "./harness/ChessArenaHarness.sol";

/// Refuses payouts: its game must still end, and still be rated.
contract RefusingWinner {
    function join(ChessArena g, uint256 id) external payable {
        g.joinGame{value: msg.value}(id);
    }

    function move(ChessArena g, uint256 id, uint16 m) external {
        g.makeMove(id, m);
    }

    receive() external payable {
        revert();
    }
}

/// On-chain Elo by the FIDE Rating Regulations (B.02). Known answers were computed independently (Python Decimal
/// from the FIDE table 8.1.2, the 400/2650 rule and FIDE K-factors); the properties are fuzzed over arbitrary
/// stored rating states, including ones no real history can reach.
contract EloTest is Test {
    ChessArena game;
    address alice = makeAddr("alice"); // white in every game here
    address bob = makeAddr("bob");
    uint256 constant RATINGS_SLOT = 7; // `ratings` mapping (pinned by test_layout)

    event RatingsUpdated(
        uint256 indexed gameId,
        address indexed white,
        uint256 whiteBefore,
        uint256 whiteAfter,
        address indexed black,
        uint256 blackBefore,
        uint256 blackAfter
    );

    function setUp() public {
        game = new ChessArena();
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _setRating(address who, uint256 rating, uint256 games, bool peaked) internal {
        bytes32 slot = keccak256(abi.encode(who, RATINGS_SLOT));
        vm.store(address(game), slot, bytes32(rating | (games << 32) | (uint256(peaked ? 1 : 0) << 64)));
    }

    function _rating(address who) internal view returns (uint256 r) {
        (r,,) = game.ratingOf(who);
    }

    function _games(address who) internal view returns (uint256 n) {
        (, n,) = game.ratingOf(who);
    }

    /// A game with `plies` moves played (1..4 of a quiet opening), alice white.
    function _gameWithPlies(uint256 plies) internal returns (uint256 id) {
        vm.prank(alice);
        id = game.createGame{value: 0.01 ether}(300, 2, true);
        vm.prank(bob);
        game.joinGame{value: 0.01 ether}(id);
        string[4] memory line = ["e2e4", "e7e5", "g1f3", "b8c6"];
        for (uint256 i; i < plies; ++i) {
            vm.prank(i % 2 == 0 ? alice : bob);
            game.makeMove(id, FenLib.mv(line[i]));
        }
    }

    /// Ends a 2-ply game: 1 = white wins, 0 = black wins (by resignation), 2 = draw (19-ply stalemate).
    function _finish(uint256 outcome) internal returns (uint256 id) {
        if (outcome == 2) {
            vm.prank(alice);
            id = game.createGame{value: 0.01 ether}(300, 2, true);
            vm.prank(bob);
            game.joinGame{value: 0.01 ether}(id);
            string[19] memory line = ["e2e3", "a7a5", "d1h5", "a8a6", "h5a5", "h7h5", "h2h4", "a6h6", "a5c7",
                "f7f6", "c7d7", "e8f7", "d7b7", "d8d3", "b7b8", "d3h7", "b8c8", "f7g6", "c8e6"];
            for (uint256 i; i < line.length; ++i) {
                vm.prank(i % 2 == 0 ? alice : bob);
                game.makeMove(id, FenLib.mv(line[i]));
            }
            assert(game.getGame(id).reason == ChessArena.Reason.Stalemate);
        } else {
            id = _gameWithPlies(2);
            vm.prank(outcome == 1 ? bob : alice);
            game.resign(id);
        }
    }

    // ------------------------------------------------------------------ layout and defaults

    function test_layout() public {
        _finish(1);
        bytes32 raw = vm.load(address(game), keccak256(abi.encode(alice, RATINGS_SLOT)));
        assertEq(uint256(raw) & type(uint32).max, 1520);
        assertEq((uint256(raw) >> 32) & type(uint32).max, 1);
    }

    function test_unratedPlayerStartsAt1500WithK40() public {
        (uint256 r, uint256 n, uint256 k) = game.ratingOf(makeAddr("nobody"));
        assertEq(r, 1500);
        assertEq(n, 0);
        assertEq(k, 40);
    }

    // ------------------------------------------------------------------ known answers (independent reference)

    function _case(uint256 rw, uint256 gw, bool pw, uint256 rb, uint256 gb, bool pb, uint256 outcome, uint256 ew, uint256 eb)
        internal
    {
        _setRating(alice, rw, gw, pw);
        _setRating(bob, rb, gb, pb);
        _finish(outcome);
        assertEq(_rating(alice), ew, "white");
        assertEq(_rating(bob), eb, "black");
        assertEq(_games(alice), gw + 1);
        assertEq(_games(bob), gb + 1);
    }

    function test_newPlayers_whiteWins() public {
        uint256 id = _gameWithPlies(2);
        vm.expectEmit(true, true, true, true);
        emit RatingsUpdated(id, alice, 1500, 1520, bob, 1500, 1480);
        vm.prank(bob);
        game.resign(id);
        assertEq(_rating(alice), 1520);
        assertEq(_rating(bob), 1480);
    }

    function test_newPlayers_draw() public {
        _finish(2);
        assertEq(_rating(alice), 1500);
        assertEq(_rating(bob), 1500);
        assertEq(_games(alice), 1);
    }

    function test_known_favouriteWins_K20() public {
        _case(1900, 30, false, 1500, 30, false, 1, 1902, 1498);
    }

    function test_known_upset_K20() public {
        _case(1900, 30, false, 1500, 30, false, 0, 1882, 1518);
    }

    function test_known_differenceCappedAt400() public {
        _case(2500, 30, false, 1500, 30, false, 0, 2482, 1518);
    }

    function test_known_mixedK_draw() public {
        _case(1600, 5, false, 1500, 40, false, 2, 1594, 1503);
    }

    function test_known_peakedPlayerUsesK10() public {
        _case(2350, 50, true, 2350, 50, false, 0, 2345, 2360);
    }

    function test_known_fideTableNotLogistic() public {
        // D = 53: FIDE expects .57 (+8.6 -> +9); the logistic curve's .5761 would give +8
        _case(1553, 30, false, 1500, 30, false, 1, 1562, 1491);
    }

    function test_known_halfPointRoundsAwayFromZero() public {
        // D = 35, E = .55 / .45, K 10: changes of -0.5 and +0.5 round to -1 and +1
        _case(2435, 50, true, 2400, 50, true, 2, 2434, 2401);
    }

    function test_known_2650_fullDifferenceForTheTopPlayer() public {
        // D = 500: the 2700 player expects .96 (no cap at 2650+), the 2200 player .08 (capped at 400)
        _case(2700, 50, true, 2200, 50, false, 1, 2700, 2198);
        _case(2700, 50, true, 2200, 50, false, 0, 2690, 2218);
    }

    function test_known_2650_beyond735ExpectsEverything() public {
        // D = 800: the 2700 player expects 1.00, so a win gains nothing and a draw costs K/2
        _case(2700, 50, true, 1900, 50, false, 1, 2700, 1898);
        _case(2700, 50, true, 1900, 50, false, 2, 2695, 1908);
    }

    function test_known_floor() public {
        _case(110, 1, false, 110, 1, false, 0, 100, 130); // games > 0: a stored rating is only in use once rated
    }

    function test_kFactorSchedule() public {
        _setRating(alice, 1500, 29, false);
        (,, uint256 k) = game.ratingOf(alice);
        assertEq(k, 40);
        _setRating(alice, 1500, 30, false);
        (,, k) = game.ratingOf(alice);
        assertEq(k, 20);
        _setRating(alice, 2390, 40, false);
        _setRating(bob, 2390, 40, false);
        _finish(1); // 2390 -> 2400
        assertEq(_rating(alice), 2400);
        (,, k) = game.ratingOf(alice);
        assertEq(k, 10, "reaching 2400 drops K to 10");
        _finish(0);
        _finish(0);
        assertLt(_rating(alice), 2400);
        (,, k) = game.ratingOf(alice);
        assertEq(k, 10, "and it stays 10 after dropping below");
    }

    // ------------------------------------------------------------------ which games are rated

    function test_unrated_whenASideNeverMoved() public {
        for (uint256 plies; plies < 2; ++plies) {
            uint256 id = _gameWithPlies(plies);
            vm.prank(bob);
            game.resign(id);
            assertEq(uint8(game.getGame(id).status), uint8(ChessArena.Status.Finished));
            assertEq(_games(alice), 0, "no rating for a game a side never moved in");
            assertEq(_games(bob), 0);
        }
        uint256 id2 = _gameWithPlies(1);
        vm.warp(block.timestamp + 400); // black flagged without moving: a forfeit, unrated
        game.claimTimeout(id2);
        assertEq(_games(alice), 0);
    }

    function test_rated_everyEnding() public {
        _finish(1); // resignation
        assertEq(_games(alice), 1);
        uint256 id = _gameWithPlies(2);
        vm.warp(block.timestamp + 303); // white (300 s + 2 s increment) flagged after both moved: rated
        game.claimTimeout(id);
        assertEq(_games(alice), 2);
        // checkmate (fool's mate, alice white is mated)
        vm.prank(alice);
        id = game.createGame{value: 0.01 ether}(300, 2, true);
        vm.prank(bob);
        game.joinGame{value: 0.01 ether}(id);
        string[4] memory line = ["f2f3", "e7e5", "g2g4", "d8h4"];
        for (uint256 i; i < 4; ++i) {
            vm.prank(i % 2 == 0 ? alice : bob);
            game.makeMove(id, FenLib.mv(line[i]));
        }
        assertEq(_games(alice), 3);
        _finish(2); // stalemate
        assertEq(_games(alice), 4);
    }

    function test_refusingWinnerIsStillRated() public {
        RefusingWinner r = new RefusingWinner();
        vm.deal(address(r), 1 ether);
        vm.prank(alice);
        uint256 id = game.createGame{value: 0.01 ether}(300, 2, true);
        r.join{value: 0.01 ether}(game, id);
        vm.prank(alice);
        game.makeMove(id, FenLib.mv("e2e4"));
        r.move(game, id, FenLib.mv("e7e5"));
        vm.prank(alice);
        game.resign(id);
        assertEq(_rating(address(r)), 1520);
        assertGt(game.pending(address(r)), 0);
    }

    // ------------------------------------------------------------------ properties over any stored state

    /// Any stored ratings (including unreachable extremes), any K state, any result: the game still ends, each
    /// change is at most K, the winner never loses points and the loser never gains, the floor and the uint32
    /// limit hold, and each player's game count goes up by one (saturating).
    function testFuzz_updateIsSafe(uint32 rw, uint32 gw, bool pw, uint32 rb, uint32 gb, bool pb, uint8 o) public {
        rw = uint32(bound(rw, 100, type(uint32).max));
        rb = uint32(bound(rb, 100, type(uint32).max));
        gw = uint32(bound(gw, 1, type(uint32).max)); // games > 0, so the stored rating is the one in use
        gb = uint32(bound(gb, 1, type(uint32).max));
        uint256 outcome = o % 3;
        _setRating(alice, rw, gw, pw);
        _setRating(bob, rb, gb, pb);
        (,, uint256 kw) = game.ratingOf(alice);
        (,, uint256 kb) = game.ratingOf(bob);
        uint256 id = _finish(outcome);
        assertEq(uint8(game.getGame(id).status), uint8(ChessArena.Status.Finished));

        uint256 nw = _rating(alice);
        uint256 nb = _rating(bob);
        assertLe(nw > rw ? nw - rw : rw - nw, kw);
        assertLe(nb > rb ? nb - rb : rb - nb, kb);
        assertGe(nw, 100);
        assertGe(nb, 100);
        if (outcome == 1) {
            assertGe(nw, rw);
            assertLe(nb, rb);
        } else if (outcome == 0) {
            assertLe(nw, rw);
            assertGe(nb, rb);
        } else if (rw > rb) {
            assertLe(nw, rw); // a draw never helps the higher-rated side
            assertGe(nb, rb);
        }
        assertEq(_games(alice), gw == type(uint32).max ? gw : gw + 1);
        assertEq(_games(bob), gb == type(uint32).max ? gb : gb + 1);
    }

    /// Equal K, both below 2650 (so the same capped difference applies to both) and nowhere near the floor: the
    /// update is zero-sum up to rounding (each side rounds its own change, so the two can differ by one point).
    /// (At 2650+ FIDE uses the full difference for the top player only, so the sum may differ, as in FIDE.)
    function testFuzz_zeroSumWithEqualK(uint16 rw, uint16 rb, uint8 o) public {
        rw = uint16(bound(rw, 1000, 2649));
        rb = uint16(bound(rb, 1000, 2649));
        _setRating(alice, rw, 100, false);
        _setRating(bob, rb, 100, false);
        _finish(o % 3);
        int256 dw = int256(_rating(alice)) - int256(uint256(rw));
        int256 db = int256(_rating(bob)) - int256(uint256(rb));
        assertLe(dw + db, 1);
        assertGe(dw + db, -1);
    }

    /// FIDE table 8.1.2 as published: the first D of each H = .51 .. .99, and 736 (H = 1.00). Written here as the
    /// lower ends of the ranges, independently of the contract's byte table and of scripts/elo_table.py.
    uint16[50] FIDE_LO = [4, 11, 18, 26, 33, 40, 47, 54, 62, 69, 77, 84, 92, 99, 107, 114, 122, 130, 138, 146, 154, 163,
        171, 180, 189, 198, 207, 216, 226, 236, 246, 257, 268, 279, 291, 303, 316, 329, 345, 358, 375, 392, 412, 433,
        457, 485, 518, 560, 620, 736];

    function _fide(uint256 d) internal view returns (uint256 h) {
        h = 50;
        for (uint256 i; i < 50 && d >= FIDE_LO[i]; ++i) ++h;
    }

    /// The expected score depends only on the difference and on which side of 2650 the player is, so every
    /// difference from -1000 to +1000 around ratings on both sides of 2650 covers every pairing. Each value
    /// equals the FIDE table, with the difference capped at 400 below 2650 and in full from 2650.
    function test_expectedScore_everyDifference() public {
        ChessArenaHarness h = new ChessArenaHarness();
        uint256[4] memory bases = [uint256(1500), 2649, 2650, 4000];
        for (uint256 bi; bi < 4; ++bi) {
            uint256 base = bases[bi];
            for (uint256 i; i <= 2000; ++i) {
                uint256 opp = base + 1000 - i; // `base` is i - 1000 points above `opp`
                uint256 d = i >= 1000 ? i - 1000 : 1000 - i;
                if (base < 2650 && d > 400) d = 400;
                uint256 want = i >= 1000 ? _fide(d) : 100 - _fide(d);
                assertEq(h.expectedScore(base, opp), want);
            }
        }
        assertEq(h.expectedScore(type(uint32).max, 100), 100); // extremes too
        assertEq(h.expectedScore(100, type(uint32).max), 8);
        assertEq(h.expectedScore(2649, 100), 92);
        assertEq(h.kFactor(29, true), 40);
        assertEq(h.kFactor(30, false), 20);
        assertEq(h.kFactor(30, true), 10);
    }

    function test_gas_ratedGameEnd() public {
        uint256 id = _gameWithPlies(2);
        vm.prank(bob);
        uint256 g0 = gasleft();
        game.resign(id);
        emit log_named_uint("resign incl. first rating of two new players", g0 - gasleft());
        id = _gameWithPlies(2);
        vm.prank(bob);
        g0 = gasleft();
        game.resign(id);
        emit log_named_uint("resign incl. rating update of two rated players (warm)", g0 - gasleft());
    }
}
