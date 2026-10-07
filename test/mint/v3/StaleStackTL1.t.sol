// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V3FeedBase} from "./V3FeedBase.sol";
import {MarketMath} from "../../../src/mint/MarketMath.sol";
import {IBellMarket} from "../../../src/mint/interfaces/IBellMarket.sol";
import {IReferenceFeed} from "../../../src/reference/l2/interfaces/IReferenceFeed.sol";

/// @title StaleStackTL1Test
/// @notice DESIGN.md test 19 (R2 codex-4), the stale stack row of the bound table, on a TL1 market over the canonical
/// ReferenceFeed. Setup: an edge position (C 6,000 USDG, D 40 bsX, CR 1.5 at 100) and a keeper position at the same CR
/// that holds 40 bsX of inventory, the anchor at 100. The book has no keeper surplus (R2 codex-5), so the aggregate
/// ratio equals the edge ratio: below SETTLE_GCR 10,500 at 144 (1.0417) and 172.8 (0.868), and canTrigger stays false
/// there only because source age keeps liqOk off. The keeper surplus effect is pinned by GlobalTriggerTL1 test 11c. No round arrives for more than LIQ_MAX_AGE (259,200 s); then rounds at 120, 144
/// and 172.8, one per WINDOW (21,600 s), each observed more than LIQ_MAX_AGE before its delivery and relayed with its
/// L1 timestamp at the current time. The feed accepts each backdated round because its observedAt is newer than the
/// latest round's (ReferenceFeed.push), and measures lateness from the L1 timestamp, so none sets lastLateReceivedAt
/// and the market has no LAG_GRACE; each confirms on its epoch roll, while source age keeps liquidation and the global
/// trigger off (BellMarketV2._priceState, liqOk). A fresh round at 172.8 reopens liquidation at the stacked price:
/// the edge position is at CR 0.868 and the insolvent branch books 17.33 percent of its debt as unbacked.
contract StaleStackTL1Test is V3FeedBase {
    uint256 internal constant EDGE_C = 6_000e6;
    uint256 internal constant EDGE_D = 40e18;
    uint256 internal constant LIQ_MAX_AGE = 259_200;

    /// @dev One round at `price18` observed LIQ_MAX_AGE + 1 s before now and delivered now; it must confirm at once.
    function _backdated(uint128 price18) internal {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 obs = uint64(block.timestamp - LIQ_MAX_AGE - 1); // a test timestamp, far below 2^64
        assertGt(obs, lastObs, "observedAt newer than the latest round");
        assertEq(
            uint8(_deliver(price18, obs, uint64(block.timestamp))),
            uint8(IReferenceFeed.Status.Accepted),
            "backdated round confirmed"
        );
    }

    /// @dev The global condition without its liqOk term: totalCollateral * 1e4 < V(totalDebt + unbackedSupply, P) *
    /// SETTLE_GCR (BellMarketV2._globalCondition).
    function _aggregateBelowGcr(uint256 price18) internal view returns (bool) {
        (uint256 tc, uint256 td, uint256 ub,) = m.totals();
        return tc * MarketMath.BPS < MarketMath.value(td + ub, price18) * m.SETTLE_GCR_BPS();
    }

    /// @dev After each backdated round: confirmed at `price18` with no pending round and no hold, no LAG_GRACE, source
    /// age above LIQ_MAX_AGE, liquidation reverts PriceNotUsable, the aggregate is below SETTLE_GCR when `belowGcr` and
    /// canTrigger is false.
    function _assertStaleState(uint256 u, uint128 price18, bool belowGcr) internal {
        (bool pend,,,) = feed.pending();
        (bool held,,,,) = feed.hold();
        assertFalse(pend, "no pending round");
        assertFalse(held, "no hold");
        assertEq(feed.lastLateReceivedAt(), 0, "lateness from the L1 timestamp: not late");
        IBellMarket.PriceView memory pv = m.prices();
        assertEq(pv.confirmed18, price18, "market on the backdated round");
        assertEq(pv.lagGraceUntil, 0, "lagGraceUntil not set");
        assertGt(block.timestamp - pv.observedAt, LIQ_MAX_AGE, "source age above LIQ_MAX_AGE");
        assertFalse(pv.liqOk, "liquidation off");
        vm.prank(keeper);
        vm.expectRevert(IBellMarket.PriceNotUsable.selector);
        m.liquidate(u, type(uint256).max, 0, keeper);
        assertEq(_aggregateBelowGcr(price18), belowGcr, "aggregate against SETTLE_GCR");
        (bool ok,) = m.canTrigger();
        assertFalse(ok, "global trigger off");
    }

    function test_19_staleStack_backdatedRoundsThenFreshRound_badDebt() public {
        _list(75e18);
        uint256 u = _open(user, EDGE_C, EDGE_D);
        uint256 k = _open(keeper, EDGE_C, EDGE_D); // no keeper surplus: the aggregate equals the edge ratio
        _walkTo(100e18);
        assertEq(m.crBps(u, 100e18), 15_000, "edge at 100");
        assertEq(m.crBps(k, 100e18), 15_000, "keeper at the edge");
        assertEq(m.LIQ_MAX_AGE(), LIQ_MAX_AGE);
        (, uint64 since) = _anchor();

        // No round for more than LIQ_MAX_AGE: liquidation is off on source age alone.
        vm.warp(uint256(since) + LIQ_MAX_AGE + WINDOW);
        assertFalse(m.prices().liqOk, "source age above LIQ_MAX_AGE");

        uint128[3] memory steps = [uint128(120e18), 144e18, 172.8e18];
        for (uint256 i; i < steps.length; ++i) {
            if (i > 0) vm.warp(block.timestamp + WINDOW);
            _backdated(steps[i]);
            (uint128 a,) = _anchor();
            assertEq(a, i == 0 ? 100e18 : steps[i - 1], "epoch rolled to the previous confirmation");
            _assertStaleState(u, steps[i], i > 0); // aggregate 1.25 at 120, 1.0417 at 144, 0.868 at 172.8
        }
        assertEq(feed.discontinuityCount(), 0, "no discontinuity");

        // A fresh round at 172.8 reopens liquidation at the stacked price.
        vm.warp(block.timestamp + 1);
        _confirm(172.8e18);
        assertTrue(m.prices().liqOk, "fresh round: liqOk");
        assertEq(m.crBps(u, 172.8e18), 8_680, "edge at 0.868");
        (bool ok, IBellMarket.SettleReason reason) = m.canTrigger();
        assertTrue(ok, "liqOk back: the global trigger fires on the same aggregate");
        assertEq(uint8(reason), uint8(IBellMarket.SettleReason.GlobalUndercollateralised));
        MarketMath.Liq memory l = _liquidate(keeper, u, type(uint256).max);
        assertTrue(l.full, "insolvent branch");
        assertEq(l.seize, EDGE_C, "all collateral");
        assertApproxEqAbs(l.badDebt * 10_000 / EDGE_D, 1_733, 1, "17.33 percent of the debt unbacked");
        assertEq(_unbacked(), l.badDebt);
    }
}
