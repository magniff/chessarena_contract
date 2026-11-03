// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChessEngine} from "./ChessEngine.sol";

/// @title ChessArena
/// @notice Trustless wagered chess. Anyone locks a stake to open a game; anyone matching the stake
///         can join. Every move is validated on-chain, the winner is computed automatically and
///         takes the pot minus a protocol fee.
///
/// Flow
///   createGame{value: stake}(baseTime, increment, white) -> GameCreated (creator declares colour + clock)
///   joinGame{value: stake}(id)             -> GameStarted (must happen within OPEN_WINDOW)
///   makeMove(id, move) ...                 -> MoveMade, and finally GameFinished
///   resign(id) / claimTimeout(id)          -> alternative endings
///   cancelGame(id)                         -> creator reclaims stake if nobody joined
contract ChessArena {
    using ChessEngine for ChessEngine.Position;

    // ------------------------------------------------------------------ config

    /// @dev TODO(release): replace with the real fee address before mainnet deployment.
    ///      script/Deploy.s.sol refuses to deploy to non-local chains while this is still the placeholder.
    address payable public constant FEE_RECIPIENT = payable(0x000000000000000000000000000000000000dEaD);

    /// @notice Fee in basis points of the total pot (both stakes). Charged on every finished game.
    uint256 public constant FEE_BPS = 250;
    /// @notice Smallest allowed stake per player: keeps the fee non-trivial and makes dust-spam pointless.
    uint256 public constant MIN_STAKE = 0.0001 ether;
    /// @notice Fischer clock: each side starts with `baseTime` and gains `increment` after every move.
    ///         A total time bank (not a per-move limit) bounds how long a hostile opponent can hold your funds.
    ///         The bank is capped at MAX_BASE_TIME, so fast moves can't be hoarded into a multi-day stall.
    uint32 public constant MIN_BASE_TIME = 30 seconds;
    uint32 public constant MAX_BASE_TIME = 1 days;
    uint32 public constant MAX_INCREMENT = 10 minutes;
    /// @notice An open game can be joined for this long; afterwards anyone may refund it to its creator.
    uint256 public constant OPEN_WINDOW = 1 hours;
    /// @dev Gas forwarded when pushing a payout; if the push fails the amount is credited for `withdraw`.
    uint256 internal constant PAYOUT_GAS = 50_000;
    /// @notice Bot profile limits. Names: [A-Za-z0-9 _.-], no leading/trailing/double spaces.
    ///         Descriptions: any UTF-8 without control bytes. Names are NOT unique: show the address with them.
    uint256 public constant MAX_NAME_BYTES = 32;
    uint256 public constant MAX_DESCRIPTION_BYTES = 280;
    /// @notice Elo ratings by the FIDE Rating Regulations (Handbook B.02, 8.1.2 and 8.3): expected score from the
    ///         FIDE table; a difference above 400 points counts as 400 for a player rated below 2650 and in full
    ///         for one rated 2650 or more; K = 40 for a player's first 30 rated games, then 20, and 10 for good once
    ///         they have reached 2400; change K * (S - E) rounded half away from zero. A game is rated only if both
    ///         sides made at least one move. Unlike FIDE everyone starts rated, at INITIAL_RATING (there is no
    ///         unrated phase), and ratings never drop below RATING_FLOOR.
    uint256 public constant INITIAL_RATING = 1500;
    uint256 public constant RATING_FLOOR = 100;
    /// @dev FIDE table 8.1.2: expected score x 100 of a player rated D = 0..735 points above the opponent, one byte
    ///      per D (above 735 it is 100). Generated and checked by scripts/elo_table.py.
    bytes internal constant EXPECTED_SCORE =
        hex"3232323233333333333333343434343434343535353535353535363636363636363737373737373738383838383838393939393939393a3a3a3a3a3a3a3a3b3b3b3b3b3b3b3c3c3c3c3c3c3c3c3d3d3d3d3d3d3d3e3e3e3e3e3e3e3e3f3f3f3f3f3f3f4040404040404040414141414141414242424242424242434343434343434344444444444444444545454545454545464646464646464647474747474747474748484848484848484949494949494949494a4a4a4a4a4a4a4a4a4b4b4b4b4b4b4b4b4b4c4c4c4c4c4c4c4c4c4d4d4d4d4d4d4d4d4d4e4e4e4e4e4e4e4e4e4e4f4f4f4f4f4f4f4f4f4f50505050505050505050515151515151515151515152525252525252525252525353535353535353535353545454545454545454545454555555555555555555555555565656565656565656565656565757575757575757575757575758585858585858585858585858585858595959595959595959595959595a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f6060606060606060606060606060606060606060606060606060606060606060606161616161616161616161616161616161616161616161616161616161616161616161616161616161616262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363";

    // ------------------------------------------------------------------ types

    enum Status {
        None,
        Open,
        Active,
        Finished,
        Cancelled
    }

    enum Result {
        None,
        WhiteWins,
        BlackWins,
        Draw
    }

    enum Reason {
        None,
        Checkmate,
        Resignation,
        Timeout,
        Stalemate,
        InsufficientMaterial,
        FiftyMoveRule,
        ThreefoldRepetition
    }

    /// @dev Laid out for the hot path: a move reads `st`, `board` and the mover's seat, and writes `st` and `board`.
    struct Game {
        address payable white; // slot 0. While Open only the creator's seat (the colour they chose) is filled.
        uint96 stake; // per player
        address payable black; // slot 1
        State st; // slot 2
        uint256 board; // slot 3: ChessEngine.Position.board
    }

    /// @dev Exactly one storage slot (30 bytes): everything a move changes except the board.
    struct State {
        Status status;
        Result result;
        Reason reason;
        uint32 increment;
        uint32 whiteTime; // seconds on white's clock as of lastMoveAt
        uint32 blackTime;
        uint40 lastMoveAt; // creation time while Open
        uint16 plies;
        // the rest of ChessEngine.Position
        bool whiteToMove;
        uint8 castling;
        uint8 epSquare;
        uint8 halfmoveClock;
        uint8 whiteKing;
        uint8 blackKing;
        uint16 fullmove;
    }

    /// @dev Flat view of a game for clients.
    struct GameView {
        uint256 id;
        Status status;
        Result result;
        Reason reason;
        address white;
        address black;
        uint256 stake;
        uint32 increment;
        uint32 whiteTime;
        uint32 blackTime;
        uint40 lastMoveAt;
        /// @dev Open: last moment it can be joined. Active: moment the side to move can be flagged. Else 0.
        uint256 deadline;
        uint16 plies;
        bool whiteToMove;
    }

    // ------------------------------------------------------------------ storage

    uint256 public nextGameId = 1;
    mapping(uint256 => Game) internal games;
    /// @dev gameId => position key => occurrences (for threefold repetition)
    mapping(uint256 => mapping(bytes32 => uint8)) internal positionCount;
    /// @dev table (= keccak(stake, baseTime, increment)) => ids of open games at that table. Matchmaking only
    ///      ever looks at the exact table it wants to sit at, so spam anywhere else can't hide a game, and spam
    ///      AT the table is joinable (and therefore costs the spammer a stake per game somebody joins).
    ///      Swap-and-pop keeps it exact (no stale entries).
    mapping(bytes32 => uint256[]) internal openByTable;
    mapping(uint256 => uint256) internal openPos; // gameId => index + 1 in its bucket
    /// @notice Payouts whose push failed; claim with `withdraw`.
    mapping(address => uint256) public pending;

    struct Profile {
        string name;
        string description;
    }

    mapping(address => Profile) internal profiles;

    /// @dev One slot per player. `games` = rated games played; a player with no rated games is at INITIAL_RATING.
    struct Rating {
        uint32 rating;
        uint32 games;
        bool reached2400; // K drops to 10 for good once a player has been rated 2400
    }

    mapping(address => Rating) internal ratings;

    /// @dev EIP-1153 transient storage: the same lock as a storage flag, without a cold slot write per call.
    bool private transient _locked;

    // ------------------------------------------------------------------ events

    event GameCreated(
        uint256 indexed gameId,
        address indexed creator,
        uint256 stake,
        uint32 baseTime,
        uint32 increment,
        bool creatorPlaysWhite
    );
    event GameCancelled(uint256 indexed gameId);
    event GameStarted(uint256 indexed gameId, address indexed white, address indexed black);
    /// @param move  from | to << 6 | promotion << 12 (a1 = 0 ... h8 = 63)
    /// @param ply   number of half-moves played so far, including this one
    event MoveMade(uint256 indexed gameId, address indexed player, uint16 move, uint16 ply);
    event GameFinished(
        uint256 indexed gameId, Result result, Reason reason, address indexed winner, uint256 payout, uint256 fee
    );
    event Withdrawn(address indexed account, uint256 amount);
    event ProfileUpdated(address indexed bot, string name, string description);
    event RatingsUpdated(
        uint256 indexed gameId,
        address indexed white,
        uint256 whiteBefore,
        uint256 whiteAfter,
        address indexed black,
        uint256 blackBefore,
        uint256 blackAfter
    );

    // ------------------------------------------------------------------ errors

    error BadStake();
    error BadTimeout();
    error Expired();
    error UnknownGame();
    error NotOpen();
    error NotActive();
    error NotCreator();
    error SelfJoin();
    error NotPlayer();
    error NotYourTurn();
    error TurnTimedOut();
    error NotTimedOut();
    error IllegalMove();
    error NothingToWithdraw();
    error Reentrancy();
    error BadName();
    error BadDescription();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    // ------------------------------------------------------------------ lobby

    /// @notice Lock `msg.value` as your stake and open a game for anyone who matches it.
    /// @param baseTime seconds each player starts with on the clock
    /// @param increment seconds added to a player's clock after each of their moves
    /// @param creatorPlaysWhite colour is chosen by the creator and visible before anyone joins. There is
    ///        deliberately no on-chain randomness: a contract joiner could read it and revert unless lucky.
    function createGame(uint32 baseTime, uint32 increment, bool creatorPlaysWhite)
        external
        payable
        nonReentrant
        returns (uint256 gameId)
    {
        if (msg.value < MIN_STAKE || msg.value > type(uint96).max) revert BadStake();
        if (baseTime < MIN_BASE_TIME || baseTime > MAX_BASE_TIME || increment > MAX_INCREMENT) revert BadTimeout();

        gameId = nextGameId++;
        Game storage g = games[gameId];
        if (creatorPlaysWhite) g.white = payable(msg.sender);
        else g.black = payable(msg.sender);
        g.stake = uint96(msg.value);
        State storage st = g.st;
        st.status = Status.Open;
        st.increment = increment;
        st.whiteTime = baseTime;
        st.blackTime = baseTime;
        st.lastMoveAt = uint40(block.timestamp);

        uint256[] storage bucket = openByTable[lobbyKey(msg.value, baseTime, increment)];
        bucket.push(gameId);
        openPos[gameId] = bucket.length;
        emit GameCreated(gameId, msg.sender, msg.value, baseTime, increment, creatorPlaysWhite);
    }

    /// @notice Refund an open game's stake to its creator. The creator may do so any time; anyone may once
    ///         the game has expired (this is how abandoned tables get cleaned up).
    function cancelGame(uint256 gameId) external nonReentrant {
        Game storage g = _game(gameId);
        if (g.st.status != Status.Open) revert NotOpen();
        if (msg.sender != _creator(g) && block.timestamp <= uint256(g.st.lastMoveAt) + OPEN_WINDOW) revert NotCreator();
        _cancel(gameId, g);
    }

    /// @notice Permissionless janitor: refund up to `limit` expired open games at a table.
    function sweepExpired(bytes32 table, uint256 limit) external nonReentrant returns (uint256 swept) {
        uint256[] storage bucket = openByTable[table];
        uint256 i;
        for (uint256 scanned; scanned < limit && i < bucket.length; ++scanned) {
            uint256 id = bucket[i];
            Game storage g = games[id];
            if (block.timestamp > uint256(g.st.lastMoveAt) + OPEN_WINDOW) {
                _cancel(id, g); // swap-and-pop moved the last entry into slot i, so don't advance
                ++swept;
            } else {
                ++i;
            }
        }
    }

    /// @notice Join an open game by sending exactly the creator's stake.
    function joinGame(uint256 gameId) external payable nonReentrant {
        Game storage g = _game(gameId);
        State memory st = g.st;
        if (st.status != Status.Open) revert NotOpen();
        if (msg.value != g.stake) revert BadStake();
        if (msg.sender == _creator(g)) revert SelfJoin();
        if (block.timestamp > uint256(st.lastMoveAt) + OPEN_WINDOW) revert Expired();

        _removeOpen(g, gameId);
        if (g.white == address(0)) g.white = payable(msg.sender);
        else g.black = payable(msg.sender);
        st.status = Status.Active;
        st.lastMoveAt = uint40(block.timestamp);

        ChessEngine.Position memory p = ChessEngine.initialPosition();
        _save(g, st, p);
        positionCount[gameId][p.positionKey()] = 1;

        emit GameStarted(gameId, g.white, g.black);
    }

    // ------------------------------------------------------------------ play

    /// @notice Play a move as the side to move. Reverts unless the move is fully legal.
    function makeMove(uint256 gameId, uint16 move) external nonReentrant {
        Game storage g = _game(gameId);
        State memory st = g.st;
        if (st.status != Status.Active) revert NotActive();
        bool white = st.whiteToMove;
        if (msg.sender != (white ? g.white : g.black)) revert NotYourTurn();
        uint256 left = white ? st.whiteTime : st.blackTime;
        uint256 elapsed = block.timestamp - st.lastMoveAt;
        if (elapsed > left) revert TurnTimedOut();

        (bool ok, ChessEngine.Position memory np) = ChessEngine.applyMove(_position(g, st), move);
        if (!ok) revert IllegalMove();

        st.lastMoveAt = uint40(block.timestamp);
        uint256 newLeft = left - elapsed + st.increment;
        if (newLeft > MAX_BASE_TIME) newLeft = MAX_BASE_TIME; // hard bound on how long any one move can take
        if (white) st.whiteTime = uint32(newLeft);
        else st.blackTime = uint32(newLeft);
        uint16 ply = ++st.plies;
        _save(g, st, np);
        emit MoveMade(gameId, msg.sender, move, ply);

        ChessEngine.Outcome o = ChessEngine.outcome(np);
        if (o == ChessEngine.Outcome.Checkmate) {
            _finish(gameId, g, white ? Result.WhiteWins : Result.BlackWins, Reason.Checkmate);
        } else if (o == ChessEngine.Outcome.Stalemate) {
            _finish(gameId, g, Result.Draw, Reason.Stalemate);
        } else if (o == ChessEngine.Outcome.InsufficientMaterial) {
            _finish(gameId, g, Result.Draw, Reason.InsufficientMaterial);
        } else if (o == ChessEngine.Outcome.FiftyMoveRule) {
            _finish(gameId, g, Result.Draw, Reason.FiftyMoveRule);
        } else if (++positionCount[gameId][np.positionKey()] >= 3) {
            _finish(gameId, g, Result.Draw, Reason.ThreefoldRepetition);
        }
    }

    /// @notice Concede the game; the opponent takes the pot.
    function resign(uint256 gameId) external nonReentrant {
        Game storage g = _game(gameId);
        if (g.st.status != Status.Active) revert NotActive();
        if (msg.sender == g.white) _finish(gameId, g, Result.BlackWins, Reason.Resignation);
        else if (msg.sender == g.black) _finish(gameId, g, Result.WhiteWins, Reason.Resignation);
        else revert NotPlayer();
    }

    /// @notice If the side to move let its clock run out, anyone can end the game in the opponent's favour.
    function claimTimeout(uint256 gameId) external nonReentrant {
        Game storage g = _game(gameId);
        State memory st = g.st;
        if (st.status != Status.Active) revert NotActive();
        bool white = st.whiteToMove;
        if (block.timestamp <= uint256(st.lastMoveAt) + (white ? st.whiteTime : st.blackTime)) revert NotTimedOut();
        _finish(gameId, g, white ? Result.BlackWins : Result.WhiteWins, Reason.Timeout);
    }

    /// @notice Pull payouts that could not be pushed.
    function withdraw() external nonReentrant {
        uint256 amount = pending[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pending[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        (bool sent,) = msg.sender.call{value: amount}("");
        require(sent, "withdraw failed");
    }

    // ------------------------------------------------------------------ profiles

    /// @notice Set the caller's public name and description (both empty = remove the profile).
    ///         Profiles never touch money or games; they exist so humans can tell bots apart.
    function setProfile(string calldata name, string calldata description) external {
        bytes calldata n = bytes(name);
        bytes calldata d = bytes(description);
        if (n.length > MAX_NAME_BYTES) revert BadName();
        for (uint256 i; i < n.length; ++i) {
            bytes1 c = n[i];
            bool ok = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-"
                || c == "_" || c == ".";
            if (c == " ") {
                // no leading, trailing or double spaces: "Magnus " can't impersonate "Magnus"
                ok = i != 0 && i != n.length - 1 && n[i - 1] != " ";
            }
            if (!ok) revert BadName();
        }
        if (d.length > MAX_DESCRIPTION_BYTES) revert BadDescription();
        for (uint256 i; i < d.length; ++i) {
            // control bytes would let a description rewrite terminals / break one-line layouts
            if (uint8(d[i]) < 0x20 || uint8(d[i]) == 0x7f) revert BadDescription();
        }
        if (n.length == 0 && d.length == 0) {
            delete profiles[msg.sender];
        } else {
            Profile storage p = profiles[msg.sender];
            p.name = name;
            p.description = description;
        }
        emit ProfileUpdated(msg.sender, name, description);
    }

    /// @notice A player's Elo rating, the number of rated games behind it, and the K-factor their next game uses.
    function ratingOf(address player) external view returns (uint256 rating, uint256 ratedGames, uint256 k) {
        Rating memory r = ratings[player];
        rating = r.games == 0 ? INITIAL_RATING : r.rating;
        ratedGames = r.games;
        k = _kFactor(r);
    }

    function profileOf(address bot) external view returns (string memory name, string memory description) {
        Profile storage p = profiles[bot];
        return (p.name, p.description);
    }

    // ------------------------------------------------------------------ views

    function getGame(uint256 gameId) external view returns (GameView memory v) {
        Game storage g = _game(gameId);
        State memory st = g.st;
        v.id = gameId;
        v.status = st.status;
        v.result = st.result;
        v.reason = st.reason;
        if (st.status == Status.Open || st.status == Status.Cancelled) {
            v.white = _creator(g); // colours not assigned yet; creator listed first
        } else {
            v.white = g.white;
            v.black = g.black;
        }
        v.stake = g.stake;
        v.increment = st.increment;
        v.whiteTime = st.whiteTime;
        v.blackTime = st.blackTime;
        v.lastMoveAt = st.lastMoveAt;
        if (st.status == Status.Open) {
            v.deadline = uint256(st.lastMoveAt) + OPEN_WINDOW;
        } else if (st.status == Status.Active) {
            v.deadline = uint256(st.lastMoveAt) + (st.whiteToMove ? st.whiteTime : st.blackTime);
        }
        v.plies = st.plies;
        v.whiteToMove = st.whiteToMove;
    }

    /// @notice Key of a lobby table: games are only matched with identical stake AND clock.
    function lobbyKey(uint256 stake, uint32 baseTime, uint32 increment) public pure returns (bytes32) {
        return keccak256(abi.encode(stake, baseTime, increment));
    }

    /// @notice Joinable (unexpired) games at a table, newest first. Reads at most `scanLimit` entries.
    function openGames(bytes32 table, uint256 maxResults, uint256 scanLimit) external view returns (uint256[] memory ids) {
        uint256[] storage bucket = openByTable[table];
        uint256 n = bucket.length;
        ids = new uint256[](maxResults < n ? maxResults : n);
        uint256 found;
        for (uint256 i = n; i > 0 && found < maxResults && n - i < scanLimit; --i) {
            uint256 id = bucket[i - 1];
            if (block.timestamp <= uint256(games[id].st.lastMoveAt) + OPEN_WINDOW) ids[found++] = id;
        }
        assembly {
            mstore(ids, found)
        }
    }

    function openGameCount(bytes32 table) external view returns (uint256) {
        return openByTable[table].length;
    }

    function getPosition(uint256 gameId) external view returns (ChessEngine.Position memory) {
        Game storage g = _game(gameId);
        return _position(g, g.st);
    }

    /// @notice Every legal move for the side to move (promotions expanded). Heavy: call via eth_call only.
    function legalMoves(uint256 gameId) external view returns (uint16[] memory) {
        Game storage g = _game(gameId);
        if (g.st.status != Status.Active) revert NotActive();
        return ChessEngine.legalMoves(_position(g, g.st));
    }

    function isMoveLegal(uint256 gameId, uint16 move) external view returns (bool) {
        Game storage g = _game(gameId);
        if (g.st.status != Status.Active) revert NotActive();
        return ChessEngine.isLegal(_position(g, g.st), move);
    }

    // ------------------------------------------------------------------ internals

    function _game(uint256 gameId) internal view returns (Game storage g) {
        g = games[gameId];
        if (g.st.status == Status.None) revert UnknownGame();
    }

    /// @dev The creator is whoever holds a seat before anyone joins (Open and Cancelled games have only one).
    function _creator(Game storage g) internal view returns (address payable) {
        address payable w = g.white;
        return w != address(0) ? w : g.black;
    }

    /// @dev The engine's view of the game: the board slot plus the position fields of `st`.
    function _position(Game storage g, State memory st) internal view returns (ChessEngine.Position memory p) {
        p.board = g.board;
        p.whiteToMove = st.whiteToMove;
        p.castling = st.castling;
        p.epSquare = st.epSquare;
        p.halfmoveClock = st.halfmoveClock;
        p.whiteKing = st.whiteKing;
        p.blackKing = st.blackKing;
        p.fullmove = st.fullmove;
    }

    /// @dev Write `st` with the position fields of `p`, and the board: two slots.
    function _save(Game storage g, State memory st, ChessEngine.Position memory p) internal {
        st.whiteToMove = p.whiteToMove;
        st.castling = p.castling;
        st.epSquare = p.epSquare;
        st.halfmoveClock = p.halfmoveClock;
        st.whiteKing = p.whiteKing;
        st.blackKing = p.blackKing;
        st.fullmove = p.fullmove;
        g.st = st;
        g.board = p.board;
    }

    function _cancel(uint256 gameId, Game storage g) internal {
        g.st.status = Status.Cancelled;
        _removeOpen(g, gameId);
        emit GameCancelled(gameId);
        _pay(_creator(g), g.stake);
    }

    /// @dev Only valid while `g` is Open (whiteTime still equals the advertised baseTime).
    function _removeOpen(Game storage g, uint256 gameId) internal {
        uint256[] storage bucket = openByTable[lobbyKey(g.stake, g.st.whiteTime, g.st.increment)];
        uint256 idx = openPos[gameId] - 1;
        uint256 last = bucket[bucket.length - 1];
        bucket[idx] = last;
        openPos[last] = idx + 1;
        bucket.pop();
        delete openPos[gameId];
    }

    function _finish(uint256 gameId, Game storage g, Result result, Reason reason) internal {
        State storage st = g.st;
        st.status = Status.Finished;
        st.result = result;
        st.reason = reason;
        _rate(gameId, g, result); // state only, no external calls, cannot revert: before any payout (CEI)

        uint256 pot = uint256(g.stake) * 2;
        uint256 fee = pot * FEE_BPS / 10_000;
        uint256 net = pot - fee;

        address winner;
        uint256 payout;
        if (result == Result.Draw) {
            payout = net / 2;
            fee += net - payout * 2; // odd wei goes to the fee
            emit GameFinished(gameId, result, reason, address(0), payout, fee);
            _pay(g.white, payout);
            _pay(g.black, payout);
        } else {
            winner = result == Result.WhiteWins ? g.white : g.black;
            payout = net;
            emit GameFinished(gameId, result, reason, winner, payout, fee);
            _pay(payable(winner), payout);
        }
        _pay(FEE_RECIPIENT, fee);
    }

    // ------------------------------------------------------------------ ratings

    /// @dev Update both players from their ratings BEFORE the game. Pure arithmetic on two storage slots: it can
    ///      neither revert nor be influenced by anyone but the two players, so it can never stop a game from ending.
    function _rate(uint256 gameId, Game storage g, Result result) internal {
        if (g.st.plies < 2) return; // as in FIDE, a game in which a side never moved is not rated
        address white = g.white;
        address black = g.black;
        Rating memory w = ratings[white];
        Rating memory b = ratings[black];
        uint256 rw = w.games == 0 ? INITIAL_RATING : w.rating;
        uint256 rb = b.games == 0 ? INITIAL_RATING : b.rating;
        uint256 scoreWhite = result == Result.WhiteWins ? 100 : result == Result.Draw ? 50 : 0;
        // each side's own expectation: with the 2650 rule the two need not add up to 1
        uint256 nw = _updated(w, rw, scoreWhite, _expectedScore(rw, rb));
        uint256 nb = _updated(b, rb, 100 - scoreWhite, _expectedScore(rb, rw));
        ratings[white] = w;
        ratings[black] = b;
        emit RatingsUpdated(gameId, white, rw, nw, black, rb, nb);
    }

    /// @dev Expected score x 100 of a player rated `ra` against `rb` (FIDE 8.1.2 with the 400-point rule of 8.3.1).
    function _expectedScore(uint256 ra, uint256 rb) internal pure returns (uint256) {
        uint256 d = ra >= rb ? ra - rb : rb - ra;
        if (d > 400 && ra < 2650) d = 400;
        uint256 h = d < EXPECTED_SCORE.length ? uint8(EXPECTED_SCORE[d]) : 100;
        return ra >= rb ? h : 100 - h;
    }

    function _kFactor(Rating memory r) internal pure returns (uint256) {
        if (r.games < 30) return 40;
        return r.reached2400 ? 10 : 20;
    }

    /// @dev New rating = old + K * (score - expected), rounded half away from zero, floored at RATING_FLOOR and
    ///      saturating at the uint32 limit; `score` and `expected` are x 100. Writes it into `r` and counts the game.
    function _updated(Rating memory r, uint256 old, uint256 score, uint256 expected) internal pure returns (uint256 nr) {
        uint256 k = _kFactor(r);
        if (score >= expected) {
            nr = old + (k * (score - expected) + 50) / 100;
            if (nr > type(uint32).max) nr = type(uint32).max;
        } else {
            uint256 down = (k * (expected - score) + 50) / 100;
            nr = old >= RATING_FLOOR + down ? old - down : RATING_FLOOR;
        }
        r.rating = uint32(nr);
        if (r.games < type(uint32).max) ++r.games;
        if (nr >= 2400) r.reached2400 = true;
    }

    /// @dev Push with bounded gas; on failure credit `pending` so a hostile receiver can never block a game's end.
    function _pay(address payable to, uint256 amount) internal {
        if (amount == 0) return;
        bool sent;
        assembly {
            // no return-data copy: a hostile receiver can't make us pay for it
            sent := call(PAYOUT_GAS, to, amount, 0, 0, 0, 0)
        }
        if (!sent) pending[to] += amount;
    }
}
