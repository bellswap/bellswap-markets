// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V3FeedBase} from "./V3FeedBase.sol";
import {MarketMath} from "../../../src/mint/MarketMath.sol";
import {IBellMarket} from "../../../src/mint/interfaces/IBellMarket.sol";
import {IReferenceFeed} from "../../../src/reference/l2/interfaces/IReferenceFeed.sol";

/// @title FeedPathsTL1Test
/// @notice DESIGN.md tests 5 to 10 on a TL1 market (BellMarketFactoryV3, BellMarketV2 code) over the canonical
/// ReferenceFeed: the price paths the feed allows between two keeper actions and the MarketMath branch each leaves an
/// edge position in (DESIGN.md, bound table). The edge position is C 6,000 USDG and D 40 bsX, opened at 75 (CR 2.0)
/// and at CR 1.5 = LIQ_CR at price 100; C is large enough that each partial result stays above MIN_COLLATERAL.
contract FeedPathsTL1Test is V3FeedBase {
    uint256 internal constant EDGE_C = 6_000e6;
    uint256 internal constant EDGE_D = 40e18;

    /// @dev Lists TL1 at 75, opens the edge position and a keeper position holding `keeperD` bsX of inventory, then
    /// walks the price to `edgeAt` (anchor there, epoch starting now).
    function _book(uint256 keeperC, uint256 keeperD, uint128 edgeAt) internal returns (uint256 u, uint256 k) {
        _list(75e18);
        u = _open(user, EDGE_C, EDGE_D);
        k = _open(keeper, keeperC, keeperD);
        _walkTo(edgeAt);
    }

    // ------------------------------------------------------------------ test 5

    /// Test 5: a +27.8 percent post goes pending, mint is blocked, the market keeps P through the challenge window,
    /// the promotion and the 86,400 s hold, steps at hold end, and the edge position liquidates in the partial branch
    /// with the full bonus and zero bad debt (repays 82.3 percent of its debt, DESIGN.md worked numbers).
    function test_5_jump278_pendingThenHold_edgeLiquidatedWithoutBadDebt() public {
        (uint256 u, uint256 k) = _book(16_000e6, EDGE_D, 100e18);
        assertEq(m.crBps(u, 100e18), 15_000, "edge at 100");

        assertEq(uint8(_post(127.8e18)), uint8(IReferenceFeed.Status.AcceptedPending), "outside 20 percent: pending");
        IBellMarket.PriceView memory pv = m.prices();
        assertTrue(pv.pending);
        assertEq(pv.confirmed18, 100e18, "market keeps P while pending");
        assertEq(uint8(pv.mintBlock), uint8(IBellMarket.MintBlock.Pending), "mint blocked");
        vm.prank(keeper);
        vm.expectRevert(IBellMarket.PriceNotUsable.selector);
        m.mint(k, 1e18, keeper);

        (,,, uint64 promotableAt) = feed.pending();
        vm.warp(promotableAt);
        (bool held,,, uint64 holdUntil,) = feed.hold();
        assertTrue(held, "promoted and held");
        assertEq(m.prices().confirmed18, 100e18, "market keeps P through the hold");
        assertFalse(m.prices().mintOk, "mint closed during the hold");

        vm.warp(holdUntil - 1);
        vm.prank(keeper);
        vm.expectRevert(IBellMarket.NotLiquidatable.selector);
        m.liquidate(u, type(uint256).max, 0, keeper);

        vm.warp(holdUntil);
        assertEq(feed.discontinuityCount(), 0, "27.8 percent is no discontinuity");
        assertEq(m.prices().confirmed18, 127.8e18, "market steps at hold end");
        assertEq(m.crBps(u, 127.8e18), 11_737, "edge at 1.1737");
        MarketMath.Liq memory l = _liquidate(keeper, u, type(uint256).max);
        _assertPartialFullBonus(u, l);
        assertApproxEqRel(l.repay, EDGE_D * 8_233 / 10_000, 0.001e18, "repays 82.3 percent of the debt");
        assertEq(_unbacked(), 0, "zero bad debt");
    }

    // ------------------------------------------------------------------ test 6

    /// Test 6a: the hold ceiling from below. A +25 percent jump is promoted; an in-hold confirmation at 139.99 raises
    /// the hold move to 3,999 bps (the running maximum); at hold end the market steps by 39.99 percent with no
    /// discontinuity and the edge position (CR 1.0715) liquidates in the partial branch with the full bonus.
    function test_6a_holdMove3999_stepsWithFullBonus() public {
        (uint256 u,) = _book(16_000e6, EDGE_D, 100e18);
        uint64 holdUntil = _promote(125e18);
        (,,,, uint256 mv) = feed.hold();
        assertEq(mv, 2_500);
        vm.warp(block.timestamp + 60);
        _confirm(139.99e18);
        (,,,, mv) = feed.hold();
        assertEq(mv, 3_999, "in-hold confirmation raises the hold move");
        assertEq(m.prices().confirmed18, 100e18, "market on the pre-jump round");

        vm.warp(holdUntil);
        assertEq(feed.discontinuityCount(), 0, "below 4,000 bps: no discontinuity");
        assertEq(m.prices().confirmed18, 139.99e18);
        assertEq(m.crBps(u, 139.99e18), 10_715, "edge at 1.0715");
        MarketMath.Liq memory l = _liquidate(keeper, u, type(uint256).max);
        _assertPartialFullBonus(u, l);
        assertEq(_unbacked(), 0, "zero bad debt");
    }

    /// Test 6b: the hold ceiling. The in-hold confirmation at 140.00 makes the hold move 4,000 bps; hold end records a
    /// discontinuity, liquidation closes and the market settles at the pre-jump price P = 100.
    function test_6b_holdMove4000_discontinuitySettlesAtP() public {
        (uint256 u,) = _book(16_000e6, EDGE_D, 100e18);
        uint64 holdUntil = _promote(125e18);
        vm.warp(block.timestamp + 60);
        _confirm(140e18);
        (,,,, uint256 mv) = feed.hold();
        assertEq(mv, 4_000);

        vm.warp(holdUntil);
        assertEq(feed.discontinuityCount(), 1, "4,000 bps: discontinuity at hold end");
        assertFalse(m.prices().liqOk, "liquidation closed");
        vm.prank(keeper);
        vm.expectRevert(IBellMarket.PriceNotUsable.selector);
        m.liquidate(u, type(uint256).max, 0, keeper);
        (bool ok, IBellMarket.SettleReason reason) = m.canTrigger();
        assertTrue(ok);
        assertEq(uint8(reason), uint8(IBellMarket.SettleReason.Discontinuity));
        m.triggerSettlement();
        (IBellMarket.SettleReason r, uint256 pEnd,,,,,) = m.settlement();
        assertEq(uint8(r), uint8(IBellMarket.SettleReason.Discontinuity));
        assertEq(pEnd, 100e18, "settles at the pre-jump price");
        assertEq(_unbacked(), 0);
    }

    // ------------------------------------------------------------------ test 7

    /// Test 7: two +19 percent direct posts six minutes apart across an epoch roll (the second post rolls the anchor
    /// to the first), the keeper skips the first: the edge position ends at 1.059 and liquidates in the partial
    /// branch with the full bonus.
    function test_7_twoDirectPostsAcrossRoll_keeperSkipsOne_partial() public {
        (uint256 u,) = _book(16_000e6, EDGE_D, 100e18);
        (, uint64 since) = _anchor();
        vm.warp(uint256(since) + WINDOW - 180);
        _confirm(119e18);
        assertLt(m.crBps(u, 119e18), 15_000, "liquidatable after the first post; the keeper skips it");

        vm.warp(uint256(since) + WINDOW + 180);
        _confirm(141.61e18);
        (uint128 a,) = _anchor();
        assertEq(a, 119e18, "the second post rolled the epoch to the first");
        assertEq(m.crBps(u, 141.61e18), 10_592, "edge at 1.059");
        MarketMath.Liq memory l = _liquidate(keeper, u, type(uint256).max);
        _assertPartialFullBonus(u, l);
        assertEq(_unbacked(), 0);
    }

    // ------------------------------------------------------------------ test 8

    /// Test 8 (B-H5): three posts inside one epoch, anchor A = 125: 0.8A (edge at 1.5), 0.96A, 1.152A, 1.2A, each
    /// within 20 percent of the confirmed price and of A, keeper off. The edge position ends at CR 1.0: full solvent
    /// branch, all collateral for all debt, no bonus, zero bad debt.
    function test_8_threePostBurstInOneEpoch_fullSolventNoBadDebt() public {
        (uint256 u,) = _book(16_000e6, EDGE_D, 100e18);
        _walkTo(125e18);
        vm.warp(block.timestamp + 60);
        _confirm(100e18);
        assertEq(m.crBps(u, 100e18), 15_000, "edge at 0.8A");
        vm.warp(block.timestamp + 60);
        _confirm(120e18);
        vm.warp(block.timestamp + 60);
        _confirm(144e18);
        vm.warp(block.timestamp + 60);
        _confirm(150e18);
        (uint128 a,) = _anchor();
        assertEq(a, 125e18, "one epoch");
        assertEq(m.crBps(u, 150e18), 10_000, "edge at 1.0");

        MarketMath.Liq memory l = _liquidate(keeper, u, type(uint256).max);
        assertTrue(l.full, "full mode");
        assertEq(l.badDebt, 0, "solvent: no bad debt");
        assertEq(l.repay, EDGE_D, "all debt repaid");
        assertEq(l.seize, EDGE_C, "all collateral seized");
        assertEq(l.seize, MarketMath.value(l.repay, 150e18), "no bonus");
        assertEq(_unbacked(), 0);
    }

    // ------------------------------------------------------------------ test 9

    /// @dev Hold stack: +30 percent promoted from 100, then a post 25 percent above the promoted price during the hold;
    /// returns the first hold end (the market steps to 130 there) and the second (it steps to 162.5).
    function _holdStack() internal returns (uint64 h1, uint64 h2) {
        h1 = _promote(130e18);
        vm.warp(block.timestamp + 60);
        assertEq(uint8(_post(162.5e18)), uint8(IReferenceFeed.Status.AcceptedPending), "pending during the hold");
        (,,, uint64 promotableAt) = feed.pending();
        assertEq(promotableAt, h1, "the pending round promotes at hold end");
        vm.warp(h1);
        bool held;
        (held,,, h2,) = feed.hold();
        assertTrue(held, "a second hold starts at the first hold end");
        assertEq(h2, h1 + 86_400);
        assertEq(feed.discontinuityCount(), 0);
        IBellMarket.PriceView memory pv = m.prices();
        assertEq(pv.confirmed18, 130e18, "the market steps to 130");
        assertFalse(pv.mintOk, "mint stays closed");
        assertEq(uint8(pv.mintBlock), uint8(IBellMarket.MintBlock.Pending));
    }

    /// Test 9a: on the hold stack, liquidation funded by minting fails (mint stays closed), and liquidation from an
    /// inventory at the revised target (the restore need after a 39.99 percent step, 96.9 percent of edge debt; here
    /// 100 percent) succeeds at both hold ends: partial branch, full bonus, zero bad debt.
    function test_9a_holdStack_inventoryAtTargetSucceeds_mintFails() public {
        _list(75e18);
        uint256 u = _open(user, 1_050e6, 7e18);
        uint256 k = _open(keeper, 3_500e6, 7e18);
        _walkTo(100e18);
        assertEq(m.crBps(u, 100e18), 15_000, "edge at 100");
        (, uint64 h2) = _holdStack();

        vm.prank(keeper);
        vm.expectRevert(IBellMarket.PriceNotUsable.selector);
        m.mint(k, 1e18, keeper);

        MarketMath.Liq memory l = _liquidate(keeper, u, m.balanceOf(keeper));
        _assertPartialFullBonus(u, l);
        assertApproxEqRel(l.repay, 7e18 * 8_516 / 10_000, 0.001e18, "restore need 85.2 percent after +30 percent");

        vm.warp(h2);
        assertEq(m.prices().confirmed18, 162.5e18, "second step at the second hold end");
        l = _liquidate(keeper, u, m.balanceOf(keeper));
        _assertPartialFullBonus(u, l);
        assertEq(_unbacked(), 0, "zero bad debt");
    }

    /// Test 9b, the codex-3 sequence: inventory 30 percent of debt (user C 1,050 USDG and D 7 bsX at 100, keeper D 3
    /// bsX). At the first hold end the repay is capped at the inventory (MarketMath maxRepay), leaving C 640.5 and
    /// D 4; mint stays closed; at the second hold end the user is at CR 0.985 and liquidation books about 40 USD of
    /// unbacked debt, while the global trigger stays off.
    function test_9b_holdStack_inventory30Percent_endsInsolvent() public {
        _list(75e18);
        uint256 u = _open(user, 1_050e6, 7e18);
        uint256 k = _open(keeper, 1_500e6, 3e18);
        _open(holder, 3_000e6, 5e18);
        _walkTo(100e18);
        (, uint64 h2) = _holdStack();

        MarketMath.Liq memory l = _liquidate(keeper, u, m.balanceOf(keeper));
        assertFalse(l.full, "partial");
        assertEq(l.repay, 3e18, "capped at the inventory");
        assertEq(l.seize, 409.5e6, "3 bsX at 130 plus 5 percent");
        (uint256 c, uint256 d) = _pos(u);
        assertEq(c, 640.5e6);
        assertEq(d, 4e18);
        assertEq(m.balanceOf(keeper), 0, "inventory spent");
        vm.prank(keeper);
        vm.expectRevert(IBellMarket.PriceNotUsable.selector);
        m.mint(k, 1e18, keeper);

        vm.warp(h2);
        assertEq(m.crBps(u, 162.5e18), 9_853, "user at 0.985");
        (bool ok,) = m.canTrigger();
        assertFalse(ok, "aggregate collateral keeps the global trigger off");
        l = _liquidate(holder, u, type(uint256).max);
        assertTrue(l.full, "insolvent branch");
        assertEq(l.seize, 640.5e6, "all collateral");
        assertApproxEqAbs(MarketMath.value(l.badDebt, 162.5e18), 40e6, 0.01e6, "about 40 USD of bad debt");
        assertEq(_unbacked(), l.badDebt);
    }

    // ------------------------------------------------------------------ test 10

    /// Test 10, LAG_GRACE with the codex-2 sequence, anchor A = 125: 0.8A (edge at 1.5), 0.96A delivered late
    /// (lastLateReceivedAt set, liquidation and the global trigger closed for 7,200 s), 1.152A and 1.2A confirming
    /// during the grace, an epoch roll, then 1.44A. Liquidation and the global trigger stay closed while the posts
    /// land; at grace end the global condition holds and the edge position (CR 0.833) liquidates in the insolvent
    /// branch with about 20.6 percent of its debt booked as unbacked.
    function test_10_lagGraceBurst_insolventAtGraceEnd() public {
        _list(75e18);
        uint256 u = _open(user, EDGE_C, EDGE_D);
        _open(holder, 9_000e6, EDGE_D);
        _walkTo(125e18);
        (, uint64 since) = _anchor();

        vm.warp(uint256(since) + WINDOW - 7_000);
        _confirm(100e18);
        assertEq(m.crBps(u, 100e18), 15_000, "edge at 0.8A");

        vm.warp(block.timestamp + 3_700);
        uint64 l1Ts = uint64(block.timestamp - 3_601); // delivery lag 3,601 s > DELIVERY_LAG_LIMIT
        assertEq(uint8(_deliver(120e18, l1Ts, l1Ts)), uint8(IReferenceFeed.Status.Accepted), "late round confirms");
        assertEq(feed.lastLateReceivedAt(), block.timestamp);
        uint256 graceEnd = block.timestamp + m.LAG_GRACE();
        IBellMarket.PriceView memory pv = m.prices();
        assertEq(pv.lagGraceUntil, graceEnd);
        assertFalse(pv.liqOk, "liquidation closed");

        vm.warp(block.timestamp + 60);
        _confirm(144e18);
        vm.warp(block.timestamp + 60);
        _confirm(150e18);
        vm.warp(uint256(since) + WINDOW);
        _confirm(180e18);
        (uint128 a,) = _anchor();
        assertEq(a, 150e18, "epoch rolled during the grace");
        assertLt(block.timestamp, graceEnd);
        assertEq(m.crBps(u, 180e18), 8_333, "edge at 0.833");

        assertFalse(m.prices().liqOk);
        vm.prank(holder);
        vm.expectRevert(IBellMarket.PriceNotUsable.selector);
        m.liquidate(u, type(uint256).max, 0, holder);
        (bool ok,) = m.canTrigger();
        assertFalse(ok, "global trigger closed during the grace");
        vm.expectRevert(IBellMarket.NoTrigger.selector);
        m.triggerSettlement();

        vm.warp(graceEnd);
        assertTrue(m.prices().liqOk, "grace over");
        IBellMarket.SettleReason reason;
        (ok, reason) = m.canTrigger();
        assertTrue(ok, "the global condition held all along");
        assertEq(uint8(reason), uint8(IBellMarket.SettleReason.GlobalUndercollateralised));
        MarketMath.Liq memory l = _liquidate(holder, u, type(uint256).max);
        assertTrue(l.full, "insolvent branch");
        assertEq(l.seize, EDGE_C, "all collateral");
        assertApproxEqAbs(l.badDebt * 10_000 / EDGE_D, 2_063, 1, "about 20.6 percent of the debt unbacked");
    }
}
