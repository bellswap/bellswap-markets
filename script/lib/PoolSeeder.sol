// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title PoolSeeder
/// @notice Testnet and local helper of script/CreatePool.s.sol (not a Bellswap protocol contract, never deployed on
/// mainnet by the scripts): adds and removes liquidity and makes one exact-input swap on a v4 pool, ERC-20 pairs only.
///
/// - Positions are bound to the caller: the PoolManager position is (this contract, ticks, salt = the caller's
///   address), so only the caller that added a position can remove it. The v4-core test router has no such binding:
///   anyone can remove a position it holds.
/// - Every token paid in comes from the caller (transferFrom msg.sender); an allowance to this contract can only be
///   spent by the owner's own calls.
/// - Bounds are enforced on chain: `max0`/`max1` on an add, `min0`/`min1` on a remove, full fill and `minOut` on a
///   swap. Outputs go to the explicit `to`.
contract PoolSeeder is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable MANAGER;

    enum Op {
        Add,
        Remove,
        Swap
    }

    struct Call {
        Op op;
        address payer;
        address to;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool zeroForOne;
        uint256 amountIn;
        uint256 bound0; // Add: max paid in currency0; Remove: min received in currency0; Swap: unused
        uint256 bound1; // Add: max paid in currency1; Remove: min received in currency1; Swap: min out
    }

    error NotManager();
    error NativeNotSupported();
    error ZeroAmount();
    error ZeroRecipient();
    error ExceedsMax(uint256 amount, uint256 max);
    error BelowMin(uint256 amount, uint256 min);
    error PartialFill(uint256 used, uint256 amountIn);

    constructor(IPoolManager manager) {
        MANAGER = manager;
    }

    /// @notice The salt of `owner`'s positions.
    function saltOf(address owner) public pure returns (bytes32) {
        return bytes32(uint256(uint160(owner)));
    }

    /// @notice Adds `liquidity` in [tickLower, tickUpper] to the caller's position, paying at most max0 and max1.
    function addLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 max0,
        uint256 max1
    ) external returns (uint256 paid0, uint256 paid1) {
        if (liquidity == 0) revert ZeroAmount();
        bytes memory r = MANAGER.unlock(
            abi.encode(Call(Op.Add, msg.sender, msg.sender, key, tickLower, tickUpper, liquidity, false, 0, max0, max1))
        );
        (paid0, paid1) = abi.decode(r, (uint256, uint256));
    }

    /// @notice Removes `liquidity` from the caller's position; the tokens go to `to`, at least min0 and min1.
    function removeLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 min0,
        uint256 min1,
        address to
    ) external returns (uint256 got0, uint256 got1) {
        if (liquidity == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroRecipient();
        bytes memory r = MANAGER.unlock(
            abi.encode(Call(Op.Remove, msg.sender, to, key, tickLower, tickUpper, liquidity, false, 0, min0, min1))
        );
        (got0, got1) = abi.decode(r, (uint256, uint256));
    }

    /// @notice Swaps exactly `amountIn` of the input side (paid by the caller) for at least `minOut`, sent to `to`.
    /// A swap that cannot use the whole input reverts (PartialFill).
    function swapExactIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 out)
    {
        if (amountIn == 0 || amountIn > uint256(type(int256).max)) revert ZeroAmount();
        if (to == address(0)) revert ZeroRecipient();
        bytes memory r =
            MANAGER.unlock(abi.encode(Call(Op.Swap, msg.sender, to, key, 0, 0, 0, zeroForOne, amountIn, 0, minOut)));
        out = abi.decode(r, (uint256));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(MANAGER)) revert NotManager();
        Call memory c = abi.decode(data, (Call));
        if (c.key.currency0.isAddressZero()) revert NativeNotSupported();
        if (c.op == Op.Swap) return _swap(c);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 delta = int256(uint256(c.liquidity)); // a uint128 always fits
        (BalanceDelta d,) = MANAGER.modifyLiquidity(
            c.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: c.tickLower,
                tickUpper: c.tickUpper,
                liquidityDelta: c.op == Op.Add ? delta : -delta,
                salt: saltOf(c.payer)
            }),
            ""
        );
        // An add pays what it owes (fees accrued on an existing position come back to the owner); a remove receives.
        uint256 owed0 = _owed(d.amount0());
        uint256 owed1 = _owed(d.amount1());
        uint256 due0 = _due(d.amount0());
        uint256 due1 = _due(d.amount1());
        if (c.op == Op.Add) {
            if (owed0 > c.bound0) revert ExceedsMax(owed0, c.bound0);
            if (owed1 > c.bound1) revert ExceedsMax(owed1, c.bound1);
        } else {
            if (due0 < c.bound0) revert BelowMin(due0, c.bound0);
            if (due1 < c.bound1) revert BelowMin(due1, c.bound1);
        }
        _settle(c.key.currency0, c.payer, owed0);
        _settle(c.key.currency1, c.payer, owed1);
        _take(c.key.currency0, c.to, due0);
        _take(c.key.currency1, c.to, due1);
        return c.op == Op.Add ? abi.encode(owed0, owed1) : abi.encode(due0, due1);
    }

    function _swap(Call memory c) private returns (bytes memory) {
        BalanceDelta d = MANAGER.swap(
            c.key,
            IPoolManager.SwapParams({
                zeroForOne: c.zeroForOne,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(c.amountIn), // bounded by type(int256).max in swapExactIn
                sqrtPriceLimitX96: c.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int128 inD, int128 outD) = c.zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        uint256 used = _owed(inD);
        if (used != c.amountIn) revert PartialFill(used, c.amountIn);
        uint256 out = _due(outD);
        if (out < c.bound1) revert BelowMin(out, c.bound1);
        (Currency cin, Currency cout) =
            c.zeroForOne ? (c.key.currency0, c.key.currency1) : (c.key.currency1, c.key.currency0);
        _settle(cin, c.payer, used);
        _take(cout, c.to, out);
        return abi.encode(out);
    }

    /// @dev The amount this contract owes the PoolManager for a delta (negative: owed).
    function _owed(int128 d) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return d < 0 ? uint256(-int256(d)) : 0;
    }

    /// @dev The amount the PoolManager owes this contract for a delta (positive: due).
    function _due(int128 d) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return d > 0 ? uint256(int256(d)) : 0;
    }

    function _settle(Currency c, address payer, uint256 amount) private {
        if (amount == 0) return;
        MANAGER.sync(c);
        IERC20(Currency.unwrap(c)).safeTransferFrom(payer, address(MANAGER), amount);
        MANAGER.settle();
    }

    function _take(Currency c, address to, uint256 amount) private {
        if (amount == 0) return;
        MANAGER.take(c, to, amount);
    }
}
