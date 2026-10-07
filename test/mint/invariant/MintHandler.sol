// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BellMarket} from "../../../src/mint/BellMarket.sol";
import {IBellMarket} from "../../../src/mint/interfaces/IBellMarket.sol";
import {MarketMath} from "../../../src/mint/MarketMath.sol";
import {MockUSDG} from "../../../src/mocks/MockUSDG.sol";
import {MockMarketFeed} from "../mocks/MockMarketFeed.sol";

/// Handler for the M invariants (SPEC 8.8): two markets on two mock feeds, four actors, a feed that walks,
/// jumps, goes pending, is promoted and held, records discontinuities, lags, stalls and delivers queued
/// rounds after an arm, and a USDG that pauses and blacklists. Per-call properties (M1, M2, M5 with F0 to
/// F5, M6, M7 to M7c, M8, M9, M11) are asserted inside each action; state properties in the invariant suite.
contract MintHandler is Test {
    MockUSDG public usdg;
    BellMarket[2] public mk;
    MockMarketFeed[2] public fd;
    address[4] public actors;

    uint256 internal constant MAX_POS = 24;
    uint128 internal constant P_MIN = 1e16;
    uint128 internal constant P_MAX = 1e22;

    // Ghosts per market.
    uint256[2] public sumCDebtAtTrigger; // sum of C over positions with D > 0 at trigger (M14)
    uint256[2] public excessAtProcess; // sum of excess assigned by processing (M14)
    uint256[2] public poolAtFinal; // M8
    uint256[2] public satAtFinal; // M8
    bool[2] public finalized;

    mapping(bytes32 => uint256) public calls;

    struct Snap {
        uint256 tc;
        uint256 td;
        uint256 ub;
        uint256 od;
        uint256 supply;
        uint256 bal;
        uint256 phase;
        uint256 pool;
        uint256 npos;
        uint64 armedAt;
    }

    constructor(
        MockUSDG usdg_,
        BellMarket a,
        BellMarket b,
        MockMarketFeed fa,
        MockMarketFeed fb,
        address[4] memory act
    ) {
        usdg = usdg_;
        mk[0] = a;
        mk[1] = b;
        fd[0] = fa;
        fd[1] = fb;
        actors = act;
        for (uint256 i; i < 4; ++i) {
            vm.startPrank(act[i]);
            usdg.approve(address(a), type(uint256).max);
            usdg.approve(address(b), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------ helpers

    function _snap(uint256 i) internal view returns (Snap memory s) {
        BellMarket m = mk[i];
        (s.tc, s.td, s.ub, s.od) = m.totals();
        s.supply = m.totalSupply();
        s.bal = usdg.balanceOf(address(m));
        s.phase = uint256(m.phase());
        (,,, s.pool,,,) = m.settlement();
        s.npos = m.positionCount();
        (, s.armedAt,,) = m.armState();
    }

    /// M11: an action on market i leaves market 1 - i unchanged.
    function _checkIsolation(uint256 i, Snap memory before) internal view {
        Snap memory afterS = _snap(1 - i);
        assertEq(keccak256(abi.encode(before)), keccak256(abi.encode(afterS)), "M11 isolation");
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    function _pos(uint256 i, uint256 seed) internal view returns (bool ok, uint256 id, address owner) {
        uint256 n = mk[i].positionCount();
        if (n == 0) return (false, 0, address(0));
        id = seed % n;
        owner = mk[i].position(id).owner;
        ok = true;
    }

    function _richest(uint256 i) internal view returns (address who, uint256 bal) {
        for (uint256 k; k < 4; ++k) {
            uint256 b = mk[i].balanceOf(actors[k]);
            if (b > bal) (who, bal) = (actors[k], b);
        }
    }

    /// M6: deposit, repay, close (and withdraw with zero debt) never revert because of feed state.
    function _noFeedRevert(bytes memory err) internal pure {
        if (err.length >= 4) assertTrue(bytes4(err) != MockMarketFeed.NoData.selector, "M6 feed revert");
    }

    function _price(uint256 i) internal view returns (uint128 p) {
        (, MockMarketFeed.Round memory r) = fd[i].confirmed();
        p = r.price18;
    }

    // ------------------------------------------------------------ position actions

    function open(uint256 mSeed, uint256 aSeed, uint256 c, uint256 d) external {
        uint256 i = mSeed % 2;
        if (mk[i].positionCount() >= MAX_POS) return;
        Snap memory other = _snap(1 - i);
        BellMarket m = mk[i];
        address a = _actor(aSeed);
        c = bound(c, 100e6, 50_000e6);
        IBellMarket.PriceView memory pv = m.prices();
        uint256 dMax = pv.mint18 == 0 ? 0 : (c / 4) * 1e30 / pv.mint18;
        d = dMax == 0 || d % 3 == 0 ? 0 : bound(d, 1, dMax);
        usdg.mint(a, c);
        vm.prank(a);
        try m.open(c, d, a) returns (uint256 id) {
            ++calls[keccak256("open")];
            if (d > 0) _checkMint(i, id, pv);
        } catch {
            vm.prank(a);
            try m.open(c, 0, a) {
                ++calls[keccak256("open")];
            } catch {}
        }
        _checkIsolation(i, other);
    }

    function deposit(uint256 mSeed, uint256 aSeed, uint256 idSeed, uint256 amt) external {
        uint256 i = mSeed % 2;
        (bool ok, uint256 id,) = _pos(i, idSeed);
        if (!ok) return;
        Snap memory other = _snap(1 - i);
        address a = _actor(aSeed);
        amt = bound(amt, 1, 10_000e6);
        usdg.mint(a, amt);
        fd[i].setBroken(true);
        vm.prank(a);
        try mk[i].deposit(id, amt) {
            ++calls[keccak256("deposit")];
        } catch (bytes memory err) {
            _noFeedRevert(err);
        }
        fd[i].setBroken(false);
        _checkIsolation(i, other);
    }

    function withdraw(uint256 mSeed, uint256 idSeed, uint256 amt) external {
        uint256 i = mSeed % 2;
        (bool ok, uint256 id, address owner) = _pos(i, idSeed);
        if (!ok) return;
        Snap memory other = _snap(1 - i);
        BellMarket m = mk[i];
        IBellMarket.Position memory p = m.position(id);
        if (p.collateral == 0) return;
        amt = bound(amt, 1, p.collateral);
        bool noDebt = p.debt == 0;
        IBellMarket.PriceView memory pv = m.prices();
        if (noDebt) fd[i].setBroken(true); // withdraw with zero debt never reads a price
        vm.prank(owner);
        try m.withdraw(id, amt, owner) {
            ++calls[keccak256("withdraw")];
            if (!noDebt) {
                assertTrue(pv.mintOk, "M2 withdraw with debt needs mintOk");
                _checkRatio(i, id, pv);
            }
        } catch (bytes memory err) {
            if (noDebt) _noFeedRevert(err);
        }
        if (noDebt) fd[i].setBroken(false);
        _checkIsolation(i, other);
    }

    function mint(uint256 mSeed, uint256 idSeed, uint256 amt) external {
        uint256 i = mSeed % 2;
        (bool ok, uint256 id, address owner) = _pos(i, idSeed);
        if (!ok) return;
        Snap memory other = _snap(1 - i);
        BellMarket m = mk[i];
        IBellMarket.PriceView memory pv = m.prices();
        IBellMarket.Position memory p = m.position(id);
        if (pv.mint18 == 0) return;
        uint256 maxD = (uint256(p.collateral) / 4) * 1e30 / pv.mint18;
        if (maxD <= p.debt) return;
        amt = bound(amt, 1, maxD - p.debt);
        vm.prank(owner);
        try m.mint(id, amt, owner) {
            ++calls[keccak256("mint")];
            _checkMint(i, id, pv);
        } catch {}
        _checkIsolation(i, other);
    }

    function repay(uint256 mSeed, uint256 aSeed, uint256 idSeed, uint256 amt) external {
        uint256 i = mSeed % 2;
        (bool ok, uint256 id,) = _pos(i, idSeed);
        if (!ok) return;
        Snap memory other = _snap(1 - i);
        address a = _actor(aSeed);
        uint256 bal = mk[i].balanceOf(a);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        fd[i].setBroken(true);
        vm.prank(a);
        try mk[i].repay(id, amt) {
            ++calls[keccak256("repay")];
        } catch (bytes memory err) {
            _noFeedRevert(err);
        }
        fd[i].setBroken(false);
        _checkIsolation(i, other);
    }

    function close(uint256 mSeed, uint256 idSeed) external {
        uint256 i = mSeed % 2;
        (bool ok, uint256 id, address owner) = _pos(i, idSeed);
        if (!ok) return;
        Snap memory other = _snap(1 - i);
        BellMarket m = mk[i];
        uint256 d = m.position(id).debt;
        // Gather the owner's debt tokens from the other actors so close can succeed.
        for (uint256 k; k < 4 && m.balanceOf(owner) < d; ++k) {
            address a = actors[k];
            if (a == owner) continue;
            uint256 need = d - m.balanceOf(owner);
            uint256 b = m.balanceOf(a);
            uint256 x = b < need ? b : need;
            if (x > 0) {
                vm.prank(a);
                m.transfer(owner, x);
            }
        }
        fd[i].setBroken(true);
        vm.prank(owner);
        try m.close(id, owner) {
            ++calls[keccak256("close")];
        } catch (bytes memory err) {
            _noFeedRevert(err);
        }
        fd[i].setBroken(false);
        _checkIsolation(i, other);
    }

    function liquidate(uint256 mSeed, uint256 idSeed, uint256 maxRepay) external {
        uint256 i = mSeed % 2;
        (bool ok, uint256 id,) = _pos(i, idSeed);
        if (!ok) return;
        id = _preferLiquidatable(i, id);
        Snap memory other = _snap(1 - i);
        _liquidate(i, id, maxRepay);
        _checkIsolation(i, other);
    }

    /// Starting at id, the first position below LIQ_CR at the market price, or id if none.
    function _preferLiquidatable(uint256 i, uint256 id) internal view returns (uint256) {
        BellMarket m = mk[i];
        uint256 n = m.positionCount();
        uint256 price = m.prices().confirmed18;
        for (uint256 k; k < n; ++k) {
            uint256 j = (id + k) % n;
            IBellMarket.Position memory p = m.position(j);
            if (MarketMath.below(p.collateral, p.debt, price, m.LIQ_CR_BPS())) return j;
        }
        return id;
    }

    struct LiqCall {
        uint256 i;
        uint256 id;
        uint256 maxRepay;
        uint256 s;
        uint256 seize;
        IBellMarket.Position p;
        IBellMarket.PriceView pv;
    }

    function _liquidate(uint256 i, uint256 id, uint256 maxRepay) internal {
        BellMarket m = mk[i];
        (address liq, uint256 bal) = _richest(i);
        if (bal == 0) return;
        LiqCall memory c;
        c.i = i;
        c.id = id;
        c.maxRepay = bound(maxRepay, 1, bal);
        c.pv = m.prices();
        c.p = m.position(id);
        vm.prank(liq);
        try m.liquidate(id, c.maxRepay, 0, liq) returns (uint256 s, uint256 seize) {
            ++calls[keccak256("liquidate")];
            c.s = s;
            c.seize = seize;
            _checkLiquidation(c);
        } catch (bytes memory err) {
            // F0: a healthy position is never liquidated.
            if (c.pv.liqOk && !MarketMath.below(c.p.collateral, c.p.debt, c.pv.confirmed18, m.LIQ_CR_BPS())) {
                assertEq(bytes4(err), IBellMarket.NotLiquidatable.selector, "F0");
            }
        }
    }

    function transferTokens(uint256 mSeed, uint256 fromSeed, uint256 toSeed, uint256 amt) external {
        uint256 i = mSeed % 2;
        address from = _actor(fromSeed);
        uint256 bal = mk[i].balanceOf(from);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        vm.prank(from);
        mk[i].transfer(_actor(toSeed), amt);
    }

    // ------------------------------------------------------------ settlement actions

    function arm(uint256 mSeed) external {
        uint256 i = mSeed % 2;
        Snap memory other = _snap(1 - i);
        BellMarket m = mk[i];
        (bool armed, uint64 armedAt,,) = m.armState();
        bool can = m.canArm();
        try m.armSettlement() {
            ++calls[keccak256("arm")];
            assertTrue(can, "canArm matches armSettlement");
            assertFalse(armed, "M7c no re-arm of a valid arm");
            (bool a2, uint64 at2, uint80 lr2,) = m.armState();
            assertTrue(a2);
            assertEq(at2, block.timestamp);
            assertEq(lr2, fd[i].latestRound());
        } catch (bytes memory err) {
            assertFalse(can, "canArm true but arm reverted");
            if (armed && fd[i].discontinuityCount() <= m.DISC_BASE() && m.phase() == IBellMarket.Phase.Live) {
                assertEq(err, abi.encodeWithSelector(IBellMarket.AlreadyArmed.selector, armedAt), "M7c");
            }
            (, uint64 at3,,) = m.armState();
            assertEq(at3, armedAt, "M7c armedAt unchanged");
        }
        _checkIsolation(i, other);
    }

    function trigger(uint256 mSeed) external {
        uint256 i = mSeed % 2;
        Snap memory other = _snap(1 - i);
        _trigger(i);
        _checkIsolation(i, other);
    }

    struct TrigPre {
        bool can;
        IBellMarket.SettleReason want;
        uint256 price;
        uint64 armedAt;
        uint80 armedRound;
        bool disc;
        uint256 sumC;
    }

    function _trigger(uint256 i) internal {
        BellMarket m = mk[i];
        TrigPre memory t;
        (t.can, t.want) = m.canTrigger();
        t.price = m.prices().confirmed18;
        (, t.armedAt, t.armedRound,) = m.armState();
        t.disc = fd[i].discontinuityCount() > m.DISC_BASE();
        t.sumC = _sumCDebt(i);
        try m.triggerSettlement() {
            ++calls[keccak256("trigger")];
            _checkTrigger(i, t);
        } catch {
            assertFalse(t.can, "canTrigger true but trigger reverted");
        }
    }

    function _checkTrigger(uint256 i, TrigPre memory t) internal {
        BellMarket m = mk[i];
        assertTrue(t.can, "M7 trigger only when 8.6 holds");
        (IBellMarket.SettleReason r, uint256 pEnd, uint256 sat,,,,) = m.settlement();
        assertEq(uint8(r), uint8(t.want));
        if (t.disc) assertEq(uint8(r), uint8(IBellMarket.SettleReason.Discontinuity), "M7 precedence");
        if (r == IBellMarket.SettleReason.Discontinuity) {
            (uint80 pre,) = fd[i].discontinuity(m.DISC_BASE());
            assertEq(pEnd, fd[i].round(pre).price18, "M7 Pend pre-jump");
        } else {
            assertEq(pEnd, t.price, "M7 Pend market price");
        }
        if (r == IBellMarket.SettleReason.Stale) {
            // M7b: armed at least ARM_DELAY ago and no round accepted since.
            assertTrue(t.armedAt != 0 && uint256(t.armedAt) + 86_400 <= block.timestamp, "M7b delay");
            assertEq(t.armedRound, fd[i].latestRound(), "M7b no round since arm");
        }
        assertEq(sat, m.totalSupply());
        sumCDebtAtTrigger[i] = t.sumC;
    }

    function process(uint256 mSeed, uint256 s1, uint256 s2, uint256 s3) external {
        uint256 i = mSeed % 2;
        BellMarket m = mk[i];
        uint256 n = m.positionCount();
        if (n == 0 || m.phase() != IBellMarket.Phase.Settling) return;
        Snap memory other = _snap(1 - i);
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (s1 % n, s2 % n, s3 % n);
        IBellMarket.Position[3] memory pre;
        for (uint256 k; k < 3; ++k) {
            pre[k] = m.position(ids[k]);
        }
        (, uint256 pEnd,,,,,) = m.settlement();
        m.processPositions(ids);
        ++calls[keccak256("process")];
        for (uint256 k; k < 3; ++k) {
            if (pre[k].processed || pre[k].debt == 0) continue;
            if (k > 0 && ids[k] == ids[0]) continue;
            if (k > 1 && ids[k] == ids[1]) continue;
            IBellMarket.Position memory post = m.position(ids[k]);
            uint256 claim = Math.mulDiv(pre[k].debt, pEnd, 1e30, Math.Rounding.Ceil);
            if (claim > pre[k].collateral) claim = pre[k].collateral;
            assertEq(post.excess, pre[k].collateral - claim, "M9 excess");
            assertTrue(post.processed);
            excessAtProcess[i] += post.excess;
        }
        _checkIsolation(i, other);
    }

    function finalize(uint256 mSeed) external {
        uint256 i = mSeed % 2;
        BellMarket m = mk[i];
        (,,,, uint256 rem,,) = m.settlement();
        IBellMarket.Phase ph = m.phase();
        try m.finalize() {
            ++calls[keccak256("finalize")];
            assertEq(rem, 0);
            assertEq(uint8(ph), uint8(IBellMarket.Phase.Settling));
            (,, uint256 sat, uint256 pool,,,) = m.settlement();
            poolAtFinal[i] = pool;
            satAtFinal[i] = sat;
            finalized[i] = true;
        } catch {
            assertTrue(rem != 0 || ph != IBellMarket.Phase.Settling);
        }
    }

    function redeem(uint256 mSeed, uint256 aSeed, uint256 amt) external {
        uint256 i = mSeed % 2;
        BellMarket m = mk[i];
        if (m.phase() != IBellMarket.Phase.Final) return;
        Snap memory other = _snap(1 - i);
        address a = _actor(aSeed);
        uint256 bal = m.balanceOf(a);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        (,, uint256 sat, uint256 pool,,,) = m.settlement();
        vm.prank(a);
        try m.redeem(amt, a) returns (uint256 paid) {
            ++calls[keccak256("redeem")];
            assertEq(paid, Math.mulDiv(amt, pool, sat), "M8 payout");
        } catch {}
        _checkIsolation(i, other);
    }

    function claimExcess(uint256 mSeed, uint256 idSeed) external {
        uint256 i = mSeed % 2;
        (bool ok, uint256 id, address owner) = _pos(i, idSeed);
        if (!ok) return;
        Snap memory other = _snap(1 - i);
        vm.prank(owner);
        try mk[i].claimExcess(id, owner) {
            ++calls[keccak256("claimExcess")];
        } catch {}
        _checkIsolation(i, other);
    }

    // ------------------------------------------------------------ feed and environment actions

    function feedWalk(uint256 mSeed, uint256 bps, bool up) external {
        uint256 i = mSeed % 2;
        MockMarketFeed f = fd[i];
        if (f.holdActive()) return;
        uint256 p = _price(i);
        bps = bound(bps, 0, 2_000);
        p = up ? p * (1e4 + bps) / 1e4 : p * (1e4 - bps) / 1e4;
        if (p < P_MIN) p = P_MIN;
        if (p > P_MAX) p = P_MAX;
        // deviationBps mostly inside the buffer cap, sometimes above it (MintBlock.BufferCap).
        f.post(uint128(p), uint64(block.timestamp), uint16(bps % 10 == 0 ? 3_001 + bps % 1_000 : 500 + bps % 1_500));
        ++calls[keccak256("feedWalk")];
    }

    /// A confirmed jump (the mock skips the guard): moves CR fast enough to reach liquidation and the
    /// Global trigger.
    function feedJump(uint256 mSeed, uint256 factorBps) external {
        uint256 i = mSeed % 2;
        MockMarketFeed f = fd[i];
        if (f.holdActive()) return;
        uint256 p = _price(i) * bound(factorBps, 5_000, 30_000) / 1e4;
        if (p < P_MIN) p = P_MIN;
        if (p > P_MAX) p = P_MAX;
        f.post(uint128(p), uint64(block.timestamp), 1_000);
        ++calls[keccak256("feedJump")];
    }

    function feedPending(uint256 mSeed, uint256 factorBps) external {
        uint256 i = mSeed % 2;
        MockMarketFeed f = fd[i];
        if (f.holdActive() || factorBps % 3 != 0) return; // pending blocks minting; keep it a minority state
        uint256 p = _price(i) * bound(factorBps, 3_000, 30_000) / 1e4;
        if (p < P_MIN) p = P_MIN;
        if (p > P_MAX) p = P_MAX;
        f.postPending(uint128(p), uint64(block.timestamp));
        ++calls[keccak256("feedPending")];
    }

    /// A correction within JUMP_BPS of the confirmed price clears a pending spike.
    function feedCorrect(uint256 mSeed) external {
        uint256 i = mSeed % 2;
        MockMarketFeed f = fd[i];
        if (!f.pendingExists() || f.holdActive()) return;
        f.post(_price(i), uint64(block.timestamp), 1_000);
        ++calls[keccak256("feedCorrect")];
    }

    function feedPromote(uint256 mSeed) external {
        MockMarketFeed f = fd[mSeed % 2];
        if (!f.pendingExists() || f.holdActive()) return;
        f.promoteWithHold();
        ++calls[keccak256("feedPromote")];
    }

    function feedEndHold(uint256 mSeed, uint256 discSeed) external {
        MockMarketFeed f = fd[mSeed % 2];
        if (!f.holdActive()) return;
        f.endHold(discSeed % 6 == 0); // a discontinuity ends the market, so keep it rare
        ++calls[keccak256("feedEndHold")];
    }

    function feedLate(uint256 mSeed) external {
        fd[mSeed % 2].setLastLate(uint64(block.timestamp));
        ++calls[keccak256("feedLate")];
    }

    /// A queued round observed long ago lands now (still stale): it voids any arm (M7b).
    function feedBacklog(uint256 mSeed) external {
        uint256 i = mSeed % 2;
        MockMarketFeed f = fd[i];
        if (f.holdActive() || f.pendingExists()) return;
        (, MockMarketFeed.Round memory r) = f.confirmed();
        f.post(r.price18, r.observedAt + 1, r.deviationBps);
        ++calls[keccak256("feedBacklog")];
    }

    function warp(uint256 secs) external {
        // Mostly short steps; one in ten long enough to cross the mint, liquidation and stale ages.
        vm.warp(block.timestamp + (secs % 10 == 0 ? bound(secs, 1 days, 8 days) : bound(secs, 1, 6 hours)));
        ++calls[keccak256("warp")];
    }

    function usdgSwitch(uint256 seed) external {
        uint256 sel = seed % 8;
        vm.startPrank(usdg.CONTROLLER());
        if (sel == 0) {
            usdg.setPaused(!usdg.paused());
        } else if (sel == 1) {
            usdg.setBlocked(_actor(seed >> 8), !usdg.blocked(_actor(seed >> 8)));
        } else {
            usdg.setPaused(false);
            usdg.setBlocked(_actor(seed >> 8), false);
        }
        vm.stopPrank();
        ++calls[keccak256("usdgSwitch")];
    }

    // ------------------------------------------------------------ per-call checks

    function _checkRatio(uint256 i, uint256 id, IBellMarket.PriceView memory pv) internal view {
        BellMarket m = mk[i];
        IBellMarket.Position memory p = m.position(id);
        // M1: C * 1e4 >= V(D, Pmint) * MINT_CR, V rounded up.
        assertGe(uint256(p.collateral) * 1e4, MarketMath.valueUp(p.debt, pv.mint18) * m.MINT_CR_BPS(), "M1");
    }

    function _checkMint(uint256 i, uint256 id, IBellMarket.PriceView memory pv) internal view {
        BellMarket m = mk[i];
        // M2: minting only with mintOk (Live, warm-up over, no pending or hold, age, buffer, no disc).
        assertTrue(pv.mintOk, "M2 mintOk");
        assertGe(block.timestamp, m.WARMUP_END(), "M2 warm-up");
        assertLe(m.totalSupply(), m.SUPPLY_CAP(), "M2 SUPPLY_CAP");
        assertLe(MarketMath.valueUp(m.totalSupply(), pv.mint18), m.CAP_USD(), "M2 CAP_USD");
        assertGe(MarketMath.value(m.position(id).debt, pv.confirmed18), m.MIN_DEBT_VALUE(), "min debt value");
        assertGt(m.position(id).collateral, 0, "M2 collateral held");
        _checkRatio(i, id, pv);
    }

    function _checkLiquidation(LiqCall memory c) internal view {
        BellMarket m = mk[c.i];
        uint256 price = c.pv.confirmed18;
        // M5: only when CR < LIQ_CR with liqOk; S and seize follow 8.5.
        assertTrue(c.pv.liqOk, "M5 liqOk");
        assertTrue(MarketMath.below(c.p.collateral, c.p.debt, price, m.LIQ_CR_BPS()), "M5 CR < LIQ_CR");
        MarketMath.Liq memory l = MarketMath.liquidation(
            c.p.collateral, c.p.debt, price, c.maxRepay, m.MINT_CR_BPS(), m.BONUS_BPS(), m.MIN_COLLATERAL()
        );
        assertEq(c.s, l.repay, "M5 S");
        assertEq(c.seize, l.seize, "M5 seize");
        assertGe(c.seize, c.s * price / 1e30, "F1");
        assertLe(c.seize, c.p.collateral, "F4");
        IBellMarket.Position memory q = m.position(c.id);
        if (l.badDebt > 0) {
            assertEq(q.collateral, 0, "F2");
            assertEq(q.debt, 0, "F2");
            assertTrue(MarketMath.below(c.p.collateral, c.p.debt, price, 1e4), "F5");
        } else {
            assertLe(c.seize, MarketMath.withBonus(c.s, price, m.BONUS_BPS()), "F4");
        }
        if (!l.full) {
            assertGe(uint256(q.collateral) * c.p.debt, uint256(c.p.collateral) * q.debt, "M5 CR not lower");
        }
    }

    function _sumCDebt(uint256 i) internal view returns (uint256 sum) {
        BellMarket m = mk[i];
        uint256 n = m.positionCount();
        for (uint256 k; k < n; ++k) {
            IBellMarket.Position memory p = m.position(k);
            if (p.debt > 0) sum += p.collateral;
        }
    }
}
