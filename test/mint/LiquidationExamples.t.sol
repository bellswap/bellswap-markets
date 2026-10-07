// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MintBase} from "./MintBase.sol";
import {BellMarket} from "../../src/mint/BellMarket.sol";
import {IBellMarket} from "../../src/mint/interfaces/IBellMarket.sol";
import {MockMarketFeed} from "./mocks/MockMarketFeed.sol";

/// Worked liquidation examples of SPEC 8.5 at T0 (t = MINT_CR 4.0, LIQ_CR 2.5, b = 0.15,
/// MIN_COLLATERAL 100 USDG). Every example: D = 10 tokens, P = 100 USD, so V = D * P = 1_000 USDG, and
/// C = CR * V. Positions are opened at P0 = 20 (Pmint 22; 4 * 10 * 22 = 880 <= C for every C below) and
/// the price then moves to 100. Expected numbers are computed by hand below with exact fractions
/// (checked with Python fractions.Fraction, scratchpad liq_examples.py), not by calling the contract.
contract LiquidationExamplesTest is MintBase {
    BellMarket internal m;
    uint256 internal constant D = 10e18;
    uint128 internal constant P = 100e18;

    function setUp() public override {
        super.setUp();
        m = listLive(feed, 0);
    }

    function _pos(uint256 c) internal returns (uint256 id) {
        id = openPos(m, alice, c, D, liquidator);
    }

    function _toP() internal {
        feed.postNow(P);
    }

    function _liq(uint256 id, uint256 maxRepay) internal returns (uint256 s, uint256 seize) {
        vm.prank(liquidator);
        (s, seize) = m.liquidate(id, maxRepay, 0, liquidator);
    }

    /// CR 300 percent, C = 3_000 USDG. Step 0: C * 1e34 = 3.0e43 >= D * P * LIQ_CR = 1e39 * 25_000 = 2.5e43,
    /// so not liquidatable. Before SP12 the partial formula gave x = (4 * 1_000 - 3_000) / 2.85 = 350.88 USDG
    /// (35.09 percent of the debt).
    function test_CR300_notLiquidatable() public {
        uint256 id = _pos(3_000e6);
        _toP();
        assertEq(m.crBps(id, P), 30_000);
        (uint256 r, uint256 s, bool f) = m.maxLiquidation(id);
        assertEq(r, 0);
        assertEq(s, 0);
        assertFalse(f);
        vm.prank(liquidator);
        vm.expectRevert(IBellMarket.NotLiquidatable.selector);
        m.liquidate(id, type(uint256).max, 0, liquidator);
    }

    /// CR 140 percent, C = 1_400 USDG: 1.4e43 >= 1e39 * 11_500 = 1.15e43, so partial (CR >= 1 + b).
    /// x = (4 * 1_000 - 1_400) / (4 - 1.15) = 2_600 / 2.85 = 912.2807017543859649... USDG.
    /// S = ceil(x / 100 tokens) = ceil(9.1228070175438596491228...e18) = 9_122_807_017_543_859_650.
    /// seize = floor(S * 100 * 1.15 / 1e12) = floor(1_049_122_807.0175...) = 1_049_122_807 (1_049.122807 USDG).
    /// C left = 1_400_000_000 - 1_049_122_807 = 350_877_193 >= 100e6, so partial stands.
    /// D left = 10e18 - 9_122_807_017_543_859_650 = 877_192_982_456_140_350.
    /// CR after = 350.877193 / (0.87719298245614035 * 100) = 4.0000000002, i.e. MINT_CR within rounding.
    function test_CR140_partial() public {
        uint256 id = _pos(1_400e6);
        _toP();
        (uint256 r0, uint256 s0, bool f0) = m.maxLiquidation(id);
        assertEq(r0, 9_122_807_017_543_859_650);
        assertEq(s0, 1_049_122_807);
        assertFalse(f0);
        vm.expectEmit(true, true, false, true, address(m));
        emit IBellMarket.Liquidated(id, liquidator, 9_122_807_017_543_859_650, 1_049_122_807, P, false, 0);
        (uint256 s, uint256 seize) = _liq(id, type(uint256).max);
        assertEq(s, 9_122_807_017_543_859_650);
        assertEq(seize, 1_049_122_807);
        assertEq(coll(m, id), 350_877_193);
        assertEq(debt(m, id), 877_192_982_456_140_350);
        assertEq(m.crBps(id, P), 40_000); // floor(350.877193e6 * 1e4 / 87.719298e6)
        assertEq(usdg.balanceOf(liquidator), 1_049_122_807);
        assertEq(openDebt(m), 1);
    }

    /// CR 118 percent, C = 1_180 USDG: 1.18e43 >= 1.15e43, so partial first:
    /// x = (4_000 - 1_180) / 2.85 = 989.47 USDG, seize = 1.15 x = 1_137.89 USDG, C left = 42.1 < 100 USDG,
    /// so it is recomputed in full mode. Solvent (1_180 >= 1_000): S = D = 10e18,
    /// seize = min(floor(10 * 100 * 1.15) = 1_150 USDG, floor(C * S / D) = 1_180 USDG) = 1_150e6.
    /// C left 30 USDG with D = 0; no bad debt.
    function test_CR118_partialRecomputedFull() public {
        uint256 id = _pos(1_180e6);
        _toP();
        vm.expectEmit(true, true, false, true, address(m));
        emit IBellMarket.Liquidated(id, liquidator, D, 1_150e6, P, true, 0);
        (uint256 s, uint256 seize) = _liq(id, type(uint256).max);
        assertEq(s, D);
        assertEq(seize, 1_150e6);
        assertEq(coll(m, id), 30e6);
        assertEq(debt(m, id), 0);
        assertEq(openDebt(m), 0);
        (,, uint256 unbacked,) = m.totals();
        assertEq(unbacked, 0);
        // The owner withdraws the rest; D == 0 allows a remainder below MIN_COLLATERAL to go to zero.
        vm.prank(alice);
        m.withdraw(id, 30e6, alice);
    }

    /// CR 112 percent, C = 1_120 USDG: 1.12e43 < 1.15e43, so full; solvent (1_120 >= 1_000).
    /// S = D; seize = min(1_150 USDG, floor(1_120 * 10 / 10) = 1_120 USDG) = 1_120e6: the whole collateral,
    /// bonus 12 percent = C / V - 1. Position ends C = 0, D = 0; no bad debt (the pre-SP7 rule booked 2.61).
    function test_CR112_fullSolvent() public {
        uint256 id = _pos(1_120e6);
        _toP();
        (uint256 s, uint256 seize) = _liq(id, type(uint256).max);
        assertEq(s, D);
        assertEq(seize, 1_120e6);
        assertEq(coll(m, id), 0);
        assertEq(debt(m, id), 0);
        (,, uint256 unbacked, uint256 od) = m.totals();
        assertEq(unbacked, 0);
        assertEq(od, 0);
    }

    /// CR 105 percent, C = 1_050 USDG: full, solvent. seize = min(1_150, 1_050) = 1_050 USDG = C;
    /// bonus 5 percent. No bad debt (the pre-SP7 rule booked 8.70 of 100).
    function test_CR105_fullSolvent() public {
        uint256 id = _pos(1_050e6);
        _toP();
        vm.expectEmit(true, true, false, true, address(m));
        emit IBellMarket.Liquidated(id, liquidator, D, 1_050e6, P, true, 0);
        (uint256 s, uint256 seize) = _liq(id, type(uint256).max);
        assertEq(s, D);
        assertEq(seize, 1_050e6);
        (,, uint256 unbacked,) = m.totals();
        assertEq(unbacked, 0);
        assertEq(m.totalSupply(), 0);
    }

    /// CR 90 percent, C = 900 USDG (insolvent): Scap = floor(900e6 * 1e34 / (100e18 * 11_500))
    /// = floor(7.826086956521739130434...e18) = 7_826_086_956_521_739_130. S = Scap < D: bad debt
    /// = 10e18 - Scap = 2_173_913_043_478_260_870, seize = C = 900e6.
    function test_CR90_insolventBadDebt() public {
        uint256 id = _pos(900e6);
        _toP();
        vm.expectEmit(true, true, false, true, address(m));
        emit IBellMarket.Liquidated(
            id, liquidator, 7_826_086_956_521_739_130, 900e6, P, true, 2_173_913_043_478_260_870
        );
        (uint256 s, uint256 seize) = _liq(id, type(uint256).max);
        assertEq(s, 7_826_086_956_521_739_130);
        assertEq(seize, 900e6);
        assertEq(coll(m, id), 0);
        assertEq(debt(m, id), 0);
        (, uint256 td, uint256 unbacked, uint256 od) = m.totals();
        assertEq(td, 0);
        assertEq(unbacked, 2_173_913_043_478_260_870);
        assertEq(od, 0);
        assertEq(m.totalSupply(), td + unbacked); // M4
    }

    /// maxRepay-limited cases, each keeps the remaining debt on the position and books no bad debt.
    /// CR 140, maxRepay 1 token: partial S = 1e18, seize = floor(1 * 100 * 1.15) = 115 USDG.
    /// CR 112, maxRepay 4 tokens: full solvent, seize = min(460, floor(1_120 * 4 / 10) = 448) = 448 USDG.
    /// CR 90, maxRepay 5 tokens: full insolvent, S = 5e18 < Scap, seize = min(900, 575) = 575 USDG.
    function test_maxRepayLimited() public {
        uint256 a = _pos(1_400e6);
        uint256 b = _pos(1_120e6);
        uint256 c = _pos(900e6);
        _toP();
        (uint256 s, uint256 seize) = _liq(a, 1e18);
        assertEq(s, 1e18);
        assertEq(seize, 115e6);
        (s, seize) = _liq(b, 4e18);
        assertEq(s, 4e18);
        assertEq(seize, 448e6);
        assertEq(m.crBps(b, P), 11_200); // pro-rata share keeps the CR
        (s, seize) = _liq(c, 5e18);
        assertEq(s, 5e18);
        assertEq(seize, 575e6);
        (,, uint256 unbacked, uint256 od) = m.totals();
        assertEq(unbacked, 0);
        assertEq(od, 3);
        // The next liquidator continues on c: now C = 325, D = 5, V = 500, still insolvent.
        // Scap = floor(325e6 * 1e34 / (100e18 * 11_500)) = 2_826_086_956_521_739_130; bad = 5e18 - Scap.
        (s, seize) = _liq(c, type(uint256).max);
        assertEq(s, 2_826_086_956_521_739_130);
        assertEq(seize, 325e6);
        (,, unbacked,) = m.totals();
        assertEq(unbacked, 5e18 - 2_826_086_956_521_739_130);
    }

    /// T1 at CR 140: t = 2.5, b = 0.12, LIQ_CR 1.75. x = (2.5 * 1_000 - 1_400) / (2.5 - 1.12) = 1_100 / 1.38
    /// = 797.1014492753623188... USDG; S = ceil(7.971014492753623188405...e18) = 7_971_014_492_753_623_189;
    /// seize = floor(S * 100 * 1.12 / 1e12) = floor(892_753_623.188...) = 892_753_623. C left 507.246377 USDG.
    function test_T1_CR140_partial() public {
        MockMarketFeed f1 = newFeed(P0);
        BellMarket m1 = listLive(f1, 1);
        // T1 mint at P0 = 20: 2.5 * 10 * 22 = 550 <= 1_400.
        uint256 id = openPos(m1, alice, 1_400e6, D, liquidator);
        f1.postNow(P);
        vm.prank(liquidator);
        (uint256 s, uint256 seize) = m1.liquidate(id, type(uint256).max, 0, liquidator);
        assertEq(s, 7_971_014_492_753_623_189);
        assertEq(seize, 892_753_623);
        assertEq(m1.position(id).collateral, 1_400e6 - 892_753_623);
    }
}
