// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BellTypes} from "../../l1/BellTypes.sol";
import {IAggregatorV3} from "../../l1/IAggregatorV3.sol";

/// @title IReferenceFeed
/// @notice One feed per (kind, source, subject): a raw AggregatorV3 mirror of every accepted observation plus the
/// confirmed and pending guard state machine of SPEC 6.6 (SPEC 4.4).
interface IReferenceFeed is IAggregatorV3 {
    /// @notice One accepted observation.
    struct Round {
        uint128 price18; // USD 18 decimals
        uint64 observedAt; // L1 source time
        uint64 receivedAt; // L2 block.timestamp at acceptance
        uint64 l1Timestamp; // L1 block.timestamp of the relay tx
        uint64 l1Block;
        uint32 maxTimeDelay;
        uint16 deviationBps;
    }

    /// @notice Result of `push`.
    enum Status {
        Accepted,
        AcceptedPending,
        NotNewer,
        FutureDated,
        OutOfRange,
        DecimalsChanged,
        CodehashChanged,
        ConfigUpdated
    }

    /// @notice How a round became confirmed.
    enum ConfirmHow {
        First,
        WithinJump,
        Correction,
        Promoted
    }

    error NoData();
    error OnlyFactory();
    error NoDiscontinuity(uint256 index);

    /// @notice Chainlink-style event, emitted for every accepted raw round.
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    event RoundAccepted(
        uint80 indexed roundId,
        uint128 price18,
        uint64 observedAt,
        uint64 receivedAt,
        uint64 l1Timestamp,
        uint64 l1Block,
        uint32 maxTimeDelay,
        uint16 deviationBps
    );
    event Confirmed(uint80 indexed roundId, ConfirmHow how);
    event PendingSet(uint80 indexed roundId, uint64 pendingSince, uint64 promotableAt);
    event PendingCleared(uint80 indexed roundId);
    event PromotionReverted(uint80 indexed jumpRound, uint80 preJumpRound, uint80 correctionRound);
    event UpdateIgnored(Status indexed status, uint128 price18, uint64 observedAt);
    event Discontinuity(uint256 indexed index, uint80 preJumpRound, uint80 jumpRound, uint256 moveBps);
    /// @notice The source configuration changed without a new observation (SPEC 6.6): no round is written.
    event ConfigUpdated(uint64 indexed observedAt, uint16 deviationBps, uint32 maxTimeDelay, uint64 l1Block);

    /// @notice The ReferenceFeedFactory that deployed this feed; the only caller of `push`.
    function FACTORY() external view returns (address);
    /// @notice keccak256(abi.encode(KIND, SOURCE, SUBJECT)).
    function FEED_ID() external view returns (bytes32);
    /// @notice 1 (sanity oracle) or 2 (L1 AggregatorV3).
    function KIND() external view returns (uint8);
    /// @notice The L1 source contract.
    function SOURCE() external view returns (address);
    /// @notice The L1 subject token (kind 1) or address(0) (kind 2).
    function SUBJECT() external view returns (address);
    /// @notice 2_000.
    function JUMP_BPS() external pure returns (uint16);
    /// @notice 21_600 seconds.
    function CHALLENGE_WINDOW() external pure returns (uint32);
    /// @notice 3_600 seconds.
    function DELIVERY_LAG_LIMIT() external pure returns (uint32);
    /// @notice 4_000.
    function DISCONTINUITY_BPS() external pure returns (uint16);
    /// @notice 86_400 seconds.
    function PROMOTION_HOLD() external pure returns (uint32);

    /// @notice Id of the latest accepted raw round (0 before the first).
    function latestRound() external view returns (uint80);
    /// @notice An accepted round; reverts NoData for an id that was never accepted.
    function round(uint80 roundId) external view returns (Round memory);
    /// @notice Effective confirmed round, applying a due promotion lazily. Reverts NoData if none.
    function confirmed() external view returns (uint80 roundId, Round memory r);
    /// @notice The pending round, lazy-aware.
    /// promotableAt = max(pendingSince + CHALLENGE_WINDOW, r.receivedAt + DELIVERY_LAG_LIMIT, holdUntil).
    function pending() external view returns (bool exists, uint80 roundId, Round memory r, uint64 promotableAt);
    /// @notice The round that started the pending clock, the clock start and the largest move from the confirmed
    /// price seen in this pending episode; lazy-aware like pending().
    function pendingAnchor() external view returns (uint80 anchorRound, uint64 pendingSince, uint256 maxPendingMoveBps);
    /// @notice Epoch anchor as stored; a due epoch roll is applied at the next push.
    function anchor() external view returns (uint128 anchorPrice, uint64 anchorSince);
    /// @notice Promotion hold, lazy-aware: while active, markets use preJumpRound instead of the promoted round.
    /// moveBps is set at promotion and raised by every confirmation accepted during the hold to its move from the
    /// preJumpRound price; the hold ends as a discontinuity when moveBps >= DISCONTINUITY_BPS.
    function hold()
        external
        view
        returns (bool active, uint80 preJumpRound, uint80 jumpRound, uint64 holdUntil, uint256 moveBps);
    /// @notice receivedAt of the latest accepted round whose delivery lag exceeded DELIVERY_LAG_LIMIT; 0 if none.
    function lastLateReceivedAt() external view returns (uint64);
    /// @notice receivedAt - l1Timestamp of the effective confirmed round (saturating).
    function deliveryLag() external view returns (uint64);
    /// @notice Latest relayed source configuration: set by every accepted round and by a config-only report, which
    /// repeats the latest round's observedAt and price and was read after the configuration in effect, ordered by
    /// (l1Block, configSeq()) (SPEC 6.6). Zeros before the first round.
    function config() external view returns (uint16 deviationBps, uint32 maxTimeDelay, uint64 l1Block);
    /// @notice Delayed-inbox index of the ticket that carried the configuration in effect: with config().l1Block the
    /// key that orders configuration reads, also within one L1 block (SPEC 6.6, BELLSWAP-R2-3). 0 before the first round.
    function configSeq() external view returns (uint64);
    /// @notice rawDecimals pinned at the first accepted report.
    function pinnedDecimals() external view returns (uint8);
    /// @notice sourceCodehash pinned at the first accepted report.
    function pinnedCodehash() external view returns (bytes32);
    /// @notice Count of promotions whose hold ended unreverted with a move of at least DISCONTINUITY_BPS;
    /// lazy-aware.
    function discontinuityCount() external view returns (uint256);
    /// @notice The i-th discontinuity (lazy-aware); reverts NoDiscontinuity if i >= discontinuityCount().
    function discontinuity(uint256 i) external view returns (uint80 preJumpRound, uint80 jumpRound);

    /// @notice Only FACTORY. Never reverts on policy; returns the status and emits events. (l1Block, seq) is the
    /// ticket's L1 block and delayed-inbox index, the lexicographic key that orders configuration reads (SPEC 6.6).
    function push(BellTypes.Report calldata r, uint64 l1Block, uint64 seq, uint64 l1Timestamp) external returns (Status);
    /// @notice Anyone. Writes a due hold end and a due promotion to storage. No other effect.
    function poke() external;
}
