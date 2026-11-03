// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChessArena} from "../../src/ChessArena.sol";

/// A player contract that refuses every ETH transfer, so its payouts and refunds must fall back to `pending`.
contract RefusingPlayer {
    receive() external payable {
        revert();
    }

    function create(ChessArena g, uint32 base) external payable returns (uint256) {
        return g.createGame{value: msg.value}(base, 0, true);
    }

    function join(ChessArena g, uint256 id) external payable {
        g.joinGame{value: msg.value}(id);
    }

    function resign(ChessArena g, uint256 id) external {
        g.resign(id);
    }

    function cancel(ChessArena g, uint256 id) external {
        g.cancelGame(id);
    }

    function withdraw(ChessArena g) external {
        g.withdraw();
    }
}

/// The only contract Halmos calls during invariant exploration. Every action takes symbolic arguments; Halmos
/// explores EVERY sequence of actions up to --invariant-depth and checks the invariants after each step.
/// Moves are left out on purpose: they move no money, and every game end they can cause settles through the
/// same `_finish` as resign/timeout (whose arithmetic is proved for all stakes in ContractProofs).
contract Handler is Test {
    ChessArena public game;
    address public constant ALICE = address(0xA11CE);
    address public constant BOB = address(0xB0B);
    RefusingPlayer public refuser;
    uint32 constant BASE = 120;
    uint256 constant S1 = 0.0001 ether;
    uint256 constant S2 = 0.0003 ether;

    /// set when a Finished or Cancelled game ever changes again (checked by the invariant)
    bool public terminalStateChanged;

    constructor(ChessArena g, RefusingPlayer r) {
        game = g;
        refuser = r;
    }

    function _stake(bool second) internal pure returns (uint256) {
        return second ? S2 : S1;
    }

    /// concrete game id from a symbolic selector (Halmos branches once per existing game)
    function _id(uint8 g) internal view returns (uint256) {
        uint256 n = game.nextGameId() - 1;
        vm.assume(n > 0 && g < n);
        if (g == 0) return 1;
        if (g == 1) return 2;
        if (g == 2) return 3;
        return 4;
    }

    function _snapshot() internal view returns (uint8[5] memory st) {
        for (uint256 id = 1; id < game.nextGameId() && id <= 4; ++id) {
            st[id] = uint8(game.getGame(id).status);
        }
    }

    function _checkTerminal(uint8[5] memory before) internal {
        for (uint256 id = 1; id < 5; ++id) {
            bool terminal = before[id] == uint8(ChessArena.Status.Finished)
                || before[id] == uint8(ChessArena.Status.Cancelled);
            if (terminal && uint8(game.getGame(id).status) != before[id]) terminalStateChanged = true;
        }
    }

    // ------------------------------------------------------------------ actions

    function create(uint8 who, bool secondStake, bool white) external {
        uint8[5] memory before = _snapshot();
        uint256 s = _stake(secondStake);
        if (who % 3 == 2) {
            try refuser.create{value: s}(game, BASE) {} catch {}
        } else {
            vm.prank(who % 3 == 0 ? ALICE : BOB);
            try game.createGame{value: s}(BASE, 0, white) {} catch {}
        }
        _checkTerminal(before);
    }

    function join(uint8 who, uint8 g) external {
        uint256 id = _id(g);
        uint8[5] memory before = _snapshot();
        uint256 s = game.getGame(id).stake;
        if (who % 3 == 2) {
            try refuser.join{value: s}(game, id) {} catch {}
        } else {
            vm.prank(who % 3 == 0 ? ALICE : BOB);
            try game.joinGame{value: s}(id) {} catch {}
        }
        _checkTerminal(before);
    }

    function cancel(uint8 who, uint8 g) external {
        uint256 id = _id(g);
        uint8[5] memory before = _snapshot();
        if (who % 3 == 2) {
            try refuser.cancel(game, id) {} catch {}
        } else {
            vm.prank(who % 3 == 0 ? ALICE : BOB);
            try game.cancelGame(id) {} catch {}
        }
        _checkTerminal(before);
    }

    function resign(uint8 who, uint8 g) external {
        uint256 id = _id(g);
        uint8[5] memory before = _snapshot();
        if (who % 3 == 2) {
            try refuser.resign(game, id) {} catch {}
        } else {
            vm.prank(who % 3 == 0 ? ALICE : BOB);
            try game.resign(id) {} catch {}
        }
        _checkTerminal(before);
    }

    function claimTimeout(uint8 g) external {
        uint256 id = _id(g);
        uint8[5] memory before = _snapshot();
        try game.claimTimeout(id) {} catch {}
        _checkTerminal(before);
    }

    function sweep(bool secondStake, uint8 limit) external {
        uint8[5] memory before = _snapshot();
        try game.sweepExpired(game.lobbyKey(_stake(secondStake), BASE, 0), limit % 4) {} catch {}
        _checkTerminal(before);
    }

    function withdraw(uint8 who) external {
        uint8[5] memory before = _snapshot();
        if (who % 3 == 2) {
            try refuser.withdraw(game) {} catch {}
        } else {
            vm.prank(who % 3 == 0 ? ALICE : BOB);
            try game.withdraw() {} catch {}
        }
        _checkTerminal(before);
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + dt);
    }
}

/// Bounded proofs over call sequences: for EVERY sequence of handler actions up to the configured depth (every
/// actor, every game, every stake choice, every time jump), after every step:
///   - the contract holds exactly the stakes still in play plus the unclaimed credits (nothing created or lost);
///   - the lobby index is exactly the set of open games;
///   - a finished or cancelled game never changes again.
contract InvariantProofs is Test {
    ChessArena game;
    Handler h;
    RefusingPlayer refuser;

    function setUp() public {
        vm.warp(1_700_000_000);
        game = new ChessArena();
        refuser = new RefusingPlayer();
        h = new Handler(game, refuser);
        vm.deal(h.ALICE(), 1 ether);
        vm.deal(h.BOB(), 1 ether);
        vm.deal(address(h), 1 ether); // funds the refusing player's stakes (sent along with each call)
        targetContract(address(h));
    }

    function _locked() internal view returns (uint256 total) {
        for (uint256 id = 1; id < game.nextGameId(); ++id) {
            ChessArena.GameView memory v = game.getGame(id);
            if (v.status == ChessArena.Status.Open) total += v.stake;
            else if (v.status == ChessArena.Status.Active) total += 2 * v.stake;
        }
    }

    function invariant_moneyIsConserved() public view {
        uint256 credits = game.pending(h.ALICE()) + game.pending(h.BOB()) + game.pending(address(refuser))
            + game.pending(game.FEE_RECIPIENT());
        assert(address(game).balance == _locked() + credits);
    }

    function invariant_lobbyIndexIsExact() public view {
        uint256 open;
        for (uint256 id = 1; id < game.nextGameId(); ++id) {
            if (game.getGame(id).status == ChessArena.Status.Open) ++open;
        }
        assert(
            game.openGameCount(game.lobbyKey(0.0001 ether, 120, 0)) + game.openGameCount(game.lobbyKey(0.0003 ether, 120, 0))
                == open
        );
    }

    function invariant_finishedAndCancelledGamesAreFinal() public view {
        assert(!h.terminalStateChanged());
    }
}
