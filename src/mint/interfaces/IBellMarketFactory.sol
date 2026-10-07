// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IBellMarketFactory
/// @notice Permissionless, ownerless listing of isolated synthetic markets over kind 1 reference feeds,
/// with a tier menu fixed at deployment (SPEC 4.7).
interface IBellMarketFactory {
    struct Tier {
        uint32 mintCrBps; // collateral ratio floor for mint and withdraw
        uint32 liqCrBps; // liquidation threshold
        uint32 bonusBps; // liquidation bonus
        uint32 bufferFloorBps; // minimum mint buffer; effective buffer = max(floor, deviationBps)
        uint32 mintMaxAge; // s
        uint32 liqMaxAge; // s
        uint32 settleStale; // s
        uint32 settleGcrBps; // global CR settlement trigger
        uint32 warmup; // s after creation with no minting
    }

    error NotCanonicalFeed(address feed);
    error NotOndoKind(address feed);
    error UnknownTier(uint8 tierId);
    error CapOutOfBounds(uint256 capUsd);
    error PriceNotUsable();
    error BadMenu(uint8 index, uint8 field);
    error BadUsdgDecimals(uint8 decimals);

    event MarketCreated(
        uint256 indexed marketId,
        address indexed market,
        address indexed feed,
        uint8 tierId,
        uint256 capUsd,
        uint256 supplyCap,
        uint256 price18AtCreation,
        address creator
    );

    /// @notice The collateral token (6 decimals).
    function USDG() external view returns (address);
    /// @notice The ReferenceFeedFactory whose kind 1 feeds may back markets.
    function REFERENCE_FACTORY() external view returns (address);
    /// @notice 25_000.
    function MIN_MINT_CR_BPS() external pure returns (uint32);
    /// @notice 15_000.
    function MIN_LIQ_CR_BPS() external pure returns (uint32);
    /// @notice 5_000 (mintCr - liqCr).
    function MIN_CR_GAP_BPS() external pure returns (uint32);
    /// @notice 500.
    function MIN_BONUS_BPS() external pure returns (uint32);
    /// @notice 2_000.
    function MAX_BONUS_BPS() external pure returns (uint32);
    /// @notice 1_000.
    function MIN_BUFFER_BPS() external pure returns (uint32);
    /// @notice 3_000 (bufferFloorBps bound and mint cutoff, SPEC 8.2).
    function MAX_BUFFER_BPS() external pure returns (uint32);
    /// @notice 172_800 s.
    function MAX_MINT_AGE() external pure returns (uint32);
    /// @notice 345_600 s.
    function MAX_LIQ_AGE() external pure returns (uint32);
    /// @notice 604_800 s.
    function MIN_SETTLE_STALE() external pure returns (uint32);
    /// @notice 2_592_000 s.
    function MAX_SETTLE_STALE() external pure returns (uint32);
    /// @notice 10_500.
    function MIN_SETTLE_GCR_BPS() external pure returns (uint32);
    /// @notice 2_592_000 s.
    function MAX_WARMUP() external pure returns (uint32);
    /// @notice 1_000e6.
    function MIN_CAP_USD() external pure returns (uint256);
    /// @notice 25_000e6.
    function MAX_CAP_USD() external pure returns (uint256);
    /// @notice 100e6.
    function MIN_COLLATERAL() external pure returns (uint256);
    /// @notice 50e6.
    function MIN_DEBT_VALUE() external pure returns (uint256);
    /// @notice 6, checked in the constructor and in createMarket.
    function USDG_DECIMALS() external pure returns (uint8);

    /// @notice Number of tiers in the menu.
    function tierCount() external view returns (uint8);
    /// @notice One tier of the menu; reverts UnknownTier.
    function tier(uint8 tierId) external view returns (Tier memory);

    /// @notice Anyone. feed must be a ReferenceFeed of REFERENCE_FACTORY with KIND() == 1, with a confirmed
    /// round no older than the tier's mintMaxAge, no pending round and no promotion hold.
    /// supplyCap = capUsd * 1e12 * 1e18 / price18; the market also stores CAP_USD = capUsd and
    /// DISC_BASE = feed.discontinuityCount() (SPEC 8.1). Also calls REFERENCE_FACTORY.createView(feed, 0).
    function createMarket(address feed, uint8 tierId, uint256 capUsd)
        external
        returns (uint256 marketId, address market);

    /// @notice CREATE2 address of the market with these creation arguments.
    function computeMarketAddress(uint256 marketId, address feed, uint8 tierId, uint256 capUsd)
        external
        view
        returns (address);
    /// @notice True iff market was deployed by this factory.
    function isMarket(address market) external view returns (bool);
    /// @notice Number of markets created.
    function marketCount() external view returns (uint256);
    /// @notice Market with this id.
    function marketAt(uint256 marketId) external view returns (address);
}
