// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MintBase} from "./MintBase.sol";
import {BellMarket} from "../../src/mint/BellMarket.sol";
import {IBellMarket} from "../../src/mint/interfaces/IBellMarket.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";
import {MockMarketFeed} from "./mocks/MockMarketFeed.sol";

/// Settlement (SPEC 8.6, 8.7, 8.10): arm, void arm, AlreadyArmed, the three triggers and their precedence,
/// processing, finalize, pooled redemption and excess claims.
/// Fixture: T0 market at P = 20 USD; alice C = 1_000, D = 10 (to alice); bob C = 500, D = 5 (to bob);
/// carol C = 300, D = 0. Supply 15 tokens.
contract SettlementTest is MintBase {
    BellMarket internal m;
    uint256 internal tObs; // observedAt of the last confirmed round

    function setUp() public override {
        super.setUp();
        m = listLive(feed, 0);
        tObs = block.timestamp;
        openPos(m, alice, 1_000e6, 10e18, alice); // id 0
        openPos(m, bob, 500e6, 5e18, bob); // id 1
        openPos(m, carol, 300e6, 0, carol); // id 2
    }

    function _ids(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (a, b, c);
    }

    // ============================================================ trigger 1: Stale (armed)

    /// 8.7 table: mint closes after 48 h, liquidation after 72 h, arming after 7 d, trigger 24 h later.
    function test_stale_fullFlow() public {
        vm.warp(tObs + 172_801);
        assertEq(uint8(m.prices().mintBlock), uint8(IBellMarket.MintBlock.Age));
        assertTrue(m.prices().liqOk);
        vm.warp(tObs + 259_201);
        assertFalse(m.prices().liqOk);
        vm.warp(tObs + 604_800);
        assertFalse(m.canArm()); // age must exceed SETTLE_STALE
        vm.expectRevert(IBellMarket.NoTrigger.selector);
        m.armSettlement();

        vm.warp(tObs + 604_801);
        assertTrue(m.canArm());
        uint64 armedAt = uint64(block.timestamp);
        vm.expectEmit(false, false, false, true, address(m));
        emit IBellMarket.SettlementArmed(armedAt, 2, armedAt + 86_400, carol);
        vm.prank(carol);
        m.armSettlement();
        assertFalse(m.canArm());
        (bool armed, uint64 at, uint80 lr, uint64 trigAt) = m.armState();
        assertTrue(armed);
        assertEq(at, armedAt);
        assertEq(lr, 2);
        assertEq(trigAt, armedAt + 86_400);

        // M7c: a second arm on a valid arm reverts and does not move armedAt.
        vm.warp(block.timestamp + 3_600);
        vm.expectRevert(abi.encodeWithSelector(IBellMarket.AlreadyArmed.selector, armedAt));
        m.armSettlement();
        (, at,,) = m.armState();
        assertEq(at, armedAt);

        // ARM_DELAY not over.
        (bool ok,) = m.canTrigger();
        assertFalse(ok);
        vm.expectRevert(abi.encodeWithSelector(IBellMarket.ArmDelayPending.selector, armedAt + 86_400));
        m.triggerSettlement();

        vm.warp(armedAt + 86_400);
        IBellMarket.SettleReason reason;
        (ok, reason) = m.canTrigger();
        assertTrue(ok);
        assertEq(uint8(reason), uint8(IBellMarket.SettleReason.Stale));
        vm.expectEmit(false, false, false, true, address(m));
        emit IBellMarket.SettlementTriggered(IBellMarket.SettleReason.Stale, P0, uint64(tObs), 15e18, bob);
        vm.prank(bob);
        m.triggerSettlement();

        assertEq(uint8(m.phase()), 1);
        (armed, at, lr,) = m.armState();
        assertFalse(armed);
        assertEq(at, 0);
        assertEq(lr, 0);
        (IBellMarket.SettleReason r, uint256 p, uint256 sat, uint256 pool, uint256 rem,,) = m.settlement();
        assertEq(uint8(r), uint8(IBellMarket.SettleReason.Stale));
        assertEq(p, P0);
        assertEq(sat, 15e18);
        assertEq(pool, 0);
        assertEq(rem, 2);
        (uint8 ph, uint256 pool2, uint256 sat2) = m.settlementState();
        assertEq(ph, 1);
        assertEq(pool2, 0);
        assertEq(sat2, 15e18);

        _processFinalizeRedeem();
    }

    /// Pend = 20: alice claim = ceil(10 * 20) = 200, excess 800; bob claim 100, excess 400; pool 300 USDG;
    /// each token redeems for 300 / 15 = 20 USDG.
    function _processFinalizeRedeem() internal {
        vm.expectRevert(abi.encodeWithSelector(IBellMarket.Unprocessed.selector, uint256(2)));
        m.finalize();
        // Excess of an unprocessed debt position is not yet claimable; a zero-debt position's C is.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBellMarket.Unprocessed.selector, uint256(2)));
        m.claimExcess(0, alice);
        vm.prank(carol);
        assertEq(m.claimExcess(2, carol), 300e6);
        vm.prank(carol);
        vm.expectRevert(IBellMarket.NothingToClaim.selector);
        m.claimExcess(2, carol);

        vm.expectEmit(true, false, false, true, address(m));
        emit IBellMarket.PositionProcessed(1, 100e6, 400e6);
        m.processPositions(_ids(2, 1, 1)); // zero-debt and duplicate ids are skipped
        (,,,, uint256 rem,,) = m.settlement();
        assertEq(rem, 1);
        m.processPositions(_ids(0, 0, 2));
        (,,, uint256 pool, uint256 rem2,,) = m.settlement();
        assertEq(rem2, 0);
        assertEq(pool, 300e6);
        assertEq(m.position(0).excess, 800e6);
        assertTrue(m.position(0).processed);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBellMarket.WrongPhase.selector, IBellMarket.Phase.Settling));
        m.redeem(1e18, alice);

        vm.expectEmit(false, false, false, true, address(m));
        emit IBellMarket.Finalized(300e6, 15e18);
        m.finalize();
        assertEq(uint8(m.phase()), 2);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(m));
        emit IBellMarket.Redeemed(alice, carol, 1e18, 20e6);
        uint256 paid = m.redeem(1e18, carol);
        assertEq(paid, 20e6);
        vm.prank(alice);
        vm.expectRevert(IBellMarket.NothingToClaim.selector);
        m.redeem(0, alice);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(m));
        emit IBellMarket.ExcessClaimed(0, alice, 800e6);
        m.claimExcess(0, alice);
        vm.prank(bob);
        vm.expectRevert(IBellMarket.NotOwner.selector);
        m.claimExcess(0, bob);

        // Everyone redeems everything; the pool is paid out exactly (M8).
        vm.prank(alice);
        m.redeem(9e18, alice);
        vm.prank(bob);
        m.redeem(5e18, bob);
        (,,, uint256 pl,, uint256 burned, uint256 paidTotal) = m.settlement();
        assertEq(burned, 15e18);
        assertEq(paidTotal, pl);
        vm.prank(bob);
        m.claimExcess(1, bob);
        assertEq(usdg.balanceOf(address(m)), 0); // M3 with nothing left
    }

    /// A round accepted after the arm (confirmed, still stale) voids it: trigger NotArmed; a new arm emits
    /// SettlementDisarmed and records a new armedAt (M7b, M7c, S18b).
    function test_stale_voidedArmByConfirmedRound() public {
        vm.warp(tObs + 604_801);
        m.armSettlement();
        uint64 firstArm = uint64(block.timestamp);
        // A backlog round observed on L1 shortly after tObs lands now: still stale.
        vm.warp(firstArm + 3_600);
        feed.post(P0, uint64(tObs + 10), 1_000);
        (bool armed,,,) = m.armState();
        assertFalse(armed);
        assertTrue(m.canArm());
        vm.warp(firstArm + 86_400);
        vm.expectRevert(IBellMarket.NotArmed.selector);
        m.triggerSettlement();

        vm.expectEmit(false, false, false, true, address(m));
        emit IBellMarket.SettlementDisarmed(3);
        vm.expectEmit(false, false, false, true, address(m));
        emit IBellMarket.SettlementArmed(firstArm + 86_400, 3, firstArm + 2 * 86_400, address(this));
        m.armSettlement();
        (, uint64 at,,) = m.armState();
        assertEq(at, firstArm + 86_400);
        vm.warp(firstArm + 2 * 86_400);
        m.triggerSettlement();
        (IBellMarket.SettleReason r,,,,,,) = m.settlement();
        assertEq(uint8(r), uint8(IBellMarket.SettleReason.Stale));
    }

    /// A fresh round voids the arm and ends the stale condition: no trigger, no arm.
    function test_stale_freshRoundDisarms() public {
        vm.warp(tObs + 604_801);
        m.armSettlement();
        feed.postNow(P0);
        vm.warp(block.timestamp + 86_400);
        assertFalse(m.canArm());
        vm.expectRevert(IBellMarket.NotArmed.selector);
        m.triggerSettlement();
        vm.expectRevert(IBellMarket.NoTrigger.selector);
        m.armSettlement();
    }

    /// A pending round voids the arm and blocks the stale condition.
    function test_stale_pendingRoundVoidsAndBlocks() public {
        vm.warp(tObs + 604_801);
        m.armSettlement();
        feed.postPending(40e18, uint64(block.timestamp));
        vm.warp(block.timestamp + 86_400);
        assertFalse(m.canArm());
        vm.expectRevert(IBellMarket.NotArmed.selector);
        m.triggerSettlement();
        vm.expectRevert(IBellMarket.NoTrigger.selector);
        m.armSettlement();
    }

    function test_trigger_noTrigger() public {
        vm.expectRevert(IBellMarket.NoTrigger.selector);
        m.triggerSettlement();
        (bool ok, IBellMarket.SettleReason r) = m.canTrigger();
        assertFalse(ok);
        assertEq(uint8(r), 0);
    }

    function test_trigger_staleWithoutArm() public {
        vm.warp(tObs + 604_801 + 86_400);
        vm.expectRevert(IBellMarket.NotArmed.selector);
        m.triggerSettlement();
    }

    // ============================================================ trigger 2: Global

    /// bob's position (C = 500, D = 5) is liquidated insolvent at P = 110 and books bad debt, then the
    /// market is below 110 percent globally and anyone triggers at once.
    /// Scap(bob) = floor(500e6 * 1e34 / (110e18 * 11_500)) = 3_952_569_169_960_474_308; bad debt
    /// 5e18 - Scap = 1_047_430_830_039_525_692.
    /// After: totalCollateral = 1_000 + 300 = 1_300 USDG, totalDebt 10e18, unbacked 1.0474e18.
    /// Global test at P = 110 with V floored (SPEC.md:1278): 1_300e6 * 1e4 < floor(11.0474e18 * 110e18 / 1e30)
    /// * 11_000 (1.3e13 < 1.3367e13): true.
    /// Pend = 110: alice claim = min(ceil(10 * 110), 1_000) = 1_000, excess 0. pool = 1_000 USDG.
    /// supplyAtTrigger = 15e18 - Scap = 11_047_430_830_039_525_692; each token pays
    /// 1_000 / 11.0474 = 90.52 USDG < Pend: unbacked supply dilutes every holder pro rata.
    function test_global_withBadDebtDilution() public {
        feed.postNow(110e18);
        vm.prank(bob);
        (uint256 s, uint256 seize) = m.liquidate(1, type(uint256).max, 0, bob);
        assertEq(s, 3_952_569_169_960_474_308);
        assertEq(seize, 500e6);
        (uint256 tc, uint256 td, uint256 ub, uint256 od) = m.totals();
        assertEq(tc, 1_300e6);
        assertEq(td, 10e18);
        assertEq(ub, 1_047_430_830_039_525_692);
        assertEq(od, 1);
        assertEq(m.totalSupply(), td + ub);

        (bool ok, IBellMarket.SettleReason r) = m.canTrigger();
        assertTrue(ok);
        assertEq(uint8(r), uint8(IBellMarket.SettleReason.GlobalUndercollateralised));
        m.triggerSettlement();
        (, uint256 pEnd, uint256 sat,,,,) = m.settlement();
        assertEq(pEnd, 110e18);
        assertEq(sat, 11_047_430_830_039_525_692);

        m.processPositions(_ids(0, 1, 2));
        m.finalize();
        (,,, uint256 pool,,,) = m.settlement();
        assertEq(pool, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(IBellMarket.NothingToClaim.selector); // excess 0
        m.claimExcess(0, alice);

        vm.prank(alice);
        uint256 paid = m.redeem(10e18, alice);
        // floor(1e28 / 11_047_430_830_039_525_692) = 905_187_835 (Python integer division)
        assertEq(paid, 905_187_835);
        assertLt(paid, 1_100e6); // less than Pend per token
    }

    function test_global_notWhileLiqNotOk() public {
        feed.postNow(110e18);
        feed.setLastLate(uint64(block.timestamp)); // lag grace: liqOk false, so no Global trigger
        (bool ok,) = m.canTrigger();
        assertFalse(ok);
        vm.expectRevert(IBellMarket.NoTrigger.selector);
        m.triggerSettlement();
    }

    function test_global_healthyMarketNoTrigger() public {
        feed.postNow(60e18); // alice CR 166, bob 166, collateral 1_800 vs V 900
        (bool ok,) = m.canTrigger();
        assertFalse(ok);
    }

    // ============================================================ trigger 3: Discontinuity

    /// A 2:1 reverse split: price jumps from 20 to 40, goes pending, is promoted and held 24 h; during
    /// the hold markets use 20 (M7d) and nothing triggers; when the hold ends unreverted a discontinuity
    /// is recorded and the market settles at once at the pre-jump 20 (S19b).
    /// alice repays 1 token first, so D = 9: claim ceil(9 * 20) = 180 (excess 820); bob claim 100
    /// (excess 400); pool 280 USDG; supply 14 tokens; 20 USDG per token.
    function test_discontinuity_fullFlow() public {
        feed.postPending(40e18, uint64(block.timestamp));
        feed.promoteWithHold();
        assertEq(m.prices().confirmed18, P0);
        (bool ok,) = m.canTrigger();
        assertFalse(ok);
        feed.endHold(true);

        IBellMarket.PriceView memory pv = m.prices();
        assertEq(uint8(pv.mintBlock), uint8(IBellMarket.MintBlock.Discontinuity));
        assertFalse(pv.liqOk);
        assertFalse(m.canArm());
        vm.expectRevert(IBellMarket.NoTrigger.selector);
        m.armSettlement();
        IBellMarket.SettleReason r;
        (ok, r) = m.canTrigger();
        assertTrue(ok);
        assertEq(uint8(r), uint8(IBellMarket.SettleReason.Discontinuity));

        // Deposit, repay and close stay open until the trigger; mint and liquidation do not.
        vm.prank(alice);
        m.repay(0, 1e18);
        vm.prank(alice);
        vm.expectRevert(IBellMarket.PriceNotUsable.selector);
        m.mint(0, 1e18, alice);
        vm.expectRevert(IBellMarket.PriceNotUsable.selector);
        m.liquidate(0, 1, 0, alice);

        vm.expectEmit(false, false, false, true, address(m));
        emit IBellMarket.SettlementTriggered(
            IBellMarket.SettleReason.Discontinuity, P0, uint64(tObs), 14e18, address(this)
        );
        m.triggerSettlement();
        m.processPositions(_ids(1, 0, 2));
        m.finalize();
        (,,, uint256 pool,,,) = m.settlement();
        assertEq(pool, 280e6);
        assertEq(m.position(0).excess, 820e6);
        vm.prank(bob);
        assertEq(m.redeem(5e18, bob), 100e6);
    }

    /// Precedence (SP9, S19d): with a discontinuity after listing and the post-jump round also stale,
    /// the reason is Discontinuity and Pend is the pre-jump price, not the stale market price.
    function test_discontinuity_precedenceOverStale() public {
        feed.postPending(40e18, uint64(block.timestamp));
        feed.promoteWithHold();
        feed.endHold(true);
        vm.warp(block.timestamp + 604_801 + 86_400);
        assertEq(m.prices().confirmed18, 40e18);
        (bool ok, IBellMarket.SettleReason r) = m.canTrigger();
        assertTrue(ok);
        assertEq(uint8(r), uint8(IBellMarket.SettleReason.Discontinuity));
        assertFalse(m.canArm());
        m.triggerSettlement();
        (IBellMarket.SettleReason rr, uint256 pEnd,,,,,) = m.settlement();
        assertEq(uint8(rr), uint8(IBellMarket.SettleReason.Discontinuity));
        assertEq(pEnd, P0);
    }

    /// A hold reverted by a correction records no discontinuity and triggers nothing (M7d, S19c).
    function test_discontinuity_revertedHoldNoTrigger() public {
        feed.postPending(40e18, uint64(block.timestamp));
        feed.promoteWithHold();
        feed.endHold(false);
        feed.postNow(P0);
        (bool ok,) = m.canTrigger();
        assertFalse(ok);
    }

    /// Only discontinuities after listing count (DISC_BASE, 8.1).
    function test_discontinuity_beforeListingIgnored() public {
        MockMarketFeed f2 = newFeed(P0);
        f2.addDiscontinuity(1, 1);
        BellMarket m2 = listLive(f2, 0);
        assertEq(m2.DISC_BASE(), 1);
        (bool ok,) = m2.canTrigger();
        assertFalse(ok);
        assertTrue(m2.prices().mintOk);
        f2.addDiscontinuity(1, 2);
        (, IBellMarket.SettleReason r) = m2.canTrigger();
        assertEq(uint8(r), uint8(IBellMarket.SettleReason.Discontinuity));
        m2.triggerSettlement();
        (, uint256 pEnd,,,,,) = m2.settlement();
        assertEq(pEnd, P0); // round 1 of f2 via discontinuity(DISC_BASE = 1).preJumpRound
    }

    // ============================================================ processing and redemption

    /// M9: each minter's excess equals C - min(D * Pend, C), independent of processing order.
    function test_processingOrderIndependent() public {
        feed.addDiscontinuity(1, 1);
        m.triggerSettlement();
        uint256 snap = vm.snapshotState();
        m.processPositions(_ids(0, 1, 2));
        uint256 e0 = m.position(0).excess;
        uint256 e1 = m.position(1).excess;
        (,,, uint256 pool,,,) = m.settlement();
        vm.revertToState(snap);
        uint256[] memory one = new uint256[](1);
        one[0] = 1;
        m.processPositions(one);
        one[0] = 0;
        m.processPositions(one);
        assertEq(m.position(0).excess, e0);
        assertEq(m.position(1).excess, e1);
        (,,, uint256 pool2,,,) = m.settlement();
        assertEq(pool2, pool);
        assertEq(e0, 1_000e6 - 200e6);
        assertEq(e1, 500e6 - 100e6);
    }

    /// M15: a position that repay left with 1 wei of debt is processable; its claim rounds up to 1 unit.
    function test_processDustDebt() public {
        vm.prank(alice);
        m.repay(0, 10e18 - 1);
        feed.addDiscontinuity(1, 1);
        m.triggerSettlement();
        (,,,, uint256 rem,,) = m.settlement();
        assertEq(rem, 2);
        m.processPositions(_ids(0, 1, 2));
        assertEq(m.position(0).excess, 1_000e6 - 1); // claim = ceil(1 * 20e18 / 1e30) = 1
        m.finalize();
    }

    function test_processOutOfRangeReverts() public {
        feed.addDiscontinuity(1, 1);
        m.triggerSettlement();
        vm.expectRevert();
        m.processPositions(_ids(0, 1, 7));
    }

    /// An undercollateralised position at Pend pays only its C into the pool; its minter's excess is 0.
    function test_processCappedByCollateral() public {
        feed.postNow(110e18); // alice D = 10 at 110 is V = 1_100 > C = 1_000
        feed.addDiscontinuity(3, 3); // pre-jump round 3 (110); rounds 1 and 2 are the listing rounds at 20
        m.triggerSettlement();
        m.processPositions(_ids(0, 1, 2));
        assertEq(m.position(0).excess, 0);
        (,,, uint256 pool,,,) = m.settlement();
        assertEq(pool, 1_000e6 + 500e6); // bob V = 550 > 500 too
    }

    /// mulDiv payout at price18 = 1e10 (MIN_PRICE18) with a 25,000 USDG cap: a per-token rate
    /// floor(pool * 1e18 / supply) would be floor(0.01) = 0, mulDiv pays every holder its exact share.
    /// Position: C = 100_000 USDG, D = 2e30 (V = 20_000 USDG at 1e10, 22_000 at Pmint): pool 20_000 USDG.
    function test_redeem_mulDivAtMinPrice() public {
        MockMarketFeed f2 = newFeed(1e10);
        BellMarket m2 = listLive(f2, 0);
        assertEq(m2.SUPPLY_CAP(), 25_000e6 * 1e30 / 1e10);
        uint256 id = openPos(m2, alice, 100_000e6, 2e30, alice);
        f2.addDiscontinuity(1, 1);
        m2.triggerSettlement();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        m2.processPositions(ids);
        m2.finalize();
        (,, uint256 sat, uint256 pool,,,) = m2.settlement();
        assertEq(pool, 20_000e6);
        assertEq(sat, 2e30);
        assertEq(pool * 1e18 / sat, 0); // the rejected per-token rate
        vm.startPrank(alice);
        assertEq(m2.redeem(1e26, alice), 1e6); // 1e26 * 2e10 / 2e30 = 1 USDG
        assertEq(m2.redeem(1e18, alice), 0); // rounds down by less than one unit
        m2.redeem(2e30 - 1e26 - 1e18, alice);
        vm.stopPrank();
        (,,,,, uint256 burned, uint256 paid) = m2.settlement();
        assertEq(burned, 2e30);
        assertLe(paid, Math.mulDiv(burned, pool, sat)); // M8
        assertGe(paid + 2, pool);
    }

    /// M8: every redemption pays the same fraction, so order does not matter; payouts sum to <= pool.
    function test_redeem_orderIndependent() public {
        feed.addDiscontinuity(1, 1);
        m.triggerSettlement();
        m.processPositions(_ids(0, 1, 2));
        m.finalize();
        vm.prank(bob);
        uint256 pb = m.redeem(5e18, bob);
        vm.prank(alice);
        uint256 pa = m.redeem(10e18, alice);
        assertEq(pb, 100e6);
        assertEq(pa, 200e6);
    }

    function test_redeem_usdgPauseAndBlacklist() public {
        feed.addDiscontinuity(1, 1);
        m.triggerSettlement();
        m.processPositions(_ids(0, 1, 2));
        m.finalize();
        usdg.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(MockUSDG.Paused.selector);
        m.redeem(1e18, alice);
        usdg.setPaused(false);
        usdg.setBlocked(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockUSDG.Blocked.selector, alice));
        m.redeem(1e18, alice);
        vm.prank(alice);
        m.redeem(1e18, carol); // T17b: pays elsewhere
        assertEq(usdg.balanceOf(carol), 20e6);
    }
}
