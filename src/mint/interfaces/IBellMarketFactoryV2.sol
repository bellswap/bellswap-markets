// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBellMarketFactory} from "./IBellMarketFactory.sol";

/// @title IBellMarketFactoryV2
/// @notice Permissionless, ownerless listing of isolated synthetic markets over kind 1 reference feeds, with a tier
/// menu and a label menu both fixed at deployment. A label is a token name and symbol bound to one set of creation
/// terms (feed, tier, cap); each label lists at most one market, so two markets of one factory never share a name or a
/// symbol, and nobody can spend a label on other terms than the deployer fixed. There is no free text at call time.
/// @dev Same immutables, constants, tier checks and createMarket refusals as IBellMarketFactory (v1). It does not
/// inherit IBellMarketFactory: the v1 createMarket(address,uint8,uint256) and computeMarketAddress overloads do not
/// exist here. Market ids are local to this factory: id = FIRST_MARKET_ID + labelId. FIRST_MARKET_ID keeps them apart
/// from the ids a v1 factory had listed when this one was deployed; v1 stays permissionless and keeps counting, so a
/// market's identity is (chain, address), never its id.
interface IBellMarketFactoryV2 {
    /// @notice One entry of the label menu: the market's ERC-20 name and symbol and the only terms it lists on.
    struct Label {
        string name; // 3 to 40 printable ASCII bytes (0x20 to 0x7e), no leading or trailing space
        string symbol; // 2 to 11 bytes of A-Z and 0-9, not starting with a digit
        address feed; // the kind 1 ReferenceFeed of REFERENCE_FACTORY the market reads
        uint8 tierId; // index in the tier menu
        uint256 capUsd; // within [MIN_CAP_USD, MAX_CAP_USD]
    }

    error NotCanonicalFeed(address feed);
    error NotOndoKind(address feed);
    error UnknownTier(uint8 tierId);
    error CapOutOfBounds(uint256 capUsd);
    error PriceNotUsable();
    error BadMenu(uint8 index, uint8 field);
    error BadUsdgDecimals(uint8 decimals);
    /// @notice A label of the constructor's menu fails a check. Field codes: 0 name, 1 symbol, 2 feed, 3 tierId,
    /// 4 capUsd, 5 name used by an earlier label, 6 symbol used by an earlier label; 255 flags an empty menu or one with
    /// more than MAX_LABELS labels.
    error BadLabels(uint8 index, uint8 field);
    /// @notice FIRST_MARKET_ID is above type(uint128).max.
    error BadFirstMarketId(uint256 firstMarketId);
    error UnknownLabel(uint8 labelId);
    error LabelUsed(uint8 labelId, address market);
    /// @notice createMarket's (feed, tierId, capUsd) differ from the terms the label is bound to.
    error LabelTermsMismatch(uint8 labelId);

    /// @notice Same signature and fields as IBellMarketFactory.MarketCreated.
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
    /// @notice Emitted right after MarketCreated: the label the market took.
    event MarketLabel(uint256 indexed marketId, uint8 indexed labelId, string name, string symbol);

    /// @notice The collateral token (6 decimals).
    function USDG() external view returns (address);
    /// @notice The ReferenceFeedFactory whose kind 1 feeds may back markets.
    function REFERENCE_FACTORY() external view returns (address);
    /// @notice Code-only data contract holding BellMarketV2's creation code after a 0x00 prefix byte.
    function MARKET_CODE() external view returns (address);
    /// @notice Id of the market of label 0; the market of label i has id FIRST_MARKET_ID + i.
    function FIRST_MARKET_ID() external view returns (uint256);
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
    /// @notice 32, the largest label menu.
    function MAX_LABELS() external pure returns (uint8);
    /// @notice 3, the shortest label name in bytes.
    function MIN_NAME_LENGTH() external pure returns (uint8);
    /// @notice 40, the longest label name in bytes.
    function MAX_NAME_LENGTH() external pure returns (uint8);
    /// @notice 2, the shortest label symbol in bytes.
    function MIN_SYMBOL_LENGTH() external pure returns (uint8);
    /// @notice 11, the longest label symbol in bytes.
    function MAX_SYMBOL_LENGTH() external pure returns (uint8);

    /// @notice Number of tiers in the menu.
    function tierCount() external view returns (uint8);
    /// @notice One tier of the menu; reverts UnknownTier.
    function tier(uint8 tierId) external view returns (IBellMarketFactory.Tier memory);

    /// @notice Number of labels in the menu.
    function labelCount() external view returns (uint8);
    /// @notice One label of the menu; reverts UnknownLabel.
    function label(uint8 labelId) external view returns (Label memory);
    /// @notice The market listed with this label, or address(0) while the label is unused; reverts UnknownLabel.
    function labelMarket(uint8 labelId) external view returns (address);

    /// @notice Anyone. The checks and effects of IBellMarketFactory.createMarket, in the same order, and in addition:
    /// labelId is in the menu (UnknownLabel), not used yet (LabelUsed), and bound to exactly (feed, tierId, capUsd)
    /// (LabelTermsMismatch); these run after the cap check and before the price check. The market gets id
    /// FIRST_MARKET_ID + labelId and the label's name and symbol, and the label is used from then on. Emits
    /// MarketCreated, then MarketLabel.
    function createMarket(address feed, uint8 tierId, uint256 capUsd, uint8 labelId)
        external
        returns (uint256 marketId, address market);

    /// @notice CREATE2 address of the market of this label. The label fixes every constructor argument, so the
    /// address is known before the market exists and does not depend on other listings; reverts UnknownLabel.
    function computeMarketAddress(uint8 labelId) external view returns (address);
    /// @notice True iff market was deployed by this factory.
    function isMarket(address market) external view returns (bool);
    /// @notice Number of markets created.
    function marketCount() external view returns (uint256);
    /// @notice The market created index-th (zero-based creation order). Not a market id: the id of the market at an
    /// index is its MARKET_ID().
    function marketAt(uint256 index) external view returns (address);
}
