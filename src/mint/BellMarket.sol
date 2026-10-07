// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IBellMarket} from "./interfaces/IBellMarket.sol";
import {IBellMarketFactory} from "./interfaces/IBellMarketFactory.sol";
import {IReferenced} from "./interfaces/IReferenced.sol";
import {IMarketReferenceFeed, IMarketReferenceFactory} from "./interfaces/IMarketReference.sol";
import {MarketMath} from "./MarketMath.sol";

/// @title BellMarket
/// @notice One isolated synthetic market (SPEC 4.8, section 8). It is the synthetic ERC-20 (18 decimals,
/// name "Bellswap Synthetic #<id>", symbol "bsX<id>", no transfer hooks) and it holds self-collateralised
/// USDG positions. No owner, no admin, no fee, no proxy, no delegatecall. Every parameter is immutable.
contract BellMarket is IBellMarket, IReferenced, ERC20, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Liquidation grace after the latest late round (SPEC 5.3).
    uint64 public constant LAG_GRACE = 7_200;
    /// @notice Wait between arm and Stale trigger, L2 time (SPEC 5.3).
    uint64 public constant ARM_DELAY = 86_400;
    /// @notice Above this relayed deviationBps minting closes (SPEC 8.2).
    uint32 public constant MAX_BUFFER_BPS = 3_000;

    address public immutable FACTORY;
    address public immutable USDG;
    address public immutable FEED;
    address public immutable REFERENCE_VIEW;
    uint256 public immutable MARKET_ID;
    uint256 public immutable SUPPLY_CAP;
    uint256 public immutable CAP_USD;
    uint256 public immutable DISC_BASE;
    uint64 public immutable WARMUP_END;
    uint32 public immutable MINT_CR_BPS;
    uint32 public immutable LIQ_CR_BPS;
    uint32 public immutable BONUS_BPS;
    uint32 public immutable BUFFER_FLOOR_BPS;
    uint32 public immutable MINT_MAX_AGE;
    uint32 public immutable LIQ_MAX_AGE;
    uint32 public immutable SETTLE_STALE;
    uint32 public immutable SETTLE_GCR_BPS;
    uint256 public immutable MIN_COLLATERAL;
    uint256 public immutable MIN_DEBT_VALUE;

    Position[] internal _positions;
    uint256 internal _totalCollateral;
    uint256 internal _totalDebt;
    uint256 internal _unbackedSupply;
    uint256 internal _openDebtPositions;

    uint64 internal _armedAt;
    uint80 internal _armedLatestRound;
    Phase internal _phase;
    SettleReason internal _reason;

    uint256 internal _settlePrice18;
    uint256 internal _supplyAtTrigger;
    uint256 internal _pool;
    uint256 internal _remaining;
    uint256 internal _redeemedBurned;
    uint256 internal _redeemedPaid;

    /// @notice Deployed only by BellMarketFactory.createMarket, which checked the feed, tier, cap and price
    /// in the same transaction and created GuardedFeedView(feed, 0) first. Reads its parameters back from
    /// the factory so the CREATE2 address depends only on (marketId, feed, tierId, capUsd).
    constructor(uint256 marketId, address feed, uint8 tierId, uint256 capUsd)
        ERC20(
            string.concat("Bellswap Synthetic #", Strings.toString(marketId)),
            string.concat("bsX", Strings.toString(marketId))
        )
    {
        IBellMarketFactory f = IBellMarketFactory(msg.sender);
        IBellMarketFactory.Tier memory t = f.tier(tierId);
        IMarketReferenceFeed rf = IMarketReferenceFeed(feed);
        (, IMarketReferenceFeed.Round memory r) = rf.confirmed();

        FACTORY = msg.sender;
        USDG = f.USDG();
        FEED = feed;
        REFERENCE_VIEW = IMarketReferenceFactory(f.REFERENCE_FACTORY()).viewOf(feed, 0);
        MARKET_ID = marketId;
        CAP_USD = capUsd;
        SUPPLY_CAP = capUsd * 1e30 / r.price18;
        DISC_BASE = rf.discontinuityCount();
        WARMUP_END = uint64(block.timestamp) + t.warmup;
        MINT_CR_BPS = t.mintCrBps;
        LIQ_CR_BPS = t.liqCrBps;
        BONUS_BPS = t.bonusBps;
        BUFFER_FLOOR_BPS = t.bufferFloorBps;
        MINT_MAX_AGE = t.mintMaxAge;
        LIQ_MAX_AGE = t.liqMaxAge;
        SETTLE_STALE = t.settleStale;
        SETTLE_GCR_BPS = t.settleGcrBps;
        MIN_COLLATERAL = f.MIN_COLLATERAL();
        MIN_DEBT_VALUE = f.MIN_DEBT_VALUE();
    }

    // ------------------------------------------------------------------ modifiers and guards

    modifier onlyPhase(Phase want) {
        if (_phase != want) revert WrongPhase(_phase);
        _;
    }

    function _ownedPosition(uint256 id) internal view returns (Position storage p) {
        p = _positions[id];
        if (p.owner != msg.sender) revert NotOwner();
    }

    // ------------------------------------------------------------------ IReferenced

    /// @inheritdoc IBellMarket
    function referenceFeed() external view override(IBellMarket, IReferenced) returns (address) {
        return REFERENCE_VIEW;
    }

    /// @inheritdoc IBellMarket
    function settlementState()
        external
        view
        override(IBellMarket, IReferenced)
        returns (uint8 phase_, uint256 pool, uint256 supplyAtTrigger)
    {
        return (uint8(_phase), _pool, _supplyAtTrigger);
    }

    // ------------------------------------------------------------------ Live phase

    /// @inheritdoc IBellMarket
    function open(uint256 collateral, uint256 mintAmount, address to)
        external
        nonReentrant
        onlyPhase(Phase.Live)
        returns (uint256 id)
    {
        if (collateral < MIN_COLLATERAL) revert BelowMinimum();
        IERC20(USDG).safeTransferFrom(msg.sender, address(this), collateral);
        id = _positions.length;
        _positions.push(
            Position({owner: msg.sender, collateral: collateral.toUint128(), debt: 0, excess: 0, processed: false})
        );
        _totalCollateral += collateral;
        emit PositionOpened(id, msg.sender);
        emit Deposited(id, msg.sender, collateral);
        if (mintAmount > 0) _mintTo(_positions[id], id, mintAmount, to);
    }

    /// @inheritdoc IBellMarket
    function deposit(uint256 id, uint256 amount) external nonReentrant onlyPhase(Phase.Live) {
        if (amount == 0) revert BelowMinimum();
        Position storage p = _positions[id];
        IERC20(USDG).safeTransferFrom(msg.sender, address(this), amount);
        p.collateral = (uint256(p.collateral) + amount).toUint128();
        _totalCollateral += amount;
        emit Deposited(id, msg.sender, amount);
    }

    /// @inheritdoc IBellMarket
    function withdraw(uint256 id, uint256 amount, address to) external nonReentrant onlyPhase(Phase.Live) {
        Position storage p = _ownedPosition(id);
        uint256 c = p.collateral;
        if (amount == 0 || amount > c) revert BelowMinimum();
        uint256 left = c - amount;
        if (left != 0 && left < MIN_COLLATERAL) revert BelowMinimum();
        uint256 d = p.debt;
        uint256 pMint;
        if (d > 0) {
            PriceView memory pv = _requireMintable();
            pMint = pv.mint18;
            if (!MarketMath.mintRatioOk(left, d, pMint, MINT_CR_BPS)) revert BelowMintRatio();
        }
        p.collateral = uint128(left);
        _totalCollateral -= amount;
        emit Withdrawn(id, to, amount, pMint);
        IERC20(USDG).safeTransfer(to, amount);
    }

    /// @inheritdoc IBellMarket
    function mint(uint256 id, uint256 amount, address to) external nonReentrant onlyPhase(Phase.Live) {
        _mintTo(_ownedPosition(id), id, amount, to);
    }

    /// @inheritdoc IBellMarket
    function repay(uint256 id, uint256 amount) external nonReentrant onlyPhase(Phase.Live) {
        Position storage p = _positions[id];
        uint256 d = p.debt;
        if (amount > d) amount = d;
        if (amount == 0) revert BelowMinimum();
        _burn(msg.sender, amount);
        p.debt = uint128(d - amount);
        _totalDebt -= amount;
        if (amount == d) --_openDebtPositions;
        emit Repaid(id, msg.sender, amount);
    }

    /// @inheritdoc IBellMarket
    function close(uint256 id, address to) external nonReentrant onlyPhase(Phase.Live) {
        Position storage p = _ownedPosition(id);
        uint256 d = p.debt;
        uint256 c = p.collateral;
        if (d > 0) {
            _burn(msg.sender, d);
            p.debt = 0;
            _totalDebt -= d;
            --_openDebtPositions;
        }
        p.collateral = 0;
        _totalCollateral -= c;
        emit Closed(id, to, c);
        if (c > 0) IERC20(USDG).safeTransfer(to, c);
    }

    /// @inheritdoc IBellMarket
    function liquidate(uint256 id, uint256 maxRepay, uint256 minSeize, address to)
        external
        nonReentrant
        onlyPhase(Phase.Live)
        returns (uint256 repaid, uint256 seized)
    {
        Position storage p = _positions[id];
        (PriceView memory pv,) = _priceState();
        if (!pv.liqOk) revert PriceNotUsable();
        uint256 c = p.collateral;
        uint256 d = p.debt;
        uint256 price = pv.confirmed18;
        if (!MarketMath.below(c, d, price, LIQ_CR_BPS)) revert NotLiquidatable();
        MarketMath.Liq memory l = MarketMath.liquidation(c, d, price, maxRepay, MINT_CR_BPS, BONUS_BPS, MIN_COLLATERAL);
        if (l.repay == 0) revert NotLiquidatable();
        if (l.seize < minSeize) revert Slippage();

        _burn(msg.sender, l.repay);
        uint256 dOut = l.repay + l.badDebt;
        p.debt = uint128(d - dOut);
        p.collateral = uint128(c - l.seize);
        _totalDebt -= dOut;
        _totalCollateral -= l.seize;
        if (l.badDebt > 0) _unbackedSupply += l.badDebt;
        if (dOut == d) --_openDebtPositions;
        emit Liquidated(id, msg.sender, l.repay, l.seize, price, l.full, l.badDebt);
        if (l.seize > 0) IERC20(USDG).safeTransfer(to, l.seize);
        return (l.repay, l.seize);
    }

    /// @inheritdoc IBellMarket
    function armSettlement() external nonReentrant onlyPhase(Phase.Live) {
        (PriceView memory pv, bool disc) = _priceState();
        if (disc) revert NoTrigger();
        uint80 latest = IMarketReferenceFeed(FEED).latestRound();
        uint64 armedAt = _armedAt;
        bool hadArm = armedAt != 0;
        if (hadArm && latest == _armedLatestRound) revert AlreadyArmed(armedAt);
        if (!_staleCondition(pv)) revert NoTrigger();
        if (hadArm) emit SettlementDisarmed(latest);
        uint64 nowTs = uint64(block.timestamp);
        _armedAt = nowTs;
        _armedLatestRound = latest;
        emit SettlementArmed(nowTs, latest, nowTs + ARM_DELAY, msg.sender);
    }

    /// @inheritdoc IBellMarket
    function triggerSettlement() external nonReentrant onlyPhase(Phase.Live) {
        (PriceView memory pv, bool disc) = _priceState();
        IMarketReferenceFeed f = IMarketReferenceFeed(FEED);
        if (disc) {
            (uint80 preJump,) = f.discontinuity(DISC_BASE);
            IMarketReferenceFeed.Round memory r = f.round(preJump);
            _trigger(SettleReason.Discontinuity, r.price18, r.observedAt);
            return;
        }
        if (_staleCondition(pv)) {
            uint64 armedAt = _armedAt;
            if (armedAt == 0 || f.latestRound() != _armedLatestRound) revert NotArmed();
            if (block.timestamp < uint256(armedAt) + ARM_DELAY) revert ArmDelayPending(armedAt + ARM_DELAY);
            _trigger(SettleReason.Stale, pv.confirmed18, pv.observedAt);
            return;
        }
        if (_globalCondition(pv)) {
            _trigger(SettleReason.GlobalUndercollateralised, pv.confirmed18, pv.observedAt);
            return;
        }
        // A stored arm whose stale condition no longer holds was voided by a round accepted after it
        // (a confirmed round ends the staleness, a pending round blocks it): NotArmed (SPEC 8.6).
        if (_armedAt != 0) revert NotArmed();
        revert NoTrigger();
    }

    // ------------------------------------------------------------------ Settling and Final phases

    /// @inheritdoc IBellMarket
    function processPositions(uint256[] calldata ids) external nonReentrant onlyPhase(Phase.Settling) {
        uint256 pEnd = _settlePrice18;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            Position storage p = _positions[id];
            uint256 d = p.debt;
            if (p.processed || d == 0) continue;
            uint256 c = p.collateral;
            uint256 claim = MarketMath.settleClaim(c, d, pEnd);
            uint256 excess = c - claim;
            p.collateral = 0;
            p.debt = 0;
            p.excess = uint128(excess);
            p.processed = true;
            _pool += claim;
            _totalCollateral -= c;
            _totalDebt -= d;
            --_openDebtPositions;
            --_remaining;
            emit PositionProcessed(id, claim, excess);
        }
    }

    /// @inheritdoc IBellMarket
    function finalize() external nonReentrant onlyPhase(Phase.Settling) {
        if (_remaining != 0) revert Unprocessed(_remaining);
        _phase = Phase.Final;
        emit Finalized(_pool, _supplyAtTrigger);
    }

    /// @inheritdoc IBellMarket
    function redeem(uint256 amount, address to) external nonReentrant onlyPhase(Phase.Final) returns (uint256 paid) {
        if (amount == 0) revert NothingToClaim();
        paid = Math.mulDiv(amount, _pool, _supplyAtTrigger);
        _burn(msg.sender, amount);
        _redeemedBurned += amount;
        _redeemedPaid += paid;
        emit Redeemed(msg.sender, to, amount, paid);
        if (paid > 0) IERC20(USDG).safeTransfer(to, paid);
    }

    /// @inheritdoc IBellMarket
    function claimExcess(uint256 id, address to) external nonReentrant returns (uint256 amount) {
        if (_phase == Phase.Live) revert WrongPhase(Phase.Live);
        Position storage p = _ownedPosition(id);
        if (p.processed) {
            amount = p.excess;
            p.excess = 0;
        } else if (p.debt == 0) {
            amount = p.collateral;
            p.collateral = 0;
            _totalCollateral -= amount;
        } else {
            revert Unprocessed(_remaining);
        }
        if (amount == 0) revert NothingToClaim();
        emit ExcessClaimed(id, to, amount);
        IERC20(USDG).safeTransfer(to, amount);
    }

    // ------------------------------------------------------------------ views

    /// @inheritdoc IBellMarket
    function phase() external view returns (Phase) {
        return _phase;
    }

    /// @inheritdoc IBellMarket
    function position(uint256 id) external view returns (Position memory) {
        return _positions[id];
    }

    /// @inheritdoc IBellMarket
    function positionCount() external view returns (uint256) {
        return _positions.length;
    }

    /// @inheritdoc IBellMarket
    function prices() external view returns (PriceView memory pv) {
        (pv,) = _priceState();
    }

    /// @inheritdoc IBellMarket
    function crBps(uint256 id, uint256 price18) external view returns (uint256) {
        Position storage p = _positions[id];
        uint256 v = MarketMath.value(p.debt, price18);
        if (v == 0) return type(uint256).max;
        return uint256(p.collateral) * 1e4 / v;
    }

    /// @inheritdoc IBellMarket
    function maxLiquidation(uint256 id) external view returns (uint256 repay_, uint256 seize, bool full) {
        Position storage p = _positions[id];
        (PriceView memory pv,) = _priceState();
        uint256 c = p.collateral;
        uint256 d = p.debt;
        if (!pv.liqOk || !MarketMath.below(c, d, pv.confirmed18, LIQ_CR_BPS)) return (0, 0, false);
        MarketMath.Liq memory l =
            MarketMath.liquidation(c, d, pv.confirmed18, type(uint256).max, MINT_CR_BPS, BONUS_BPS, MIN_COLLATERAL);
        return (l.repay, l.seize, l.full);
    }

    /// @inheritdoc IBellMarket
    function canTrigger() external view returns (bool ok, SettleReason reason) {
        if (_phase != Phase.Live) return (false, SettleReason.None);
        (PriceView memory pv, bool disc) = _priceState();
        if (disc) return (true, SettleReason.Discontinuity);
        if (_staleCondition(pv)) {
            if (
                _armedAt != 0 && IMarketReferenceFeed(FEED).latestRound() == _armedLatestRound
                    && block.timestamp >= uint256(_armedAt) + ARM_DELAY
            ) return (true, SettleReason.Stale);
            return (false, SettleReason.None);
        }
        if (_globalCondition(pv)) return (true, SettleReason.GlobalUndercollateralised);
        return (false, SettleReason.None);
    }

    /// @inheritdoc IBellMarket
    function canArm() external view returns (bool ok) {
        if (_phase != Phase.Live) return false;
        (PriceView memory pv, bool disc) = _priceState();
        if (disc || !_staleCondition(pv)) return false;
        return !_validArm();
    }

    /// @inheritdoc IBellMarket
    function armState()
        external
        view
        returns (bool armed, uint64 armedAt, uint80 armedLatestRound, uint64 triggerableAt)
    {
        armedAt = _armedAt;
        armedLatestRound = _armedLatestRound;
        armed = _validArm();
        triggerableAt = armedAt == 0 ? 0 : armedAt + ARM_DELAY;
    }

    /// @inheritdoc IBellMarket
    function totals()
        external
        view
        returns (uint256 totalCollateral, uint256 totalDebt, uint256 unbackedSupply, uint256 openDebtPositions)
    {
        return (_totalCollateral, _totalDebt, _unbackedSupply, _openDebtPositions);
    }

    /// @inheritdoc IBellMarket
    function settlement()
        external
        view
        returns (
            SettleReason reason,
            uint256 price18,
            uint256 supplyAtTrigger,
            uint256 pool,
            uint256 remaining,
            uint256 redeemedBurned,
            uint256 redeemedPaid
        )
    {
        return (_reason, _settlePrice18, _supplyAtTrigger, _pool, _remaining, _redeemedBurned, _redeemedPaid);
    }

    /// @inheritdoc IBellMarket
    function assets() public view returns (uint256) {
        return IERC20(USDG).balanceOf(address(this));
    }

    /// @inheritdoc IBellMarket
    function liabilities() public view returns (uint256) {
        (PriceView memory pv,) = _priceState();
        return MarketMath.value(totalSupply(), pv.confirmed18);
    }

    /// @inheritdoc IBellMarket
    function coverageBps() external view returns (uint256) {
        uint256 l = liabilities();
        if (l == 0) return type(uint256).max;
        return Math.mulDiv(assets(), 1e4, l);
    }

    // ------------------------------------------------------------------ internals

    /// @dev Prices and gates of SPEC 8.2. `disc` is FEED.discontinuityCount() > DISC_BASE.
    function _priceState() internal view returns (PriceView memory pv, bool disc) {
        IMarketReferenceFeed f = IMarketReferenceFeed(FEED);
        (bool held, uint80 preJump,,,) = f.hold();
        IMarketReferenceFeed.Round memory r;
        if (held) r = f.round(preJump);
        else (, r) = f.confirmed();
        (bool pend,,,) = f.pending();
        uint64 late = f.lastLateReceivedAt();
        disc = f.discontinuityCount() > DISC_BASE;

        uint256 price = r.price18;
        pv.confirmed18 = price;
        pv.observedAt = r.observedAt;
        pv.pending = pend || held;
        pv.lagGraceUntil = late == 0 ? 0 : late + LAG_GRACE;
        // The feed's latest relayed configuration, not the round's: Ondo changes allowedDeviationBps without a new
        // observation, and a config-only report updates only this (SPEC 6.6, 8.2).
        (uint16 cfgDev,,) = f.config();
        uint256 dev = cfgDev;
        if (dev <= MAX_BUFFER_BPS) {
            uint256 buffer = dev > BUFFER_FLOOR_BPS ? dev : BUFFER_FLOOR_BPS;
            pv.mint18 = Math.ceilDiv(price * (1e4 + buffer), 1e4);
        }
        uint256 age = MarketMath.age(r.observedAt);
        bool live = _phase == Phase.Live;
        if (!live) pv.mintBlock = MintBlock.Phase;
        else if (block.timestamp < WARMUP_END) pv.mintBlock = MintBlock.Warmup;
        else if (pv.pending) pv.mintBlock = MintBlock.Pending;
        else if (age > MINT_MAX_AGE) pv.mintBlock = MintBlock.Age;
        else if (dev > MAX_BUFFER_BPS) pv.mintBlock = MintBlock.BufferCap;
        else if (disc) pv.mintBlock = MintBlock.Discontinuity;
        pv.mintOk = pv.mintBlock == MintBlock.None;
        pv.liqOk = live && age <= LIQ_MAX_AGE && block.timestamp >= pv.lagGraceUntil && !disc;
    }

    function _requireMintable() internal view returns (PriceView memory pv) {
        (pv,) = _priceState();
        if (pv.mintBlock == MintBlock.Warmup) revert WarmingUp();
        if (!pv.mintOk) revert PriceNotUsable();
    }

    function _mintTo(Position storage p, uint256 id, uint256 amount, address to) internal {
        if (amount == 0) revert BelowMinimum();
        PriceView memory pv = _requireMintable();
        uint256 dOld = p.debt;
        uint256 d = dOld + amount;
        if (!MarketMath.mintRatioOk(p.collateral, d, pv.mint18, MINT_CR_BPS)) revert BelowMintRatio();
        uint256 supply = totalSupply() + amount;
        if (supply > SUPPLY_CAP || MarketMath.valueUp(supply, pv.mint18) > CAP_USD) revert CapExceeded();
        if (MarketMath.value(d, pv.confirmed18) < MIN_DEBT_VALUE) revert BelowMinimum();
        p.debt = d.toUint128();
        _totalDebt += amount;
        if (dOld == 0) ++_openDebtPositions;
        _mint(to, amount);
        emit Minted(id, to, amount, pv.mint18);
    }

    /// @dev age(observedAt of the market round) > SETTLE_STALE with no pending round and no hold.
    function _staleCondition(PriceView memory pv) internal view returns (bool) {
        return !pv.pending && MarketMath.age(pv.observedAt) > SETTLE_STALE;
    }

    /// @dev liqOk and totalCollateral * 1e4 < V(totalDebt + unbackedSupply, P) * SETTLE_GCR, with V floored as
    /// defined in SPEC 8.2 ("Units": V(D, P) = D * P / 1e30). Unlike the 8.4 health test, 8.6 does not state an exact
    /// form.
    function _globalCondition(PriceView memory pv) internal view returns (bool) {
        return pv.liqOk
            && _totalCollateral * MarketMath.BPS
                < MarketMath.value(_totalDebt + _unbackedSupply, pv.confirmed18) * SETTLE_GCR_BPS;
    }

    function _validArm() internal view returns (bool) {
        return _armedAt != 0 && IMarketReferenceFeed(FEED).latestRound() == _armedLatestRound;
    }

    function _trigger(SettleReason reason, uint256 pEnd, uint64 observedAt) internal {
        uint256 supply = totalSupply();
        _phase = Phase.Settling;
        _reason = reason;
        _settlePrice18 = pEnd;
        _supplyAtTrigger = supply;
        _remaining = _openDebtPositions;
        _armedAt = 0;
        _armedLatestRound = 0;
        emit SettlementTriggered(reason, pEnd, observedAt, supply, msg.sender);
    }
}
