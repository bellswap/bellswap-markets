// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IGuardedFeedView} from "./interfaces/IGuardedFeedView.sol";
import {IReferenceFeed} from "./interfaces/IReferenceFeed.sol";
import {ReferenceDescription} from "./ReferenceDescription.sol";

/// @title GuardedFeedView
/// @notice AggregatorV3 over the effective confirmed observation of one ReferenceFeed with an optional age limit
/// (SPEC 4.5). Deployed only by ReferenceFeedFactory.createView. Views only; no storage, no events.
contract GuardedFeedView is IGuardedFeedView {
    uint256 internal constant TO_8 = 1e10;

    /// @inheritdoc IGuardedFeedView
    address public immutable FACTORY;
    /// @inheritdoc IGuardedFeedView
    address public immutable FEED;
    /// @inheritdoc IGuardedFeedView
    uint32 public immutable MAX_AGE;

    /// @param feed A ReferenceFeed created by the deploying factory (checked there).
    /// @param maxAge Age limit in seconds, at most MAX_VIEW_AGE (checked there); 0 disables the age check.
    constructor(address feed, uint32 maxAge) {
        FACTORY = msg.sender;
        FEED = feed;
        MAX_AGE = maxAge;
    }

    /// @notice Always 8.
    function decimals() external pure returns (uint8) {
        return 8;
    }

    /// @notice Always 1.
    function version() external pure returns (uint256) {
        return 1;
    }

    /// @notice "Bellswap Guarded k<kind> 0x<source> 0x<subject> / USD" (the FEED description tail).
    function description() external view returns (string memory) {
        IReferenceFeed f = IReferenceFeed(FEED);
        return string.concat("Bellswap Guarded ", ReferenceDescription.tail(f.KIND(), f.SOURCE(), f.SUBJECT()));
    }

    /// @notice (cRound, int256(c.price18 / 1e10), t, t, cRound) with t = min(c.observedAt, block.timestamp).
    /// Reverts NoData without a confirmed round and Stale when MAX_AGE != 0 and the saturating age of
    /// c.observedAt exceeds MAX_AGE.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (uint80 id, IReferenceFeed.Round memory c) = IReferenceFeed(FEED).confirmed();
        return _face(id, c);
    }

    /// @notice Only the current confirmed round id, else NoHistory; same checks and shape as latestRoundData.
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (uint80 id, IReferenceFeed.Round memory c) = IReferenceFeed(FEED).confirmed();
        if (roundId != id) revert NoHistory(roundId);
        return _face(id, c);
    }

    /// @inheritdoc IGuardedFeedView
    function isPending() external view returns (bool) {
        IReferenceFeed f = IReferenceFeed(FEED);
        (bool p,,,) = f.pending();
        if (p) return true;
        (bool h,,,,) = f.hold();
        return h;
    }

    /// @inheritdoc IGuardedFeedView
    function deliveryLag() external view returns (uint64) {
        return IReferenceFeed(FEED).deliveryLag();
    }

    function _face(uint80 id, IReferenceFeed.Round memory c)
        internal
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 age = block.timestamp > c.observedAt ? block.timestamp - c.observedAt : 0;
        if (MAX_AGE != 0 && age > MAX_AGE) revert Stale(c.observedAt, MAX_AGE);
        uint256 t = c.observedAt < block.timestamp ? c.observedAt : block.timestamp;
        return (id, int256(uint256(c.price18) / TO_8), t, t, id);
    }
}
