// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChessArena} from "../../src/ChessArena.sol";
import {FenLib} from "../FenLib.sol";
import {ChessArenaHarness} from "../harness/ChessArenaHarness.sol";

/// Symbolic proofs (Halmos) of the money and clock arithmetic: every stake (all of uint96), every clock setting,
/// every timing, both seat assignments. The chess itself runs on concrete moves, so paths stay few. `forge test`
/// skips these (check_ prefix); run with scripts/prove.sh.
contract ContractProofs is Test {
    ChessArena game;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);
    address fee;
    uint256 constant T0 = 1_700_000_000;
    uint256 constant MIN_STAKE = 0.0001 ether;

    ChessArenaHarness ratingHarness;

    function setUp() public {
        ratingHarness = new ChessArenaHarness();
        game = new ChessArena();
        fee = game.FEE_RECIPIENT();
        vm.warp(T0);
    }

    function _start(uint96 stake, bool aliceWhite, uint32 base, uint32 inc) internal returns (uint256 id) {
        vm.deal(ALICE, stake);
        vm.deal(BOB, stake);
        vm.prank(ALICE);
        id = game.createGame{value: stake}(base, inc, aliceWhite);
        vm.prank(BOB);
        game.joinGame{value: stake}(id);
    }

    function _fee(uint96 stake) internal pure returns (uint256) {
        return uint256(stake) * 2 * 250 / 10_000;
    }

    // ------------------------------------------------------------------ payouts

    /// Either player resigns, from either seat: the other gets the pot minus the fee, the fee recipient gets the
    /// fee, the loser gets nothing, the contract keeps nothing, and the result names the right colour.
    function check_resignationPaysExactly(uint96 stake, bool aliceWhite, bool aliceResigns) public {
        vm.assume(stake >= MIN_STAKE);
        uint256 id = _start(stake, aliceWhite, 300, 2);
        vm.prank(aliceResigns ? ALICE : BOB);
        game.resign(id);

        address winner = aliceResigns ? BOB : ALICE;
        address loser = aliceResigns ? ALICE : BOB;
        assert(winner.balance == uint256(stake) * 2 - _fee(stake));
        assert(loser.balance == 0);
        assert(fee.balance == _fee(stake));
        assert(address(game).balance == 0);
        bool whiteWon = (winner == ALICE) == aliceWhite;
        ChessArena.GameView memory v = game.getGame(id);
        assert(v.result == (whiteWon ? ChessArena.Result.WhiteWins : ChessArena.Result.BlackWins));
    }

    /// A draw splits the pot exactly: equal halves, the fee plus any odd wei to the fee recipient, nothing
    /// created or lost. Reached through a real 19-ply stalemate (Loyd), so the real settlement path runs.
    function check_drawSplitsExactly(uint96 stake, bool aliceWhite) public {
        vm.assume(stake >= MIN_STAKE);
        uint256 id = _start(stake, aliceWhite, 300, 2);
        string[19] memory line = ["e2e3", "a7a5", "d1h5", "a8a6", "h5a5", "h7h5", "h2h4", "a6h6", "a5c7", "f7f6",
            "c7d7", "e8f7", "d7b7", "d8d3", "b7b8", "d3h7", "b8c8", "f7g6", "c8e6"];
        address white = aliceWhite ? ALICE : BOB;
        address black = aliceWhite ? BOB : ALICE;
        for (uint256 i; i < line.length; ++i) {
            vm.prank(i % 2 == 0 ? white : black);
            game.makeMove(id, FenLib.mv(line[i]));
        }
        ChessArena.GameView memory v = game.getGame(id);
        assert(v.result == ChessArena.Result.Draw && v.reason == ChessArena.Reason.Stalemate);

        uint256 pot = uint256(stake) * 2;
        uint256 net = pot - _fee(stake);
        assert(ALICE.balance == net / 2);
        assert(BOB.balance == net / 2);
        assert(fee.balance == _fee(stake) + net % 2);
        assert(ALICE.balance + BOB.balance + fee.balance == pot);
        assert(address(game).balance == 0);
    }

    // ------------------------------------------------------------------ clock

    /// Anyone may flag the side to move exactly when its time is up, never a second earlier. Every base time,
    /// increment, delay and seat assignment. (Split from the payout below to keep each solver query small; the
    /// settlement code does not depend on the timing, only on the result.)
    function check_flagFallTimingIsExact(uint32 base, uint32 inc, uint32 dt, bool aliceWhite) public {
        vm.assume(base >= 30 && base <= 1 days && inc <= 10 minutes);
        uint256 id = _start(uint96(MIN_STAKE), aliceWhite, base, inc);
        vm.warp(T0 + dt);
        vm.prank(CAROL);
        try game.claimTimeout(id) {
            assert(dt > base); // white (to move) had `base` seconds
            ChessArena.GameView memory v = game.getGame(id);
            assert(v.result == ChessArena.Result.BlackWins && v.reason == ChessArena.Reason.Timeout);
        } catch (bytes memory err) {
            assert(dt <= base);
            assert(bytes4(err) == ChessArena.NotTimedOut.selector);
            assert(game.getGame(id).status == ChessArena.Status.Active);
        }
    }

    /// A flagged player's opponent is paid exactly, for every stake and seat; the caller who flagged gets nothing.
    function check_flagFallPaysExactly(uint96 stake, bool aliceWhite) public {
        vm.assume(stake >= MIN_STAKE);
        uint256 id = _start(stake, aliceWhite, 300, 2);
        vm.warp(T0 + 301);
        vm.prank(CAROL);
        game.claimTimeout(id);
        address black = aliceWhite ? BOB : ALICE;
        address white = aliceWhite ? ALICE : BOB;
        assert(black.balance == uint256(stake) * 2 - _fee(stake));
        assert(white.balance == 0);
        assert(fee.balance == _fee(stake));
        assert(CAROL.balance == 0);
        assert(address(game).balance == 0);
    }

    /// A move is accepted iff it arrives within the mover's time; the clock then charges exactly the elapsed
    /// time, adds the increment, caps at one day, and leaves the opponent's clock alone. Two moves, so both
    /// colours' clocks are covered.
    function check_moveClockIsExact(uint32 base, uint32 inc, uint32 dt1, uint32 dt2) public {
        vm.assume(base >= 30 && base <= 1 days && inc <= 10 minutes);
        vm.assume(dt1 <= base); // white moves in time (the late case is the next proof)
        uint256 id = _start(uint96(MIN_STAKE), true, base, inc);

        vm.warp(T0 + dt1);
        vm.prank(ALICE);
        game.makeMove(id, FenLib.mv("e2e4"));
        ChessArena.GameView memory v = game.getGame(id);
        uint256 w = uint256(base) - dt1 + inc;
        if (w > 1 days) w = 1 days;
        assert(v.whiteTime == w);
        assert(v.blackTime == base);
        assert(v.lastMoveAt == T0 + dt1);
        assert(!v.whiteToMove);
        assert(v.deadline == T0 + dt1 + base);

        vm.warp(T0 + uint256(dt1) + dt2);
        vm.prank(BOB);
        try game.makeMove(id, FenLib.mv("e7e5")) {
            assert(dt2 <= base);
            v = game.getGame(id);
            uint256 b = uint256(base) - dt2 + inc;
            if (b > 1 days) b = 1 days;
            assert(v.blackTime == b);
            assert(v.whiteTime == w);
            assert(v.deadline == T0 + uint256(dt1) + dt2 + w);
        } catch (bytes memory err) {
            assert(dt2 > base);
            assert(bytes4(err) == ChessArena.TurnTimedOut.selector);
        }
    }

    function check_lateMoveIsRefused(uint32 base, uint32 dt) public {
        vm.assume(base >= 30 && base <= 1 days && dt > base);
        uint256 id = _start(uint96(MIN_STAKE), true, base, 0);
        vm.warp(T0 + dt);
        vm.prank(ALICE);
        try game.makeMove(id, FenLib.mv("e2e4")) {
            assert(false);
        } catch (bytes memory err) {
            assert(bytes4(err) == ChessArena.TurnTimedOut.selector);
        }
    }

    /// Nobody but the side to move can move, whoever they are.
    function check_onlySideToMoveCanMove(address caller, bool aliceWhite) public {
        uint256 id = _start(uint96(MIN_STAKE), aliceWhite, 300, 2);
        vm.assume(caller != (aliceWhite ? ALICE : BOB));
        vm.prank(caller);
        try game.makeMove(id, FenLib.mv("e2e4")) {
            assert(false);
        } catch (bytes memory err) {
            assert(bytes4(err) == ChessArena.NotYourTurn.selector);
        }
    }

    // ------------------------------------------------------------------ ratings

    function _k(uint32 games, bool peaked) internal pure returns (uint256) {
        return games < 30 ? 40 : (peaked ? 10 : 20);
    }

    /// The rating step, for EVERY old rating (>= the floor), game count, K state, result and EVERY expected score
    /// 0..100 (a superset of the FIDE table's values): it never reverts; it is the exact rounding of
    /// K * (score - expected) (|100 * change - K * (S - E)| <= 50) unless the floor or the uint32 limit
    /// stops it; it points the right way; it counts the game; and the 2400 flag is sticky.
    /// (The table lookup reads memory at a data-dependent offset, which Halmos cannot model; it is checked
    /// exhaustively over every rating difference in test/Elo.t.sol instead.)
    function check_ratingStepIsExact(uint32 old, uint32 games, bool peaked, uint8 s, uint8 expected) public {
        vm.assume(old >= 100 && expected <= 100 && s < 3);
        uint256 score = uint256(s) * 50;
        uint256 k = _k(games, peaked);
        try ratingHarness.updated(old, games, peaked, old, score, expected) returns (
            uint256 nr, uint32 rRating, uint32 rGames, bool rPeaked
        ) {
            assert(rRating == nr);
            assert(nr >= 100 && nr <= type(uint32).max);
            int256 change = int256(nr) - int256(uint256(old));
            int256 exact = int256(k) * (int256(score) - int256(uint256(expected))); // 100 x the real change
            int256 err = change * 100 - exact;
            bool floored = nr == 100 && exact < 0;
            bool saturated = nr == type(uint32).max && exact > 0;
            if (!floored && !saturated) assert(err <= 50 && err >= -50);
            if (score >= expected) assert(nr >= old);
            else assert(nr <= old);
            assert(change <= int256(k) && change >= -int256(k));
            assert(rGames == (games == type(uint32).max ? games : games + 1));
            assert(rPeaked == (peaked || nr >= 2400));
        } catch {
            assert(false); // the step must never revert
        }
    }

    // ------------------------------------------------------------------ refunds

    /// An unjoined stake always comes back to its creator, exactly, from either seat: the creator may cancel any
    /// time; a stranger only after the open window, and the refund still goes to the creator. Joining is
    /// possible exactly until the window closes.
    function check_openGameRefundsExactly(uint96 stake, bool asWhite, uint32 dt, bool byStranger) public {
        vm.assume(stake >= MIN_STAKE);
        vm.deal(ALICE, stake);
        vm.prank(ALICE);
        uint256 id = game.createGame{value: stake}(300, 2, asWhite);
        vm.warp(T0 + dt);
        vm.prank(byStranger ? CAROL : ALICE);
        try game.cancelGame(id) {
            assert(!byStranger || dt > 1 hours);
            assert(ALICE.balance == stake);
            assert(CAROL.balance == 0);
            assert(address(game).balance == 0);
        } catch (bytes memory err) {
            assert(byStranger && dt <= 1 hours);
            assert(bytes4(err) == ChessArena.NotCreator.selector);
            assert(address(game).balance == stake);
        }
    }

    function check_joinWindowIsExact(uint96 stake, uint32 dt) public {
        vm.assume(stake >= MIN_STAKE);
        vm.deal(ALICE, stake);
        vm.deal(BOB, stake);
        vm.prank(ALICE);
        uint256 id = game.createGame{value: stake}(300, 2, true);
        vm.warp(T0 + dt);
        vm.prank(BOB);
        try game.joinGame{value: stake}(id) {
            assert(dt <= 1 hours);
            assert(address(game).balance == uint256(stake) * 2);
        } catch (bytes memory err) {
            assert(dt > 1 hours);
            assert(bytes4(err) == ChessArena.Expired.selector);
            assert(BOB.balance == stake);
        }
    }
}
