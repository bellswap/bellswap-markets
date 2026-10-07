// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMarketReferenceFeed, IMarketReferenceFactory} from "../../../src/mint/interfaces/IMarketReference.sol";

/// Test double of ReferenceFeed (SPEC 4.4) exposing the views the minting layer reads. The guard state
/// machine is not modelled: tests set the confirmed round, pending flag, hold, late receipt and
/// discontinuities directly, which lets handlers walk, jump, stall, lag and split at will.
contract MockMarketFeed is IMarketReferenceFeed {
    error NoData();
    error NoDiscontinuity(uint256 index);

    uint8 public KIND;
    /// The reference factory that "deployed" this feed; set by MockMarketRefFactory.register.
    address public FACTORY;
    uint80 internal _latest;
    uint80 public confirmedRound;
    mapping(uint80 => Round) internal _rounds;

    bool public pendingExists;
    uint80 public pendingRound;

    bool public holdActive;
    uint80 public holdPre;
    uint80 public holdJump;

    uint64 internal _lastLate;
    uint80[2][] internal _disc;
    /// Latest relayed configuration (SPEC 6.6): set by every accepted round and by setConfig (a config-only report).
    uint16 internal _cfgDev;
    /// When true every view the market reads reverts NoData (models any feed failure).
    bool public broken;

    modifier notBroken() {
        if (broken) revert NoData();
        _;
    }

    constructor(uint8 kind) {
        KIND = kind;
    }

    // ---- setters

    function setFactory(address f) external {
        FACTORY = f;
    }

    /// Accept a new raw round and confirm it (a WithinJump step), clearing any pending round.
    function post(uint128 price18, uint64 observedAt, uint16 deviationBps) public returns (uint80 id) {
        id = _accept(price18, observedAt, deviationBps);
        confirmedRound = id;
        pendingExists = false;
        pendingRound = 0;
    }

    /// Post at block.timestamp with deviation 1_000.
    function postNow(uint128 price18) external returns (uint80) {
        return post(price18, uint64(block.timestamp), 1_000);
    }

    /// Accept a new raw round that goes pending.
    function postPending(uint128 price18, uint64 observedAt) external returns (uint80 id) {
        id = _accept(price18, observedAt, 1_000);
        pendingExists = true;
        pendingRound = id;
    }

    function clearPending() external {
        pendingExists = false;
        pendingRound = 0;
    }

    /// Promote the pending round and start a hold that keeps markets on the pre-jump round.
    function promoteWithHold() external {
        holdActive = true;
        holdPre = confirmedRound;
        holdJump = pendingRound;
        confirmedRound = pendingRound;
        pendingExists = false;
        pendingRound = 0;
    }

    /// End the hold; with recordDisc, record a discontinuity (pre-jump, jump).
    function endHold(bool recordDisc) external {
        if (recordDisc) _disc.push([holdPre, holdJump]);
        holdActive = false;
        holdPre = 0;
        holdJump = 0;
    }

    /// Record a discontinuity directly.
    function addDiscontinuity(uint80 pre, uint80 jump) external {
        _disc.push([pre, jump]);
    }

    /// Models a config-only report (SPEC 6.6): changes the configuration, no round.
    function setConfig(uint16 deviationBps) external {
        _cfgDev = deviationBps;
    }

    function setLastLate(uint64 t) external {
        _lastLate = t;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function setKind(uint8 k) external {
        KIND = k;
    }

    function _accept(uint128 price18, uint64 observedAt, uint16 deviationBps) internal returns (uint80 id) {
        id = ++_latest;
        _rounds[id] = Round({
            price18: price18,
            observedAt: observedAt,
            receivedAt: uint64(block.timestamp),
            l1Timestamp: observedAt,
            l1Block: 0,
            maxTimeDelay: 172_800,
            deviationBps: deviationBps
        });
        _cfgDev = deviationBps;
    }

    // ---- IMarketReferenceFeed

    function round(uint80 roundId) external view notBroken returns (Round memory) {
        if (roundId == 0 || roundId > _latest) revert NoData();
        return _rounds[roundId];
    }

    function confirmed() external view notBroken returns (uint80, Round memory) {
        if (confirmedRound == 0) revert NoData();
        return (confirmedRound, _rounds[confirmedRound]);
    }

    function pending() external view notBroken returns (bool, uint80, Round memory r, uint64) {
        if (pendingExists) r = _rounds[pendingRound];
        return (pendingExists, pendingRound, r, 0);
    }

    function hold() external view notBroken returns (bool, uint80, uint80, uint64, uint256) {
        return (holdActive, holdPre, holdJump, 0, 0);
    }

    function lastLateReceivedAt() external view notBroken returns (uint64) {
        return _lastLate;
    }

    function config() external view notBroken returns (uint16, uint32, uint64) {
        return (_cfgDev, 172_800, 0);
    }

    function latestRound() external view notBroken returns (uint80) {
        return _latest;
    }

    function discontinuityCount() external view notBroken returns (uint256) {
        return _disc.length;
    }

    function discontinuity(uint256 i) external view notBroken returns (uint80, uint80) {
        if (i >= _disc.length) revert NoDiscontinuity(i);
        return (_disc[i][0], _disc[i][1]);
    }
}

/// Test double of ReferenceFeedFactory (SPEC 4.3): a registry of canonical feeds and a view registry.
contract MockMarketRefFactory is IMarketReferenceFactory {
    mapping(address => bool) public isFeed;
    mapping(bytes32 => address) internal _views;
    uint256 public createViewCalls;

    function register(address feed) external {
        isFeed[feed] = true;
        MockMarketFeed(feed).setFactory(address(this));
    }

    function createView(address feed, uint32 maxAge) external returns (address v) {
        ++createViewCalls;
        bytes32 k = keccak256(abi.encode(feed, maxAge));
        v = _views[k];
        if (v == address(0)) {
            v = address(uint160(uint256(keccak256(abi.encode("view", feed, maxAge)))));
            _views[k] = v;
        }
    }

    function viewOf(address feed, uint32 maxAge) external view returns (address) {
        return _views[keccak256(abi.encode(feed, maxAge))];
    }
}
