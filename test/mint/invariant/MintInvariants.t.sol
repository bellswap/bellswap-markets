// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {console2} from "forge-std/console2.sol";

import {MintBase} from "../MintBase.sol";
import {BellMarket} from "../../../src/mint/BellMarket.sol";
import {IBellMarket} from "../../../src/mint/interfaces/IBellMarket.sol";
import {MockMarketFeed} from "../mocks/MockMarketFeed.sol";
import {MintHandler} from "./MintHandler.sol";

/// M invariants of SPEC 8.8 across two markets (T0 and T1). State properties are checked here after
/// every handler call; per-call properties (M1, M2, M5 with F0 to F5, M6, M7, M7b, M7c, M8 payout, M9,
/// M11) are asserted inside MintHandler. M7d is covered by the hold paths of the mock feed plus the unit
/// tests; M10 by the bytecode scan in BellMarketFactory.t.sol; M12 is structural (the market reads only
/// FEED and USDG, see BellMarket._priceState).
contract MintInvariantsTest is MintBase {
    MintHandler internal handler;
    BellMarket[2] internal mks;

    function setUp() public override {
        super.setUp();
        mks[0] = listLive(feed, 0);
        MockMarketFeed fb = newFeed(50e18);
        mks[1] = listLive(fb, 1);
        feed.postNow(P0); // listing the second market advanced time past the first feed's mint age
        address[4] memory act = [alice, bob, carol, liquidator];
        handler = new MintHandler(usdg, mks[0], mks[1], feed, fb, act);
        // The handler controls USDG pause and blacklist through CONTROLLER = this test contract.
        vm.label(address(handler), "handler");
        targetContract(address(handler));
        excludeSender(address(this));
    }

    struct Sums {
        uint256 sumC;
        uint256 sumD;
        uint256 sumExcess;
        uint256 withDebt;
    }

    function _sumPositions(BellMarket m) internal view returns (Sums memory z) {
        uint256 n = m.positionCount();
        for (uint256 k; k < n; ++k) {
            IBellMarket.Position memory p = m.position(k);
            z.sumC += p.collateral;
            z.sumD += p.debt;
            z.sumExcess += p.excess;
            if (p.debt > 0) ++z.withDebt;
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 250
    /// forge-config: c4.invariant.runs = 128
    /// forge-config: c4.invariant.depth = 250
    /// forge-config: invariant.invariant.runs = 10000
    /// forge-config: invariant.invariant.depth = 250
    function invariant_M3_M4_M13_M14_M8() public view {
        for (uint256 i; i < 2; ++i) {
            _checkAccounting(i);
            _checkSettlement(i);
        }
    }

    /// M3, M4, M13 and the totals.
    function _checkAccounting(uint256 i) internal view {
        BellMarket m = mks[i];
        Sums memory z = _sumPositions(m);
        (uint256 tc, uint256 td, uint256 ub, uint256 od) = m.totals();
        (,,, uint256 pool,,, uint256 paid) = m.settlement();
        assertEq(tc, z.sumC, "totalCollateral == sum(C)");
        assertEq(td, z.sumD, "totalDebt == sum(D)");
        // M3: USDG balance covers every claim on it.
        assertGe(usdg.balanceOf(address(m)), z.sumC + pool - paid + z.sumExcess, "M3");
        // M13: openDebtPositions == count(D > 0).
        assertEq(od, z.withDebt, "M13");
        if (m.phase() == IBellMarket.Phase.Live) {
            assertEq(m.totalSupply(), td + ub, "M4");
            assertEq(pool, 0);
        }
    }

    /// M14 and M8.
    function _checkSettlement(uint256 i) internal view {
        BellMarket m = mks[i];
        IBellMarket.Phase ph = m.phase();
        if (ph == IBellMarket.Phase.Live) return;
        (,,, uint256 od) = m.totals();
        (,, uint256 sat, uint256 pool, uint256 rem, uint256 burned, uint256 paid) = m.settlement();
        assertEq(rem, od, "remaining == unprocessed debt positions");
        // M14: once every position is processed, pool + excess assigned == sum(C with D > 0 at trigger).
        if (rem == 0) assertEq(pool + handler.excessAtProcess(i), handler.sumCDebtAtTrigger(i), "M14");
        if (ph == IBellMarket.Phase.Final && sat > 0) {
            // M8: pool and supplyAtTrigger constant after finalize; cumulative payout bounds.
            assertEq(pool, handler.poolAtFinal(i), "M8 pool constant");
            assertEq(sat, handler.satAtFinal(i), "M8 sat constant");
            assertLe(paid, Math.mulDiv(burned, pool, sat), "M8 paid <= share");
            assertLe(Math.mulDiv(burned, pool, sat), pool, "M8 share <= pool");
        }
    }

    /// M15: in Settling, every debt position is processable by anyone in one batch at bounded gas and
    /// finalize is then reachable.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 250
    /// forge-config: c4.invariant.runs = 128
    /// forge-config: c4.invariant.depth = 250
    /// forge-config: invariant.invariant.runs = 10000
    /// forge-config: invariant.invariant.depth = 250
    function invariant_M15_processingLiveness() public {
        for (uint256 i; i < 2; ++i) {
            BellMarket m = mks[i];
            if (m.phase() != IBellMarket.Phase.Settling) continue;
            uint256 snap = vm.snapshotState();
            uint256 n = m.positionCount();
            uint256[] memory ids = new uint256[](n);
            // Reverse order.
            for (uint256 k; k < n; ++k) {
                ids[k] = n - 1 - k;
            }
            vm.prank(makeAddr("anyone"));
            uint256 g = gasleft();
            m.processPositions(ids);
            assertLt(g - gasleft(), 30_000_000 / 4, "bounded gas");
            (,,,, uint256 rem,,) = m.settlement();
            assertEq(rem, 0, "M15 all processed");
            m.finalize();
            vm.revertToState(snap);
        }
    }

    /// Coverage report of the handler (printed with -vv); not an assertion.
    function afterInvariant() external view {
        string[19] memory names = [
            "open",
            "deposit",
            "withdraw",
            "mint",
            "repay",
            "close",
            "liquidate",
            "arm",
            "trigger",
            "process",
            "finalize",
            "redeem",
            "claimExcess",
            "feedPending",
            "feedPromote",
            "feedEndHold",
            "feedBacklog",
            "usdgSwitch",
            "feedJump"
        ];
        for (uint256 k; k < names.length; ++k) {
            console2.log(names[k], handler.calls(keccak256(bytes(names[k]))));
        }
    }
}
