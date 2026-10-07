// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V3FeedBase} from "./V3FeedBase.sol";
import {MarketMath} from "../../../src/mint/MarketMath.sol";
import {IBellMarket} from "../../../src/mint/interfaces/IBellMarket.sol";

/// @title GlobalTriggerTL1Test
/// @notice DESIGN.md test 11: the global trigger at settleGcr 10,500 on a TL1 market. On a book of edge positions only
/// (CR 1.5 at 100) it does not fire after a 39.99 percent hold step (aggregate 1.0715) and fires after 44 percent
/// (1.2 x 1.2 across an epoch roll, aggregate 1.0417). With a keeper position at CR 3.0 and equal debt in the book (R2
/// codex-5), it stays off after +44 percent and after +72.8 percent, when the user position is insolvent (CR 0.868)
/// while the aggregate is 1.302: the trigger is not an insolvency backstop on that book.
contract GlobalTriggerTL1Test is V3FeedBase {
    uint256 internal constant EDGE_C = 6_000e6;
    uint256 internal constant EDGE_D = 40e18;

    function _edgeBook(bool withKeeper) internal returns (uint256 u) {
        _list(75e18);
        u = _open(user, EDGE_C, EDGE_D);
        if (withKeeper) _open(keeper, 12_000e6, EDGE_D); // CR 3.0 at 100
        _walkTo(100e18);
        assertEq(m.crBps(u, 100e18), 15_000, "edge at 100");
    }

    /// @dev 100 to 120 in the current epoch, then 144 after the roll (two +20 percent posts, keeper misses one).
    function _plus44() internal {
        (, uint64 since) = _anchor();
        vm.warp(block.timestamp + 60);
        _confirm(120e18);
        vm.warp(uint256(since) + WINDOW);
        _confirm(144e18);
    }

    function test_11a_edgeBook_noTriggerAfter3999() public {
        uint256 u = _edgeBook(false);
        uint64 holdUntil = _promote(139.99e18);
        vm.warp(holdUntil);
        assertEq(m.prices().confirmed18, 139.99e18);
        assertEq(m.crBps(u, 139.99e18), 10_715, "aggregate 1.0715 >= 1.05");
        (bool ok,) = m.canTrigger();
        assertFalse(ok, "one legal step does not end the market");
        vm.expectRevert(IBellMarket.NoTrigger.selector);
        m.triggerSettlement();
    }

    function test_11b_edgeBook_triggerAfter44() public {
        uint256 u = _edgeBook(false);
        _plus44();
        assertEq(m.crBps(u, 144e18), 10_416, "aggregate 1.0417 < 1.05");
        (bool ok, IBellMarket.SettleReason reason) = m.canTrigger();
        assertTrue(ok);
        assertEq(uint8(reason), uint8(IBellMarket.SettleReason.GlobalUndercollateralised));
        m.triggerSettlement();
        assertEq(uint8(m.phase()), uint8(IBellMarket.Phase.Settling));
        (, uint256 pEnd,,,,,) = m.settlement();
        assertEq(pEnd, 144e18);
    }

    function test_11c_keeperInBook_triggerOffWhileUserInsolvent() public {
        uint256 u = _edgeBook(true);
        _plus44();
        assertEq(m.crBps(u, 144e18), 10_416, "user at 1.0417");
        (uint256 tc, uint256 td,,) = m.totals();
        assertEq(tc * 1e4 / MarketMath.value(td, 144e18), 15_625, "aggregate 1.5625");
        (bool ok,) = m.canTrigger();
        assertFalse(ok, "keeper surplus keeps the trigger off");
        vm.expectRevert(IBellMarket.NoTrigger.selector);
        m.triggerSettlement();

        (, uint64 since) = _anchor();
        vm.warp(uint256(since) + WINDOW);
        _confirm(172.8e18);
        (uint256 c, uint256 d) = _pos(u);
        assertTrue(MarketMath.below(c, d, 172.8e18, 1e4), "user insolvent");
        assertEq(m.crBps(u, 172.8e18), 8_680, "user at 0.868");
        assertEq(tc * 1e4 / MarketMath.value(td, 172.8e18), 13_020, "aggregate 1.302");
        (ok,) = m.canTrigger();
        assertFalse(ok, "the trigger is not an insolvency backstop on this book");
        vm.expectRevert(IBellMarket.NoTrigger.selector);
        m.triggerSettlement();
    }
}
