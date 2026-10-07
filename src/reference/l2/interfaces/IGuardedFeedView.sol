// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAggregatorV3} from "../../l1/IAggregatorV3.sol";

/// @title IGuardedFeedView
/// @notice AggregatorV3 over the confirmed observation of one ReferenceFeed, with an optional age limit (SPEC 4.5).
interface IGuardedFeedView is IAggregatorV3 {
    error NoData();
    error Stale(uint256 observedAt, uint32 maxAge);
    error NoHistory(uint80 roundId);

    /// @notice The ReferenceFeedFactory that deployed this view.
    function FACTORY() external view returns (address);
    /// @notice The ReferenceFeed this view reads.
    function FEED() external view returns (address);
    /// @notice Maximum age in seconds of the confirmed observation; 0 = never revert on age.
    function MAX_AGE() external view returns (uint32);
    /// @notice True while the feed has a pending round or an active promotion hold.
    function isPending() external view returns (bool);
    /// @notice The feed's deliveryLag() of its effective confirmed round.
    function deliveryLag() external view returns (uint64);
}
