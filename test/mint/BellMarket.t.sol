// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MintBase} from "./MintBase.sol";
import {BellMarket} from "../../src/mint/BellMarket.sol";
import {IBellMarket} from "../../src/mint/interfaces/IBellMarket.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";

/// Unit tests per BellMarket function (SPEC 4.8, 8.2 to 8.4). Fixture: T0 market listed at P0 = 20 USD,
/// warm-up passed, fresh confirmed round with deviationBps 1_000, so Pmint = 22 USD.
/// Reference position: C = 1_000 USDG, D = 10 tokens: V(D, Pmint) = 220 USDG, 4 * 220 = 880 <= 1_000.
contract BellMarketTest is MintBase {
    BellMarket internal m;

    function setUp() public override {
        super.setUp();
        m = listLive(feed, 0);
    }

    // ------------------------------------------------------------ metadata and IReferenced

    /// The (name, symbol) the fixture's market carries: generated from the id on v1, the label on V2.
    function expectedLabel() internal view virtual returns (string memory, string memory) {
        return ("Bellswap Synthetic #0", "bsX0");
    }

    function test_metadata() public view {
        (string memory name, string memory symbol) = expectedLabel();
        assertEq(m.name(), name);
        assertEq(m.symbol(), symbol);
        assertEq(m.decimals(), 18);
        (uint8 ph, uint256 pool, uint256 sat) = m.settlementState();
        assertEq(ph, 0);
        assertEq(pool, 0);
        assertEq(sat, 0);
        assertEq(m.referenceFeed(), m.REFERENCE_VIEW());
    }

    // ------------------------------------------------------------ open

    function test_open_belowMinimum() public {
        fund(alice, 100e6, m);
        vm.prank(alice);
        vm.expectRevert(IBellMarket.BelowMinimum.selector);
        m.open(100e6 - 1, 0, alice);
    }

    function test_open_noMintNeedsNoPrice() public {
        feed.setBroken(true);
        fund(alice, 100e6, m);
        vm.expectEmit(true, true, false, true, address(m));
        emit IBellMarket.PositionOpened(0, alice);
        vm.expectEmit(true, true, false, true, address(m));
        emit IBellMarket.Deposited(0, alice, 100e6);
        vm.prank(alice);
        uint256 id = m.open(100e6, 0, alice);
        assertEq(id, 0);
        IBellMarket.Position memory p = m.position(0);
        assertEq(p.owner, alice);
        assertEq(p.collateral, 100e6);
        assertEq(p.debt, 0);
        assertEq(m.positionCount(), 1);
        (uint256 tc, uint256 td, uint256 ub, uint256 od) = m.totals();
        assertEq(tc, 100e6);
        assertEq(td, 0);
        assertEq(ub, 0);
        assertEq(od, 0);
        assertEq(m.assets(), 100e6);
    }

    function test_open_withMint() public {
        fund(alice, 1_000e6, m);
        vm.expectEmit(true, true, false, true, address(m));
        emit IBellMarket.Minted(0, bob, 10e18, 22e18);
        vm.prank(alice);
        m.open(1_000e6, 10e18, bob);
        assertEq(m.balanceOf(bob), 10e18);
        assertEq(debt(m, 0), 10e18);
        assertEq(openDebt(m), 1);
        assertEq(m.totalSupply(), 10e18);
    }

    function test_open_mintDuringWarmupReverts() public {
        BellMarket w = BellMarket(createMarketOn(address(feed), 0, 1_000e6));
        fund(alice, 2_000e6, w);
        vm.startPrank(alice);
        vm.expectRevert(IBellMarket.WarmingUp.selector);
        w.open(1_000e6, 10e18, alice);
        w.open(1_000e6, 0, alice); // collateral only is fine
        vm.stopPrank();
        assertEq(uint8(w.prices().mintBlock), uint8(IBellMarket.MintBlock.Warmup));
    }

    // ------------------------------------------------------------ deposit

    function test_deposit_anyoneNoPrice() public {
        openPos(m, alice, 1_000e6, 10e18, alice);
        feed.setBroken(true);
        fund(carol, 50e6, m);
        vm.expectEmit(true, true, false, true, address(m));
        emit IBellMarket.Deposited(0, carol, 50e6);
        vm.prank(carol);
        m.deposit(0, 50e6);
        assertEq(coll(m, 0), 1_050e6);
    }

    function test_deposit_zeroReverts() public {
        openPos(m, alice, 1_000e6, 0, alice);
        vm.expectRevert(IBellMarket.BelowMinimum.selector);
        m.deposit(0, 0);
    }

    function test_deposit_usdgPauseReverts() public {
        openPos(m, alice, 1_000e6, 0, alice);
        fund(carol, 50e6, m);
        usdg.setPaused(true);
        vm.prank(carol);
        vm.expectRevert(MockUSDG.Paused.selector);
        m.deposit(0, 50e6);
    }

    // ------------------------------------------------------------ withdraw

    function test_withdraw_notOwner() public {
        openPos(m, alice, 1_000e6, 0, alice);
        vm.prank(bob);
        vm.expectRevert(IBellMarket.NotOwner.selector);
        m.withdraw(0, 1e6, bob);
    }

    function test_withdraw_zeroDebtReadsNoPrice() public {
        openPos(m, alice, 1_000e6, 0, alice);
        feed.setBroken(true);
        vm.expectEmit(true, true, false, true, address(m));
        emit IBellMarket.Withdrawn(0, carol, 900e6, 0);
        vm.prank(alice);
        m.withdraw(0, 900e6, carol);
        assertEq(usdg.balanceOf(carol), 900e6);
        vm.prank(alice);
        m.withdraw(0, 100e6, alice); // to zero is allowed with D == 0
        assertEq(coll(m, 0), 0);
    }

    function test_withdraw_belowMinimumRemainder() public {
        openPos(m, alice, 1_000e6, 0, alice);
        vm.startPrank(alice);
        vm.expectRevert(IBellMarket.BelowMinimum.selector);
        m.withdraw(0, 900e6 + 1, alice); // leaves 99.999999 USDG
        vm.expectRevert(IBellMarket.BelowMinimum.selector);
        m.withdraw(0, 1_000e6 + 1, alice);
        vm.expectRevert(IBellMarket.BelowMinimum.selector);
        m.withdraw(0, 0, alice);
        vm.stopPrank();
    }

    function test_withdraw_withDebtRatio() public {
        openPos(m, alice, 1_000e6, 10e18, alice);
        vm.startPrank(alice);
        // Needed: 4 * V(10, 22) = 880 USDG. 120 USDG withdrawable, 120.000001 is not.
        vm.expectRevert(IBellMarket.BelowMintRatio.selector);
        m.withdraw(0, 120e6 + 1, alice);
        vm.expectEmit(true, true, false, true, address(m));
        emit IBellMarket.Withdrawn(0, alice, 120e6, 22e18);
        m.withdraw(0, 120e6, alice);
        vm.expectRevert(IBellMarket.BelowMintRatio.selector);
        m.withdraw(0, 880e6, alice); // to zero with debt
        vm.stopPrank();
        assertEq(coll(m, 0), 880e6);
    }

    function test_withdraw_withDebtNeedsMintOk() public {
        openPos(m, alice, 2_000e6, 10e18, alice);
        feed.postPending(40e18, uint64(block.timestamp));
        vm.prank(alice);
        vm.expectRevert(IBellMarket.PriceNotUsable.selector);
        m.withdraw(0, 1e6, alice);
    }

    // ------------------------------------------------------------ mint

    function test_mint_notOwner() public {
        openPos(m, alice, 1_000e6, 0, alice);
        vm.prank(bob);
        vm.expectRevert(IBellMarket.NotOwner.selector);
        m.mint(0, 1e18, bob);
    }

    function test_mint_ratioBoundary() public {
        openPos(m, alice, 880e6, 0, alice);
        vm.startPrank(alice);
        vm.expectRevert(IBellMarket.BelowMintRatio.selector);
        m.mint(0, 10e18 + 1, alice); // V rounds up to 220.000001, 4x = 880.000004 > 880
        m.mint(0, 10e18, alice);
        vm.stopPrank();
        assertEq(debt(m, 0), 10e18);
    }

    function test_mint_minDebtValue() public {
        openPos(m, alice, 1_000e6, 0, alice);
        vm.startPrank(alice);
        vm.expectRevert(IBellMarket.BelowMinimum.selector);
        m.mint(0, 2.5e18 - 1, alice); // V(D, 20) < 50 USDG
        m.mint(0, 2.5e18, alice);
        m.mint(0, 1, alice); // the minimum applies to the position's debt after the mint
        vm.expectRevert(IBellMarket.BelowMinimum.selector);
        m.mint(0, 0, alice);
        vm.stopPrank();
        assertEq(openDebt(m), 1);
    }

    function test_mint_supplyCap() public {
        // SUPPLY_CAP = 25_000e6 * 1e30 / 20e18 = 1_250e18. The price halves, so CAP_USD does not bind.
        assertEq(m.SUPPLY_CAP(), 1_250e18);
        feed.postNow(10e18);
        openPos(m, alice, 60_000e6, 1_250e18, alice);
        vm.prank(alice);
        vm.expectRevert(IBellMarket.CapExceeded.selector);
        m.mint(0, 1, alice);
    }

    function test_mint_capUsdAtPmint() public {
        // Price doubles to 40: Pmint = 44, CAP_USD allows ceil(V(S, 44)) <= 25_000 USDG, i.e. S <= 568.18 tokens.
        feed.postNow(40e18);
        fund(alice, 110_000e6, m);
        vm.startPrank(alice);
        m.open(110_000e6, 0, alice);
        vm.expectRevert(IBellMarket.CapExceeded.selector);
        m.mint(0, 569e18, alice); // V = 25_036 USDG
        m.mint(0, 568e18, alice); // V = 24_992 USDG
        vm.stopPrank();
    }

    function test_mint_blockedStates() public {
        openPos(m, alice, 10_000e6, 0, alice);
        uint256 snap = vm.snapshotState();

        feed.postPending(40e18, uint64(block.timestamp));
        _expectMintBlocked(IBellMarket.MintBlock.Pending);
        vm.revertToState(snap);

        feed.postPending(40e18, uint64(block.timestamp));
        feed.promoteWithHold();
        _expectMintBlocked(IBellMarket.MintBlock.Pending);
        vm.revertToState(snap);

        vm.warp(block.timestamp + 172_801);
        _expectMintBlocked(IBellMarket.MintBlock.Age);
        vm.revertToState(snap);

        feed.post(P0, uint64(block.timestamp), 3_001);
        _expectMintBlocked(IBellMarket.MintBlock.BufferCap);
        vm.revertToState(snap);

        feed.addDiscontinuity(1, 1);
        _expectMintBlocked(IBellMarket.MintBlock.Discontinuity);
    }

    function _expectMintBlocked(IBellMarket.MintBlock want) internal {
        IBellMarket.PriceView memory pv = m.prices();
        assertEq(uint8(pv.mintBlock), uint8(want));
        assertFalse(pv.mintOk);
        vm.prank(alice);
        vm.expectRevert(IBellMarket.PriceNotUsable.selector);
        m.mint(0, 10e18, alice);
    }

    function test_mint_ageBoundary() public {
        openPos(m, alice, 10_000e6, 0, alice);
        vm.warp(block.timestamp + 172_800);
        vm.prank(alice);
        m.mint(0, 10e18, alice);
    }

    // ------------------------------------------------------------ repay

    function test_repay_anyoneClampsAndNeedsNoPrice() public {
        openPos(m, alice, 1_000e6, 10e18, carol);
        feed.setBroken(true);
        vm.expectEmit(true, true, false, true, address(m));
        emit IBellMarket.Repaid(0, carol, 4e18);
        vm.prank(carol);
        m.repay(0, 4e18);
        assertEq(debt(m, 0), 6e18);
        assertEq(openDebt(m), 1);
        vm.prank(carol);
        m.repay(0, 100e18); // clamps to 6e18
        assertEq(debt(m, 0), 0);
        assertEq(m.balanceOf(carol), 0);
        assertEq(openDebt(m), 0);
        vm.expectRevert(IBellMarket.BelowMinimum.selector);
        vm.prank(carol);
        m.repay(0, 1);
    }

    function test_repay_leavesDust() public {
        openPos(m, alice, 1_000e6, 10e18, alice);
        vm.prank(alice);
        m.repay(0, 10e18 - 1);
        assertEq(debt(m, 0), 1);
        assertEq(openDebt(m), 1);
    }

    function test_repay_worksWhileUsdgPaused() public {
        openPos(m, alice, 1_000e6, 10e18, alice);
        usdg.setPaused(true);
        vm.prank(alice);
        m.repay(0, 1e18);
        assertEq(debt(m, 0), 9e18);
    }

    // ------------------------------------------------------------ close

    function test_close() public {
        openPos(m, alice, 1_000e6, 10e18, alice);
        feed.setBroken(true);
        vm.expectEmit(true, true, false, true, address(m));
        emit IBellMarket.Closed(0, carol, 1_000e6);
        vm.prank(alice);
        m.close(0, carol);
        assertEq(usdg.balanceOf(carol), 1_000e6);
        assertEq(m.totalSupply(), 0);
        assertEq(openDebt(m), 0);
        (uint256 tc, uint256 td,,) = m.totals();
        assertEq(tc, 0);
        assertEq(td, 0);
    }

    function test_close_notOwnerAndNeedsTokens() public {
        openPos(m, alice, 1_000e6, 10e18, bob);
        vm.prank(bob);
        vm.expectRevert(IBellMarket.NotOwner.selector);
        m.close(0, bob);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, uint256(10e18))
        );
        m.close(0, alice);
    }

    // ------------------------------------------------------------ liquidate gates

    function _liquidatablePosition() internal returns (uint256 id) {
        id = openPos(m, alice, 1_000e6, 10e18, liquidator);
        feed.postNow(50e18); // V = 500, CR 200 percent < 250
    }

    function test_liquidate_healthyReverts() public {
        openPos(m, alice, 1_000e6, 10e18, liquidator);
        vm.prank(liquidator);
        vm.expectRevert(IBellMarket.NotLiquidatable.selector);
        m.liquidate(0, type(uint256).max, 0, liquidator);
    }

    function test_liquidate_zeroDebtReverts() public {
        openPos(m, alice, 1_000e6, 0, alice);
        vm.expectRevert(IBellMarket.NotLiquidatable.selector);
        m.liquidate(0, type(uint256).max, 0, liquidator);
    }

    function test_liquidate_ageGate() public {
        _liquidatablePosition();
        vm.warp(block.timestamp + 259_201);
        assertFalse(m.prices().liqOk);
        vm.prank(liquidator);
        vm.expectRevert(IBellMarket.PriceNotUsable.selector);
        m.liquidate(0, type(uint256).max, 0, liquidator);
        (uint256 r, uint256 s, bool f) = m.maxLiquidation(0);
        assertEq(r + s, 0);
        assertFalse(f);
    }

    function test_liquidate_lagGrace() public {
        _liquidatablePosition();
        feed.setLastLate(uint64(block.timestamp));
        assertEq(m.prices().lagGraceUntil, block.timestamp + 7_200);
        feed.postNow(50e18); // a timely round later does not end the grace (SP13)
        vm.prank(liquidator);
        vm.expectRevert(IBellMarket.PriceNotUsable.selector);
        m.liquidate(0, type(uint256).max, 0, liquidator);
        vm.warp(block.timestamp + 7_200);
        vm.prank(liquidator);
        m.liquidate(0, type(uint256).max, 0, liquidator);
    }

    function test_liquidate_discontinuityGate() public {
        _liquidatablePosition();
        feed.addDiscontinuity(1, 2);
        vm.prank(liquidator);
        vm.expectRevert(IBellMarket.PriceNotUsable.selector);
        m.liquidate(0, type(uint256).max, 0, liquidator);
    }

    function test_liquidate_slippage() public {
        _liquidatablePosition();
        (, uint256 seize,) = m.maxLiquidation(0);
        vm.prank(liquidator);
        vm.expectRevert(IBellMarket.Slippage.selector);
        m.liquidate(0, type(uint256).max, seize + 1, liquidator);
        vm.prank(liquidator);
        (, uint256 got) = m.liquidate(0, type(uint256).max, seize, liquidator);
        assertEq(got, seize);
    }

    function test_liquidate_zeroMaxRepayReverts() public {
        _liquidatablePosition();
        vm.prank(liquidator);
        vm.expectRevert(IBellMarket.NotLiquidatable.selector);
        m.liquidate(0, 0, 0, liquidator);
    }

    function test_liquidate_pendingUsesConfirmed_holdUsesPreJump() public {
        openPos(m, alice, 1_000e6, 10e18, liquidator);
        // A pending spike to 50 is never used: CR at the confirmed 20 is 500 percent.
        feed.postPending(50e18, uint64(block.timestamp));
        assertTrue(m.prices().liqOk);
        vm.prank(liquidator);
        vm.expectRevert(IBellMarket.NotLiquidatable.selector);
        m.liquidate(0, type(uint256).max, 0, liquidator);
        // Promoted but held (M7d): markets keep the pre-jump 20.
        feed.promoteWithHold();
        assertEq(m.prices().confirmed18, P0);
        assertTrue(m.prices().pending);
        vm.prank(liquidator);
        vm.expectRevert(IBellMarket.NotLiquidatable.selector);
        m.liquidate(0, type(uint256).max, 0, liquidator);
        // Hold ends below DISCONTINUITY_BPS: the promoted 50 is now the market price.
        feed.endHold(false);
        assertEq(m.prices().confirmed18, 50e18);
        vm.prank(liquidator);
        m.liquidate(0, type(uint256).max, 0, liquidator);
    }

    function test_liquidate_blacklistedOwnerStillLiquidatable_toElsewhere() public {
        _liquidatablePosition();
        usdg.setBlocked(liquidator, true);
        vm.prank(liquidator);
        m.liquidate(0, type(uint256).max, 0, carol); // T17b: pays to another address
        assertGt(usdg.balanceOf(carol), 0);
    }

    // ------------------------------------------------------------ prices() and views

    function test_prices_fields() public {
        IBellMarket.PriceView memory pv = m.prices();
        assertEq(pv.confirmed18, P0);
        assertEq(pv.mint18, 22e18);
        assertEq(pv.observedAt, block.timestamp);
        assertEq(pv.lagGraceUntil, 0);
        assertFalse(pv.pending);
        assertTrue(pv.mintOk);
        assertTrue(pv.liqOk);
        assertEq(uint8(pv.mintBlock), 0);

        feed.post(P0, uint64(block.timestamp), 1_500); // buffer = max(1_000, 1_500)
        assertEq(m.prices().mint18, 23e18);
        feed.post(P0, uint64(block.timestamp), 500); // buffer = max(1_000, 500)
        assertEq(m.prices().mint18, 22e18);
        feed.post(P0, uint64(block.timestamp), 3_000);
        assertEq(m.prices().mint18, 26e18);
        assertTrue(m.prices().mintOk);
        feed.post(P0, uint64(block.timestamp), 3_001);
        assertEq(m.prices().mint18, 0);
    }

    function test_prices_mintRoundsUp() public {
        feed.post(1e10 + 1, uint64(block.timestamp), 1_000);
        // (1e10 + 1) * 1.1 = 11_000_000_001.1 -> 11_000_000_002
        assertEq(m.prices().mint18, 11_000_000_002);
    }

    function test_prices_futureObservedAtSaturates() public {
        // R9: observedAt = now + 1 must not revert any market check.
        feed.post(P0, uint64(block.timestamp + 1), 1_000);
        IBellMarket.PriceView memory pv = m.prices();
        assertTrue(pv.mintOk);
        assertTrue(pv.liqOk);
        assertFalse(m.canArm());
        (bool ok,) = m.canTrigger();
        assertFalse(ok);
        openPos(m, alice, 1_000e6, 10e18, alice);
        vm.prank(alice);
        m.withdraw(0, 1e6, alice);
    }

    function test_prices_phaseBlockAfterTrigger() public {
        openPos(m, alice, 1_000e6, 10e18, alice);
        feed.addDiscontinuity(1, 1);
        m.triggerSettlement();
        IBellMarket.PriceView memory pv = m.prices();
        assertEq(uint8(pv.mintBlock), uint8(IBellMarket.MintBlock.Phase));
        assertFalse(pv.liqOk);
    }

    function test_crBps() public {
        openPos(m, alice, 1_000e6, 10e18, alice);
        assertEq(m.crBps(0, 20e18), 50_000); // 1_000 / 200
        assertEq(m.crBps(0, 50e18), 20_000);
        openPos(m, bob, 100e6, 0, bob);
        assertEq(m.crBps(1, 20e18), type(uint256).max);
    }

    function test_maxLiquidation_healthy() public {
        openPos(m, alice, 1_000e6, 10e18, alice);
        (uint256 r, uint256 s, bool f) = m.maxLiquidation(0);
        assertEq(r, 0);
        assertEq(s, 0);
        assertFalse(f);
    }

    function test_assetsLiabilitiesCoverage() public {
        assertEq(m.liabilities(), 0);
        assertEq(m.coverageBps(), type(uint256).max);
        openPos(m, alice, 1_000e6, 10e18, alice);
        assertEq(m.assets(), 1_000e6);
        assertEq(m.liabilities(), 200e6);
        assertEq(m.coverageBps(), 50_000);
        usdg.mint(address(m), 1e6); // a donation counts in assets only
        assertEq(m.assets(), 1_001e6);
    }

    // ------------------------------------------------------------ phase gates after trigger

    function test_liveFunctionsClosedAfterTrigger() public {
        openPos(m, alice, 1_000e6, 10e18, alice);
        feed.addDiscontinuity(1, 1);
        m.triggerSettlement();
        bytes memory wp = abi.encodeWithSelector(IBellMarket.WrongPhase.selector, IBellMarket.Phase.Settling);
        vm.startPrank(alice);
        vm.expectRevert(wp);
        m.open(100e6, 0, alice);
        vm.expectRevert(wp);
        m.deposit(0, 1);
        vm.expectRevert(wp);
        m.withdraw(0, 1, alice);
        vm.expectRevert(wp);
        m.mint(0, 1, alice);
        vm.expectRevert(wp);
        m.repay(0, 1);
        vm.expectRevert(wp);
        m.close(0, alice);
        vm.expectRevert(wp);
        m.liquidate(0, 1, 0, alice);
        vm.expectRevert(wp);
        m.armSettlement();
        vm.expectRevert(wp);
        m.triggerSettlement();
        vm.expectRevert(wp);
        m.redeem(1, alice);
        vm.stopPrank();
    }

    function test_settlingFunctionsClosedWhileLive() public {
        bytes memory wp = abi.encodeWithSelector(IBellMarket.WrongPhase.selector, IBellMarket.Phase.Live);
        vm.expectRevert(wp);
        m.processPositions(new uint256[](0));
        vm.expectRevert(wp);
        m.finalize();
        vm.expectRevert(wp);
        m.redeem(1, alice);
        vm.expectRevert(wp);
        m.claimExcess(0, alice);
    }

    function test_tokenTransfersHaveNoHooks() public {
        openPos(m, alice, 1_000e6, 10e18, alice);
        vm.prank(alice);
        assertTrue(m.transfer(bob, 1e18));
        assertEq(m.balanceOf(bob), 1e18);
    }
}
