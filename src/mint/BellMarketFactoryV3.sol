// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IBellMarketFactory} from "./interfaces/IBellMarketFactory.sol";
import {IBellMarketFactoryV2} from "./interfaces/IBellMarketFactoryV2.sol";
import {IMarketReferenceFeed, IMarketReferenceFactory} from "./interfaces/IMarketReference.sol";
import {BellMarketV2} from "./BellMarketV2.sol";

/// @title BellMarketFactoryV3
/// @notice Permissionless, ownerless listing of isolated synthetic markets over kind 1 reference feeds
/// (SPEC 4.7, 8.1), with a label menu next to the tier menu. Both menus are written once in the constructor; no
/// function changes them. A label is an ERC-20 (name, symbol) bound to one (feed, tierId, capUsd); each label lists at
/// most one market, at id FIRST_MARKET_ID + labelId.
/// @dev BellMarketFactoryV2 (src/mint/BellMarketFactoryV2.sol) with lower tier bounds and one added tier check; the
/// listing, the labels, the events, the interface (IBellMarketFactoryV2) and the market code (BellMarketV2, stored and
/// deployed as in V2, size fallback 2 of SPEC 11.5) are unchanged. Changes against V2, all in the tier rules:
/// - MIN_MINT_CR_BPS 17_500 (V2: 25_000) and MIN_CR_GAP_BPS 2_500 (V2: 5_000);
/// - the full bonus rule: liqCrBps * 1e4 >= (1e4 + bonusBps) * STEP_BOUND_BPS, refused as BadMenu(i, 2). The feed
///   applies a move below 40 percent without settling (DISCONTINUITY_BPS 4_000 at hold end, ReferenceFeed), so a
///   position at LIQ_CR before such a step is still at or above 1 + bonus after it and liquidates in the partial branch
///   with the full bonus (MarketMath.liquidation step 1), with no bad debt. The rule bounds one step between two
///   liquidation chances; steps that stack while liquidation is closed are outside it.
/// MIN_LIQ_CR_BPS, the bonus, buffer, age, settlement and warm-up bounds, the cap bounds, MIN_COLLATERAL and
/// MIN_DEBT_VALUE are V2's. The constructor checks the labels' charset, length, uniqueness (names compared
/// case-insensitively for ASCII letters) and terms only; which words a label may contain is an off-chain lint of the
/// deployed menu.
/// Market ids are factory-local: id = FIRST_MARKET_ID + labelId counts within this factory only, and the v1
/// BellMarketFactory, a BellMarketFactoryV2, another BellMarketFactoryV3 or a factory on another chain can list a
/// market with the same id. FIRST_MARKET_ID chosen past the other factories' ids keeps the id ranges apart on one
/// chain, but nothing on chain enforces it. A market's identity is (chain id, market address), never its MARKET_ID;
/// indexers, front ends and integrators key markets by that pair.
contract BellMarketFactoryV3 is IBellMarketFactoryV2 {
    /// @notice 17_500 in V3; the IBellMarketFactoryV2 NatSpec states V2's 25_000.
    uint32 public constant MIN_MINT_CR_BPS = 17_500;
    uint32 public constant MIN_LIQ_CR_BPS = 15_000;
    /// @notice 2_500 (mintCr - liqCr) in V3; the IBellMarketFactoryV2 NatSpec states V2's 5_000.
    uint32 public constant MIN_CR_GAP_BPS = 2_500;
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
    uint8 public constant MAX_LABELS = 32;
    uint8 public constant MIN_NAME_LENGTH = 3;
    uint8 public constant MAX_NAME_LENGTH = 40;
    uint8 public constant MIN_SYMBOL_LENGTH = 2;
    uint8 public constant MAX_SYMBOL_LENGTH = 11;
    /// @dev 1 + s with s = 40 percent, the largest move the feed applies without settling (ReferenceFeed
    /// DISCONTINUITY_BPS 4_000), in bps; the full bonus rule of _checkTier. Internal, so the ABI is V2's.
    uint32 internal constant STEP_BOUND_BPS = 14_000;

    /// Field codes of BadMenu(index, field): 0 to 8 follow the Tier struct order; MENU_SIZE flags an empty
    /// menu or one with more than 255 tiers. BadLabels uses MENU_SIZE for an empty or oversized label menu.
    uint8 internal constant MENU_SIZE = type(uint8).max;
    /// Field codes of BadLabels(index, field).
    uint8 internal constant LABEL_NAME = 0;
    uint8 internal constant LABEL_SYMBOL = 1;
    uint8 internal constant LABEL_FEED = 2;
    uint8 internal constant LABEL_TIER = 3;
    uint8 internal constant LABEL_CAP = 4;
    uint8 internal constant LABEL_NAME_TAKEN = 5;
    uint8 internal constant LABEL_SYMBOL_TAKEN = 6;

    address public immutable USDG;
    address public immutable REFERENCE_FACTORY;
    /// @notice Code-only data contract holding BellMarketV2's creation code after a 0x00 prefix byte.
    address public immutable MARKET_CODE;
    /// @notice Id of the market of label 0. Ids are local to this factory, not unique across factories or chains; a
    /// market is identified by (chain id, address) (see the contract NatSpec and IBellMarketFactoryV2).
    uint256 public immutable FIRST_MARKET_ID;

    IBellMarketFactory.Tier[] internal _menu;
    Label[] internal _labels;
    /// @dev labelId => the market listed with it; zero while the label is unused.
    mapping(uint8 => address) internal _labelMarket;
    address[] internal _markets;
    mapping(address => bool) public isMarket;

    /// @notice Checks every tier against the hard bounds and every label against the charset, length, uniqueness and
    /// term rules, and stores both menus once. Uniqueness: no two labels share a name or a symbol, compared after
    /// folding ASCII A-Z to a-z.
    /// @param usdg Collateral token; decimals() must be 6.
    /// @param referenceFactory The ReferenceFeedFactory whose kind 1 feeds may back markets.
    /// @param menu Tier menu, checked as in BellMarketFactoryV2 with the V3 bounds and the full bonus rule.
    /// @param labels Label menu, 1 to MAX_LABELS entries. Each feed must already be a kind 1 feed of referenceFactory
    /// with FACTORY() == referenceFactory, each tierId an index of `menu`, each capUsd within the cap bounds.
    /// @param firstMarketId Id of label 0's market, at most type(uint128).max.
    constructor(
        address usdg,
        address referenceFactory,
        IBellMarketFactory.Tier[] memory menu,
        Label[] memory labels,
        uint256 firstMarketId
    ) {
        _checkDecimals(usdg);
        if (menu.length == 0 || menu.length > type(uint8).max) revert BadMenu(0, MENU_SIZE);
        for (uint256 i; i < menu.length; ++i) {
            _checkTier(uint8(i), menu[i]);
            _menu.push(menu[i]);
        }
        if (labels.length == 0 || labels.length > MAX_LABELS) revert BadLabels(0, MENU_SIZE);
        for (uint256 i; i < labels.length; ++i) {
            _checkLabel(uint8(i), labels, menu.length, referenceFactory);
            _labels.push(labels[i]);
        }
        if (firstMarketId > type(uint128).max) revert BadFirstMarketId(firstMarketId);
        USDG = usdg;
        REFERENCE_FACTORY = referenceFactory;
        FIRST_MARKET_ID = firstMarketId;
        MARKET_CODE = _storeCode(type(BellMarketV2).creationCode);
    }

    /// @inheritdoc IBellMarketFactoryV2
    function createMarket(address feed, uint8 tierId, uint256 capUsd, uint8 labelId)
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
        IBellMarketFactory.Tier memory t = tier(tierId);
        if (capUsd < MIN_CAP_USD || capUsd > MAX_CAP_USD) revert CapOutOfBounds(capUsd);
        Label memory l = label(labelId);
        address used = _labelMarket[labelId];
        if (used != address(0)) revert LabelUsed(labelId, used);
        if (l.feed != feed || l.tierId != tierId || l.capUsd != capUsd) revert LabelTermsMismatch(labelId);
        uint256 price18 = _usablePrice(f, t.mintMaxAge);

        rf.createView(feed, 0);
        marketId = FIRST_MARKET_ID + labelId;
        bytes memory init = _initCode(marketId, l);
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
        _labelMarket[labelId] = market;
        emit MarketCreated(
            marketId, market, feed, tierId, capUsd, BellMarketV2(market).SUPPLY_CAP(), price18, msg.sender
        );
        emit MarketLabel(marketId, labelId, l.name, l.symbol);
    }

    /// @inheritdoc IBellMarketFactoryV2
    function computeMarketAddress(uint8 labelId) external view returns (address) {
        uint256 marketId = FIRST_MARKET_ID + labelId;
        bytes32 initHash = keccak256(_initCode(marketId, label(labelId)));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(marketId), initHash))))
        );
    }

    /// @inheritdoc IBellMarketFactoryV2
    function tierCount() external view returns (uint8) {
        return uint8(_menu.length);
    }

    /// @inheritdoc IBellMarketFactoryV2
    function tier(uint8 tierId) public view returns (IBellMarketFactory.Tier memory) {
        if (tierId >= _menu.length) revert UnknownTier(tierId);
        return _menu[tierId];
    }

    /// @inheritdoc IBellMarketFactoryV2
    function labelCount() external view returns (uint8) {
        return uint8(_labels.length);
    }

    /// @inheritdoc IBellMarketFactoryV2
    function label(uint8 labelId) public view returns (Label memory) {
        if (labelId >= _labels.length) revert UnknownLabel(labelId);
        return _labels[labelId];
    }

    /// @inheritdoc IBellMarketFactoryV2
    function labelMarket(uint8 labelId) external view returns (address) {
        if (labelId >= _labels.length) revert UnknownLabel(labelId);
        return _labelMarket[labelId];
    }

    /// @inheritdoc IBellMarketFactoryV2
    function marketCount() external view returns (uint256) {
        return _markets.length;
    }

    /// @inheritdoc IBellMarketFactoryV2
    function marketAt(uint256 index) external view returns (address) {
        return _markets[index];
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

    /// @dev BellMarketV2 creation code (copied from MARKET_CODE) followed by the ABI-encoded constructor args
    /// (marketId, feed, tierId, capUsd, name, symbol).
    function _initCode(uint256 marketId, Label memory l) internal view returns (bytes memory init) {
        address data = MARKET_CODE;
        bytes memory args = abi.encode(marketId, l.feed, l.tierId, l.capUsd, l.name, l.symbol);
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

    /// @dev V2's tier bounds with MIN_MINT_CR_BPS and MIN_CR_GAP_BPS lowered, plus the full bonus rule (field code 2).
    function _checkTier(uint8 i, IBellMarketFactory.Tier memory t) internal pure {
        if (t.mintCrBps < MIN_MINT_CR_BPS) revert BadMenu(i, 0);
        if (t.liqCrBps < MIN_LIQ_CR_BPS || t.liqCrBps > t.mintCrBps || t.mintCrBps - t.liqCrBps < MIN_CR_GAP_BPS) {
            revert BadMenu(i, 1);
        }
        if (t.bonusBps < MIN_BONUS_BPS || t.bonusBps > MAX_BONUS_BPS || t.bonusBps >= t.liqCrBps - 10_000) {
            revert BadMenu(i, 2);
        }
        // Full bonus rule (V3): LIQ_CR >= (1 + bonus) * 1.4, in uint256 so the products cannot overflow.
        if (uint256(t.liqCrBps) * 10_000 < (10_000 + uint256(t.bonusBps)) * STEP_BOUND_BPS) revert BadMenu(i, 2);
        if (t.bufferFloorBps < MIN_BUFFER_BPS || t.bufferFloorBps > MAX_BUFFER_BPS) revert BadMenu(i, 3);
        if (t.mintMaxAge > MAX_MINT_AGE) revert BadMenu(i, 4);
        if (t.liqMaxAge > MAX_LIQ_AGE) revert BadMenu(i, 5);
        if (t.settleStale < MIN_SETTLE_STALE || t.settleStale > MAX_SETTLE_STALE) revert BadMenu(i, 6);
        if (t.settleGcrBps < MIN_SETTLE_GCR_BPS) revert BadMenu(i, 7);
        if (t.warmup > MAX_WARMUP) revert BadMenu(i, 8);
    }

    /// @dev labels[i] against the rules of IBellMarketFactoryV2.Label and against labels[0..i-1].
    function _checkLabel(uint8 i, Label[] memory labels, uint256 tiers, address referenceFactory) internal view {
        Label memory l = labels[i];
        if (!_isName(bytes(l.name))) revert BadLabels(i, LABEL_NAME);
        if (!_isSymbol(bytes(l.symbol))) revert BadLabels(i, LABEL_SYMBOL);
        if (!_isOndoFeed(l.feed, referenceFactory)) revert BadLabels(i, LABEL_FEED);
        if (l.tierId >= tiers) revert BadLabels(i, LABEL_TIER);
        if (l.capUsd < MIN_CAP_USD || l.capUsd > MAX_CAP_USD) revert BadLabels(i, LABEL_CAP);
        bytes32 n = _foldedHash(bytes(l.name));
        bytes32 s = _foldedHash(bytes(l.symbol));
        for (uint256 j; j < i; ++j) {
            if (_foldedHash(bytes(labels[j].name)) == n) revert BadLabels(i, LABEL_NAME_TAKEN);
            if (_foldedHash(bytes(labels[j].symbol)) == s) revert BadLabels(i, LABEL_SYMBOL_TAKEN);
        }
    }

    /// @dev keccak256 of `b` with ASCII A-Z folded to a-z: the duplicate key of _checkLabel, so two names that differ
    /// only in letter case ("Tanker Line", "TANKER LINE") count as the same name. Symbols are A-Z and 0-9 only, so for
    /// them the fold changes nothing.
    function _foldedHash(bytes memory b) internal pure returns (bytes32) {
        bytes memory out = new bytes(b.length);
        for (uint256 k; k < b.length; ++k) {
            bytes1 c = b[k];
            out[k] = c >= 0x41 && c <= 0x5a ? bytes1(uint8(c) + 32) : c;
        }
        return keccak256(out);
    }

    /// @dev MIN_NAME_LENGTH to MAX_NAME_LENGTH bytes, each printable ASCII (0x20 to 0x7e), the first and the last not a
    /// space (so a name is never blank).
    function _isName(bytes memory b) internal pure returns (bool) {
        uint256 n = b.length;
        if (n < MIN_NAME_LENGTH || n > MAX_NAME_LENGTH) return false;
        if (b[0] == 0x20 || b[n - 1] == 0x20) return false;
        for (uint256 k; k < n; ++k) {
            if (b[k] < 0x20 || b[k] > 0x7e) return false;
        }
        return true;
    }

    /// @dev MIN_SYMBOL_LENGTH to MAX_SYMBOL_LENGTH bytes of A-Z and 0-9, the first a letter.
    function _isSymbol(bytes memory b) internal pure returns (bool) {
        uint256 n = b.length;
        if (n < MIN_SYMBOL_LENGTH || n > MAX_SYMBOL_LENGTH) return false;
        for (uint256 k; k < n; ++k) {
            bytes1 c = b[k];
            bool letter = c >= 0x41 && c <= 0x5a;
            bool digit = c >= 0x30 && c <= 0x39;
            if (!letter && !(digit && k != 0)) return false;
        }
        return true;
    }

    /// @dev The createMarket feed checks as one predicate: a feed of referenceFactory, with FACTORY() equal to it and
    /// KIND() == 1. isFeed comes first, so FACTORY() and KIND() are only called on a listed feed.
    function _isOndoFeed(address feed, address referenceFactory) internal view returns (bool) {
        if (!IMarketReferenceFactory(referenceFactory).isFeed(feed)) return false;
        IMarketReferenceFeed f = IMarketReferenceFeed(feed);
        return f.FACTORY() == referenceFactory && f.KIND() == 1;
    }
}
