// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IBellswapHook
/// @notice Interface of the Bellswap pool layer hook (SPEC 4.6). An immutable Uniswap v4 hook with a
///         per-pool fee curve anchored to a reference feed (SPEC 7). Flags BEFORE_INITIALIZE and
///         BEFORE_SWAP only (low 14 address bits 0x2080), no return-delta flag.
interface IBellswapHook {
    /// @notice Directional charges the gap fee only on trades that move the pool price further from
    ///         the anchor; Symmetric charges it on both directions.
    enum FeeMode {
        Directional,
        Symmetric
    }

    /// @notice Fresh: every feed readable and within staleAfter. Stale: a feed is older than
    ///         staleAfter. Broken: a feed is unreadable, short, non-positive, out of range or
    ///         future-dated. Settled: the synthetic of a synthetic pool is not Live, or its
    ///         settlementState() cannot be read.
    enum Regime {
        Fresh,
        Stale,
        Broken,
        Settled
    }

    /// @notice Per-pool fee curve, fixed at creation.
    /// @param feed base/USD AggregatorV3 on this chain.
    /// @param quoteFeed quote/USD AggregatorV3, or address(0) = the creator declares quote == 1 USD.
    /// @param baseIsCurrency0 True if cfg.feed prices currency0 of the PoolKey.
    /// @param baseFee Fee in pips while Fresh and inside the band, [MIN_FEE, 10_000].
    /// @param maxFee Fee cap in pips, [baseFee, MAX_FEE]; charged in every non-Fresh regime.
    /// @param bandBps Gap tolerated before the gap fee starts, [0, 2_000].
    /// @param slope Pips per bp of gap beyond the band, [0, 1_000]; 0 = flat fee preset.
    /// @param staleAfter Seconds from the feed's updatedAt, [3_600, 604_800].
    /// @param mode Directional or Symmetric gap fee.
    struct PoolConfig {
        address feed;
        address quoteFeed;
        bool baseIsCurrency0;
        uint24 baseFee;
        uint24 maxFee;
        uint16 bandBps;
        uint16 slope;
        uint32 staleAfter;
        FeeMode mode;
    }

    /// @notice Everything recorded about a pool at creation; written once per PoolId.
    struct PoolInfo {
        PoolConfig cfg;
        uint8 baseDecimals; // [0, 18], read once
        uint8 quoteDecimals; // [0, 18], read once
        uint8 feedDecimals; // [6, 18], read once
        uint8 quoteFeedDecimals; // [6, 18] or 0 if no quote feed
        bool synthetic; // created through createSyntheticPool
        address creator;
        bytes32 configHash; // keccak256(abi.encode(cfg))
    }

    error OnlyViaCreatePool();
    error NotPoolManager();
    error WrongHook();
    error NotDynamicFee();
    error NativeNotSupported();
    error UseSyntheticPool();
    error NotReferenced();
    error BadConfig(uint8 code);
    error BadDecimals(address token);
    error FeedUnusable(address feed);
    error InitPriceOffAnchor(uint256 gapBps);

    /// @notice Emitted once per pool, by createPool or createSyntheticPool.
    event PoolCreated(
        PoolId indexed id,
        address indexed feed,
        address indexed creator,
        PoolKey key,
        PoolConfig cfg,
        bytes32 configHash,
        bool synthetic
    );

    /// @notice The Uniswap v4 PoolManager this hook serves (immutable).
    function POOL_MANAGER() external view returns (IPoolManager);

    /// @notice The quote currency of every synthetic pool (immutable).
    function USDG() external view returns (address);

    /// @notice Lowest fee the hook ever returns, in pips: 100.
    function MIN_FEE() external pure returns (uint24);

    /// @notice Highest fee the hook ever returns, in pips: 100_000.
    function MAX_FEE() external pure returns (uint24);

    /// @notice Gas forwarded to every external read of a feed or token: 100_000.
    function FEED_CALL_GAS() external pure returns (uint256);

    /// @notice Floor of the init price band at creation, in bps: 1_000.
    function INIT_BAND_FLOOR_BPS() external pure returns (uint16);

    /// @notice Creates and initialises a generic pool with a caller-chosen fee curve.
    /// @param key The PoolKey; hooks must be this hook and fee DYNAMIC_FEE_FLAG.
    /// @param cfg The fee curve, checked against the SPEC 5.2 bounds.
    /// @param sqrtPriceX96 Initial price; must be within max(bandBps, INIT_BAND_FLOOR_BPS) of the anchor.
    /// @return id The PoolId.
    /// @return tick The initial tick returned by PoolManager.initialize.
    function createPool(PoolKey calldata key, PoolConfig calldata cfg, uint160 sqrtPriceX96)
        external
        returns (PoolId id, int24 tick);

    /// @notice Creates and initialises the pool of a synthetic against USDG with the canonical curve.
    /// @param synth A token that declares referenceFeed().
    /// @param tickSpacing Tick spacing of the key, [1, 32_767].
    /// @param sqrtPriceX96 Initial price; must be within INIT_BAND_FLOOR_BPS of the anchor.
    /// @return id The PoolId.
    /// @return tick The initial tick returned by PoolManager.initialize.
    function createSyntheticPool(address synth, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        returns (PoolId id, int24 tick);

    /// @notice The canonical fee curve of every synthetic pool (SPEC 5.2).
    /// @param feed The synthetic's reference feed.
    /// @param baseIsCurrency0 True if the synthetic sorts as currency0.
    /// @return The PoolConfig.
    function canonicalConfig(address feed, bool baseIsCurrency0) external pure returns (PoolConfig memory);

    /// @notice What the hook recorded about a pool. All zero for an unknown pool.
    /// @param id The PoolId.
    /// @return The PoolInfo.
    function poolInfo(PoolId id) external view returns (PoolInfo memory);

    /// @notice The anchor of a pool right now.
    /// @param id The PoolId.
    /// @return quotePerBaseX18 Whole quote tokens per whole base token, times 1e18; 0 when Broken.
    /// @return regime The regime beforeSwap would see.
    /// @return age Seconds since the oldest feed's updatedAt; 0 when Broken.
    function anchorPriceX18(PoolId id) external view returns (uint256 quotePerBaseX18, Regime regime, uint256 age);

    /// @notice The fee beforeSwap would charge right now for a swap in the given direction without a price
    ///         limit: the larger of the SPEC 7.3 fees at the current pool price and at the pool price
    ///         before the first swap of the current block (the current price when no swap happened yet in
    ///         this block). A swap whose sqrtPriceLimitX96 lies strictly between those two prices is read
    ///         at its limit instead of the block-start price, so it is charged this fee or less.
    /// @param key The PoolKey.
    /// @param zeroForOne Swap direction as in SwapParams.
    /// @return fee Fee in pips, without the override flag.
    /// @return gapBps Gap between the price that set the fee and the anchor, in bps of the anchor (0 when Broken).
    /// @return away True if the swap moves that price away from the anchor.
    /// @return regime The regime.
    function quoteFee(PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (uint24 fee, uint256 gapBps, bool away, Regime regime);

    /// @notice Number of pools created on this hook.
    function poolCount() external view returns (uint256);

    /// @notice The PoolId at an index of the creation list.
    /// @param index Position in creation order, [0, poolCount()).
    function poolAt(uint256 index) external view returns (PoolId);
}
