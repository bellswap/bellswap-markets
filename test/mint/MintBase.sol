// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {BellMarketFactory} from "../../src/mint/BellMarketFactory.sol";
import {BellMarket} from "../../src/mint/BellMarket.sol";
import {IBellMarketFactory} from "../../src/mint/interfaces/IBellMarketFactory.sol";
import {IBellMarket} from "../../src/mint/interfaces/IBellMarket.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";
import {MockMarketFeed, MockMarketRefFactory} from "./mocks/MockMarketFeed.sol";

/// Shared fixture: MockUSDG (6 decimals, controller = this), a mock reference factory, a kind 1 mock
/// feed at P0 = 20 USD, and a BellMarketFactory with the testnet menu T0, T1, T2 of SPEC 5.3.
abstract contract MintBase is Test {
    uint256 internal constant START = 1_700_000_000;
    uint128 internal constant P0 = 20e18;

    MockUSDG internal usdg;
    MockMarketRefFactory internal refFactory;
    MockMarketFeed internal feed;
    BellMarketFactory internal factory;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal liquidator = makeAddr("liquidator");

    function t0() internal pure returns (IBellMarketFactory.Tier memory) {
        return IBellMarketFactory.Tier(40_000, 25_000, 1_500, 1_000, 172_800, 259_200, 604_800, 11_000, 259_200);
    }

    function t1() internal pure returns (IBellMarketFactory.Tier memory) {
        return IBellMarketFactory.Tier(25_000, 17_500, 1_200, 1_000, 172_800, 259_200, 604_800, 11_000, 259_200);
    }

    function t2() internal pure returns (IBellMarketFactory.Tier memory) {
        return IBellMarketFactory.Tier(40_000, 25_000, 1_500, 1_000, 172_800, 259_200, 604_800, 11_000, 600);
    }

    function menu() internal pure returns (IBellMarketFactory.Tier[] memory m) {
        m = new IBellMarketFactory.Tier[](3);
        m[0] = t0();
        m[1] = t1();
        m[2] = t2();
    }

    function setUp() public virtual {
        vm.warp(START);
        usdg = new MockUSDG(6, address(this));
        refFactory = new MockMarketRefFactory();
        factory = new BellMarketFactory(address(usdg), address(refFactory), menu());
        feed = newFeed(P0);
    }

    function newFeed(uint128 price) internal returns (MockMarketFeed f) {
        f = new MockMarketFeed(1);
        refFactory.register(address(f));
        f.postNow(price);
    }

    /// Lists a market on `f` through the factory under test. MintBaseV2 (test/mint/v2/MintBaseV2.sol) overrides it to
    /// list a BellMarketV2 through BellMarketFactoryV2, so every suite on this fixture also runs against V2; the
    /// market is used through the BellMarket type, whose ABI BellMarketV2 shares.
    function createMarketOn(address f, uint8 tierId, uint256 capUsd) internal virtual returns (address a) {
        (, a) = factory.createMarket(f, tierId, capUsd);
    }

    /// Creates a market on `f` with tier `tierId` and cap 25,000 USDG, then warps past warm-up and
    /// re-posts the current price so it stays fresh.
    function listLive(MockMarketFeed f, uint8 tierId) internal returns (BellMarket m) {
        address a = createMarketOn(address(f), tierId, 25_000e6);
        m = BellMarket(a);
        vm.warp(m.WARMUP_END());
        (, MockMarketFeed.Round memory r) = f.confirmed();
        f.postNow(r.price18);
    }

    function fund(address who, uint256 amount, BellMarket m) internal {
        usdg.mint(who, amount);
        vm.prank(who);
        usdg.approve(address(m), type(uint256).max);
    }

    /// Opens a position for `owner` with collateral c and debt d minted to `to`.
    function openPos(BellMarket m, address owner, uint256 c, uint256 d, address to) internal returns (uint256 id) {
        fund(owner, c, m);
        vm.prank(owner);
        id = m.open(c, d, to);
    }

    function coll(BellMarket m, uint256 id) internal view returns (uint256) {
        return m.position(id).collateral;
    }

    function debt(BellMarket m, uint256 id) internal view returns (uint256) {
        return m.position(id).debt;
    }

    function openDebt(BellMarket m) internal view returns (uint256 n) {
        (,,, n) = m.totals();
    }
}
