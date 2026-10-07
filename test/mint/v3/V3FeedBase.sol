// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {BellTypes} from "../../../src/reference/l1/BellTypes.sol";
import {ReferenceFeedFactory} from "../../../src/reference/l2/ReferenceFeedFactory.sol";
import {IReferenceFeed} from "../../../src/reference/l2/interfaces/IReferenceFeed.sol";
import {BellMarketFactoryV3} from "../../../src/mint/BellMarketFactoryV3.sol";
import {BellMarketV2} from "../../../src/mint/BellMarketV2.sol";
import {MarketMath} from "../../../src/mint/MarketMath.sol";
import {IBellMarket} from "../../../src/mint/interfaces/IBellMarket.sol";
import {IBellMarketFactory} from "../../../src/mint/interfaces/IBellMarketFactory.sol";
import {IBellMarketFactoryV2} from "../../../src/mint/interfaces/IBellMarketFactoryV2.sol";
import {MockUSDG} from "../../../src/mocks/MockUSDG.sol";

/// @notice Tier structs of the M1 design (tiers.md section 2), in the field order of IBellMarketFactory.Tier.
abstract contract TierFixtures {
    /// @dev T3, the live bsX0 tier: T0 with no warm-up (script/lib/BellswapScript.sol, branch "T3").
    function t3() internal pure returns (IBellMarketFactory.Tier memory) {
        return IBellMarketFactory.Tier(40_000, 25_000, 1_500, 1_000, 172_800, 259_200, 604_800, 11_000, 0);
    }

    /// @dev TL0, the S0 rehearsal tier; fits BellMarketFactoryV2.
    function tl0() internal pure returns (IBellMarketFactory.Tier memory) {
        return IBellMarketFactory.Tier(25_000, 15_000, 500, 1_000, 172_800, 259_200, 604_800, 10_500, 600);
    }

    /// @dev TL1, the S1 candidate tier; fits only BellMarketFactoryV3.
    function tl1() internal pure returns (IBellMarketFactory.Tier memory) {
        return IBellMarketFactory.Tier(17_500, 15_000, 500, 1_000, 129_600, 259_200, 604_800, 10_500, 600);
    }
}

/// @notice Fixture of the V3 feed path tests: the canonical reference layer (ReferenceFeedFactory, a kind 1
/// ReferenceFeed and its GuardedFeedView, rounds delivered from the aliased L1 relay), MockUSDG and a
/// BellMarketFactoryV3 with the menu [TL0, TL1] and the TL1 label of tiers.md section 3 (Tanker, TANKR, cap 10,000 USDG).
/// Prices are in USD with 18 decimals and every round carries deviationBps 1_000, so the mint buffer is 10 percent
/// (BellMarketV2._priceState). A position with C = 3,000 USDG and D = 20 bsX is at CR 1.5, the TL1 edge, at price 100.
abstract contract V3FeedBase is Test, TierFixtures {
    address internal constant L1_RELAY = address(0xBE11);
    address internal constant ORACLE_L1 = address(0x0AC1E);
    address internal constant TOKEN_L1 = address(0x70CE);
    bytes32 internal constant CODEHASH = keccak256("oracle code");
    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant CAP_TL1 = 10_000e6;
    uint32 internal constant WINDOW = 21_600;
    uint16 internal constant DEV_BPS = 1_000;

    ReferenceFeedFactory internal rf;
    IReferenceFeed internal feed;
    BellMarketFactoryV3 internal factory;
    MockUSDG internal usdg;
    BellMarketV2 internal m;
    uint64 internal lastObs;
    uint64 internal l1Block = 1;

    address internal user = makeAddr("user");
    address internal keeper = makeAddr("keeper");
    address internal holder = makeAddr("holder");

    function setUp() public virtual {
        vm.warp(START);
        rf = new ReferenceFeedFactory(L1_RELAY, ORACLE_L1);
        feed = IReferenceFeed(rf.createFeed(1, ORACLE_L1, TOKEN_L1));
        usdg = new MockUSDG(6, address(this));
        IBellMarketFactory.Tier[] memory menu = new IBellMarketFactory.Tier[](2);
        menu[0] = tl0();
        menu[1] = tl1();
        IBellMarketFactoryV2.Label[] memory labels = new IBellMarketFactoryV2.Label[](1);
        labels[0] = IBellMarketFactoryV2.Label("Tanker", "TANKR", address(feed), 1, CAP_TL1);
        factory = new BellMarketFactoryV3(address(usdg), address(rf), menu, labels, 3);
    }

    // ------------------------------------------------------------------ feed

    /// @dev One kind 1 report delivered from the aliased relay with observedAt `obs` and L1 timestamp `l1Ts`.
    function _deliver(uint128 price18, uint64 obs, uint64 l1Ts) internal returns (IReferenceFeed.Status) {
        BellTypes.Report[] memory r = new BellTypes.Report[](1);
        r[0] = BellTypes.Report(1, ORACLE_L1, TOKEN_L1, price18, obs, 172_800, DEV_BPS, 18, CODEHASH);
        uint80 before = feed.latestRound();
        vm.prank(rf.L1_RELAY_ALIAS());
        rf.report(l1Block++, 0, l1Ts, r);
        assertEq(feed.latestRound(), before + 1, "round accepted");
        lastObs = obs;
        uint80 n = feed.latestRound();
        (uint80 confirmedId,) = feed.confirmed();
        (, uint80 pendingId,,) = feed.pending();
        if (confirmedId == n) return IReferenceFeed.Status.Accepted;
        if (pendingId == n) return IReferenceFeed.Status.AcceptedPending;
        return IReferenceFeed.Status.NotNewer;
    }

    /// @dev A timely post: observed now (or one second after the latest round), delivered with no lag.
    function _post(uint128 price18) internal returns (IReferenceFeed.Status) {
        uint64 obs = uint64(block.timestamp);
        if (obs <= lastObs) obs = lastObs + 1;
        return _deliver(price18, obs, obs > block.timestamp ? obs : uint64(block.timestamp));
    }

    /// @dev A post that confirms at once (within JUMP_BPS of the confirmed price and the anchor).
    function _confirm(uint128 price18) internal {
        assertEq(uint8(_post(price18)), uint8(IReferenceFeed.Status.Accepted), "confirmed at once");
        (, IReferenceFeed.Round memory c) = feed.confirmed();
        assertEq(c.price18, price18);
    }

    function _confirmed() internal view returns (uint128 p) {
        (, IReferenceFeed.Round memory c) = feed.confirmed();
        p = c.price18;
    }

    function _anchor() internal view returns (uint128 price, uint64 since) {
        return feed.anchor();
    }

    /// @dev Moves the confirmed price up to `target` in steps of at most 20 percent, one per epoch, then rolls the
    /// epoch once more, so the anchor equals `target` and a new epoch starts now.
    function _walkTo(uint128 target) internal {
        uint128 c = _confirmed();
        while (c != target) {
            (, uint64 since) = _anchor();
            if (block.timestamp < uint256(since) + WINDOW) vm.warp(uint256(since) + WINDOW);
            uint128 next = c * 6 / 5;
            if (next > target) next = target;
            _confirm(next);
            c = next;
        }
        (, uint64 s2) = _anchor();
        if (block.timestamp < uint256(s2) + WINDOW) vm.warp(uint256(s2) + WINDOW);
        _confirm(target);
        (uint128 a, uint64 s3) = _anchor();
        assertEq(a, target, "anchor at target");
        assertEq(s3, block.timestamp, "epoch starts now");
    }

    /// @dev Posts a jump that goes pending and warps to its promotion; returns the end of the hold it starts.
    function _promote(uint128 price18) internal returns (uint64 holdUntil) {
        assertEq(uint8(_post(price18)), uint8(IReferenceFeed.Status.AcceptedPending), "pending");
        (,,, uint64 promotableAt) = feed.pending();
        vm.warp(promotableAt);
        bool held;
        (held,,, holdUntil,) = feed.hold();
        assertTrue(held, "promoted and held");
    }

    // ------------------------------------------------------------------ market

    /// @dev Lists the TL1 label at `openPrice`, warps past the 600 s warm-up and refreshes the round.
    function _list(uint128 openPrice) internal {
        _post(openPrice);
        (, address a) = factory.createMarket(address(feed), 1, CAP_TL1, 0);
        m = BellMarketV2(a);
        vm.warp(m.WARMUP_END());
        _post(openPrice);
        assertTrue(m.prices().mintOk, "mint open after warm-up");
    }

    function _open(address owner, uint256 c, uint256 d) internal returns (uint256 id) {
        usdg.mint(owner, c);
        vm.startPrank(owner);
        usdg.approve(address(m), type(uint256).max);
        id = m.open(c, d, owner);
        vm.stopPrank();
    }

    function _pos(uint256 id) internal view returns (uint256 c, uint256 d) {
        IBellMarket.Position memory p = m.position(id);
        return (p.collateral, p.debt);
    }

    function _unbacked() internal view returns (uint256 ub) {
        (,, ub,) = m.totals();
    }

    /// @dev Liquidates `id` from `who` with `maxRepay`, after asserting the market's result equals MarketMath at the
    /// market price; returns MarketMath's result (branch, repay, seize, bad debt).
    function _liquidate(address who, uint256 id, uint256 maxRepay) internal returns (MarketMath.Liq memory l) {
        (uint256 c, uint256 d) = _pos(id);
        uint256 p = m.prices().confirmed18;
        l = MarketMath.liquidation(c, d, p, maxRepay, m.MINT_CR_BPS(), m.BONUS_BPS(), m.MIN_COLLATERAL());
        uint256 ub0 = _unbacked();
        vm.prank(who);
        (uint256 repaid, uint256 seized) = m.liquidate(id, maxRepay, 0, who);
        assertEq(repaid, l.repay, "repay");
        assertEq(seized, l.seize, "seize");
        assertEq(_unbacked() - ub0, l.badDebt, "unbacked supply grows by the bad debt");
    }

    /// @dev The partial branch with the full bonus and no bad debt, the remainder restored to MINT_CR within rounding.
    function _assertPartialFullBonus(uint256 id, MarketMath.Liq memory l) internal view {
        uint256 p = m.prices().confirmed18;
        assertFalse(l.full, "partial branch");
        assertEq(l.badDebt, 0, "no bad debt");
        assertEq(l.seize, MarketMath.withBonus(l.repay, p, m.BONUS_BPS()), "full 5 percent bonus");
        (uint256 c, uint256 d) = _pos(id);
        assertGe(c, m.MIN_COLLATERAL(), "remainder at or above MIN_COLLATERAL");
        // Restored to M: (C' + 2) * 1e34 >= D' * P * MINT_CR (LiquidationFuzz M5 rounding allowance).
        assertTrue((c + 2) * 1e34 >= d * p * m.MINT_CR_BPS(), "restored to 175 percent");
        assertApproxEqAbs(m.crBps(id, p), m.MINT_CR_BPS(), 1, "CR 175 percent within one bps");
    }
}
