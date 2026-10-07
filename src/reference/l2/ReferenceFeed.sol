// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BellTypes} from "../l1/BellTypes.sol";
import {IReferenceFeed} from "./interfaces/IReferenceFeed.sol";
import {ReferenceDescription} from "./ReferenceDescription.sol";

/// @title ReferenceFeed
/// @notice One feed per (kind, source, subject), deployed only by ReferenceFeedFactory.createFeed (SPEC 4.4).
/// Stores every accepted observation as a raw round (AggregatorV3 face, 8 decimals) and runs the acceptance and
/// guard state machine of SPEC 6.6, which yields the confirmed observation, the pending round, the epoch anchor,
/// the promotion hold and the discontinuity list that the minting layer reads (SPEC 8.2, 8.10).
/// No owner, no admin function, no proxy, no fee path (SPEC 4 contract rules).
contract ReferenceFeed is IReferenceFeed {
    uint16 internal constant JUMP = 2_000;
    uint32 internal constant WINDOW = 21_600;
    uint32 internal constant LAG_LIMIT = 3_600;
    uint16 internal constant DISC = 4_000;
    uint32 internal constant HOLD = 86_400;
    /// @dev MIN_PRICE18 (SPEC 5.1): keeps the 8-decimal answer at 1 or more.
    uint128 internal constant MIN_PRICE18 = 1e10;
    /// @dev 18 to 8 decimals.
    uint256 internal constant TO_8 = 1e10;
    uint256 internal constant BPS = 1e4;

    /// @inheritdoc IReferenceFeed
    address public immutable FACTORY;
    /// @inheritdoc IReferenceFeed
    bytes32 public immutable FEED_ID;
    /// @inheritdoc IReferenceFeed
    uint8 public immutable KIND;
    /// @inheritdoc IReferenceFeed
    address public immutable SOURCE;
    /// @inheritdoc IReferenceFeed
    address public immutable SUBJECT;

    /// @dev A discontinuity: the round confirmed before the promotion and the promoted round (SPEC 4.4).
    struct Disc {
        uint80 preJumpRound;
        uint80 jumpRound;
    }

    /// @dev The guard fields of SPEC 4.4 storage, grouped in one struct so a push loads and stores them together.
    /// Field names are the SPEC names.
    struct Guard {
        uint80 confirmedRound;
        uint80 pendingRound;
        uint80 pendingAnchorRound;
        uint128 anchorPrice;
        uint64 pendingSince;
        uint64 anchorSince;
        uint80 holdPreJumpRound;
        uint80 holdJumpRound; // 0 when no hold
        uint64 holdUntil; // end of the current or last hold, kept after it ends
        uint256 maxPendingMoveBps;
        uint256 holdMoveBps;
    }

    /// @dev What the lazy steps did, in order: an optional hold end, an optional promotion, an optional hold end.
    struct Lazy {
        uint8 nDisc;
        bool firstDiscBeforePromotion;
        bool promoted;
        uint80 promotedRound;
        Disc[2] disc;
        uint256[2] discMove;
    }

    /// @dev Ondo's configurer changes allowedDeviationBps and maxTimeDelay without a new lastUpdated, so the
    /// configuration is tracked apart from the rounds; (l1Block, seq) orders it so an older report cannot replace it.
    /// seq, the ticket's delayed-inbox index, orders two reads of one L1 block (BELLSWAP-R2-3).
    struct Config {
        uint16 deviationBps;
        uint32 maxTimeDelay;
        uint64 l1Block;
        uint64 seq;
    }

    mapping(uint80 => Round) internal rounds;
    /// @inheritdoc IReferenceFeed
    uint80 public latestRound;
    /// @inheritdoc IReferenceFeed
    uint64 public lastLateReceivedAt;
    /// @inheritdoc IReferenceFeed
    uint8 public pinnedDecimals;
    bool internal pinned;
    /// @dev Delayed-inbox index of the ticket that carried the latest round; with that round's l1Block it is the
    /// round's configuration key in `_config`. Packed into the slot of latestRound, which every accepted round writes.
    uint64 internal roundSeq;
    /// @inheritdoc IReferenceFeed
    bytes32 public pinnedCodehash;
    Guard internal guard;
    Disc[] internal discontinuities;
    /// @dev The configuration of the latest config-only report (SPEC 6.6). It is in effect only while its (l1Block, seq)
    /// is above the latest round's; otherwise the latest round's values are, so an accepted round writes only roundSeq.
    Config internal cfg;

    /// @param kind 1 (sanity oracle) or 2 (L1 AggregatorV3); validated by the factory.
    /// @param source The L1 source contract.
    /// @param subject The L1 subject token (kind 1) or address(0) (kind 2).
    constructor(uint8 kind, address source, address subject) {
        FACTORY = msg.sender;
        KIND = kind;
        SOURCE = source;
        SUBJECT = subject;
        FEED_ID = BellTypes.feedId(kind, source, subject);
    }

    // ------------------------------------------------------------------ constants

    /// @inheritdoc IReferenceFeed
    function JUMP_BPS() external pure returns (uint16) {
        return JUMP;
    }

    /// @inheritdoc IReferenceFeed
    function CHALLENGE_WINDOW() external pure returns (uint32) {
        return WINDOW;
    }

    /// @inheritdoc IReferenceFeed
    function DELIVERY_LAG_LIMIT() external pure returns (uint32) {
        return LAG_LIMIT;
    }

    /// @inheritdoc IReferenceFeed
    function DISCONTINUITY_BPS() external pure returns (uint16) {
        return DISC;
    }

    /// @inheritdoc IReferenceFeed
    function PROMOTION_HOLD() external pure returns (uint32) {
        return HOLD;
    }

    // ------------------------------------------------------------------ AggregatorV3 raw face

    /// @notice Always 8 (SPEC 4.4, 5.1).
    function decimals() external pure returns (uint8) {
        return 8;
    }

    /// @notice Always 1.
    function version() external pure returns (uint256) {
        return 1;
    }

    /// @notice "Bellswap Reference k<kind> 0x<source> 0x<subject> / USD", hex only, no names (SPEC 4.4, 14.1).
    function description() external view returns (string memory) {
        return string.concat("Bellswap Reference ", ReferenceDescription.tail(KIND, SOURCE, SUBJECT));
    }

    /// @notice Latest accepted raw round: (roundId, int256(price18 / 1e10), t, t, roundId) with
    /// t = min(observedAt, block.timestamp). Reverts NoData before the first round.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint80 id = latestRound;
        if (id == 0) revert NoData();
        return _face(id);
    }

    /// @notice Same shape as latestRoundData for any accepted round; reverts NoData otherwise.
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (roundId == 0 || roundId > latestRound) revert NoData();
        return _face(roundId);
    }

    // ------------------------------------------------------------------ guard views

    /// @inheritdoc IReferenceFeed
    function round(uint80 roundId) external view returns (Round memory) {
        if (roundId == 0 || roundId > latestRound) revert NoData();
        return rounds[roundId];
    }

    /// @inheritdoc IReferenceFeed
    function confirmed() external view returns (uint80 roundId, Round memory r) {
        (Guard memory g,) = _effective();
        if (g.confirmedRound == 0) revert NoData();
        return (g.confirmedRound, rounds[g.confirmedRound]);
    }

    /// @inheritdoc IReferenceFeed
    function pending() external view returns (bool exists, uint80 roundId, Round memory r, uint64 promotableAt) {
        (Guard memory g,) = _effective();
        if (g.pendingRound == 0) return (false, 0, r, 0);
        return (true, g.pendingRound, rounds[g.pendingRound], _promotableAt(g));
    }

    /// @inheritdoc IReferenceFeed
    /// @dev Returns zeros while no pending round exists (the stored pendingSince of an ended episode is hidden).
    function pendingAnchor()
        external
        view
        returns (uint80 anchorRound, uint64 pendingSince, uint256 maxPendingMoveBps)
    {
        (Guard memory g,) = _effective();
        if (g.pendingRound == 0) return (0, 0, 0);
        return (g.pendingAnchorRound, g.pendingSince, g.maxPendingMoveBps);
    }

    /// @inheritdoc IReferenceFeed
    function anchor() external view returns (uint128 anchorPrice, uint64 anchorSince) {
        return (guard.anchorPrice, guard.anchorSince);
    }

    /// @inheritdoc IReferenceFeed
    /// @dev While no hold is active, preJumpRound, holdUntil and moveBps describe the last hold (0 if none).
    function hold()
        external
        view
        returns (bool active, uint80 preJumpRound, uint80 jumpRound, uint64 holdUntil, uint256 moveBps)
    {
        (Guard memory g,) = _effective();
        return (g.holdJumpRound != 0, g.holdPreJumpRound, g.holdJumpRound, g.holdUntil, g.holdMoveBps);
    }

    /// @inheritdoc IReferenceFeed
    function config() external view returns (uint16 deviationBps, uint32 maxTimeDelay, uint64 l1Block) {
        Config memory c = _config();
        return (c.deviationBps, c.maxTimeDelay, c.l1Block);
    }

    /// @inheritdoc IReferenceFeed
    function configSeq() external view returns (uint64) {
        return _config().seq;
    }

    /// @inheritdoc IReferenceFeed
    /// @dev Reverts NoData before the first confirmed round.
    function deliveryLag() external view returns (uint64) {
        (Guard memory g,) = _effective();
        if (g.confirmedRound == 0) revert NoData();
        Round storage c = rounds[g.confirmedRound];
        return _sat(c.receivedAt, c.l1Timestamp);
    }

    /// @inheritdoc IReferenceFeed
    function discontinuityCount() external view returns (uint256) {
        (, Lazy memory o) = _effective();
        return discontinuities.length + o.nDisc;
    }

    /// @inheritdoc IReferenceFeed
    function discontinuity(uint256 i) external view returns (uint80 preJumpRound, uint80 jumpRound) {
        uint256 stored = discontinuities.length;
        if (i < stored) {
            Disc storage d = discontinuities[i];
            return (d.preJumpRound, d.jumpRound);
        }
        (, Lazy memory o) = _effective();
        if (i - stored < o.nDisc) {
            Disc memory d = o.disc[i - stored];
            return (d.preJumpRound, d.jumpRound);
        }
        revert NoDiscontinuity(i);
    }

    // ------------------------------------------------------------------ state changes

    /// @inheritdoc IReferenceFeed
    function push(BellTypes.Report calldata r, uint64 l1Block, uint64 seq, uint64 l1Timestamp)
        external
        returns (Status)
    {
        if (msg.sender != FACTORY) revert OnlyFactory();

        uint80 last = latestRound;
        if (r.observedAt <= rounds[last].observedAt) {
            if (
                last == 0 || r.observedAt != rounds[last].observedAt || r.rawDecimals != pinnedDecimals
                    || r.sourceCodehash != pinnedCodehash || !_readAfterConfig(l1Block, seq)
            ) return _ignore(Status.NotNewer, r);
            if (r.price18 == rounds[last].price18) return _configOnly(r, l1Block, seq);
            // A same-second correction: the source changed the price again within the second of the latest round
            // and this read is later by (l1Block, seq), so it is accepted as a new round with the same observedAt
            // and runs through the guard like any other (CX2-CONTRACTS-1).
        }
        if (r.observedAt > l1Timestamp) return _ignore(Status.FutureDated, r);
        if (r.price18 < MIN_PRICE18) return _ignore(Status.OutOfRange, r);
        if (pinned) {
            if (r.rawDecimals != pinnedDecimals) return _ignore(Status.DecimalsChanged, r);
            if (r.sourceCodehash != pinnedCodehash) return _ignore(Status.CodehashChanged, r);
        } else {
            pinned = true;
            pinnedDecimals = r.rawDecimals;
            pinnedCodehash = r.sourceCodehash;
        }

        uint64 t = uint64(block.timestamp);
        uint80 n = last + 1;
        latestRound = n;
        roundSeq = seq;
        rounds[n] = Round({
            price18: r.price18,
            observedAt: r.observedAt,
            receivedAt: t,
            l1Timestamp: l1Timestamp,
            l1Block: l1Block,
            maxTimeDelay: r.maxTimeDelay,
            deviationBps: r.deviationBps
        });
        emit AnswerUpdated(int256(uint256(r.price18) / TO_8), n, _clamp(r.observedAt));
        emit RoundAccepted(n, r.price18, r.observedAt, t, l1Timestamp, l1Block, r.maxTimeDelay, r.deviationBps);
        if (_sat(t, l1Timestamp) > LAG_LIMIT) lastLateReceivedAt = t;

        // 1. lazy steps, then the epoch roll
        Guard memory g = guard;
        Lazy memory o;
        _lazy(g, o, t);
        _writeLazy(o);
        if (g.anchorSince != 0 && uint256(t) >= uint256(g.anchorSince) + WINDOW) {
            g.anchorPrice = rounds[g.confirmedRound].price18;
            g.anchorSince = t;
        }

        // 2. evaluate r
        Status s = _evaluate(g, n, r.price18, t);
        guard = g;
        return s;
    }

    /// @inheritdoc IReferenceFeed
    function poke() external {
        Guard memory g = guard;
        Lazy memory o;
        _lazy(g, o, uint64(block.timestamp));
        _writeLazy(o);
        guard = g;
    }

    // ------------------------------------------------------------------ internals

    /// @dev A report repeating the latest round's observedAt with its decimals and codehash, read after the
    /// configuration in effect, that is (l1Block, seq) is lexicographically greater: a newer L1 block, or the same
    /// block and a later delayed-inbox index (a read after the configurer's transaction in that block, BELLSWAP-R2-3).
    /// With the same price it is a config-only update, applied even when deviationBps and maxTimeDelay are unchanged, so
    /// that its key supersedes any older in-flight report (a restore delivered before the intermediate value it undoes,
    /// BELLSWAP-R2-1). It writes only `cfg`: no round, no receivedAt, no late receipt, no guard or lazy step. With a
    /// different price it is a same-second correction, which `push` accepts as a new round (CX2-CONTRACTS-1). Anything
    /// else, including a replay (equal key) or an older read redeemed late, stays NotNewer (SPEC 6.6).
    function _configOnly(BellTypes.Report calldata r, uint64 l1Block, uint64 seq) internal returns (Status) {
        cfg = Config(r.deviationBps, r.maxTimeDelay, l1Block, seq);
        emit ConfigUpdated(r.observedAt, r.deviationBps, r.maxTimeDelay, l1Block);
        return Status.ConfigUpdated;
    }

    /// @dev The configuration in effect: the latest config-only report if it was read after the latest round, by
    /// (l1Block, seq), else the latest round's. A config-only report for an older observation was read before the
    /// source posted the round's observation, so it orders before the round also within one L1 block; a config-only
    /// report for the round's observation read after it in the same block orders after it by seq. On an equal key
    /// (only possible without a real seq) the round wins.
    function _config() internal view returns (Config memory c) {
        c = cfg;
        Round storage rd = rounds[latestRound];
        uint64 rs = roundSeq;
        if (!_readAfter(c.l1Block, c.seq, rd.l1Block, rs)) {
            c = Config(rd.deviationBps, rd.maxTimeDelay, rd.l1Block, rs);
        }
    }

    /// @dev (l1Block, seq) is read after the configuration in effect, which is at or after the latest round's read.
    function _readAfterConfig(uint64 l1Block, uint64 seq) internal view returns (bool) {
        Config memory c = _config();
        return _readAfter(l1Block, seq, c.l1Block, c.seq);
    }

    /// @dev (block, seq) is lexicographically greater than (refBlock, refSeq).
    function _readAfter(uint64 block_, uint64 seq, uint64 refBlock, uint64 refSeq) internal pure returns (bool) {
        return block_ > refBlock || (block_ == refBlock && seq > refSeq);
    }

    function _ignore(Status s, BellTypes.Report calldata r) internal returns (Status) {
        emit UpdateIgnored(s, r.price18, r.observedAt);
        return s;
    }

    /// @dev Step 2 of SPEC 6.6 on the in-memory guard `g`; round `n` with price `p` is already stored.
    function _evaluate(Guard memory g, uint80 n, uint128 p, uint64 t) internal returns (Status) {
        if (g.confirmedRound == 0) {
            g.confirmedRound = n;
            g.anchorPrice = p;
            g.anchorSince = t;
            emit Confirmed(n, ConfirmHow.First);
            return Status.Accepted;
        }
        if (g.holdJumpRound != 0 && _within(p, rounds[g.holdPreJumpRound].price18)) {
            // revert a promotion: no discontinuity is recorded for it
            uint80 jumpRound = g.holdJumpRound;
            uint80 preJumpRound = g.holdPreJumpRound;
            g.confirmedRound = n;
            _clearPending(g);
            g.holdJumpRound = 0;
            if (g.holdUntil > t) g.holdUntil = t;
            // The new epoch is anchored at the pre-jump price markets used during the hold, not at p, so a revert
            // is not a free epoch boundary: later WithinJump confirmations stay within JUMP_BPS of the pre-jump
            // price until the next roll (C2 review; SPEC 6.6 pseudo-code, revert branch).
            g.anchorPrice = rounds[preJumpRound].price18;
            g.anchorSince = t;
            emit PromotionReverted(jumpRound, preJumpRound, n);
            emit Confirmed(n, ConfirmHow.Correction);
            return Status.Accepted;
        }
        uint128 c = rounds[g.confirmedRound].price18;
        if (_within(p, c) && _within(p, g.anchorPrice)) {
            bool hadPending = g.pendingRound != 0;
            if (g.holdJumpRound != 0) {
                // Markets use the pre-jump price during the hold and switch to the confirmed price at its end, so a
                // confirmation during the hold counts toward the hold's move (SP11, 8.10; C2 review).
                uint256 hm = _moveBps(p, rounds[g.holdPreJumpRound].price18);
                if (hm > g.holdMoveBps) g.holdMoveBps = hm;
            }
            g.confirmedRound = n;
            _clearPending(g);
            emit Confirmed(n, hadPending ? ConfirmHow.Correction : ConfirmHow.WithinJump);
            return Status.Accepted;
        }
        uint256 mv = _moveBps(p, c);
        if (g.pendingRound == 0 || !_within(p, rounds[g.pendingAnchorRound].price18)) {
            // a new pending episode, or a post outside JUMP_BPS of the pending anchor: restart the clock. The rounds of
            // the discarded chain can no longer be promoted, so their moves are dropped with them: a corrected spike
            // must not become the promotion's discontinuity move (C2 review; SPEC 6.6 else-branch, R12, threat rows
            // T2 and T34).
            g.pendingSince = t;
            g.pendingAnchorRound = n;
            g.maxPendingMoveBps = mv;
        } else if (mv > g.maxPendingMoveBps) {
            g.maxPendingMoveBps = mv;
        }
        g.pendingRound = n;
        emit PendingSet(n, g.pendingSince, _promotableAt(g));
        return Status.AcceptedPending;
    }

    function _clearPending(Guard memory g) internal {
        if (g.pendingRound != 0) emit PendingCleared(g.pendingRound);
        g.pendingRound = 0;
        g.pendingAnchorRound = 0;
        g.maxPendingMoveBps = 0;
    }

    /// @dev Lazy steps of SPEC 6.6: endHoldIfDue, promoteIfDue, endHoldIfDue. Pure in memory; `o` records events.
    function _lazy(Guard memory g, Lazy memory o, uint64 t) internal view {
        _endHoldIfDue(g, o, t);
        _promoteIfDue(g, o, t);
        _endHoldIfDue(g, o, t);
    }

    function _endHoldIfDue(Guard memory g, Lazy memory o, uint64 t) internal pure {
        if (g.holdJumpRound == 0 || t < g.holdUntil) return;
        if (g.holdMoveBps >= DISC) {
            if (o.nDisc == 0 && !o.promoted) o.firstDiscBeforePromotion = true;
            o.disc[o.nDisc] = Disc(g.holdPreJumpRound, g.holdJumpRound);
            o.discMove[o.nDisc] = g.holdMoveBps;
            o.nDisc++;
        }
        g.holdJumpRound = 0;
    }

    function _promoteIfDue(Guard memory g, Lazy memory o, uint64 t) internal view {
        if (g.pendingRound == 0 || g.holdJumpRound != 0) return;
        uint64 promotableAt = _promotableAt(g);
        if (t < promotableAt) return;
        uint128 q = rounds[g.confirmedRound].price18;
        uint128 np = rounds[g.pendingRound].price18;
        g.holdPreJumpRound = g.confirmedRound;
        g.holdJumpRound = g.pendingRound;
        g.holdUntil = promotableAt + HOLD;
        uint256 mv = g.maxPendingMoveBps;
        uint256 m = _moveBps(np, q);
        if (m > mv) mv = m;
        m = _moveBps(np, g.anchorPrice);
        if (m > mv) mv = m;
        g.holdMoveBps = mv;
        g.confirmedRound = g.pendingRound;
        // clear pending without a PendingCleared event
        g.pendingRound = 0;
        g.pendingAnchorRound = 0;
        g.maxPendingMoveBps = 0;
        g.anchorPrice = np;
        g.anchorSince = promotableAt;
        o.promoted = true;
        o.promotedRound = g.confirmedRound;
    }

    /// @dev Writes the discontinuities and emits the events of the lazy steps in their order.
    function _writeLazy(Lazy memory o) internal {
        uint256 k;
        if (o.nDisc != 0 && o.firstDiscBeforePromotion) {
            _recordDisc(o.disc[0], o.discMove[0]);
            k = 1;
        }
        if (o.promoted) emit Confirmed(o.promotedRound, ConfirmHow.Promoted);
        for (; k < o.nDisc; ++k) {
            _recordDisc(o.disc[k], o.discMove[k]);
        }
    }

    function _recordDisc(Disc memory d, uint256 moveBps) internal {
        uint256 index = discontinuities.length;
        discontinuities.push(d);
        emit Discontinuity(index, d.preJumpRound, d.jumpRound, moveBps);
    }

    function _effective() internal view returns (Guard memory g, Lazy memory o) {
        g = guard;
        _lazy(g, o, uint64(block.timestamp));
    }

    /// @dev base = max(pendingSince + CHALLENGE_WINDOW, holdUntil);
    /// promotableAt = min(max(base, rounds[pendingRound].receivedAt + DELIVERY_LAG_LIMIT), base + DELIVERY_LAG_LIMIT).
    /// The lag term is capped at DELIVERY_LAG_LIMIT past base: replacements within JUMP_BPS of the pending anchor
    /// arriving less than DELIVERY_LAG_LIMIT apart would otherwise postpone promotion forever (C2 review; SPEC 6.6
    /// promotableAt, SP4, R5 and the 31 h disclosure).
    function _promotableAt(Guard memory g) internal view returns (uint64 at) {
        uint64 base = g.pendingSince + WINDOW;
        if (g.holdUntil > base) base = g.holdUntil;
        at = rounds[g.pendingRound].receivedAt + LAG_LIMIT;
        if (at < base) at = base;
        else if (at > base + LAG_LIMIT) at = base + LAG_LIMIT;
    }

    function _face(uint80 id)
        internal
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Round storage rd = rounds[id];
        uint256 t = _clamp(rd.observedAt);
        return (id, int256(uint256(rd.price18) / TO_8), t, t, id);
    }

    /// @dev min(observedAt, block.timestamp): an exposed updatedAt never exceeds the L2 clock (SPEC 6.5).
    function _clamp(uint64 observedAt) internal view returns (uint256) {
        return observedAt < block.timestamp ? observedAt : block.timestamp;
    }

    /// @dev Saturating a - b.
    function _sat(uint64 a, uint64 b) internal pure returns (uint64) {
        return a > b ? a - b : 0;
    }

    /// @dev |x - y| * 1e4 <= JUMP_BPS * y.
    function _within(uint256 x, uint256 y) internal pure returns (bool) {
        uint256 d = x > y ? x - y : y - x;
        return d * BPS <= uint256(JUMP) * y;
    }

    /// @dev |x - y| * 1e4 / y, rounded down; y is never 0 here (every stored price is at least 1e10).
    function _moveBps(uint256 x, uint256 y) internal pure returns (uint256) {
        uint256 d = x > y ? x - y : y - x;
        return d * BPS / y;
    }
}
