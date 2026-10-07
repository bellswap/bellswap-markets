// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V3FeedBase} from "./V3FeedBase.sol";
import {MarketMath} from "../../../src/mint/MarketMath.sol";
import {IBellMarket} from "../../../src/mint/interfaces/IBellMarket.sol";

/// @title HoldEndTL1Test
/// @notice DESIGN.md tests 17 (codex-1) and 18 (Fable must-fix 1) on a TL1 market over the canonical ReferenceFeed.
/// Setup: an edge position (C 6,000 USDG, D 40 bsX, CR 1.5 at 100) and a keeper position holding 40 bsX of inventory;
/// a 139.99 post is promoted from 100 (hold move 3,999 bps) and held until holdUntil, with the market on 100.
/// A post of 167.988 delivered in the first block at holdUntil ends the hold, rolls the anchor to 139.99 and confirms
/// 20 percent more in one transaction. Test 18 runs the keeper's hold-end liquidation and that post in one block
/// (vm.warp to holdUntil, no vm.roll between the two calls) in both orders, each from the same state snapshot.
contract HoldEndTL1Test is V3FeedBase {
    uint256 internal constant EDGE_C = 6_000e6;
    uint256 internal constant EDGE_D = 40e18;

    function _setUpHold() internal returns (uint256 u, uint64 holdUntil) {
        _list(75e18);
        u = _open(user, EDGE_C, EDGE_D);
        _open(keeper, 16_000e6, EDGE_D);
        _walkTo(100e18);
        holdUntil = _promote(139.99e18);
        (,,,, uint256 mv) = feed.hold();
        assertEq(mv, 3_999, "below the 4,000 bps discontinuity");
        assertEq(m.prices().confirmed18, 100e18, "market on the pre-jump round");
    }

    /// Test 17: before holdUntil the market prices on 100 and a liquidation reverts NotLiquidatable; the post of
    /// 167.988 in the first block at holdUntil confirms at once with no discontinuity, so the edge position goes from
    /// 1.5 to 0.893 with no point at which a keeper could act, and liquidation books bad debt (insolvent branch).
    function test_17_holdEndPlusDirectPost_oneTransaction_insolvent() public {
        (uint256 u, uint64 holdUntil) = _setUpHold();
        vm.warp(holdUntil - 1);
        assertEq(m.prices().confirmed18, 100e18);
        vm.prank(keeper);
        vm.expectRevert(IBellMarket.NotLiquidatable.selector);
        m.liquidate(u, type(uint256).max, 0, keeper);

        vm.warp(holdUntil);
        _confirm(167.988e18);
        assertEq(feed.discontinuityCount(), 0, "no discontinuity");
        (bool held,,,,) = feed.hold();
        assertFalse(held, "the push ended the hold");
        (uint128 a,) = _anchor();
        assertEq(a, 139.99e18, "the push rolled the anchor to the promoted price");
        assertEq(m.prices().confirmed18, 167.988e18, "68 percent in one transaction");
        assertEq(m.crBps(u, 167.988e18), 8_929, "edge at 0.893");

        MarketMath.Liq memory l = _liquidate(keeper, u, type(uint256).max);
        assertTrue(l.full, "insolvent branch");
        assertEq(l.seize, EDGE_C, "all collateral");
        assertGt(l.badDebt, 0, "bad debt");
        assertApproxEqAbs(l.badDebt * 10_000 / EDGE_D, 1_496, 1, "about 15 percent of the debt unbacked");
    }

    /// Test 18: the keeper's hold-end liquidation and the 167.988 post in the first block at holdUntil.
    /// (a) Liquidation first: CR 1.0715, partial branch with the full 5 percent bonus, restored to 175 percent, zero
    /// bad debt; the post then confirms with the position solvent. (b) Post first: the same liquidation lands in the
    /// insolvent branch at 0.893.
    function test_18_holdEndOrdering_sameBlock() public {
        (uint256 u, uint64 holdUntil) = _setUpHold();
        vm.warp(holdUntil);
        uint256 blockNo = block.number;
        uint256 snap = vm.snapshotState();

        // (a) keeper liquidation ordered before the push
        assertEq(m.prices().confirmed18, 139.99e18, "hold over: the market steps by 39.99 percent");
        assertEq(m.crBps(u, 139.99e18), 10_715, "edge at 1.0715");
        MarketMath.Liq memory l = _liquidate(keeper, u, type(uint256).max);
        _assertPartialFullBonus(u, l);
        _confirm(167.988e18);
        assertEq(block.number, blockNo, "one block");
        (uint256 c, uint256 d) = _pos(u);
        assertFalse(MarketMath.below(c, d, 167.988e18, 1e4), "solvent after the push");
        assertEq(_unbacked(), 0, "zero bad debt");

        vm.revertToState(snap);

        // (b) the same liquidation ordered after the push
        _confirm(167.988e18);
        l = _liquidate(keeper, u, type(uint256).max);
        assertEq(block.number, blockNo, "one block");
        assertTrue(l.full, "insolvent branch");
        assertEq(l.seize, EDGE_C, "all collateral");
        assertApproxEqAbs(l.badDebt * 10_000 / EDGE_D, 1_496, 1, "about 15 percent of the debt unbacked");
        assertEq(_unbacked(), l.badDebt);
    }
}
