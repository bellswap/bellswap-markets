// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {MintBase} from "../MintBase.sol";
import {MintBaseV3} from "./MintBaseV3.sol";
import {MathHarness} from "../LiquidationFuzz.t.sol";
import {BellMarket} from "../../../src/mint/BellMarket.sol";
import {IBellMarket} from "../../../src/mint/interfaces/IBellMarket.sol";
import {MarketMath} from "../../../src/mint/MarketMath.sol";

/// @title LiquidationMathTLTest
/// @notice DESIGN.md test 3: MarketMath at TL1 and over the TL tier ranges. Units: the TL1 restore to MINT_CR within
/// one unit on the worked numbers, and the switch to full mode below MIN_COLLATERAL (the DESIGN.md example: C 100 USDG,
/// D 51.948 bsX at 1 USD, then +30 percent: all debt repaid, 70.91 USDG seized). Fuzz: the F1, F2, F4, F5 and M5
/// properties of test/mint/LiquidationFuzz.t.sol with M in [1.75, 4.0], L in [1.47, M - 0.25] and B in [0.05, 0.2],
/// and the branch rule: full mode exactly when CR < 1 + B or the partial result would leave less than MIN_COLLATERAL.
contract LiquidationMathTLTest is Test {
    uint256 internal constant MIN_COLL = 100e6;
    MathHarness internal h = new MathHarness();

    struct Case {
        uint256 c;
        uint256 d;
        uint256 p;
        uint256 maxRepay;
        uint256 mintCr;
        uint256 liqCr;
        uint256 bonus;
    }

    function _tier(uint256 seed, Case memory k) internal pure {
        if (seed % 4 == 0) {
            (k.mintCr, k.liqCr, k.bonus) = (17_500, 15_000, 500); // TL1
            return;
        }
        k.mintCr = 17_500 + (seed >> 8) % 22_501; // [17_500, 40_000]
        k.liqCr = 14_700 + (seed >> 40) % (k.mintCr - 2_500 - 14_700 + 1); // [14_700, M - 2_500]
        k.bonus = 500 + (seed >> 80) % 1_501; // [500, 2_000]
    }

    /// TL1 worked numbers (DESIGN.md): an edge position after +27.8 percent and after +39.99 percent restores to 175
    /// percent within one unit of collateral.
    function test_3_tl1RestoreToMintCrWithinOneUnit() public pure {
        uint256[2] memory prices = [uint256(127.8e18), 139.99e18];
        for (uint256 i; i < 2; ++i) {
            uint256 c = 6_000e6;
            uint256 d = 40e18; // CR 1.5 at 100
            uint256 p = prices[i];
            MarketMath.Liq memory l = MarketMath.liquidation(c, d, p, type(uint256).max, 17_500, 500, MIN_COLL);
            assertFalse(l.full, "partial");
            assertEq(l.seize, MarketMath.withBonus(l.repay, p, 500), "full bonus");
            uint256 cLeft = c - l.seize;
            uint256 dLeft = d - l.repay;
            assertTrue((cLeft + 1) * 1e34 >= dLeft * p * 17_500, "CR >= 175 percent within one unit");
            assertTrue(
                (cLeft - 1) * 1e34 < dLeft * p * 17_500 + p * 17_500, "and not above it by more than one bsX wei"
            );
        }
    }

    /// DESIGN.md worked numbers: below MIN_COLLATERAL the partial result is recomputed in full mode.
    function test_3_tl1FullModeBelowMinCollateral() public pure {
        uint256 c = 100e6;
        uint256 d = 51.948e18;
        uint256 p = 1.3e18;
        assertTrue(MarketMath.below(c, d, p, 15_000), "CR 1.481 below L");
        uint256 s = MarketMath.partialRepay(c, d, p, 17_500, 500);
        assertLt(c - MarketMath.withBonus(s, p, 500), MIN_COLL, "the partial would leave 72.73 USDG");
        MarketMath.Liq memory l = MarketMath.liquidation(c, d, p, type(uint256).max, 17_500, 500, MIN_COLL);
        assertTrue(l.full, "full mode");
        assertEq(l.repay, d, "all debt repaid");
        assertEq(l.badDebt, 0);
        assertEq(l.seize, 70_909_020, "seizes 70.91 USDG, D * P * 1.05");
    }

    function _case(uint256 d, uint256 p, uint256 cr, uint256 maxRepay, uint256 seed)
        internal
        pure
        returns (Case memory k)
    {
        _tier(seed, k);
        k.d = bound(d, 1e12, 1e30);
        k.p = bound(p, 1e10, 1e24);
        uint256 crBps = bound(cr, 5_000, k.liqCr - 1);
        k.c = k.d * k.p / 1e30 * crBps / 1e4;
        k.maxRepay = seed % 3 == 0 ? type(uint256).max : bound(maxRepay, 1, k.d);
    }

    /// F1, F2, F4, F5, M5 and the branch rule over the TL ranges, with C from a fuzzed CR in [50 percent, L).
    function testFuzz_3_tlRanges_properties(uint256 d, uint256 p, uint256 cr, uint256 maxRepay, uint256 seed)
        public
        view
    {
        Case memory k = _case(d, p, cr, maxRepay, seed);
        vm.assume(k.c > 0 && h.below(k.c, k.d, k.p, k.liqCr));
        MarketMath.Liq memory l = h.liquidation(k.c, k.d, k.p, k.maxRepay, k.mintCr, k.bonus);
        assertLe(l.repay, k.d, "S <= D");
        assertLe(l.repay, k.maxRepay, "S <= maxRepay");
        assertLe(l.seize, k.c, "F4");
        // Branch rule (MarketMath.liquidation steps 1 and 3).
        bool underBonus = h.below(k.c, k.d, k.p, 1e4 + k.bonus);
        if (!underBonus) {
            uint256 s = MarketMath.partialRepay(k.c, k.d, k.p, k.mintCr, k.bonus);
            if (s > k.d) s = k.d;
            if (s > k.maxRepay) s = k.maxRepay;
            bool fits = MarketMath.withBonus(s, k.p, k.bonus) + MIN_COLL <= k.c;
            assertEq(l.full, !fits, "full mode only below MIN_COLLATERAL");
        } else {
            assertTrue(l.full, "full mode below 1 + B");
        }
        if (l.repay == 0) return;
        assertGe(l.seize, l.repay * k.p / 1e30, "F1");
        if (l.badDebt == 0) {
            assertLe(l.seize, MarketMath.withBonus(l.repay, k.p, k.bonus), "F4");
        } else {
            assertEq(l.seize, k.c, "F2");
            assertEq(l.repay + l.badDebt, k.d, "F2");
            assertTrue(h.below(k.c, k.d, k.p, 1e4), "F5 bad debt only when insolvent");
        }
        if (!l.full) {
            uint256 cLeft = k.c - l.seize;
            uint256 dLeft = k.d - l.repay;
            assertGe(cLeft, MIN_COLL, "remainder at or above MIN_COLLATERAL");
            assertGe(cLeft * k.d, k.c * dLeft, "M5 CR not lower");
            if (k.maxRepay == type(uint256).max) {
                assertTrue((cLeft + 2) * 1e34 >= dLeft * k.p * k.mintCr, "M5 CR >= MINT_CR within rounding");
            }
        }
    }
}

/// @title UnbackedOnlyInsolventTL1Test
/// @notice DESIGN.md test 12, the bad-debt half, through a live TL1 market (BellMarketFactoryV3, MintBase mock feed):
/// for any position below LIQ_CR and any maxRepay, a liquidation raises unbackedSupply only in the insolvent branch
/// (CR below 1 before, all collateral seized, the position closed), by exactly the bad debt, and M4 holds after it.
contract UnbackedOnlyInsolventTL1Test is MintBase, MintBaseV3 {
    BellMarket internal mk;

    function createMarketOn(address f, uint8 tierId, uint256 capUsd) internal override returns (address) {
        return listV3(address(usdg), address(refFactory), menuTL(), f, tierId, capUsd);
    }

    function setUp() public override {
        super.setUp();
        mk = listLive(feed, 1);
        assertEq(mk.MINT_CR_BPS(), 17_500);
        openPos(mk, bob, 20_000e6, 200e18, liquidator); // inventory for the liquidator, CR 5 at 20
    }

    function testFuzz_12_unbackedOnlyInInsolventBranch(uint256 c, uint256 d, uint256 p, uint256 maxRepay) public {
        uint256 cc = bound(c, 100e6, 5_000e6);
        // Mint limit at Pmint 22: 1.75 * D * 22 <= C; MIN_DEBT_VALUE 50 USD at 20.
        uint256 dMax = cc * 1e4 / 17_500 * 1e30 / 22e18;
        vm.assume(dMax > 2.5e18);
        uint256 dd = bound(d, 2.5e18, dMax);
        uint256 id = openPos(mk, alice, cc, dd, alice);
        uint256 pMin = cc * 1e34 / (dd * 15_000) + 1; // CR below 150
        uint256 pp = bound(p, pMin, pMin * 3);
        feed.postNow(uint128(pp));
        uint256 mr = bound(maxRepay, 1, mk.balanceOf(liquidator));
        bool insolvent = MarketMath.below(cc, dd, pp, 1e4);
        (,, uint256 ub0,) = mk.totals();

        vm.prank(liquidator);
        try mk.liquidate(id, mr, 0, liquidator) returns (uint256, uint256 seize) {
            (uint256 tc, uint256 td, uint256 ub1,) = mk.totals();
            assertEq(mk.totalSupply(), td + ub1, "M4");
            assertEq(tc, coll(mk, 0) + coll(mk, 1), "totalCollateral == sum(C)");
            if (ub1 > ub0) {
                assertTrue(insolvent, "bad debt only from an insolvent position");
                assertEq(seize, cc, "all collateral seized");
                assertEq(debt(mk, id), 0, "position closed");
                assertEq(coll(mk, id), 0);
            } else {
                assertEq(ub1, ub0, "unbacked supply unchanged");
            }
        } catch (bytes memory err) {
            assertEq(bytes4(err), IBellMarket.NotLiquidatable.selector, "only Scap == 0 dust");
            // The revert is allowed only where the market's own rule refuses: not below LIQ_CR, or a zero repay cap.
            MarketMath.Liq memory l =
                MarketMath.liquidation(cc, dd, pp, mr, mk.MINT_CR_BPS(), mk.BONUS_BPS(), mk.MIN_COLLATERAL());
            assertTrue(
                !MarketMath.below(cc, dd, pp, mk.LIQ_CR_BPS()) || l.repay == 0, "NotLiquidatable only at Scap == 0"
            );
        }
    }

    /// A position the market must liquidate (C 100 USDG, D 2.5 bsX, price 60, maxRepay 200 bsX, insolvent full mode):
    /// the call succeeds with the repay capped at Scap = C / (p * (1 + B)) and all collateral seized.
    function test_12_insolventScapLiquidates() public {
        uint256 id = openPos(mk, alice, 100e6, 2.5e18, alice);
        feed.postNow(uint128(60e18));
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = mk.liquidate(id, 200e18, 0, liquidator);
        assertEq(repaid, 1_587_301_587_301_587_301, "repay == Scap");
        assertEq(seized, 100e6, "all collateral seized");
        assertEq(debt(mk, id), 0, "position closed");
    }

    /// The fuzz property rejects a market whose liquidate always reverts NotLiquidatable on a liquidatable position.
    function test_12_fuzzCatchesSpuriousNotLiquidatable() public {
        vm.mockCallRevert(
            address(mk),
            abi.encodeWithSelector(BellMarket.liquidate.selector),
            abi.encodeWithSelector(IBellMarket.NotLiquidatable.selector)
        );
        vm.expectRevert(bytes("NotLiquidatable only at Scap == 0"));
        this.testFuzz_12_unbackedOnlyInInsolventBranch(100e6, 2.5e18, 60e18, 200e18);
    }
}
