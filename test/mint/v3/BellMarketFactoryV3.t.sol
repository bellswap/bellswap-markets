// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {MintBase} from "../MintBase.sol";
import {TierFixtures} from "./V3FeedBase.sol";
import {BellswapScript} from "../../../script/lib/BellswapScript.sol";
import {BellMarketFactoryV2} from "../../../src/mint/BellMarketFactoryV2.sol";
import {BellMarketFactoryV3} from "../../../src/mint/BellMarketFactoryV3.sol";
import {BellMarketV2} from "../../../src/mint/BellMarketV2.sol";
import {IBellMarketFactory} from "../../../src/mint/interfaces/IBellMarketFactory.sol";
import {IBellMarketFactoryV2} from "../../../src/mint/interfaces/IBellMarketFactoryV2.sol";

/// @notice BellMarketFactoryV3 with _checkTier exposed, so a tier is checked without a constructor run.
contract FactoryV3TierHarness is BellMarketFactoryV3 {
    constructor(
        address usdg,
        address rf,
        IBellMarketFactory.Tier[] memory menu,
        IBellMarketFactoryV2.Label[] memory labels
    ) BellMarketFactoryV3(usdg, rf, menu, labels, 0) {}

    function checkTier(IBellMarketFactory.Tier memory t) external pure {
        _checkTier(0, t);
    }
}

/// @notice The tier menu of script/lib/BellswapScript.sol, exposed.
contract ScriptTiers is BellswapScript {
    function tier(string memory name) external pure returns (IBellMarketFactory.Tier memory) {
        return _tier(name);
    }
}

/// @title BellMarketFactoryV3Test
/// @notice DESIGN.md tests 1 (factory V3 bounds) and 2 (factory V3 parity with V2). Bounds: the TL0 and TL1 structs of
/// tiers.md section 2 are accepted as written (and equal the BellswapScript branches); single-field edits of TL1 below
/// a bound are refused with the BadMenu field code of that bound; the full bonus rule liqCr * 1e4 >= (1e4 + bonus) *
/// 14_000 refuses every tier that breaks it (unit boundaries and a fuzz against the formula); TL2-style tiers are
/// refused. Parity: MARKET_CODE is BellMarketV2's creation code, and a V2 and a V3 factory deployed at the same address
/// with the same arguments list the same market (address, runtime code, getters, events).
contract BellMarketFactoryV3Test is MintBase, TierFixtures {
    FactoryV3TierHarness internal h;

    function setUp() public override {
        super.setUp();
        h = new FactoryV3TierHarness(address(usdg), address(refFactory), _one(tl1()), _label(0, 10_000e6));
    }

    function _one(IBellMarketFactory.Tier memory t) internal pure returns (IBellMarketFactory.Tier[] memory m) {
        m = new IBellMarketFactory.Tier[](1);
        m[0] = t;
    }

    function _label(uint8 tierId, uint256 cap) internal view returns (IBellMarketFactoryV2.Label[] memory l) {
        l = new IBellMarketFactoryV2.Label[](1);
        l[0] = IBellMarketFactoryV2.Label("Tanker", "TANKR", address(feed), tierId, cap);
    }

    function _expectBadMenu(uint8 field) internal {
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.BadMenu.selector, uint8(0), field));
    }

    /// @dev The full bonus rule (DESIGN.md, Collateral ratio rule 2), as written there.
    function _rule2(uint256 liq, uint256 bonus) internal pure returns (bool) {
        return liq * 1e4 >= (1e4 + bonus) * 14_000;
    }

    // ------------------------------------------------------------------ test 1: bounds

    function test_1_constants() public {
        BellMarketFactoryV2 f2 =
            new BellMarketFactoryV2(address(usdg), address(refFactory), _one(tl0()), _label(0, 10_000e6), 0);
        BellMarketFactoryV3 f3 =
            new BellMarketFactoryV3(address(usdg), address(refFactory), _one(tl0()), _label(0, 10_000e6), 0);
        assertEq(f3.MIN_MINT_CR_BPS(), 17_500, "relaxed from 25_000");
        assertEq(f3.MIN_CR_GAP_BPS(), 2_500, "relaxed from 5_000");
        assertEq(f2.MIN_MINT_CR_BPS(), 25_000);
        assertEq(f2.MIN_CR_GAP_BPS(), 5_000);
        // Every other bound is V2's.
        assertEq(f3.MIN_LIQ_CR_BPS(), f2.MIN_LIQ_CR_BPS());
        assertEq(f3.MIN_BONUS_BPS(), f2.MIN_BONUS_BPS());
        assertEq(f3.MAX_BONUS_BPS(), f2.MAX_BONUS_BPS());
        assertEq(f3.MIN_BUFFER_BPS(), f2.MIN_BUFFER_BPS());
        assertEq(f3.MAX_BUFFER_BPS(), f2.MAX_BUFFER_BPS());
        assertEq(f3.MAX_MINT_AGE(), f2.MAX_MINT_AGE());
        assertEq(f3.MAX_LIQ_AGE(), f2.MAX_LIQ_AGE());
        assertEq(f3.MIN_SETTLE_STALE(), f2.MIN_SETTLE_STALE());
        assertEq(f3.MAX_SETTLE_STALE(), f2.MAX_SETTLE_STALE());
        assertEq(f3.MIN_SETTLE_GCR_BPS(), f2.MIN_SETTLE_GCR_BPS());
        assertEq(f3.MAX_WARMUP(), f2.MAX_WARMUP());
        assertEq(f3.MIN_CAP_USD(), f2.MIN_CAP_USD());
        assertEq(f3.MAX_CAP_USD(), f2.MAX_CAP_USD());
        assertEq(f3.MIN_COLLATERAL(), f2.MIN_COLLATERAL());
        assertEq(f3.MIN_DEBT_VALUE(), f2.MIN_DEBT_VALUE());
    }

    /// TL0 and TL1 of tiers.md section 2 are accepted as written, and the BellswapScript branches return them.
    function test_1_acceptsTL0AndTL1AsWritten() public {
        IBellMarketFactory.Tier[] memory menu = new IBellMarketFactory.Tier[](2);
        menu[0] = tl0();
        menu[1] = tl1();
        IBellMarketFactoryV2.Label[] memory labels = new IBellMarketFactoryV2.Label[](2);
        labels[0] = IBellMarketFactoryV2.Label("Bellswap Synthetic TL0 Rehearsal", "LEVTL0", address(feed), 0, 5_000e6);
        labels[1] = IBellMarketFactoryV2.Label("Tanker", "TANKR", address(feed), 1, 10_000e6);
        BellMarketFactoryV3 f = new BellMarketFactoryV3(address(usdg), address(refFactory), menu, labels, 3);
        assertEq(keccak256(abi.encode(f.tier(0))), keccak256(abi.encode(tl0())), "TL0 stored as written");
        assertEq(keccak256(abi.encode(f.tier(1))), keccak256(abi.encode(tl1())), "TL1 stored as written");

        ScriptTiers s = new ScriptTiers();
        assertEq(keccak256(abi.encode(s.tier("TL0"))), keccak256(abi.encode(tl0())), "BellswapScript TL0");
        assertEq(keccak256(abi.encode(s.tier("TL1"))), keccak256(abi.encode(tl1())), "BellswapScript TL1");
        assertEq(keccak256(abi.encode(s.tier("T3"))), keccak256(abi.encode(t3())), "BellswapScript T3");
    }

    /// The SPEC 5.3 tiers and T3 satisfy the full bonus rule and stay listable on V3.
    function test_1_acceptsT0T1T2T3() public view {
        h.checkTier(t0());
        h.checkTier(t1());
        h.checkTier(t2());
        h.checkTier(t3());
    }

    /// TL1 does not fit V2 (mintCrBps below 25_000), TL0 does (tiers.md section 4).
    function test_1_v2RefusesTL1AcceptsTL0() public {
        vm.expectRevert(abi.encodeWithSelector(IBellMarketFactoryV2.BadMenu.selector, uint8(0), uint8(0)));
        new BellMarketFactoryV2(address(usdg), address(refFactory), _one(tl1()), _label(0, 10_000e6), 0);
        new BellMarketFactoryV2(address(usdg), address(refFactory), _one(tl0()), _label(0, 5_000e6), 0);
    }

    /// Single-field edits of the TL1 struct below each relaxed or kept bound (DESIGN.md test 1).
    function test_1_refusesSingleFieldEditsOfTL1() public {
        IBellMarketFactory.Tier memory t = tl1();
        t.mintCrBps = 17_499;
        _expectBadMenu(0);
        h.checkTier(t);

        t = tl1();
        t.liqCrBps = 14_999;
        _expectBadMenu(1);
        h.checkTier(t);

        t = tl1();
        t.liqCrBps = 15_001; // gap 2_499
        _expectBadMenu(1);
        h.checkTier(t);

        t = tl1();
        t.bufferFloorBps = 999;
        _expectBadMenu(3);
        h.checkTier(t);

        t = tl1();
        t.bonusBps = 750; // liq 150 with bonus 7.5 percent: 1.5 < 1.075 * 1.4 = 1.505
        _expectBadMenu(2);
        h.checkTier(t);

        t = tl1();
        t.bonusBps = 5_000; // bonus at liq minus 100 percent (also above MAX_BONUS_BPS)
        _expectBadMenu(2);
        h.checkTier(t);

        // The constructor refuses the same tier with the same code.
        t = tl1();
        t.bonusBps = 750;
        _expectBadMenu(2);
        new BellMarketFactoryV3(address(usdg), address(refFactory), _one(t), _label(0, 10_000e6), 0);
    }

    /// The rule's boundaries: at liq 15_000 the largest bonus is 714 bps; at bonus 1_500 the smallest liq is 16_100.
    function test_1_rule2Boundaries() public {
        IBellMarketFactory.Tier memory t = tl1();
        t.bonusBps = 714; // 10_714 * 14_000 = 149_996_000 <= 150_000_000
        h.checkTier(t);
        t.bonusBps = 715; // 10_715 * 14_000 = 150_010_000 > 150_000_000
        _expectBadMenu(2);
        h.checkTier(t);

        t = t0();
        t.liqCrBps = 16_100; // 11_500 * 14_000 = 161_000_000
        h.checkTier(t);
        t.liqCrBps = 16_099;
        _expectBadMenu(2);
        h.checkTier(t);
    }

    /// TL2 (mint 165, liq 135, cut in DESIGN.md) and TL2-style tiers are refused.
    function test_1_refusesTL2Style() public {
        IBellMarketFactory.Tier memory tl2 =
            IBellMarketFactory.Tier(16_500, 13_500, 500, 500, 172_800, 259_200, 604_800, 10_500, 600);
        _expectBadMenu(0);
        h.checkTier(tl2);

        // With mint at the floor, liq 135 is below MIN_LIQ_CR_BPS.
        tl2.mintCrBps = 17_500;
        _expectBadMenu(1);
        h.checkTier(tl2);

        // At the liq floor with a 10 percent bonus: 1.5 < 1.1 * 1.4 = 1.54.
        IBellMarketFactory.Tier memory t = tl1();
        t.bonusBps = 1_000;
        _expectBadMenu(2);
        h.checkTier(t);
    }

    /// Every tier inside the other bounds is refused with BadMenu(i, 2) exactly when it breaks the full bonus rule.
    function testFuzz_1_rule2RefusesEveryBreakingTier(uint256 liq, uint256 bonus, uint256 gap) public {
        liq = bound(liq, 15_000, 60_000);
        bonus = bound(bonus, 500, 2_000);
        gap = bound(gap, 2_500, 40_000);
        IBellMarketFactory.Tier memory t = tl1();
        t.liqCrBps = uint32(liq);
        t.bonusBps = uint32(bonus);
        t.mintCrBps = uint32(liq + gap < 17_500 ? 17_500 : liq + gap);
        if (_rule2(liq, bonus)) {
            h.checkTier(t);
        } else {
            _expectBadMenu(2);
            h.checkTier(t);
        }
    }

    // ------------------------------------------------------------------ test 2: parity

    function test_2_marketCodeIsBellMarketV2() public view {
        assertEq(
            keccak256(h.MARKET_CODE().code),
            keccak256(abi.encodePacked(hex"00", type(BellMarketV2).creationCode)),
            "MARKET_CODE holds 0x00 ++ BellMarketV2 creation code"
        );
    }

    /// A V2 and a V3 factory with the same arguments, deployed at the same address from the same state, list the same
    /// label as the same market: address, id, runtime code, every getter and the two events.
    function test_2_createMarketMatchesV2() public {
        IBellMarketFactoryV2.Label[] memory l = _label(0, 10_000e6);
        uint256 snap = vm.snapshotState();

        BellMarketFactoryV2 f2 = new BellMarketFactoryV2(address(usdg), address(refFactory), _one(tl0()), l, 7);
        vm.recordLogs();
        (uint256 id2, address m2) = f2.createMarket(address(feed), 0, 10_000e6, 0);
        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        bytes memory code2 = m2.code;
        bytes memory getters2 = _getters(BellMarketV2(m2));
        assertEq(f2.computeMarketAddress(0), m2);

        vm.revertToState(snap);
        BellMarketFactoryV3 f3 = new BellMarketFactoryV3(address(usdg), address(refFactory), _one(tl0()), l, 7);
        assertEq(address(f3), address(f2), "same factory address");
        vm.recordLogs();
        (uint256 id3, address m3) = f3.createMarket(address(feed), 0, 10_000e6, 0);
        Vm.Log[] memory logs3 = vm.getRecordedLogs();

        assertEq(id3, id2, "market id");
        assertEq(m3, m2, "market address");
        assertEq(keccak256(m3.code), keccak256(code2), "runtime code");
        assertEq(keccak256(_getters(BellMarketV2(m3))), keccak256(getters2), "getters");
        assertEq(f3.computeMarketAddress(0), m3);
        assertEq(logs3.length, logs2.length, "event count");
        for (uint256 i; i < logs2.length; ++i) {
            assertEq(logs3[i].emitter, logs2[i].emitter, "emitter");
            assertEq(keccak256(abi.encode(logs3[i].topics)), keccak256(abi.encode(logs2[i].topics)), "topics");
            assertEq(keccak256(logs3[i].data), keccak256(logs2[i].data), "data");
        }
    }

    function _getters(BellMarketV2 mk) internal view returns (bytes memory) {
        return bytes.concat(
            abi.encode(mk.name(), mk.symbol(), mk.FACTORY(), mk.USDG(), mk.FEED(), mk.REFERENCE_VIEW(), mk.MARKET_ID()),
            abi.encode(mk.SUPPLY_CAP(), mk.CAP_USD(), mk.DISC_BASE(), mk.WARMUP_END(), mk.MINT_CR_BPS()),
            abi.encode(mk.LIQ_CR_BPS(), mk.BONUS_BPS(), mk.BUFFER_FLOOR_BPS(), mk.MINT_MAX_AGE(), mk.LIQ_MAX_AGE()),
            abi.encode(mk.SETTLE_STALE(), mk.SETTLE_GCR_BPS(), mk.MIN_COLLATERAL(), mk.MIN_DEBT_VALUE())
        );
    }
}
