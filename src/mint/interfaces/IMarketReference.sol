// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IMarketReferenceFeed
/// @notice The subset of IReferenceFeed (SPEC 4.4) that the minting layer reads. The Round layout is
/// ABI-identical to IReferenceFeed.Round, so a canonical ReferenceFeed satisfies this interface.
interface IMarketReferenceFeed {
    struct Round {
        uint128 price18; // USD 18 decimals
        uint64 observedAt; // L1 source time
        uint64 receivedAt; // L2 block.timestamp at acceptance
        uint64 l1Timestamp; // L1 block.timestamp of the relay tx
        uint64 l1Block;
        uint32 maxTimeDelay;
        uint16 deviationBps;
    }

    /// @notice 1 for a feed backed by the immutable sanity oracle, 2 for a relayed aggregator.
    function KIND() external view returns (uint8);
    /// @notice The ReferenceFeedFactory that deployed this feed.
    function FACTORY() external view returns (address);
    /// @notice Latest accepted raw round id.
    function latestRound() external view returns (uint80);
    /// @notice An accepted round.
    function round(uint80 roundId) external view returns (Round memory);
    /// @notice Effective confirmed round, lazy-aware. Reverts NoData if none.
    function confirmed() external view returns (uint80 roundId, Round memory r);
    /// @notice The pending round, lazy-aware.
    function pending() external view returns (bool exists, uint80 roundId, Round memory r, uint64 promotableAt);
    /// @notice The promotion hold, lazy-aware.
    function hold()
        external
        view
        returns (bool active, uint80 preJumpRound, uint80 jumpRound, uint64 holdUntil, uint256 moveBps);
    /// @notice Latest relayed source configuration, including config-only updates (SPEC 6.6, 8.2).
    function config() external view returns (uint16 deviationBps, uint32 maxTimeDelay, uint64 l1Block);
    /// @notice receivedAt of the latest late round; 0 if none.
    function lastLateReceivedAt() external view returns (uint64);
    /// @notice Number of recorded discontinuities, lazy-aware.
    function discontinuityCount() external view returns (uint256);
    /// @notice The i-th discontinuity.
    function discontinuity(uint256 i) external view returns (uint80 preJumpRound, uint80 jumpRound);
}

/// @title IMarketReferenceFactory
/// @notice The subset of IReferenceFeedFactory (SPEC 4.3) that the minting layer calls.
interface IMarketReferenceFactory {
    /// @notice True iff feed was deployed by this factory.
    function isFeed(address feed) external view returns (bool);
    /// @notice Anyone; idempotent. Deploys or returns GuardedFeedView(feed, maxAge).
    function createView(address feed, uint32 maxAge) external returns (address view_);
    /// @notice The GuardedFeedView of (feed, maxAge), or 0 if not created.
    function viewOf(address feed, uint32 maxAge) external view returns (address);
}
