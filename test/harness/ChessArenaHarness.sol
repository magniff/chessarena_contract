// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChessArena} from "../../src/ChessArena.sol";

/// Test-only: exposes internal pieces of the shipped contract (inherited, so this is the same compiled code) so
/// they can be tested and proved in isolation. Never deployed.
contract ChessArenaHarness is ChessArena {
    function expectedScore(uint256 ra, uint256 rb) external pure returns (uint256) {
        return _expectedScore(ra, rb);
    }

    function kFactor(uint32 games, bool peaked) external pure returns (uint256) {
        return _kFactor(Rating(0, games, peaked));
    }

    function updated(uint32 rating, uint32 games, bool peaked, uint256 old, uint256 score, uint256 expected)
        external
        pure
        returns (uint256 nr, uint32 rRating, uint32 rGames, bool rPeaked)
    {
        Rating memory r = Rating(rating, games, peaked);
        nr = _updated(r, old, score, expected);
        return (nr, r.rating, r.games, r.reached2400);
    }
}
