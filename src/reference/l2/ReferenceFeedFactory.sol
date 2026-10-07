// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BellTypes} from "../l1/BellTypes.sol";
import {AddressAliasHelper} from "../../vendor/AddressAliasHelper.sol";
import {IReferenceFeedFactory} from "./interfaces/IReferenceFeedFactory.sol";
import {IReferenceFeed} from "./interfaces/IReferenceFeed.sol";
import {ReferenceFeed} from "./ReferenceFeed.sol";
import {GuardedFeedView} from "./GuardedFeedView.sol";

/// @title ReferenceFeedFactory
/// @notice The only L2 entry point for relayed reports (SPEC 4.3). Authenticates the aliased L1 relay (SPEC 6.4)
/// and routes each report to its existing feed. Feeds and views are deployed only by the open createFeed and
/// createView, never inside report, so a ticket's L2 gas stays predictable.
/// No owner, no admin function, no proxy, no fee path (SPEC 4 contract rules).
contract ReferenceFeedFactory is IReferenceFeedFactory {
    uint32 internal constant VIEW_AGE_LIMIT = 2_592_000;

    /// @inheritdoc IReferenceFeedFactory
    address public immutable L1_RELAY;
    /// @inheritdoc IReferenceFeedFactory
    address public immutable L1_RELAY_ALIAS;
    /// @inheritdoc IReferenceFeedFactory
    address public immutable ONDO_ORACLE_L1;

    /// @inheritdoc IReferenceFeedFactory
    mapping(bytes32 => address) public feedOf;
    /// @inheritdoc IReferenceFeedFactory
    mapping(address => bool) public isFeed;
    /// @dev key keccak256(abi.encode(feed, maxAge)) (SPEC 4.3 storage `viewOf`).
    mapping(bytes32 => address) internal viewByKey;
    /// @inheritdoc IReferenceFeedFactory
    mapping(address => bool) public isView;
    address[] internal feeds;

    /// @param l1Relay The BellswapRelay on the parent chain.
    /// @param ondoOracleL1 The sanity oracle on the parent chain; must equal BellswapRelay.ONDO_ORACLE().
    constructor(address l1Relay, address ondoOracleL1) {
        L1_RELAY = l1Relay;
        L1_RELAY_ALIAS = AddressAliasHelper.applyL1ToL2Alias(l1Relay);
        ONDO_ORACLE_L1 = ondoOracleL1;
    }

    /// @inheritdoc IReferenceFeedFactory
    function MAX_VIEW_AGE() external pure returns (uint32) {
        return VIEW_AGE_LIMIT;
    }

    /// @inheritdoc IReferenceFeedFactory
    function report(uint64 l1Block, uint64 seq, uint64 l1Timestamp, BellTypes.Report[] calldata reports) external {
        if (msg.sender != L1_RELAY_ALIAS) revert NotL1Relay(msg.sender);
        uint64 lag = block.timestamp > l1Timestamp ? uint64(block.timestamp - l1Timestamp) : 0;
        emit BatchReceived(l1Block, l1Timestamp, reports.length, lag);
        for (uint256 i; i < reports.length; ++i) {
            BellTypes.Report calldata r = reports[i];
            bytes32 id = BellTypes.feedId(r.kind, r.source, r.subject);
            (bool ok, FactoryIgnore why) = _reportRoute(r.kind, r.source, r.subject);
            if (!ok) {
                emit ReportIgnored(id, why, r.observedAt);
                continue;
            }
            address feed = feedOf[id];
            if (feed == address(0)) {
                emit ReportIgnored(id, FactoryIgnore.NoFeed, r.observedAt);
                continue;
            }
            IReferenceFeed(feed).push(r, l1Block, seq, l1Timestamp);
        }
    }

    /// @inheritdoc IReferenceFeedFactory
    /// @dev kind 2 also requires source != 0 (BadSource).
    function createFeed(uint8 kind, address source, address subject) external returns (address feed) {
        bytes32 id = BellTypes.feedId(kind, source, subject);
        feed = feedOf[id];
        if (feed != address(0)) return feed;
        if (kind == BellTypes.KIND_ONDO) {
            if (source != ONDO_ORACLE_L1) revert BadSource(source);
            if (subject == address(0)) revert BadSubject(subject);
        } else if (kind == BellTypes.KIND_AGGREGATOR) {
            if (source == address(0)) revert BadSource(source);
            if (subject != address(0)) revert BadSubject(subject);
        } else {
            revert BadKind(kind);
        }
        feed = address(new ReferenceFeed{salt: id}(kind, source, subject));
        feedOf[id] = feed;
        isFeed[feed] = true;
        feeds.push(feed);
        emit FeedCreated(id, feed, kind, source, subject);
    }

    /// @inheritdoc IReferenceFeedFactory
    function createView(address feed, uint32 maxAge) external returns (address view_) {
        if (!isFeed[feed]) revert NotFeed(feed);
        if (maxAge > VIEW_AGE_LIMIT) revert BadMaxAge(maxAge);
        bytes32 key = keccak256(abi.encode(feed, maxAge));
        view_ = viewByKey[key];
        if (view_ != address(0)) return view_;
        view_ = address(new GuardedFeedView{salt: key}(feed, maxAge));
        viewByKey[key] = view_;
        isView[view_] = true;
        emit ViewCreated(view_, feed, maxAge);
    }

    /// @inheritdoc IReferenceFeedFactory
    function feedIdOf(uint8 kind, address source, address subject) external pure returns (bytes32) {
        return BellTypes.feedId(kind, source, subject);
    }

    /// @inheritdoc IReferenceFeedFactory
    function computeFeedAddress(uint8 kind, address source, address subject) external view returns (address) {
        bytes32 initHash =
            keccak256(abi.encodePacked(type(ReferenceFeed).creationCode, abi.encode(kind, source, subject)));
        return _create2(BellTypes.feedId(kind, source, subject), initHash);
    }

    /// @inheritdoc IReferenceFeedFactory
    function computeViewAddress(address feed, uint32 maxAge) external view returns (address) {
        bytes32 initHash = keccak256(abi.encodePacked(type(GuardedFeedView).creationCode, abi.encode(feed, maxAge)));
        return _create2(keccak256(abi.encode(feed, maxAge)), initHash);
    }

    /// @inheritdoc IReferenceFeedFactory
    function viewOf(address feed, uint32 maxAge) external view returns (address) {
        return viewByKey[keccak256(abi.encode(feed, maxAge))];
    }

    /// @inheritdoc IReferenceFeedFactory
    function feedCount() external view returns (uint256) {
        return feeds.length;
    }

    /// @inheritdoc IReferenceFeedFactory
    /// @dev Reverts with a panic for index >= feedCount().
    function feedAt(uint256 index) external view returns (address) {
        return feeds[index];
    }

    /// @dev Routing checks of `report`, same rules as createFeed but returning the ignore reason.
    function _reportRoute(uint8 kind, address source, address subject)
        internal
        view
        returns (bool ok, FactoryIgnore why)
    {
        if (kind == BellTypes.KIND_ONDO) {
            if (source != ONDO_ORACLE_L1) return (false, FactoryIgnore.BadSource);
            if (subject == address(0)) return (false, FactoryIgnore.BadSubject);
            return (true, FactoryIgnore.BadKind);
        }
        if (kind == BellTypes.KIND_AGGREGATOR) {
            if (subject != address(0)) return (false, FactoryIgnore.BadSubject);
            return (true, FactoryIgnore.BadKind);
        }
        return (false, FactoryIgnore.BadKind);
    }

    function _create2(bytes32 salt, bytes32 initHash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }
}
