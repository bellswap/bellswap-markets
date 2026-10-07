// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MarketMath
/// @notice Liquidation and settlement arithmetic of SPEC 8.4 to 8.6. Internal functions only, so no call
/// compiles to DELEGATECALL (SPEC 4). Units: collateral C in USDG (1e6), debt D in synthetic (1e18),
/// prices in 1e18, value V(D, P) = D * P / 1e30 in USDG units.
library MarketMath {
    uint256 internal constant BPS = 1e4;
    uint256 internal constant SCALE = 1e30; // 1e18 (token) * 1e18 (price) / 1e6 (USDG)
    uint256 internal constant SCALE_BPS = 1e34; // SCALE * BPS

    /// Result of the liquidation rule of SPEC 8.5 steps 1 to 4.
    struct Liq {
        uint256 repay; // S, synthetic units burned from the liquidator
        uint256 seize; // USDG paid to the liquidator
        uint256 badDebt; // debt moved to unbackedSupply (insolvent full mode only)
        bool full; // full mode (including a partial result recomputed in full mode)
    }

    /// @dev V(D, P) rounded down.
    function value(uint256 d, uint256 p) internal pure returns (uint256) {
        return Math.mulDiv(d, p, SCALE);
    }

    /// @dev V(D, P) rounded up.
    function valueUp(uint256 d, uint256 p) internal pure returns (uint256) {
        return Math.mulDiv(d, p, SCALE, Math.Rounding.Ceil);
    }

    /// @dev Exact test C * 1e34 < D * P * ratioBps, i.e. CR below ratioBps with no rounding of V.
    /// C * 1e34 < X  <=>  C < ceil(X / 1e34). p * ratioBps fits in 256 bits for p < 2**200.
    function below(uint256 c, uint256 d, uint256 p, uint256 ratioBps) internal pure returns (bool) {
        if (d == 0 || p == 0) return false;
        return c < Math.mulDiv(d, p * ratioBps, SCALE_BPS, Math.Rounding.Ceil);
    }

    /// @dev Mint and withdraw ratio of SPEC 8.3: C * 1e4 >= V(D, Pmint) * MINT_CR with V rounded up
    /// (rounded against the owner).
    function mintRatioOk(uint256 c, uint256 d, uint256 pMint, uint256 mintCrBps) internal pure returns (bool) {
        if (d == 0) return true;
        return c * BPS >= valueUp(d, pMint) * mintCrBps;
    }

    /// @dev Seize value floor(S * P * (1e4 + B) / 1e34).
    function withBonus(uint256 s, uint256 p, uint256 bonusBps) internal pure returns (uint256) {
        return Math.mulDiv(s, p * (BPS + bonusBps), SCALE_BPS);
    }

    /// @dev SIP-15 partial repay, exact: S = ceil((t*V - C) / (t - (1 + b)) * 1e30 / P)
    /// = ceil((MINT*D*P - C*1e34) / (P * (MINT - 1e4 - B))). Split as MINT*D = q1*den + r1 so that every
    /// product fits in 256 bits: S = q1 + ceil((r1*P - C*1e34) / (P*den)). Caller guarantees
    /// C * 1e34 < D * P * MINT (CR below LIQ_CR < MINT_CR), so the result is positive.
    function partialRepay(uint256 c, uint256 d, uint256 p, uint256 mintCrBps, uint256 bonusBps)
        internal
        pure
        returns (uint256)
    {
        uint256 den = mintCrBps - BPS - bonusBps;
        uint256 a = mintCrBps * d;
        uint256 q1 = a / den;
        uint256 n2 = (a % den) * p;
        uint256 m2 = c * SCALE_BPS;
        uint256 den2 = p * den;
        if (n2 >= m2) return q1 + Math.ceilDiv(n2 - m2, den2);
        uint256 k = (m2 - n2) / den2;
        return q1 > k ? q1 - k : 0;
    }

    /// @notice Liquidation rule of SPEC 8.5 steps 1 to 4, for a position that passed step 0
    /// (liqOk and C * 1e34 < D * P * LIQ_CR_BPS). Rounding is against the liquidator.
    function liquidation(
        uint256 c,
        uint256 d,
        uint256 p,
        uint256 maxRepay,
        uint256 mintCrBps,
        uint256 bonusBps,
        uint256 minCollateral
    ) internal pure returns (Liq memory l) {
        // Step 1: partial unless CR < 1 + b.
        if (!below(c, d, p, BPS + bonusBps)) {
            uint256 s = partialRepay(c, d, p, mintCrBps, bonusBps);
            if (s > d) s = d;
            if (s > maxRepay) s = maxRepay;
            uint256 seize = withBonus(s, p, bonusBps);
            // A partial result that would leave C - seize < MIN_COLLATERAL is recomputed in full mode.
            if (seize + minCollateral <= c) {
                l.repay = s;
                l.seize = seize;
                return l;
            }
        }
        l.full = true;
        uint256 cap = maxRepay < d ? maxRepay : d;
        if (!below(c, d, p, BPS)) {
            // Step 3: full, solvent (C >= V). Pro-rata share of the collateral caps the bonus.
            uint256 bonusSeize = withBonus(cap, p, bonusBps);
            uint256 share = Math.mulDiv(c, cap, d);
            l.repay = cap;
            l.seize = bonusSeize < share ? bonusSeize : share;
            return l;
        }
        // Step 4: full, insolvent (C < V).
        uint256 sCap = Math.mulDiv(c, SCALE_BPS, p * (BPS + bonusBps));
        uint256 s4 = cap < sCap ? cap : sCap;
        l.repay = s4;
        if (s4 == sCap && sCap < d) {
            l.seize = c;
            l.badDebt = d - s4;
        } else {
            uint256 sz = withBonus(s4, p, bonusBps);
            l.seize = sz < c ? sz : c;
        }
    }

    /// @dev Settlement claim of SPEC 8.6: min(ceil(D * Pend / 1e30), C).
    function settleClaim(uint256 c, uint256 d, uint256 pEnd) internal pure returns (uint256) {
        uint256 v = valueUp(d, pEnd);
        return v < c ? v : c;
    }

    /// @dev Saturating age (SPEC 6.5, R9).
    function age(uint256 t) internal view returns (uint256) {
        return block.timestamp > t ? block.timestamp - t : 0;
    }
}
