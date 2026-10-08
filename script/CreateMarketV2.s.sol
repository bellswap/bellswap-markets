// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {BellswapScript} from "./lib/BellswapScript.sol";
import {LabelLint} from "./lib/LabelLint.sol";
import {IBellMarket} from "../src/mint/interfaces/IBellMarket.sol";
import {IBellMarketFactory} from "../src/mint/interfaces/IBellMarketFactory.sol";
import {IBellMarketFactoryV2} from "../src/mint/interfaces/IBellMarketFactoryV2.sol";
import {IMarketReferenceFeed, IMarketReferenceFactory} from "../src/mint/interfaces/IMarketReference.sol";

/// @title CreateMarketV2
/// @notice One labelled market: `BellMarketFactoryV2.createMarket(feed, tierId, capUsd, labelId)` on the child chain,
/// with the feed, tier and cap the label is bound to (read from the factory). The factory is the stack's
/// BellMarketFactoryV2 (stacks.<S>.marketFactoryV2) by default, or its BellMarketFactoryV3 (stacks.<S>.marketFactoryV3,
/// M1 step S1, same interface and the same BellMarketV2 code) with BELLSWAP_MARKET_FACTORY=V3; on 4663 V3 needs
/// BELLSWAP_V3_MAINNET_CHAIN=4663 (DESIGN.md decision 12, lifted by the founder on 2026-10-07) and the label's tier must
/// be TL1; chain 1 is refused. Every refusal of the factory
/// (src/mint/BellMarketFactoryV2.sol, createMarket) is raised here first with a readable reason, before a transaction
/// exists; the label must also pass script/lib/LabelLint.sol; after the call the market's immutables, id, name and
/// symbol are checked against the plan.
///
/// Mainnet (chain 4663, and chain 1, which is refused as a parent chain) runs only behind the operator gate of SPEC 10.3
/// (G0): BELLSWAP_MAINNET_CONFIRMED must equal the printed transaction description byte for byte, or the script refuses
/// before sending (dry run included). Operator listing on mainnet stays a policy decision (SPEC 8.1, M3.2: counsel
/// clearance); this gate makes it an explicit, recorded act, it does not grant it.
///
/// Dry run by default, as CreateMarket.s.sol: without --broadcast the call is executed pranked as the signer, so forge
/// saves no transaction. With --broadcast the script refuses unless BELLSWAP_CREATE_MARKET_BROADCAST equals this
/// chain's id. script/run.sh refuses --resume; re-run with --broadcast instead. A label already listed at its
/// predicted address is skipped (nothing to send, the address book line is printed again).
///
/// The market id and address do not depend on other listings: id = FIRST_MARKET_ID + labelId and the CREATE2 address
/// is computeMarketAddress(labelId). A listing of another label between simulation and mining changes nothing; a
/// listing of the same label by someone else lists the same market (same terms, same address; creator, WARMUP_END,
/// SUPPLY_CAP and DISC_BASE follow that transaction's block), and this run then reverts LabelUsed and sends nothing.
///
/// Environment (names only):
///   BELLSWAP_MARKET_LABEL             the labelId to list (required)
///   BELLSWAP_MARKET_FACTORY           V2 (default) or V3: the factory key, marketFactoryV2 or marketFactoryV3
///   BELLSWAP_CREATE_MARKET_BROADCAST  must equal the chain id for a --broadcast run
///   BELLSWAP_MAINNET_CONFIRMED        on 4663: the exact description this script prints
/// Config keys read: stacks.<S>.referenceFactory, stacks.<S>.marketFactoryV2 or stacks.<S>.marketFactoryV3. Key
/// written (run.sh, broadcast only): stacks.<S>.marketsV2.<marketId> or stacks.<S>.marketsV3.<marketId>, after run.sh's
/// post-broadcast check that labelMarket(labelId) is the planned market.
contract CreateMarketV2 is BellswapScript {
    string internal constant BROADCAST_ENV = "BELLSWAP_CREATE_MARKET_BROADCAST";
    string internal constant LABEL_ENV = "BELLSWAP_MARKET_LABEL";
    string internal constant FACTORY_ENV = "BELLSWAP_MARKET_FACTORY";
    uint256 internal constant UNSET = type(uint256).max;
    uint256 internal constant CAP_SCALE = 1e30;

    error BroadcastNotEnabled(string env, string expected);

    struct Request {
        address factory; // stacks.<S>.marketFactoryV2, or stacks.<S>.marketFactoryV3 when v3
        address referenceFactory; // stacks.<S>.referenceFactory
        uint256 labelId;
        bool v3; // BELLSWAP_MARKET_FACTORY=V3
    }

    struct Plan {
        address factory;
        address referenceFactory;
        address usdg;
        uint8 labelId;
        IBellMarketFactoryV2.Label label;
        IBellMarketFactory.Tier tier;
        uint256 marketId; // FIRST_MARKET_ID + labelId
        address market; // computeMarketAddress(labelId)
        bool exists; // labelMarket(labelId) already is this market
        uint80 roundId;
        uint256 price18;
        uint256 age;
        uint256 supplyCap;
        uint256 discBase;
        address view0;
        string key;
        bool v3;
    }

    function run() external {
        _requireChildChain();
        _loadConfig();
        _run(_request());
    }

    function _run(Request memory r) internal returns (address market) {
        Plan memory p = _plan(r);
        _log(p);
        if (p.exists) {
            console.log("CreateMarketV2: the label already lists the planned market; nothing to send.");
            _set(p.key, p.market);
            console.log(_expectLine(p));
            return p.market;
        }
        bool broadcasting = _isBroadcastRun();
        _checkBroadcastGuard(broadcasting, vm.envOr(BROADCAST_ENV, string("")));
        _gate(_description(p));

        _beginSend(broadcasting);
        market = _execute(p);
        _endSend(broadcasting);

        _set(p.key, market);
        console.log(_expectLine(p));
        if (!broadcasting) {
            console.log("CreateMarketV2: dry run, nothing was sent and nothing was saved (no --broadcast).");
        }
    }

    function _execute(Plan memory p) internal returns (address market) {
        uint256 id;
        (id, market) =
            IBellMarketFactoryV2(p.factory).createMarket(p.label.feed, p.label.tierId, p.label.capUsd, p.labelId);
        _postflight(p, id, market);
        console.log("CreateMarketV2: market created", market);
        console.log("  symbol", IERC20Metadata(market).symbol(), "id", id);
    }

    // ------------------------------------------------------------------ checks

    function _checkBroadcastGuard(bool broadcasting, string memory guard) internal view {
        if (!broadcasting) return;
        string memory want = vm.toString(block.chainid);
        if (keccak256(bytes(guard)) != keccak256(bytes(want))) {
            console.log(
                string.concat("CreateMarketV2: --broadcast refused; set ", BROADCAST_ENV, "=", want, " to send.")
            );
            revert BroadcastNotEnabled(BROADCAST_ENV, want);
        }
    }

    /// @notice The read-only plan, raising in order every refusal createMarket would give (factory pair, USDG decimals,
    /// label in the menu and passing the lint, feed, tier, cap, label unused, usable round). A label that already lists
    /// its predicted market ends the plan before the round checks.
    function _plan(Request memory r) internal view returns (Plan memory p) {
        _requireChildChain();
        p.factory = r.factory;
        p.referenceFactory = r.referenceFactory;
        p.v3 = r.v3;
        string memory v = r.v3 ? "V3" : "V2";
        if (r.v3 && !_v3Allowed()) {
            revert Preflight("the V3 market factory on 4663 needs BELLSWAP_V3_MAINNET_CHAIN=4663 (DESIGN.md decision 12)");
        }
        if (r.factory.code.length == 0) revert Preflight(string.concat(v, " market factory has no code"));
        if (r.referenceFactory.code.length == 0) revert Preflight("reference factory has no code");
        IBellMarketFactoryV2 mf = IBellMarketFactoryV2(r.factory);
        if (mf.REFERENCE_FACTORY() != r.referenceFactory) {
            revert Preflight(string.concat(
                    "the ", v, " factory's REFERENCE_FACTORY is not this stack's referenceFactory"
                ));
        }
        p.usdg = mf.USDG();
        if (p.usdg.code.length == 0) revert Preflight("the factory's USDG has no code");
        if (IERC20Metadata(p.usdg).decimals() != mf.USDG_DECIMALS()) {
            revert Preflight("the factory's USDG does not have 6 decimals: createMarket refuses");
        }
        uint8 n = mf.labelCount();
        if (r.labelId >= n) {
            revert Preflight(string.concat(
                    "label ",
                    vm.toString(r.labelId),
                    " is not in the factory's menu of ",
                    vm.toString(uint256(n)),
                    " labels"
                ));
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        p.labelId = uint8(r.labelId); // below labelCount(), a uint8
        p.label = mf.label(p.labelId);
        (bool ok, string memory why) = LabelLint.check(p.label.name, p.label.symbol);
        if (!ok) revert Preflight(string.concat("label fails script/lib/LabelLint.sol: ", why));
        p.tier = mf.tier(p.label.tierId);
        if (r.v3 && _isMainnet() && keccak256(abi.encode(p.tier)) != keccak256(abi.encode(_tier("TL1")))) {
            revert Preflight("mainnet V3 label tier is not TL1 (DESIGN.md decision 12)");
        }
        _checkFeed(p.label.feed, r.referenceFactory);
        if (p.label.capUsd < mf.MIN_CAP_USD() || p.label.capUsd > mf.MAX_CAP_USD()) revert Preflight("label capUsd");
        p.marketId = mf.FIRST_MARKET_ID() + p.labelId;
        p.market = mf.computeMarketAddress(p.labelId);
        p.key = string.concat("stacks.", _stack(), ".markets", v, ".", vm.toString(p.marketId));

        address listed = mf.labelMarket(p.labelId);
        if (listed != address(0)) {
            if (listed != p.market) revert Preflight("labelMarket differs from computeMarketAddress");
            p.exists = true;
            return p;
        }
        if (p.market.code.length > 0) revert Preflight("the market address already has code");

        (p.roundId, p.price18, p.age) = _usableRound(IMarketReferenceFeed(p.label.feed), p.tier.mintMaxAge);
        p.supplyCap = p.label.capUsd * CAP_SCALE / p.price18;
        if (p.supplyCap == 0) revert Preflight("supply cap rounds to 0 at the confirmed price");
        p.discBase = IMarketReferenceFeed(p.label.feed).discontinuityCount();
        p.view0 = IMarketReferenceFactory(r.referenceFactory).viewOf(p.label.feed, 0);
    }

    function _checkFeed(address feed, address referenceFactory) internal view {
        if (feed.code.length == 0) revert Preflight("feed has no code");
        if (!IMarketReferenceFactory(referenceFactory).isFeed(feed)) {
            revert Preflight("feed is not a feed of this stack's ReferenceFeedFactory");
        }
        if (IMarketReferenceFeed(feed).FACTORY() != referenceFactory) {
            revert Preflight("feed.FACTORY() is not this stack's ReferenceFeedFactory");
        }
        if (IMarketReferenceFeed(feed).KIND() != 1) revert Preflight("feed is not kind 1: markets need an Ondo feed");
    }

    function _usableRound(IMarketReferenceFeed f, uint32 mintMaxAge)
        internal
        view
        returns (uint80 roundId, uint256 price18, uint256 age)
    {
        IMarketReferenceFeed.Round memory r;
        try f.confirmed() returns (uint80 id, IMarketReferenceFeed.Round memory rr) {
            (roundId, r) = (id, rr);
        } catch {
            revert Preflight("feed has no confirmed round: relay one first");
        }
        price18 = r.price18;
        if (price18 == 0) revert Preflight("the confirmed round's price is 0");
        // forge-lint: disable-next-line(block-timestamp)
        age = block.timestamp > r.observedAt ? block.timestamp - r.observedAt : 0;
        if (age > mintMaxAge) {
            revert Preflight(string.concat(
                    "confirmed round is ",
                    vm.toString(age),
                    " s old, more than the tier's mintMaxAge ",
                    vm.toString(uint256(mintMaxAge)),
                    " s: relay a newer round"
                ));
        }
        (bool pend,,,) = f.pending();
        if (pend) revert Preflight("feed has a pending round: createMarket refuses until it is promoted");
        (bool held,,,,) = f.hold();
        if (held) revert Preflight("feed is in a promotion hold: createMarket refuses until it ends");
    }

    function _postflight(Plan memory p, uint256 id, address market) internal view {
        IBellMarketFactoryV2 mf = IBellMarketFactoryV2(p.factory);
        if (id != p.marketId || market != p.market) revert Postflight("market id or address differs from the plan");
        if (mf.labelMarket(p.labelId) != market || !mf.isMarket(market)) revert Postflight("factory listing");
        IBellMarket m = IBellMarket(market);
        if (m.FACTORY() != p.factory || m.FEED() != p.label.feed || m.USDG() != p.usdg || m.MARKET_ID() != id) {
            revert Postflight("market factory, feed, USDG or id");
        }
        if (m.CAP_USD() != p.label.capUsd || m.SUPPLY_CAP() != p.supplyCap || m.DISC_BASE() != p.discBase) {
            revert Postflight("market cap, supply cap or discontinuity base");
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (m.WARMUP_END() != uint64(block.timestamp) + p.tier.warmup) revert Postflight("market warm-up end");
        if (
            m.MINT_CR_BPS() != p.tier.mintCrBps || m.LIQ_CR_BPS() != p.tier.liqCrBps
                || m.MINT_MAX_AGE() != p.tier.mintMaxAge || m.SETTLE_STALE() != p.tier.settleStale
        ) revert Postflight("market tier");
        address view0 = IMarketReferenceFactory(p.referenceFactory).viewOf(p.label.feed, 0);
        if (view0 == address(0) || m.referenceFeed() != view0) revert Postflight("market reference view");
        if (
            keccak256(bytes(IERC20Metadata(market).name())) != keccak256(bytes(p.label.name))
                || keccak256(bytes(IERC20Metadata(market).symbol())) != keccak256(bytes(p.label.symbol))
        ) revert Postflight("market name or symbol differs from the label");
    }

    // ------------------------------------------------------------------ config

    function _request() internal view returns (Request memory) {
        return _requestFor(vm.envOr(FACTORY_ENV, string("")), vm.envOr(LABEL_ENV, UNSET));
    }

    /// @notice The request for the factory selector `v` ("" or "V2": marketFactoryV2; "V3": marketFactoryV3) and
    /// `labelId`, from the address book. Split from _request so a test passes both without vm.setEnv.
    function _requestFor(string memory v, uint256 labelId) internal view returns (Request memory r) {
        bytes memory b = bytes(v);
        r.v3 = keccak256(b) == keccak256("V3");
        if (!r.v3 && b.length != 0 && keccak256(b) != keccak256("V2")) {
            revert Preflight(string.concat(FACTORY_ENV, " must be V2 or V3"));
        }
        r.factory = _mustAddr(_stackKey(r.v3 ? "marketFactoryV3" : "marketFactoryV2"));
        r.referenceFactory = _mustAddr(_stackKey("referenceFactory"));
        r.labelId = labelId;
        if (r.labelId == UNSET) revert Preflight(string.concat(LABEL_ENV, " not set"));
    }

    // ------------------------------------------------------------------ output

    /// @notice The post-broadcast check for run.sh: the label lists the planned market (address bound to the label).
    function _expectLine(Plan memory p) internal pure returns (string memory) {
        return string.concat(
            "BELLSWAP_EXPECT ",
            vm.toString(p.market),
            " ",
            vm.toString(p.factory),
            " labelMarket(uint8)(address) ",
            vm.toString(uint256(p.labelId))
        );
    }

    function _description(Plan memory p) internal view returns (string memory) {
        return string.concat(
            "CreateMarketV2 ",
            _chainName(),
            ": factory ",
            vm.toString(p.factory),
            " createMarket(feed ",
            vm.toString(p.label.feed),
            ", tierId ",
            vm.toString(uint256(p.label.tierId)),
            ", capUsd ",
            vm.toString(p.label.capUsd),
            ", labelId ",
            vm.toString(uint256(p.labelId)),
            ") creates market ",
            vm.toString(p.marketId),
            " '",
            p.label.name,
            "' ",
            p.label.symbol,
            " at ",
            vm.toString(p.market)
        );
    }

    function _log(Plan memory p) internal pure {
        console.log(p.v3 ? "V3 market factory" : "V2 market factory", p.factory);
        console.log("reference factory", p.referenceFactory);
        console.log("label id         ", uint256(p.labelId));
        console.log("label name       ", p.label.name);
        console.log("label symbol     ", p.label.symbol);
        console.log("feed             ", p.label.feed);
        console.log("market id        ", p.marketId);
        console.log("market address   ", p.market);
        console.log("tier id          ", uint256(p.label.tierId), "warmup s", uint256(p.tier.warmup));
        console.log("capUsd (raw)     ", p.label.capUsd);
        if (p.exists) return;
        console.log("confirmed price18", p.price18);
        console.log("round age s      ", p.age);
        console.log("supplyCap        ", p.supplyCap);
        console.log("discontinuities  ", p.discBase);
    }
}
