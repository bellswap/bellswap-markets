// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MintBase} from "./MintBase.sol";
import {BellMarket} from "../../src/mint/BellMarket.sol";
import {IBellMarket} from "../../src/mint/interfaces/IBellMarket.sol";
import {MarketMath} from "../../src/mint/MarketMath.sol";

/// Exposes the internal liquidation arithmetic for property fuzzing.
contract MathHarness {
    function below(uint256 c, uint256 d, uint256 p, uint256 r) external pure returns (bool) {
        return MarketMath.below(c, d, p, r);
    }

    function liquidation(uint256 c, uint256 d, uint256 p, uint256 maxRepay, uint256 mintCr, uint256 bonus)
        external
        pure
        returns (MarketMath.Liq memory)
    {
        return MarketMath.liquidation(c, d, p, maxRepay, mintCr, bonus, 100e6);
    }
}

/// Fuzz properties F0 to F5 of SPEC 8.5 over C, D, P, maxRepay and tiers (the menu tiers plus any tier
/// inside the factory hard bounds), on the pure rule and through a live market.
contract LiquidationMathFuzzTest is Test {
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
        uint256 sel = seed % 4;
        if (sel == 0) {
            (k.mintCr, k.liqCr, k.bonus) = (40_000, 25_000, 1_500); // T0, T2
        } else if (sel == 1) {
            (k.mintCr, k.liqCr, k.bonus) = (25_000, 17_500, 1_200); // T1
        } else {
            k.mintCr = 25_000 + (seed >> 8) % 75_001; // [25_000, 100_000]
            k.liqCr = 15_000 + (seed >> 40) % (k.mintCr - 5_000 - 15_000 + 1); // gap >= 5_000
            uint256 bMax = k.liqCr - 10_001 < 2_000 ? k.liqCr - 10_001 : 2_000;
            k.bonus = 500 + (seed >> 80) % (bMax - 500 + 1);
        }
    }

    function _case(uint256 c, uint256 d, uint256 p, uint256 maxRepay, uint256 seed)
        internal
        pure
        returns (Case memory k)
    {
        _tier(seed, k);
        k.c = bound(c, 1, 1e15); // up to 1e9 USDG
        k.d = bound(d, 1, 1e32);
        k.p = bound(p, 1e10, 1e30);
        k.maxRepay = bound(maxRepay, 1, type(uint256).max);
    }

    /// F1, F2, F4, F5 and the M5 CR rule, for every position that passes step 0.
    function testFuzz_F1_F2_F4_F5(uint256 c, uint256 d, uint256 p, uint256 maxRepay, uint256 seed) public view {
        Case memory k = _case(c, d, p, maxRepay, seed);
        vm.assume(h.below(k.c, k.d, k.p, k.liqCr)); // step 0 holds
        MarketMath.Liq memory l = h.liquidation(k.c, k.d, k.p, k.maxRepay, k.mintCr, k.bonus);

        assertLe(l.repay, k.d, "S <= D");
        assertLe(l.repay, k.maxRepay, "S <= maxRepay");
        // F4: seize <= C always.
        assertLe(l.seize, k.c, "F4 seize <= C");
        if (l.repay == 0) return; // market reverts NotLiquidatable (Scap == 0 dust)
        // F1: the liquidator never receives less than the value it repays.
        assertGe(l.seize, l.repay * k.p / 1e30, "F1");
        uint256 withBonus = MarketMath.withBonus(l.repay, k.p, k.bonus);
        if (l.badDebt == 0) {
            assertLe(l.seize, withBonus, "F4 seize <= S * P * (1 + b)");
        } else {
            // F2: bad debt only when all collateral is seized and the position ends at C = 0, D = 0.
            assertEq(l.seize, k.c, "F2 seize == C");
            assertEq(l.repay + l.badDebt, k.d, "F2 D ends at 0");
            assertTrue(l.full, "F2 full mode");
            // F4 bad-debt branch: C < (S + 1) * P * (1e4 + B) / 1e34.
            assertTrue(k.c * 1e34 < (l.repay + 1) * k.p * (1e4 + k.bonus), "F4 bad-debt bound");
            // F5: no bad debt on a solvent position.
            assertTrue(h.below(k.c, k.d, k.p, 1e4), "F5 insolvent before");
        }
        if (!l.full) {
            // M5: after a partial liquidation CR is not lower than before: (C - seize) / (D - S) >= C / D.
            uint256 dLeft = k.d - l.repay;
            assertGt(dLeft, 0);
            assertGe((k.c - l.seize) * k.d, k.c * dLeft, "M5 CR not lower");
            // And C - seize >= MIN_COLLATERAL (otherwise full mode).
            assertGe(k.c - l.seize, 100e6);
        }
    }

    /// Same properties with C derived from a fuzzed CR in [50, LIQ_CR) percent, so the partial, solvent
    /// full, insolvent full and bad-debt branches are all hit, with maxRepay above and below S.
    function testFuzz_F1_F2_F4_F5_byCr(uint256 d, uint256 p, uint256 cr, uint256 maxRepay, uint256 seed) public view {
        Case memory k = _case(1, d, p, maxRepay, seed);
        k.d = bound(d, 1e12, 1e30);
        k.p = bound(p, 1e10, 1e24);
        uint256 crBps = bound(cr, 5_000, k.liqCr - 1);
        k.c = k.d * k.p / 1e30 * crBps / 1e4;
        vm.assume(k.c > 0);
        k.maxRepay = seed % 3 == 0 ? type(uint256).max : bound(maxRepay, 1, k.d);
        this.checkProperties(k);
    }

    function checkProperties(Case memory k) external view {
        vm.assume(h.below(k.c, k.d, k.p, k.liqCr));
        MarketMath.Liq memory l = h.liquidation(k.c, k.d, k.p, k.maxRepay, k.mintCr, k.bonus);
        assertLe(l.repay, k.d);
        assertLe(l.repay, k.maxRepay);
        assertLe(l.seize, k.c, "F4");
        if (l.repay == 0) return;
        assertGe(l.seize, l.repay * k.p / 1e30, "F1");
        if (l.badDebt == 0) {
            assertLe(l.seize, MarketMath.withBonus(l.repay, k.p, k.bonus), "F4");
        } else {
            assertEq(l.seize, k.c, "F2");
            assertEq(l.repay + l.badDebt, k.d, "F2");
            assertTrue(k.c * 1e34 < (l.repay + 1) * k.p * (1e4 + k.bonus), "F4 bad-debt bound");
            assertTrue(h.below(k.c, k.d, k.p, 1e4), "F5");
        }
        if (!l.full) assertGe((k.c - l.seize) * k.d, k.c * (k.d - l.repay), "M5");
    }

    /// M5: when the full partial S was repaid (maxRepay unbounded), the CR is at least MINT_CR within
    /// rounding: C' * 1e34 * (1 + 1e-9) >= D' * P * MINT_CR, allowing one USDG unit of seize rounding.
    function testFuzz_M5_partialRestoresMintCr(uint256 c, uint256 d, uint256 p, uint256 seed) public view {
        Case memory k = _case(c, d, p, type(uint256).max, seed);
        k.maxRepay = type(uint256).max;
        k.d = bound(d, 1e15, 1e32);
        vm.assume(h.below(k.c, k.d, k.p, k.liqCr));
        MarketMath.Liq memory l = h.liquidation(k.c, k.d, k.p, k.maxRepay, k.mintCr, k.bonus);
        if (l.full) return;
        uint256 cLeft = k.c - l.seize;
        uint256 dLeft = k.d - l.repay;
        // Exact target: cLeft >= t * V(dLeft). The ceil on S can only raise CR; the floor on seize and
        // the ceil on S together move cLeft by at most 2 units below the exact real value.
        assertTrue((cLeft + 2) * 1e34 >= dLeft * k.p * k.mintCr, "M5 CR >= MINT_CR within rounding");
    }
}

/// F0 and F3 through a live market: fuzzed collateral, debt, price and maxRepay on T0.
contract LiquidationMarketFuzzTest is MintBase {
    BellMarket internal m;

    function setUp() public override {
        super.setUp();
        m = listLive(feed, 0);
    }

    function _open(uint256 c, uint256 d) internal returns (uint256 id, uint256 cc, uint256 dd) {
        cc = bound(c, 100e6, 1e11);
        // Mint limit at Pmint 22: 4 * D * 22 <= C, CAP_USD 25_000 at 22, MIN_DEBT_VALUE 50 at 20.
        uint256 dMax = (cc / 4) * 1e30 / 22e18; // ceil(V(dMax, 22)) <= floor(C / 4)
        if (dMax > 1_100e18) dMax = 1_100e18; // leaves CAP_USD room for a second position
        vm.assume(dMax >= 2.5e18 + 1);
        dd = bound(d, 2.5e18, dMax - 1);
        id = openPos(m, alice, cc, dd, liquidator);
    }

    /// F0: a position with C * 1e34 >= D * P * LIQ_CR_BPS is never liquidatable, including CR in
    /// [LIQ_CR, MINT_CR), and maxLiquidation returns (0, 0, false).
    function testFuzz_F0_healthyNeverLiquidated(uint256 c, uint256 d, uint256 p) public {
        (uint256 id, uint256 cc, uint256 dd) = _open(c, d);
        uint256 pMax = cc * 1e34 / (dd * 25_000); // largest P with CR >= 250
        vm.assume(pMax >= 1e10);
        uint256 pp = bound(p, 1e10, pMax);
        vm.assume(pp < type(uint128).max);
        feed.postNow(uint128(pp));
        assertFalse(cc * 1e34 < dd * pp * 25_000);
        (uint256 r, uint256 s, bool f) = m.maxLiquidation(id);
        assertEq(r, 0);
        assertEq(s, 0);
        assertFalse(f);
        vm.prank(liquidator);
        vm.expectRevert(IBellMarket.NotLiquidatable.selector);
        m.liquidate(id, type(uint256).max, 0, liquidator);
    }

    /// F3: M4 (totalSupply == sum(D) + unbackedSupply) and M13 hold after every branch; the market pays
    /// exactly `seize` and burns exactly `S`.
    function testFuzz_F3_M4AfterEveryBranch(uint256 c, uint256 d, uint256 p, uint256 maxRepay) public {
        (uint256 id, uint256 cc, uint256 dd) = _open(c, d);
        // A second, healthy position so sums are not trivial.
        openPos(m, bob, 10_000e6, 10e18, bob);
        uint256 pMin = cc * 1e34 / (dd * 25_000) + 1; // CR < 250
        uint256 pp = bound(p, pMin, pMin * 40);
        feed.postNow(uint128(pp));
        uint256 mr = bound(maxRepay, 1, dd * 2);
        (uint256 er, uint256 es,) = m.maxLiquidation(id);
        uint256 supplyBefore = m.totalSupply();
        uint256 usdgBefore = usdg.balanceOf(liquidator);
        vm.prank(liquidator);
        try m.liquidate(id, mr, 0, liquidator) returns (uint256 s, uint256 seize) {
            if (mr >= dd) {
                assertEq(s, er, "maxLiquidation S");
                assertEq(seize, es, "maxLiquidation seize");
            }
            assertEq(m.totalSupply(), supplyBefore - s);
            assertEq(usdg.balanceOf(liquidator), usdgBefore + seize);
            assertGe(seize, s * pp / 1e30, "F1");
        } catch (bytes memory err) {
            assertEq(bytes4(err), IBellMarket.NotLiquidatable.selector); // only Scap == 0 dust
        }
        (uint256 tc, uint256 td, uint256 ub, uint256 od) = m.totals();
        assertEq(m.totalSupply(), td + ub, "M4");
        assertEq(td, debt(m, 0) + debt(m, 1));
        assertEq(tc, coll(m, 0) + coll(m, 1));
        uint256 n = (debt(m, 0) > 0 ? 1 : 0) + (debt(m, 1) > 0 ? 1 : 0);
        assertEq(od, n, "M13");
        assertEq(usdg.balanceOf(address(m)), tc, "M3");
    }
}
