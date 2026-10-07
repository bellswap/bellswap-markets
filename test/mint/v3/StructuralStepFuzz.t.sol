// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MarketMath} from "../../../src/mint/MarketMath.sol";

/// @title StructuralStepFuzzTest
/// @notice DESIGN.md test 4 (B test 5): for every tier that passes the full bonus rule of BellMarketFactoryV3
/// (liqCr * 1e4 >= (1e4 + bonus) * 14_000), any position at or above LIQ_CR and any single step below 40 percent, the
/// post-step CR is at least LIQ_CR / 1.4 >= 1 + bonus, so MarketMath takes the partial branch, or the solvent full
/// branch when the remainder would fall below MIN_COLLATERAL; either way it pays the full bonus and books no bad debt.
/// A tier that breaks the rule (TL2, liq 135) does not have this property: the unit case shows its insolvent branch.
contract StructuralStepFuzzTest is Test {
    uint256 internal constant MIN_COLL = 100e6;

    function testFuzz_4_stepBelow40KeepsFullBonus(
        uint256 seed,
        uint256 d,
        uint256 p,
        uint256 headroom,
        uint256 stepBps,
        uint256 maxRepay
    ) public pure {
        uint256 liq = bound(seed, 15_000, 40_000);
        uint256 bMax = liq * 1e4 / 14_000 - 1e4; // largest bonus the rule allows at this liq
        if (bMax > 2_000) bMax = 2_000;
        uint256 bonus = bound(seed >> 64, 500, bMax);
        assertTrue(liq * 1e4 >= (1e4 + bonus) * 14_000, "tier passes rule 2");
        uint256 mint = bound(seed >> 128, liq + 2_500 < 17_500 ? 17_500 : liq + 2_500, 60_000);

        d = bound(d, 1e15, 1e30);
        p = bound(p, 1e10, 1e24);
        // C at or above LIQ_CR: ceil(D * P * L / 1e34), plus up to the same again.
        uint256 c = Math.mulDiv(d, p * liq, 1e34, Math.Rounding.Ceil);
        c += bound(headroom, 0, c);
        assertFalse(MarketMath.below(c, d, p, liq), "CR >= L before the step");

        uint256 s = bound(stepBps, 0, 3_999);
        uint256 p2 = p * (1e4 + s) / 1e4;
        assertFalse(MarketMath.below(c, d, p2, 1e4 + bonus), "post-step CR >= 1 + bonus");
        if (!MarketMath.below(c, d, p2, liq)) return; // not liquidatable after the step

        uint256 mr = bound(maxRepay, 1, type(uint256).max);
        MarketMath.Liq memory l = MarketMath.liquidation(c, d, p2, mr, mint, bonus, MIN_COLL);
        assertEq(l.badDebt, 0, "no bad debt");
        assertEq(l.seize, MarketMath.withBonus(l.repay, p2, bonus), "full bonus");
    }

    /// The rule's counter-example: TL2 (liq 135, bonus 5) after a 39.99 percent step ends at 0.964, below 1 + bonus
    /// and below 1, and an edge position takes the insolvent branch with bad debt.
    function test_4_tl2BreaksRule2_insolventAfter3999() public pure {
        uint256 c = 1_350e6;
        uint256 d = 10e18; // CR 1.35 at 100
        uint256 p2 = 139.99e18;
        assertTrue(MarketMath.below(c, d, p2, 1e4), "insolvent after the step");
        MarketMath.Liq memory l = MarketMath.liquidation(c, d, p2, type(uint256).max, 16_500, 500, MIN_COLL);
        assertTrue(l.full);
        assertGt(l.badDebt, 0, "bad debt");
    }
}
