// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title PoolPrice
/// @notice Price conversions of the Bellswap scripts (CreatePool.s.sol, script/scenarios/). A price is "whole quote
/// tokens per whole base token, times 1e18", the unit of the hook's anchor (BellswapHook.anchorPriceX18).
library PoolPrice {
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant BPS = 1e4;

    /// @notice sqrtPriceX96 of a pool whose base token (baseDec decimals) is worth `quotePerBaseX18` quote tokens
    /// (quoteDec decimals), rounded down. Reverts (FullMath) when the raw price is 2^128 or more.
    function sqrtPriceX96(bool baseIsCurrency0, uint8 baseDec, uint8 quoteDec, uint256 quotePerBaseX18)
        internal
        pure
        returns (uint160)
    {
        // priceX192 = raw currency1 per raw currency0, times 2^192.
        uint256 num = baseIsCurrency0 ? quotePerBaseX18 * 10 ** quoteDec : SCALE * 10 ** baseDec;
        uint256 den = baseIsCurrency0 ? SCALE * 10 ** baseDec : quotePerBaseX18 * 10 ** quoteDec;
        uint256 root;
        if (num / den < uint256(1) << 64) {
            root = Math.sqrt(FullMath.mulDiv(num, uint256(1) << 192, den));
        } else {
            // A raw price of 2^64 or more (a very cheap base sorted as currency1): price x 2^128 fits; its root is
            // shifted by 32 bits. FullMath reverts above 2^128, which is outside the v4 range anyway.
            root = Math.sqrt(FullMath.mulDiv(num, uint256(1) << 128, den)) << 32;
        }
        // The pool range check (TickMath) is the caller's.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(root);
    }

    /// @notice The inverse, with the hook's own formula (BellswapHook._priceX18, src/hook/BellswapHook.sol:535-551),
    /// so a start price is checked against the anchor exactly as createSyntheticPool checks it.
    function priceX18(uint160 sqrtPrice, bool baseIsCurrency0, uint8 baseDec, uint8 quoteDec)
        internal
        pure
        returns (uint256)
    {
        if (sqrtPrice == 0) return 0;
        uint256 num = SCALE * 10 ** baseDec;
        uint256 den = 10 ** quoteDec;
        if (sqrtPrice <= type(uint128).max) {
            uint256 priceX192 = uint256(sqrtPrice) * sqrtPrice;
            if (baseIsCurrency0) return FullMath.mulDiv(priceX192, num, den << 192);
            return FullMath.mulDiv(uint256(1) << 192, num, priceX192) / den;
        }
        uint256 priceX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, 1 << 64);
        if (baseIsCurrency0) return FullMath.mulDiv(priceX128, num, den << 128);
        return FullMath.mulDiv(uint256(1) << 128, num, priceX128) / den;
    }

    /// @notice |px - anchor| in bps of the anchor, rounded down (BellswapHook._gapBps without its saturation).
    function gapBps(uint256 px, uint256 anchor) internal pure returns (uint256) {
        uint256 diff = px > anchor ? px - anchor : anchor - px;
        return FullMath.mulDiv(diff, BPS, anchor);
    }
}
