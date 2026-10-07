// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MintBase} from "../MintBase.sol";
import {BellMarket} from "../../../src/mint/BellMarket.sol";
import {BellMarketFactoryV2} from "../../../src/mint/BellMarketFactoryV2.sol";
import {BellMarketV2} from "../../../src/mint/BellMarketV2.sol";
import {IBellMarket} from "../../../src/mint/interfaces/IBellMarket.sol";
import {IBellMarketFactoryV2} from "../../../src/mint/interfaces/IBellMarketFactoryV2.sol";

/// A v1 BellMarket and a BellMarketV2 on one kind 1 feed (the mainnet layout: bsX0 next to a labelled market). Caps,
/// positions, arms and settlement are per market; the feed's price state (pending, age, hold) gates both at once;
/// DISC_BASE is per market, fixed at listing. Price moves are posted on the mock feed directly (test/mint/mocks).
contract TwoMarketsOneFeedTest is MintBase {
    BellMarket internal m1;
    BellMarketV2 internal m2;
    BellMarketFactoryV2 internal f2;

    function setUp() public override {
        super.setUp();
        IBellMarketFactoryV2.Label[] memory l = new IBellMarketFactoryV2.Label[](2);
        l[0] = IBellMarketFactoryV2.Label("Bellswap Test Label", "BSTL", address(feed), 2, 1_000e6);
        l[1] = IBellMarketFactoryV2.Label("Bellswap Late Label", "BSLL", address(feed), 2, 1_000e6);
        f2 = new BellMarketFactoryV2(address(usdg), address(refFactory), menu(), l, 2);
        (, address a1) = factory.createMarket(address(feed), 2, 25_000e6); // T2: warm-up 600 s
        m1 = BellMarket(a1);
        (, address a2) = f2.createMarket(address(feed), 2, 1_000e6, 0);
        m2 = BellMarketV2(a2);
        vm.warp(block.timestamp + 600);
        feed.postNow(P0);
    }

    function _m2() internal view returns (BellMarket) {
        return BellMarket(address(m2));
    }

    function _totals(address m) internal view returns (bytes32) {
        (uint256 c, uint256 d, uint256 u, uint256 n) = IBellMarket(m).totals();
        return keccak256(abi.encode(c, d, u, n, IBellMarket(m).positionCount(), IERC20Like(m).totalSupply()));
    }

    function test_sameFeedSameViewDistinctTokens() public view {
        assertEq(m1.FEED(), m2.FEED());
        assertEq(m1.referenceFeed(), m2.referenceFeed());
        assertEq(m1.symbol(), "bsX0");
        assertEq(m2.symbol(), "BSTL");
        assertEq(m1.MARKET_ID(), 0);
        assertEq(m2.MARKET_ID(), 2, "V2 ids start at FIRST_MARKET_ID");
    }

    /// Separate caps: the V2 market's 1,000 USD cap binds while the v1 market (25,000 USD) keeps minting.
    function test_capsArePerMarket() public {
        // At Pmint 22: 45 tokens are 990 USD, 46 are 1,012 USD.
        openPos(_m2(), alice, 5_000e6, 45e18, alice);
        fund(bob, 5_000e6, _m2());
        vm.prank(bob);
        vm.expectRevert(IBellMarket.CapExceeded.selector);
        m2.open(5_000e6, 1e18, bob);
        openPos(m1, bob, 5_000e6, 45e18, bob);
        openPos(m1, carol, 5_000e6, 45e18, carol);
        assertEq(m1.totalSupply(), 90e18);
        assertEq(m2.totalSupply(), 45e18);
    }

    /// Shared price state: a pending round, an old round and a hold block minting on both markets at once.
    function test_priceGatesAreShared() public {
        feed.postPending(2 * P0, uint64(block.timestamp));
        assertEq(uint8(m1.prices().mintBlock), uint8(IBellMarket.MintBlock.Pending));
        assertEq(uint8(m2.prices().mintBlock), uint8(IBellMarket.MintBlock.Pending));
        feed.clearPending();
        assertTrue(m1.prices().mintOk && m2.prices().mintOk);
        vm.warp(block.timestamp + 172_801);
        assertEq(uint8(m1.prices().mintBlock), uint8(IBellMarket.MintBlock.Age));
        assertEq(uint8(m2.prices().mintBlock), uint8(IBellMarket.MintBlock.Age));
    }

    /// Market-specific undercollateralisation: a price rise takes the thinly collateralised V2 market below
    /// SETTLE_GCR while the v1 market stays healthy; settling V2 leaves v1's accounting as it was.
    function test_globalUndercollateralisationIsPerMarket() public {
        openPos(_m2(), alice, 1_000e6, 10e18, alice); // CR 500 percent at 20
        openPos(m1, bob, 20_000e6, 10e18, bob); // CR 10,000 percent at 20
        feed.postNow(200e18); // x10: V2 at 50 percent, v1 at 1,000 percent
        (bool ok2, IBellMarket.SettleReason r2) = m2.canTrigger();
        (bool ok1,) = m1.canTrigger();
        assertTrue(ok2);
        assertEq(uint8(r2), uint8(IBellMarket.SettleReason.GlobalUndercollateralised));
        assertFalse(ok1);

        bytes32 before = _totals(address(m1));
        m2.triggerSettlement();
        assertEq(uint8(m2.phase()), uint8(IBellMarket.Phase.Settling));
        assertEq(uint8(m1.phase()), uint8(IBellMarket.Phase.Live));
        assertEq(_totals(address(m1)), before, "v1 accounting unchanged");
        vm.expectRevert(IBellMarket.NoTrigger.selector);
        m1.triggerSettlement();
        // v1 still operates: bob repays and closes.
        vm.prank(bob);
        m1.close(0, bob);
        assertEq(m1.totalSupply(), 0);
    }

    /// Arms are per market but read the shared feed: two independent arms are both voided by one new round.
    function test_sharedRoundVoidsBothArms() public {
        openPos(m1, alice, 1_000e6, 10e18, alice);
        openPos(_m2(), bob, 1_000e6, 10e18, bob);
        vm.warp(block.timestamp + 604_801);
        m1.armSettlement();
        vm.warp(block.timestamp + 3_600);
        m2.armSettlement(); // armed later, independently
        (bool armed1,,,) = m1.armState();
        (bool armed2,,,) = m2.armState();
        assertTrue(armed1 && armed2);

        feed.postNow(P0); // one accepted round on the shared feed
        (armed1,,,) = m1.armState();
        (armed2,,,) = m2.armState();
        assertFalse(armed1 || armed2, "one round voids both arms");
        vm.warp(block.timestamp + 86_400);
        vm.expectRevert(IBellMarket.NotArmed.selector);
        m1.triggerSettlement();
        vm.expectRevert(IBellMarket.NotArmed.selector);
        m2.triggerSettlement();
    }

    /// DISC_BASE is fixed at listing: a discontinuity before the second V2 listing counts for the markets listed
    /// before it only.
    function test_discontinuityBaseIsPerListing() public {
        feed.addDiscontinuity(1, 1);
        feed.postNow(P0);
        (, address late) = f2.createMarket(address(feed), 2, 1_000e6, 1);
        assertEq(m1.DISC_BASE(), 0);
        assertEq(m2.DISC_BASE(), 0);
        assertEq(BellMarketV2(late).DISC_BASE(), 1);
        (bool ok1, IBellMarket.SettleReason r1) = m1.canTrigger();
        (bool ok2,) = m2.canTrigger();
        (bool okLate,) = BellMarketV2(late).canTrigger();
        assertTrue(ok1 && ok2);
        assertEq(uint8(r1), uint8(IBellMarket.SettleReason.Discontinuity));
        assertFalse(okLate);
    }

    /// Settlement of one synth leaves the other synth's balances and redemption path alone.
    function test_settlementOfV1LeavesV2Untouched() public {
        openPos(m1, alice, 1_000e6, 10e18, alice);
        openPos(_m2(), bob, 1_000e6, 10e18, bob);
        feed.addDiscontinuity(1, 1);
        bytes32 before = _totals(address(m2));
        uint256 bobBal = m2.balanceOf(bob);
        m1.triggerSettlement();
        uint256[] memory ids = new uint256[](1);
        m1.processPositions(ids);
        m1.finalize();
        vm.prank(alice);
        m1.redeem(10e18, alice);
        assertEq(_totals(address(m2)), before);
        assertEq(m2.balanceOf(bob), bobBal);
        assertEq(uint8(m2.phase()), uint8(IBellMarket.Phase.Live));
    }
}

/// Polish Q5: two BellMarketV2 markets of one factory on one feed (labels 0 and 1). Positions, settlement and
/// redemption are per market: a price rise takes the thin market below SETTLE_GCR, it settles, processes, finalizes
/// and redeems, while the other V2 market keeps its accounting and stays Live. The hook side (each pool Settled only
/// with its own market) is test/integration/MarketV2Hook.t.sol test_twoV2MarketsOnOneFeedSettleSeparately.
contract TwoV2MarketsOneFeedTest is MintBase {
    BellMarketFactoryV2 internal f2;
    BellMarketV2 internal a;
    BellMarketV2 internal b;

    function setUp() public override {
        super.setUp();
        IBellMarketFactoryV2.Label[] memory l = new IBellMarketFactoryV2.Label[](2);
        l[0] = IBellMarketFactoryV2.Label("Bellswap Test Label", "BSTL", address(feed), 2, 25_000e6);
        l[1] = IBellMarketFactoryV2.Label("Bellswap Late Label", "BSLL", address(feed), 2, 25_000e6);
        f2 = new BellMarketFactoryV2(address(usdg), address(refFactory), menu(), l, 2);
        (, address a1) = f2.createMarket(address(feed), 2, 25_000e6, 0);
        (, address a2) = f2.createMarket(address(feed), 2, 25_000e6, 1);
        (a, b) = (BellMarketV2(a1), BellMarketV2(a2));
        vm.warp(block.timestamp + 600);
        feed.postNow(P0);
    }

    function _bm(BellMarketV2 m) internal pure returns (BellMarket) {
        return BellMarket(address(m));
    }

    function _totals(address m) internal view returns (bytes32) {
        (uint256 c, uint256 d, uint256 u, uint256 n) = IBellMarket(m).totals();
        return keccak256(abi.encode(c, d, u, n, IBellMarket(m).positionCount(), IERC20Like(m).totalSupply()));
    }

    function test_twoV2MarketsSettleSeparately() public {
        assertEq(a.FEED(), b.FEED());
        assertEq(a.MARKET_ID(), 2);
        assertEq(b.MARKET_ID(), 3);
        openPos(_bm(a), alice, 1_000e6, 10e18, alice); // CR 500 percent at 20
        openPos(_bm(b), bob, 20_000e6, 10e18, bob); // CR 10,000 percent at 20
        feed.postNow(200e18); // x10: a at 50 percent, b at 1,000 percent
        (bool okA, IBellMarket.SettleReason rA) = a.canTrigger();
        (bool okB,) = b.canTrigger();
        assertTrue(okA);
        assertEq(uint8(rA), uint8(IBellMarket.SettleReason.GlobalUndercollateralised));
        assertFalse(okB);

        bytes32 before = _totals(address(b));
        uint256 bobBal = b.balanceOf(bob);
        a.triggerSettlement();
        vm.expectRevert(IBellMarket.NoTrigger.selector);
        b.triggerSettlement();
        uint256[] memory ids = new uint256[](1);
        a.processPositions(ids);
        a.finalize();
        assertEq(uint8(a.phase()), uint8(IBellMarket.Phase.Final));
        uint256 got = usdg.balanceOf(alice);
        vm.prank(alice);
        a.redeem(10e18, alice);
        assertGt(usdg.balanceOf(alice), got, "a redeems");
        assertEq(a.totalSupply(), 0);

        assertEq(_totals(address(b)), before, "b accounting unchanged");
        assertEq(b.balanceOf(bob), bobBal);
        assertEq(uint8(b.phase()), uint8(IBellMarket.Phase.Live));
        vm.prank(bob);
        b.close(0, bob);
        assertEq(b.totalSupply(), 0);
    }
}

interface IERC20Like {
    function totalSupply() external view returns (uint256);
}
