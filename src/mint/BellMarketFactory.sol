// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IBellMarketFactory} from "./interfaces/IBellMarketFactory.sol";
import {IMarketReferenceFeed, IMarketReferenceFactory} from "./interfaces/IMarketReference.sol";
import {BellMarket} from "./BellMarket.sol";

/// @title BellMarketFactory
/// @notice Permissionless, ownerless listing of isolated synthetic markets over kind 1 reference feeds
/// (SPEC 4.7, 8.1). The tier menu is written once in the constructor; no function changes it.
/// @dev Size fallback 2 of SPEC 11.5: the constructor stores BellMarket's creation code in a code-only
/// data contract (runtime = 0x00 ++ creationCode, so a call to it stops at once) and createMarket copies it
/// with EXTCODECOPY and deploys with CREATE2 from memory. The factory runtime holds only the data address.
contract BellMarketFactory is IBellMarketFactory {
    uint32 public constant MIN_MINT_CR_BPS = 25_000;
    uint32 public constant MIN_LIQ_CR_BPS = 15_000;
    uint32 public constant MIN_CR_GAP_BPS = 5_000;
    uint32 public constant MIN_BONUS_BPS = 500;
    uint32 public constant MAX_BONUS_BPS = 2_000;
    uint32 public constant MIN_BUFFER_BPS = 1_000;
    uint32 public constant MAX_BUFFER_BPS = 3_000;
    uint32 public constant MAX_MINT_AGE = 172_800;
    uint32 public constant MAX_LIQ_AGE = 345_600;
    uint32 public constant MIN_SETTLE_STALE = 604_800;
    uint32 public constant MAX_SETTLE_STALE = 2_592_000;
    uint32 public constant MIN_SETTLE_GCR_BPS = 10_500;
    uint32 public constant MAX_WARMUP = 2_592_000;
    uint256 public constant MIN_CAP_USD = 1_000e6;
    uint256 public constant MAX_CAP_USD = 25_000e6;
    uint256 public constant MIN_COLLATERAL = 100e6;
    uint256 public constant MIN_DEBT_VALUE = 50e6;
    uint8 public constant USDG_DECIMALS = 6;

    /// Field codes of BadMenu(index, field): 0 to 8 follow the Tier struct order; MENU_SIZE flags an empty
    /// menu or one with more than 255 tiers.
    uint8 internal constant MENU_SIZE = type(uint8).max;

    address public immutable USDG;
    address public immutable REFERENCE_FACTORY;
    /// @notice Code-only data contract holding BellMarket's creation code after a 0x00 prefix byte.
    address public immutable MARKET_CODE;

    Tier[] internal _menu;
    address[] internal _markets;
    mapping(address => bool) public isMarket;

    /// @notice Checks every tier against the hard bounds and stores the menu once.
    /// @param usdg Collateral token; decimals() must be 6.
    /// @param referenceFactory The ReferenceFeedFactory whose kind 1 feeds may back markets.
    /// @param menu Tier menu (T0 only on mainnet; T0, T1, T2 on testnet, SPEC 5.3).
    constructor(address usdg, address referenceFactory, Tier[] memory menu) {
        _checkDecimals(usdg);
        if (menu.length == 0 || menu.length > type(uint8).max) revert BadMenu(0, MENU_SIZE);
        for (uint256 i; i < menu.length; ++i) {
            _checkTier(uint8(i), menu[i]);
            _menu.push(menu[i]);
        }
        USDG = usdg;
        REFERENCE_FACTORY = referenceFactory;
        MARKET_CODE = _storeCode(type(BellMarket).creationCode);
    }

    /// @inheritdoc IBellMarketFactory
    function createMarket(address feed, uint8 tierId, uint256 capUsd)
        external
        returns (uint256 marketId, address market)
    {
        _checkDecimals(USDG);
        IMarketReferenceFactory rf = IMarketReferenceFactory(REFERENCE_FACTORY);
        if (!rf.isFeed(feed)) revert NotCanonicalFeed(feed);
        IMarketReferenceFeed f = IMarketReferenceFeed(feed);
        // SPEC 1.3 (SPEC.md:52): the factory also requires feed.FACTORY() == REFERENCE_FACTORY.
        if (f.FACTORY() != REFERENCE_FACTORY) revert NotCanonicalFeed(feed);
        if (f.KIND() != 1) revert NotOndoKind(feed);
        Tier memory t = tier(tierId);
        if (capUsd < MIN_CAP_USD || capUsd > MAX_CAP_USD) revert CapOutOfBounds(capUsd);
        uint256 price18 = _usablePrice(f, t.mintMaxAge);

        rf.createView(feed, 0);
        marketId = _markets.length;
        bytes memory init = _initCode(marketId, feed, tierId, capUsd);
        assembly ("memory-safe") {
            market := create2(0, add(init, 0x20), mload(init), marketId)
            if iszero(market) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
        _markets.push(market);
        isMarket[market] = true;
        emit MarketCreated(marketId, market, feed, tierId, capUsd, BellMarket(market).SUPPLY_CAP(), price18, msg.sender);
    }

    /// @inheritdoc IBellMarketFactory
    function computeMarketAddress(uint256 marketId, address feed, uint8 tierId, uint256 capUsd)
        external
        view
        returns (address)
    {
        bytes32 initHash = keccak256(_initCode(marketId, feed, tierId, capUsd));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(marketId), initHash))))
        );
    }

    /// @inheritdoc IBellMarketFactory
    function tierCount() external view returns (uint8) {
        return uint8(_menu.length);
    }

    /// @inheritdoc IBellMarketFactory
    function tier(uint8 tierId) public view returns (Tier memory) {
        if (tierId >= _menu.length) revert UnknownTier(tierId);
        return _menu[tierId];
    }

    /// @inheritdoc IBellMarketFactory
    function marketCount() external view returns (uint256) {
        return _markets.length;
    }

    /// @inheritdoc IBellMarketFactory
    function marketAt(uint256 marketId) external view returns (address) {
        return _markets[marketId];
    }

    /// @dev Deploys a data contract whose runtime is 0x00 ++ code (SSTORE2 layout, no functions).
    function _storeCode(bytes memory code) internal returns (address data) {
        bytes memory runtime = abi.encodePacked(hex"00", code);
        // PUSH4 len, DUP1, PUSH1 0x0e, PUSH1 0, CODECOPY, PUSH1 0, RETURN: returns the 14-byte-offset tail.
        bytes memory initCode = abi.encodePacked(hex"63", uint32(runtime.length), hex"80600e6000396000f3", runtime);
        assembly ("memory-safe") {
            data := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(data != address(0) && data.code.length == runtime.length);
    }

    /// @dev BellMarket creation code (copied from MARKET_CODE) followed by the ABI-encoded constructor args.
    function _initCode(uint256 marketId, address feed, uint8 tierId, uint256 capUsd)
        internal
        view
        returns (bytes memory init)
    {
        address data = MARKET_CODE;
        bytes memory args = abi.encode(marketId, feed, tierId, capUsd);
        uint256 codeLen = data.code.length - 1;
        uint256 argsLen = args.length;
        init = new bytes(codeLen + argsLen);
        assembly ("memory-safe") {
            let dst := add(init, 0x20)
            extcodecopy(data, dst, 1, codeLen)
            mcopy(add(dst, codeLen), add(args, 0x20), argsLen)
        }
    }

    function _checkDecimals(address usdg) internal view {
        uint8 dec = IERC20Metadata(usdg).decimals();
        if (dec != USDG_DECIMALS) revert BadUsdgDecimals(dec);
    }

    /// @dev Confirmed round exists, age <= mintMaxAge (saturating), no pending round, no promotion hold.
    function _usablePrice(IMarketReferenceFeed f, uint32 mintMaxAge) internal view returns (uint256) {
        IMarketReferenceFeed.Round memory r;
        try f.confirmed() returns (uint80, IMarketReferenceFeed.Round memory rr) {
            r = rr;
        } catch {
            revert PriceNotUsable();
        }
        uint256 age = block.timestamp > r.observedAt ? block.timestamp - r.observedAt : 0;
        if (r.price18 == 0 || age > mintMaxAge) revert PriceNotUsable();
        (bool pend,,,) = f.pending();
        (bool held,,,,) = f.hold();
        if (pend || held) revert PriceNotUsable();
        return r.price18;
    }

    function _checkTier(uint8 i, Tier memory t) internal pure {
        if (t.mintCrBps < MIN_MINT_CR_BPS) revert BadMenu(i, 0);
        if (t.liqCrBps < MIN_LIQ_CR_BPS || t.liqCrBps > t.mintCrBps || t.mintCrBps - t.liqCrBps < MIN_CR_GAP_BPS) {
            revert BadMenu(i, 1);
        }
        if (t.bonusBps < MIN_BONUS_BPS || t.bonusBps > MAX_BONUS_BPS || t.bonusBps >= t.liqCrBps - 10_000) {
            revert BadMenu(i, 2);
        }
        if (t.bufferFloorBps < MIN_BUFFER_BPS || t.bufferFloorBps > MAX_BUFFER_BPS) revert BadMenu(i, 3);
        if (t.mintMaxAge > MAX_MINT_AGE) revert BadMenu(i, 4);
        if (t.liqMaxAge > MAX_LIQ_AGE) revert BadMenu(i, 5);
        if (t.settleStale < MIN_SETTLE_STALE || t.settleStale > MAX_SETTLE_STALE) revert BadMenu(i, 6);
        if (t.settleGcrBps < MIN_SETTLE_GCR_BPS) revert BadMenu(i, 7);
        if (t.warmup > MAX_WARMUP) revert BadMenu(i, 8);
    }
}
