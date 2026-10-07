// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MintBase} from "../MintBase.sol";
import {BellMarket} from "../../../src/mint/BellMarket.sol";
import {MockMarketFeed} from "../mocks/MockMarketFeed.sol";
import {MintHandler} from "./MintHandler.sol";

/// Deterministic walk through every handler action, so each per-call assertion path runs at least once
/// regardless of how the invariant fuzzer distributes calls.
contract HandlerSmokeTest is MintBase {
    MintHandler internal h;

    function setUp() public override {
        super.setUp();
        BellMarket a = listLive(feed, 0);
        MockMarketFeed fb = newFeed(50e18);
        BellMarket b = listLive(fb, 1);
        feed.postNow(P0);
        h = new MintHandler(usdg, a, b, feed, fb, [alice, bob, carol, liquidator]);
    }

    function _n(string memory k) internal view returns (uint256) {
        return h.calls(keccak256(bytes(k)));
    }

    function test_everyActionPath() public {
        // Positions on both markets, with and without debt.
        h.open(0, 0, 4_400e6, 1); // alice, mints
        h.open(0, 1, 2_000e6, 2); // bob, mints
        h.open(0, 2, 500e6, 3); // carol, collateral only (d % 3 == 0)
        h.open(1, 0, 3_000e6, 1);
        assertGe(_n("open"), 4);
        h.deposit(0, 3, 2, 10e6);
        h.mint(0, 2, 5e18);
        h.withdraw(0, 2, 1e6);
        h.transferTokens(0, 0, 3, 1e18);
        h.repay(0, 3, 0, 1e17);
        // Price x3: debt positions fall below 250 percent.
        h.feedJump(0, 30_000);
        h.liquidate(0, 0, type(uint256).max);
        h.liquidate(0, 1, 1e18);
        assertGe(_n("liquidate"), 1, "liquidate path");
        h.feedPending(0, 30_000);
        h.feedCorrect(0);
        h.feedPending(0, 30_000);
        h.feedPromote(0);
        h.feedEndHold(0, 1);
        h.feedLate(0);
        h.feedBacklog(1);
        h.usdgSwitch(0);
        h.usdgSwitch(2);
        h.close(1, 0);
        // Stale settlement on market 1: 7 d + 1 s, arm, backlog voids, re-arm, 24 h, trigger.
        h.warp(0); // multiple of 10: long warp
        vm.warp(block.timestamp + 8 days);
        h.arm(1);
        h.feedBacklog(1);
        h.arm(1);
        vm.warp(block.timestamp + 1 days);
        h.trigger(1);
        assertGe(_n("arm"), 2, "arm path");
        assertGe(_n("trigger"), 1, "trigger path");
        h.process(1, 0, 1, 2);
        h.finalize(1);
        h.redeem(1, 0, 1e18);
        h.claimExcess(1, 0);
        assertGe(_n("finalize"), 1);
        // Market 0: Global or Discontinuity trigger.
        h.trigger(0);
    }
}
