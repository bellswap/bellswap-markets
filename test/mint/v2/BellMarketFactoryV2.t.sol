// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {MintBase} from "../MintBase.sol";
import {BellMarketFactoryV2} from "../../../src/mint/BellMarketFactoryV2.sol";
import {BellMarketV2} from "../../../src/mint/BellMarketV2.sol";
import {IBellMarketFactory} from "../../../src/mint/interfaces/IBellMarketFactory.sol";
import {IBellMarketFactoryV2} from "../../../src/mint/interfaces/IBellMarketFactoryV2.sol";
import {MockMarketFeed} from "../mocks/MockMarketFeed.sol";
import {MutableDecimalsToken} from "../mocks/MutableDecimalsToken.sol";

/// BellMarketFactoryV2: the v1 constants, menu checks and createMarket refusals (test/mint/BellMarketFactory.t.sol),
/// plus the label menu: constructor checks (charset, length, terms, uniqueness, size), use-once labels bound to their
/// terms, ids FIRST_MARKET_ID + labelId independent of creation order, CREATE2 addresses known per label, both events,
/// no v1 createMarket overload and no admin surface.
contract BellMarketFactoryV2Test is MintBase {
    uint256 internal constant FIRST = 2; // next to bsX0 and bsX1 of the v1 factory
    uint256 internal constant EIP170 = 24_576;
    uint256 internal constant EIP3860 = 49_152;

    BellMarketFactoryV2 internal f2;
    MockMarketFeed internal feedB;

    function setUp() public override {
        super.setUp();
        feedB = newFeed(50e18);
        f2 = new BellMarketFactoryV2(address(usdg), address(refFactory), menu(), labels(), FIRST);
    }

    /// Label 0: T0 on `feed`, cap 5,000; label 1: T2 on `feed`, cap 25,000; label 2: T1 on feedB, cap 1,000.
    function labels() internal view returns (IBellMarketFactoryV2.Label[] memory l) {
        l = new IBellMarketFactoryV2.Label[](3);
        l[0] = IBellMarketFactoryV2.Label("Bellswap Alpha", "ALPHA", address(feed), 0, 5_000e6);
        l[1] = IBellMarketFactoryV2.Label("Bellswap Beta", "BETA", address(feed), 2, 25_000e6);
        l[2] = IBellMarketFactoryV2.Label("Bellswap Gamma", "GAMMA2", address(feedB), 1, 1_000e6);
    }

    function _label(string memory name, string memory symbol)
        internal
        view
        returns (IBellMarketFactoryV2.Label[] memory l)
    {
        l = new IBellMarketFactoryV2.Label[](1);
        l[0] = IBellMarketFactoryV2.Label(name, symbol, address(feed), 0, 1_000e6);
    }

    function _deploy(IBellMarketFactoryV2.Label[] memory l) internal returns (BellMarketFactoryV2) {
        return new BellMarketFactoryV2(address(usdg), address(refFactory), menu(), l, FIRST);
    }

    function _expectBadLabels(IBellMarketFactoryV2.Label[] memory l, uint8 index, uint8 field) internal {
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.BadLabels.selector, index, field));
        _deploy(l);
    }

    function _create(uint8 labelId) internal returns (uint256 id, address a) {
        IBellMarketFactoryV2.Label memory l = f2.label(labelId);
        return f2.createMarket(l.feed, l.tierId, l.capUsd, labelId);
    }

    // ------------------------------------------------------------ constants, immutables and menus

    function test_constantsEqualV1() public view {
        assertEq(f2.MIN_MINT_CR_BPS(), factory.MIN_MINT_CR_BPS());
        assertEq(f2.MIN_LIQ_CR_BPS(), factory.MIN_LIQ_CR_BPS());
        assertEq(f2.MIN_CR_GAP_BPS(), factory.MIN_CR_GAP_BPS());
        assertEq(f2.MIN_BONUS_BPS(), factory.MIN_BONUS_BPS());
        assertEq(f2.MAX_BONUS_BPS(), factory.MAX_BONUS_BPS());
        assertEq(f2.MIN_BUFFER_BPS(), factory.MIN_BUFFER_BPS());
        assertEq(f2.MAX_BUFFER_BPS(), factory.MAX_BUFFER_BPS());
        assertEq(f2.MAX_MINT_AGE(), factory.MAX_MINT_AGE());
        assertEq(f2.MAX_LIQ_AGE(), factory.MAX_LIQ_AGE());
        assertEq(f2.MIN_SETTLE_STALE(), factory.MIN_SETTLE_STALE());
        assertEq(f2.MAX_SETTLE_STALE(), factory.MAX_SETTLE_STALE());
        assertEq(f2.MIN_SETTLE_GCR_BPS(), factory.MIN_SETTLE_GCR_BPS());
        assertEq(f2.MAX_WARMUP(), factory.MAX_WARMUP());
        assertEq(f2.MIN_CAP_USD(), factory.MIN_CAP_USD());
        assertEq(f2.MAX_CAP_USD(), factory.MAX_CAP_USD());
        assertEq(f2.MIN_COLLATERAL(), factory.MIN_COLLATERAL());
        assertEq(f2.MIN_DEBT_VALUE(), factory.MIN_DEBT_VALUE());
        assertEq(f2.USDG_DECIMALS(), factory.USDG_DECIMALS());
        assertEq(f2.MAX_LABELS(), 32);
        assertEq(f2.MIN_NAME_LENGTH(), 3);
        assertEq(f2.MAX_NAME_LENGTH(), 40);
        assertEq(f2.MIN_SYMBOL_LENGTH(), 2);
        assertEq(f2.MAX_SYMBOL_LENGTH(), 11);
        assertEq(f2.USDG(), address(usdg));
        assertEq(f2.REFERENCE_FACTORY(), address(refFactory));
        assertEq(f2.FIRST_MARKET_ID(), FIRST);
    }

    function test_menuStoredOnce() public view {
        assertEq(f2.tierCount(), 3);
        for (uint8 i; i < 3; ++i) {
            assertEq(keccak256(abi.encode(f2.tier(i))), keccak256(abi.encode(factory.tier(i))), "tier equals v1");
        }
    }

    function test_tier_unknownReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.UnknownTier.selector, uint8(3)));
        f2.tier(3);
    }

    function test_labelsStoredOnce() public view {
        assertEq(f2.labelCount(), 3);
        IBellMarketFactoryV2.Label[] memory want = labels();
        for (uint8 i; i < 3; ++i) {
            assertEq(keccak256(abi.encode(f2.label(i))), keccak256(abi.encode(want[i])), "label");
            assertEq(f2.labelMarket(i), address(0), "unused");
        }
    }

    function test_label_unknownReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.UnknownLabel.selector, uint8(3)));
        f2.label(3);
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.UnknownLabel.selector, uint8(3)));
        f2.labelMarket(3);
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.UnknownLabel.selector, uint8(3)));
        f2.computeMarketAddress(3);
    }

    function test_marketCodeIsBellMarketV2DataOnly() public view {
        bytes memory code = f2.MARKET_CODE().code;
        assertEq(uint8(code[0]), 0, "data contract starts with STOP");
        assertEq(keccak256(code), keccak256(abi.encodePacked(hex"00", type(BellMarketV2).creationCode)));
        assertLe(code.length, EIP170, "data contract within EIP-170");
    }

    // ------------------------------------------------------------ constructor: tiers and USDG (as v1)

    function test_constructor_badUsdgDecimals() public {
        MutableDecimalsToken tok = new MutableDecimalsToken(18);
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.BadUsdgDecimals.selector, uint8(18)));
        new BellMarketFactoryV2(address(tok), address(refFactory), menu(), labels(), FIRST);
    }

    function test_constructor_emptyMenu() public {
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.BadMenu.selector, uint8(0), uint8(255)));
        new BellMarketFactoryV2(address(usdg), address(refFactory), new IBellMarketFactory.Tier[](0), labels(), FIRST);
    }

    /// Every BadMenu case of the v1 suite, field by field.
    function test_constructor_badMenuFieldsAsV1() public {
        IBellMarketFactory.Tier[11] memory bad;
        uint8[11] memory field = [0, 1, 1, 1, 2, 2, 3, 3, 4, 5, 6];
        for (uint256 k; k < 11; ++k) {
            bad[k] = t0();
        }
        bad[0].mintCrBps = 24_999;
        (bad[1].liqCrBps, bad[1].mintCrBps) = (14_999, 25_000);
        bad[2].liqCrBps = 35_001;
        bad[3].liqCrBps = 45_000;
        bad[4].bonusBps = 499;
        bad[5].bonusBps = 2_001;
        bad[6].bufferFloorBps = 999;
        bad[7].bufferFloorBps = 3_001;
        bad[8].mintMaxAge = 172_801;
        bad[9].liqMaxAge = 345_601;
        bad[10].settleStale = 604_799;
        for (uint256 k; k < 11; ++k) {
            IBellMarketFactory.Tier[] memory m = new IBellMarketFactory.Tier[](1);
            m[0] = bad[k];
            vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.BadMenu.selector, uint8(0), field[k]));
            new BellMarketFactoryV2(address(usdg), address(refFactory), m, _label("Abc", "AB"), FIRST);
        }
        IBellMarketFactory.Tier[] memory menu3 = menu();
        menu3[2].warmup = 2_592_001;
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.BadMenu.selector, uint8(2), uint8(8)));
        new BellMarketFactoryV2(address(usdg), address(refFactory), menu3, labels(), FIRST);
        menu3 = menu();
        menu3[1].settleGcrBps = 10_499;
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.BadMenu.selector, uint8(1), uint8(7)));
        new BellMarketFactoryV2(address(usdg), address(refFactory), menu3, labels(), FIRST);
    }

    // ------------------------------------------------------------ constructor: labels

    function test_constructor_labelMenuSize() public {
        _expectBadLabels(new IBellMarketFactoryV2.Label[](0), 0, 255);
        IBellMarketFactoryV2.Label[] memory l = new IBellMarketFactoryV2.Label[](33);
        for (uint256 i; i < 33; ++i) {
            l[i] = IBellMarketFactoryV2.Label(
                string.concat("Market ", vm.toString(i)), string.concat("M", vm.toString(i)), address(feed), 0, 1_000e6
            );
        }
        _expectBadLabels(l, 0, 255);
    }

    /// P3 of the plan review: the largest menu (32 labels, 40-byte names, 11-byte symbols) fits the EIP-3860 init code
    /// limit with the repo's compiler settings, deploys, and every label lists.
    function test_constructor_largestMenuFitsInitCodeLimit() public {
        IBellMarketFactoryV2.Label[] memory l = new IBellMarketFactoryV2.Label[](32);
        for (uint256 i; i < 32; ++i) {
            string memory n = vm.toString(100 + i);
            l[i] = IBellMarketFactoryV2.Label(
                string.concat("A forty byte market name for test no ", n),
                string.concat("MAXSYMB", n, "X"),
                address(feed),
                0,
                1_000e6
            );
            assertEq(bytes(l[i].name).length, 40);
            assertEq(bytes(l[i].symbol).length, 11);
        }
        bytes memory init = abi.encodePacked(
            type(BellMarketFactoryV2).creationCode, abi.encode(address(usdg), address(refFactory), menu(), l, FIRST)
        );
        emit log_named_uint("factory init code bytes, 32 labels", init.length);
        assertLe(init.length, EIP3860, "EIP-3860");
        BellMarketFactoryV2 big = _deploy(l);
        assertLe(address(big).code.length, EIP170, "EIP-170");
        assertEq(big.labelCount(), 32);
        (uint256 id, address a) = big.createMarket(address(feed), 0, 1_000e6, 31);
        assertEq(id, FIRST + 31);
        assertEq(BellMarketV2(a).name(), l[31].name);
    }

    function test_constructor_nameRules() public {
        // Too short, too long, below 0x20, DEL, leading space, trailing space, blank.
        string[7] memory bad = [
            string("Ab"),
            "A forty one byte market name for test 123",
            string(abi.encodePacked("Ab", bytes1(0x1f), "c")),
            string(abi.encodePacked("Ab", bytes1(0x7f), "c")),
            " Abc",
            "Abc ",
            "     "
        ];
        for (uint256 k; k < bad.length; ++k) {
            _expectBadLabels(_label(bad[k], "AB"), 0, 0);
        }
        // Accepted: 3 and 40 bytes, inner spaces, quotes, backslash and every other printable byte.
        _deploy(_label("Abc", "AB"));
        _deploy(_label("A forty byte market name for test no 123", "AB"));
        _deploy(_label("A \"quoted\" name \\ with 'marks' ~!@#", "AB"));
    }

    function test_constructor_symbolRules() public {
        // Too short, too long, lower case, leading digit, space, dash, non-ASCII byte.
        string[7] memory bad =
            [string("A"), "ABCDEFGHIJKL", "Abc", "1ABC", "AB C", "AB-C", string(abi.encodePacked("AB", bytes1(0xc3)))];
        for (uint256 k; k < bad.length; ++k) {
            _expectBadLabels(_label("Abc", bad[k]), 0, 1);
        }
        _deploy(_label("Abc", "A1"));
        _deploy(_label("Abc", "ABCDEFGHIJK"));
        _deploy(_label("Abc", "Z9Z9"));
    }

    function test_constructor_labelFeedMustBeCanonicalKind1() public {
        IBellMarketFactoryV2.Label[] memory l = _label("Abc", "AB");
        MockMarketFeed rogue = new MockMarketFeed(1); // not registered
        rogue.postNow(P0);
        l[0].feed = address(rogue);
        _expectBadLabels(l, 0, 2);
        MockMarketFeed odd = new MockMarketFeed(1);
        refFactory.register(address(odd));
        odd.setFactory(address(0xBEEF));
        l[0].feed = address(odd);
        _expectBadLabels(l, 0, 2);
        MockMarketFeed k2 = new MockMarketFeed(2);
        refFactory.register(address(k2));
        l[0].feed = address(k2);
        _expectBadLabels(l, 0, 2);
        l[0].feed = address(0);
        _expectBadLabels(l, 0, 2);
        // A registered kind 1 feed without any round is accepted: the price is checked at createMarket.
        MockMarketFeed empty = new MockMarketFeed(1);
        refFactory.register(address(empty));
        l[0].feed = address(empty);
        _deploy(l);
    }

    function test_constructor_labelTierAndCap() public {
        IBellMarketFactoryV2.Label[] memory l = _label("Abc", "AB");
        l[0].tierId = 3; // menu has 3 tiers
        _expectBadLabels(l, 0, 3);
        l = _label("Abc", "AB");
        l[0].capUsd = 999_999_999;
        _expectBadLabels(l, 0, 4);
        l[0].capUsd = 25_000e6 + 1;
        _expectBadLabels(l, 0, 4);
        l[0].capUsd = 25_000e6;
        _deploy(l);
    }

    function test_constructor_duplicatesRefused() public {
        IBellMarketFactoryV2.Label[] memory l = labels();
        l[2].name = l[0].name;
        _expectBadLabels(l, 2, 5);
        l = labels();
        l[1].symbol = l[0].symbol; // another name, the same symbol
        _expectBadLabels(l, 1, 6);
        // The same terms under two labels are fine: two markets on one feed, tier and cap.
        l = labels();
        (l[1].tierId, l[1].capUsd) = (l[0].tierId, l[0].capUsd);
        _deploy(l);
    }

    /// Polish Q2: the duplicate check folds ASCII letter case, so a name that differs from an earlier one only in case
    /// is taken. Symbols are A-Z and 0-9 only (a lower-case symbol fails the charset first), so for them the fold is a
    /// no-op; non-letter bytes are compared exactly.
    function test_constructor_duplicatesRefusedCaseInsensitive() public {
        IBellMarketFactoryV2.Label[] memory l = labels();
        l[2].name = "BELLSWAP ALPHA"; // l[0].name upper-cased
        _expectBadLabels(l, 2, 5);
        l = labels();
        l[1].name = "bellswap alpha";
        _expectBadLabels(l, 1, 5);
        l = labels();
        l[1].name = "bELLSWAP aLPHA";
        _expectBadLabels(l, 1, 5);
        l = labels();
        l[1].symbol = "alpha"; // lower case is not a symbol: the charset refuses it before the duplicate check
        _expectBadLabels(l, 1, 1);
        // Names that differ in a non-letter byte, or only by an adjacent ASCII code ('@' 0x40, '[' 0x5b), stay distinct.
        l = labels();
        (l[0].name, l[1].name, l[2].name) = ("Label @1", "Label `1", "Label [1");
        BellMarketFactoryV2 f = _deploy(l);
        assertEq(f.labelCount(), 3);
        l = labels();
        (l[0].name, l[1].name) = ("Bellswap Alpha 1", "Bellswap Alpha 2");
        _deploy(l);
    }

    function test_constructor_badFirstMarketId() public {
        uint256 bad = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.BadFirstMarketId.selector, bad));
        new BellMarketFactoryV2(address(usdg), address(refFactory), menu(), labels(), bad);
        new BellMarketFactoryV2(address(usdg), address(refFactory), menu(), labels(), type(uint128).max);
    }

    // ------------------------------------------------------------ createMarket

    function test_createMarket_happyPath() public {
        address predicted = f2.computeMarketAddress(0);
        uint256 supplyCap = uint256(5_000e6) * 1e30 / P0; // 250e18
        vm.expectEmit(true, true, true, true, address(f2));
        emit IBellMarketFactoryV2.MarketCreated(FIRST, predicted, address(feed), 0, 5_000e6, supplyCap, P0, alice);
        vm.expectEmit(true, true, true, true, address(f2));
        emit IBellMarketFactoryV2.MarketLabel(FIRST, 0, "Bellswap Alpha", "ALPHA");
        vm.prank(alice);
        (uint256 id, address a) = f2.createMarket(address(feed), 0, 5_000e6, 0);
        assertEq(id, FIRST);
        assertEq(a, predicted);
        assertTrue(f2.isMarket(a));
        assertFalse(factory.isMarket(a), "not a v1 market");
        assertEq(f2.marketCount(), 1);
        assertEq(f2.marketAt(0), a);
        assertEq(f2.labelMarket(0), a);
        assertEq(refFactory.createViewCalls(), 1);

        BellMarketV2 m = BellMarketV2(a);
        assertEq(m.name(), "Bellswap Alpha");
        assertEq(m.symbol(), "ALPHA");
        assertEq(m.decimals(), 18);
        assertEq(m.FACTORY(), address(f2));
        assertEq(m.USDG(), address(usdg));
        assertEq(m.FEED(), address(feed));
        assertEq(m.REFERENCE_VIEW(), refFactory.viewOf(address(feed), 0));
        assertEq(m.referenceFeed(), m.REFERENCE_VIEW());
        assertEq(m.MARKET_ID(), FIRST);
        assertEq(m.SUPPLY_CAP(), supplyCap);
        assertEq(m.CAP_USD(), 5_000e6);
        assertEq(m.DISC_BASE(), 0);
        assertEq(m.WARMUP_END(), START + 259_200);
        assertEq(m.MINT_CR_BPS(), 40_000);
        assertEq(m.LIQ_CR_BPS(), 25_000);
        assertEq(m.BONUS_BPS(), 1_500);
        assertEq(m.BUFFER_FLOOR_BPS(), 1_000);
        assertEq(m.MINT_MAX_AGE(), 172_800);
        assertEq(m.LIQ_MAX_AGE(), 259_200);
        assertEq(m.SETTLE_STALE(), 604_800);
        assertEq(m.SETTLE_GCR_BPS(), 11_000);
        assertEq(m.MIN_COLLATERAL(), 100e6);
        assertEq(m.MIN_DEBT_VALUE(), 50e6);
        assertEq(uint8(m.phase()), 0);
    }

    /// The v1 MarketCreated topic is unchanged, so log readers of v1 decode V2 listings as they are.
    function test_marketCreatedEventSignatureEqualsV1() public {
        assertEq(IBellMarketFactoryV2.MarketCreated.selector, IBellMarketFactory.MarketCreated.selector);
        vm.recordLogs();
        (uint256 id, address a) = _create(1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(f2)) continue;
            ++seen;
            if (seen == 1) {
                assertEq(logs[i].topics[0], IBellMarketFactory.MarketCreated.selector);
                assertEq(uint256(logs[i].topics[1]), id);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), a);
            } else {
                assertEq(logs[i].topics[0], IBellMarketFactoryV2.MarketLabel.selector);
                assertEq(uint256(logs[i].topics[1]), id);
                assertEq(uint256(logs[i].topics[2]), 1);
                (string memory n, string memory s) = abi.decode(logs[i].data, (string, string));
                assertEq(n, "Bellswap Beta");
                assertEq(s, "BETA");
            }
        }
        assertEq(seen, 2, "MarketCreated then MarketLabel");
    }

    /// Ids are FIRST_MARKET_ID + labelId whatever the creation order; marketAt is the zero-based creation order; the
    /// predicted address of a label does not move when other labels list first.
    function test_createMarket_idsFollowLabelsNotOrder() public {
        address p0 = f2.computeMarketAddress(0);
        address p2 = f2.computeMarketAddress(2);
        (uint256 id2, address a2) = _create(2);
        assertEq(id2, FIRST + 2);
        assertEq(a2, p2);
        assertEq(f2.computeMarketAddress(0), p0, "label 0's address unchanged by another listing");
        (uint256 id0, address a0) = _create(0);
        assertEq(id0, FIRST);
        assertEq(a0, p0);
        assertEq(f2.marketCount(), 2);
        assertEq(f2.marketAt(0), a2, "index 0 is the first created");
        assertEq(f2.marketAt(1), a0);
        assertEq(BellMarketV2(f2.marketAt(0)).MARKET_ID(), FIRST + 2, "index is not the id");
        vm.expectRevert();
        f2.marketAt(2);
    }

    function test_createMarket_labelUsedOnce() public {
        (, address a) = _create(0);
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.LabelUsed.selector, uint8(0), a));
        f2.createMarket(address(feed), 0, 5_000e6, 0);
        // Another label with other terms still lists.
        _create(1);
        assertEq(f2.marketCount(), 2);
    }

    function test_createMarket_unknownLabel() public {
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.UnknownLabel.selector, uint8(3)));
        f2.createMarket(address(feed), 0, 5_000e6, 3);
    }

    /// Codex P1 of the plan review: nobody can spend a label on other terms than the deployer bound it to.
    function test_createMarket_termsMustMatchLabel() public {
        bytes memory mismatch = abi.encodeWithSelector(IBellMarketFactoryV2.LabelTermsMismatch.selector, uint8(0));
        vm.expectRevert(mismatch);
        f2.createMarket(address(feedB), 0, 5_000e6, 0); // other canonical feed
        vm.expectRevert(mismatch);
        f2.createMarket(address(feed), 2, 5_000e6, 0); // other tier
        vm.expectRevert(mismatch);
        f2.createMarket(address(feed), 0, 25_000e6, 0); // other cap
        assertEq(f2.labelMarket(0), address(0), "label still unused");
        _create(0);
    }

    function test_createMarket_discBaseSnapshotsCount() public {
        feed.addDiscontinuity(1, 1);
        (, address a) = _create(0);
        assertEq(BellMarketV2(a).DISC_BASE(), 1);
    }

    // ------------------------------------------------------------ createMarket refusals, as v1 and in v1's order

    function test_createMarket_notCanonical() public {
        MockMarketFeed rogue = new MockMarketFeed(1);
        rogue.postNow(P0);
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.NotCanonicalFeed.selector, address(rogue)));
        f2.createMarket(address(rogue), 0, 5_000e6, 0);
    }

    function test_createMarket_factoryMismatch() public {
        MockMarketFeed odd = new MockMarketFeed(1);
        refFactory.register(address(odd));
        odd.setFactory(address(0xBEEF));
        odd.postNow(P0);
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.NotCanonicalFeed.selector, address(odd)));
        f2.createMarket(address(odd), 0, 5_000e6, 0);
    }

    function test_createMarket_kind2Rejected() public {
        MockMarketFeed k2 = new MockMarketFeed(2);
        refFactory.register(address(k2));
        k2.postNow(P0);
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.NotOndoKind.selector, address(k2)));
        f2.createMarket(address(k2), 0, 5_000e6, 0);
    }

    /// The tier and cap checks come before the label checks, as in v1 (a wrong label does not hide them).
    function test_createMarket_unknownTierBeforeLabel() public {
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.UnknownTier.selector, uint8(7)));
        f2.createMarket(address(feed), 7, 5_000e6, 9);
    }

    function test_createMarket_capBoundsBeforeLabel() public {
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.CapOutOfBounds.selector, uint256(999_999_999)));
        f2.createMarket(address(feed), 0, 999_999_999, 9);
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.CapOutOfBounds.selector, uint256(25_000e6 + 1)));
        f2.createMarket(address(feed), 0, 25_000e6 + 1, 0);
    }

    function _oneOn(MockMarketFeed f) internal returns (BellMarketFactoryV2) {
        IBellMarketFactoryV2.Label[] memory l = _label("Abc", "AB");
        l[0].feed = address(f);
        return _deploy(l);
    }

    function test_createMarket_noData() public {
        MockMarketFeed empty = new MockMarketFeed(1);
        refFactory.register(address(empty));
        BellMarketFactoryV2 g = _oneOn(empty);
        vm.expectRevert(IBellMarketFactoryV2.PriceNotUsable.selector);
        g.createMarket(address(empty), 0, 1_000e6, 0);
    }

    function test_createMarket_stale() public {
        vm.warp(START + 172_801);
        vm.expectRevert(IBellMarketFactoryV2.PriceNotUsable.selector);
        f2.createMarket(address(feed), 0, 5_000e6, 0);
    }

    function test_createMarket_ageBoundaryAccepted() public {
        vm.warp(START + 172_800);
        _create(0);
    }

    function test_createMarket_futureObservedAtSaturates() public {
        feed.post(P0, uint64(block.timestamp + 1), 1_000);
        _create(0);
    }

    function test_createMarket_pending() public {
        feed.postPending(2 * P0, uint64(block.timestamp));
        vm.expectRevert(IBellMarketFactoryV2.PriceNotUsable.selector);
        f2.createMarket(address(feed), 0, 5_000e6, 0);
    }

    function test_createMarket_hold() public {
        feed.postPending(2 * P0, uint64(block.timestamp));
        feed.promoteWithHold();
        vm.expectRevert(IBellMarketFactoryV2.PriceNotUsable.selector);
        f2.createMarket(address(feed), 0, 5_000e6, 0);
    }

    /// A failed price check leaves the label unused: the same label lists once the price is usable again.
    function test_createMarket_refusalKeepsLabelUnused() public {
        feed.postPending(2 * P0, uint64(block.timestamp));
        vm.expectRevert(IBellMarketFactoryV2.PriceNotUsable.selector);
        f2.createMarket(address(feed), 0, 5_000e6, 0);
        feed.clearPending();
        _create(0);
    }

    function test_createMarket_usdgDecimalsChanged() public {
        MutableDecimalsToken tok = new MutableDecimalsToken(6);
        BellMarketFactoryV2 g = new BellMarketFactoryV2(address(tok), address(refFactory), menu(), labels(), FIRST);
        tok.setDecimals(18);
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.BadUsdgDecimals.selector, uint8(18)));
        g.createMarket(address(feed), 0, 5_000e6, 0);
    }

    function test_computeMarketAddress_dependsOnLabelAndFactory() public {
        assertTrue(f2.computeMarketAddress(0) != f2.computeMarketAddress(1));
        BellMarketFactoryV2 other = _deploy(labels());
        assertTrue(other.computeMarketAddress(0) != f2.computeMarketAddress(0));
        // The same factory code with another FIRST_MARKET_ID: another id, so another salt and init code.
        BellMarketFactoryV2 shifted =
            new BellMarketFactoryV2(address(usdg), address(refFactory), menu(), labels(), FIRST + 1);
        (uint256 id,) = shifted.createMarket(address(feed), 0, 5_000e6, 0);
        assertEq(id, FIRST + 1);
    }

    /// script/verify.sh passes label names and symbols to cast as hex bytes: the ABI encoding of a string equals that of
    /// bytes with the same content, so the market's constructor arguments, and its CREATE2 address, come out the same.
    function test_constructorArgsAsBytesEncodeLikeStrings() public view {
        string memory name = 'Tank "Line", A\\B\'s';
        string memory symbol = "TNKA";
        assertEq(
            abi.encode(uint256(2), address(feed), uint8(1), uint256(25_000e6), name, symbol),
            abi.encode(uint256(2), address(feed), uint8(1), uint256(25_000e6), bytes(name), bytes(symbol))
        );
        IBellMarketFactoryV2.Label memory l = f2.label(0);
        bytes memory init = abi.encodePacked(
            type(BellMarketV2).creationCode,
            abi.encode(FIRST, l.feed, l.tierId, l.capUsd, bytes(l.name), bytes(l.symbol))
        );
        assertEq(vm.computeCreate2Address(bytes32(FIRST), keccak256(init), address(f2)), f2.computeMarketAddress(0));
    }

    // ------------------------------------------------------------ surface: no v1 overload, no admin

    function test_noV1CreateMarketOverload() public {
        (bool ok,) = address(f2)
            .call(
                abi.encodeWithSelector(
                    IBellMarketFactory.createMarket.selector, address(feed), uint8(0), uint256(5_000e6)
                )
            );
        assertFalse(ok, "createMarket(address,uint8,uint256)");
        (ok,) = address(f2)
            .call(
                abi.encodeWithSelector(
                    IBellMarketFactory.computeMarketAddress.selector,
                    uint256(0),
                    address(feed),
                    uint8(0),
                    uint256(5_000e6)
                )
            );
        assertFalse(ok, "computeMarketAddress(uint256,address,uint8,uint256)");
        assertEq(f2.marketCount(), 0);
    }

    function test_noOwnerRoleOrProxyGetter() public {
        (, address a) = _create(0);
        address[2] memory targets = [address(f2), a];
        bytes[6] memory probes = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("pendingOwner()"),
            abi.encodeWithSignature("admin()"),
            abi.encodeWithSignature("implementation()"),
            abi.encodeWithSignature("hasRole(bytes32,address)", bytes32(0), address(1)),
            abi.encodeWithSignature("setLabel(uint8,string,string)", uint8(0), "x", "X")
        ];
        for (uint256 t; t < 2; ++t) {
            for (uint256 i; i < probes.length; ++i) {
                (bool ok,) = targets[t].call(probes[i]);
                assertFalse(ok, "probe answered");
            }
        }
    }
}
