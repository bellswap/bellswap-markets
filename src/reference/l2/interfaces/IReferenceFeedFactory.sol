// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BellTypes} from "../../l1/BellTypes.sol";

/// @title IReferenceFeedFactory
/// @notice The only L2 entry point for relayed reports; deploys ReferenceFeeds and GuardedFeedViews (SPEC 4.3).
interface IReferenceFeedFactory {
    /// @notice Why `report` skipped one report.
    enum FactoryIgnore {
        BadKind,
        BadSource,
        BadSubject,
        NoFeed
    }

    error NotL1Relay(address sender);
    error BadKind(uint8 kind);
    error BadSource(address source);
    /// @dev Not in SPEC 4.3; createFeed needs an error for a bad subject (listed as a deviation).
    error BadSubject(address subject);
    error NotFeed(address feed);
    error BadMaxAge(uint32 maxAge);

    event FeedCreated(
        bytes32 indexed feedId, address indexed feed, uint8 kind, address indexed source, address subject
    );
    event ViewCreated(address indexed view_, address indexed feed, uint32 maxAge);
    event ReportIgnored(bytes32 indexed feedId, FactoryIgnore reason, uint64 observedAt);
    event BatchReceived(uint64 indexed l1Block, uint64 l1Timestamp, uint256 count, uint64 lag);

    /// @notice The L1 BellswapRelay.
    function L1_RELAY() external view returns (address);
    /// @notice AddressAliasHelper.applyL1ToL2Alias(L1_RELAY), the only accepted `report` sender.
    function L1_RELAY_ALIAS() external view returns (address);
    /// @notice The L1 sanity oracle; the only kind 1 source. Must equal BellswapRelay.ONDO_ORACLE().
    function ONDO_ORACLE_L1() external view returns (address);
    /// @notice 2_592_000 (30 days); a view maxAge of 0 means no age check.
    function MAX_VIEW_AGE() external pure returns (uint32);

    /// @notice Only msg.sender == L1_RELAY_ALIAS. Never reverts for that sender except out of gas. `seq` is the
    /// ticket's delayed-inbox index (BellswapRelay reads it from the Bridge), passed to every push with l1Block.
    function report(uint64 l1Block, uint64 seq, uint64 l1Timestamp, BellTypes.Report[] calldata reports) external;
    /// @notice Anyone; idempotent. kind 1 requires source == ONDO_ORACLE_L1 and subject != 0; kind 2 requires
    /// subject == 0.
    function createFeed(uint8 kind, address source, address subject) external returns (address feed);
    /// @notice Anyone; idempotent. feed must satisfy isFeed.
    function createView(address feed, uint32 maxAge) external returns (address view_);

    /// @notice BellTypes.feedId(kind, source, subject).
    function feedIdOf(uint8 kind, address source, address subject) external pure returns (bytes32);
    /// @notice CREATE2 address of the feed for (kind, source, subject), created or not.
    function computeFeedAddress(uint8 kind, address source, address subject) external view returns (address);
    /// @notice CREATE2 address of the view for (feed, maxAge), created or not.
    function computeViewAddress(address feed, uint32 maxAge) external view returns (address);
    /// @notice The feed for `feedId`; 0 if not created.
    function feedOf(bytes32 feedId) external view returns (address);
    /// @notice The view for (feed, maxAge); 0 if not created.
    function viewOf(address feed, uint32 maxAge) external view returns (address);
    /// @notice True for every feed this factory created.
    function isFeed(address feed) external view returns (bool);
    /// @notice True for every view this factory created.
    function isView(address view_) external view returns (bool);
    /// @notice Number of feeds created.
    function feedCount() external view returns (uint256);
    /// @notice The feed at `index` in creation order.
    function feedAt(uint256 index) external view returns (address);
}
