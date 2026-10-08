// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";

import {BellswapScript} from "./lib/BellswapScript.sol";
import {LabelLint} from "./lib/LabelLint.sol";
import {BellMarketFactoryV3} from "../src/mint/BellMarketFactoryV3.sol";
import {BellMarketV2} from "../src/mint/BellMarketV2.sol";
import {IBellMarketFactory} from "../src/mint/interfaces/IBellMarketFactory.sol";
import {IBellMarketFactoryV2} from "../src/mint/interfaces/IBellMarketFactoryV2.sol";
import {IMarketReferenceFeed, IMarketReferenceFactory} from "../src/mint/interfaces/IMarketReference.sol";

/// @title DeployMintV3
/// @notice BellMarketFactoryV3(USDG, REFERENCE_FACTORY, menu, labels, firstMarketId) on the child chain through the
/// CREATE2 proxy, the pattern of DeployMintV2.s.sol with V3 keys. The tier menu is given by tier names in
/// stacks.<S>.menuV3 (any tier of BellswapScript._tier, TL1 included); the label menu by stacks.<S>.labelsV3
/// ({"name", "symbol", "feed", "tier", "capUsd"} objects, tier a name of menuV3); the first market id by
/// stacks.<S>.firstMarketIdV3.
/// Robinhood Chain testnet (46630) and the local child chain; Robinhood Chain (4663) only with
/// BELLSWAP_V3_MAINNET_CHAIN=4663 (DESIGN.md decision 12, lifted by the founder on 2026-10-07), and there only behind the
/// G0 gate (BELLSWAP_MAINNET_CONFIRMED) and the mainnet preflight: USDG is SPEC 10.3's, menuV3 is exactly [TL1], the
/// v1 factory is configured and has code, and the book holds exactly the agreed deployment (firstMarketIdV3 100, one
/// label: name 'Tanker', symbol TANKR, feed 0xA8Dd192FFcAcC451D104BEEB628190ab4D3aA6ad, tier TL1, capUsd 10000000000),
/// pinned in code so a changed book cannot pass. Chain 1 and every other chain are refused before any address book
/// read.
/// On every chain a configured stacks.<S>.marketFactoryV3 other than the CREATE2 prediction is refused: a changed
/// menuV3, labelsV3 or firstMarketIdV3 would otherwise deploy a second factory and overwrite the key while marketsV3
/// and the pool records still belong to the first one. Replacing a V3 factory is not a re-run of this script.
/// Pre-flight, before a transaction exists: every label passes script/lib/LabelLint.sol and every rule the
/// constructor enforces, with its reason; firstMarketIdV3 is at least the marketCount() of the stack's v1 factory and
/// at least FIRST_MARKET_ID + labelCount() of the stack's BellMarketFactoryV2 (the S0 factory), when each is
/// configured and has code, so V3 ids start past both ranges; a re-run that finds the factory already at its CREATE2
/// address skips those checks.
/// Post-flight: USDG, REFERENCE_FACTORY, FIRST_MARKET_ID, every tier and every label equal the configured values, and
/// MARKET_CODE holds 0x00 ++ BellMarketV2's creation code.
/// Config keys read: usdg, stacks.<S>.referenceFactory, stacks.<S>.menuV3, stacks.<S>.labelsV3,
/// stacks.<S>.firstMarketIdV3, stacks.<S>.marketFactory, stacks.<S>.marketFactoryV2, stacks.<S>.marketFactoryV3. Key
/// written: stacks.<S>.marketFactoryV3.
contract DeployMintV3 is BellswapScript {
    /// @notice A chain other than Robinhood Chain testnet (46630), the local child chain and 4663 with
    /// BELLSWAP_V3_MAINNET_CHAIN=4663.
    error TestnetOnly(uint256 chainId);

    // The agreed 4663 deployment (founder, 2026-10-07): one TL1 label, Tanker (TANKR) on the kind 1 feed 0xA8Dd...,
    // capUsd 10,000 USDG, V3 ids from 100. A change to any of these is a code change, not a book edit.
    uint256 internal constant MAINNET_V3_FIRST_MARKET_ID = 100;
    string internal constant MAINNET_V3_NAME = "Tanker";
    string internal constant MAINNET_V3_SYMBOL = "TANKR";
    address internal constant MAINNET_V3_FEED = 0xA8Dd192FFcAcC451D104BEEB628190ab4D3aA6ad;
    uint256 internal constant MAINNET_V3_CAP_USD = 10_000e6;

    /// @notice What the script deploys, read from the address book.
    struct Params {
        address usdg;
        address referenceFactory;
        string[] menuNames;
        IBellMarketFactory.Tier[] menu;
        IBellMarketFactoryV2.Label[] labels;
        uint256 firstMarketId;
    }

    function run() external {
        _loadConfig();
        _deploy();
    }

    /// @notice run() after the address book is loaded: guard, read, pre-flight, gate, deploy, post-flight, print the
    /// key.
    function _deploy() internal returns (address addr) {
        _requireChildChain();
        _testnetGuard();
        _requireCreate2Proxy();
        Params memory p = _params();
        bytes32 salt = _salt(string.concat("BellMarketFactoryV3.", _stack()));
        bytes memory init = _initCode(p);
        address predicted = _predict(salt, init);
        _requireNoOtherFactory(predicted);
        _preflight(p, predicted.code.length > 0);

        _startBroadcast();
        if (predicted.code.length == 0) _gate(_description(p, salt, predicted));
        (addr,) = _create2(salt, init);
        vm.stopBroadcast();

        _check(BellMarketFactoryV3(addr), p);
        _set(string.concat("stacks.", _stack(), ".marketFactoryV3"), addr);
    }

    /// @notice Refuses every chain but 46630, the local child chain and 4663 with BELLSWAP_V3_MAINNET_CHAIN=4663.
    function _testnetGuard() internal view {
        if (block.chainid == ROBINHOOD_TESTNET || block.chainid == LOCAL_CHILD) return;
        if (block.chainid == ROBINHOOD && _v3Allowed()) return;
        console.log(
            string.concat(
                "DeployMintV3: refused on chain ",
                vm.toString(block.chainid),
                "; on 4663 set ",
                V3_MAINNET_ENV,
                "=4663."
            )
        );
        revert TestnetOnly(block.chainid);
    }

    function _params() internal view returns (Params memory p) {
        p.usdg = _mustAddr(".usdg");
        p.referenceFactory = _mustAddr(_stackKey("referenceFactory"));
        p.menuNames = _stringList(_stackKey("menuV3"));
        if (p.menuNames.length == 0) revert MissingConfig(_stackKey("menuV3"));
        p.menu = _menu(p.menuNames);
        p.labels = _labelsV2(_stackKey("labelsV3"), p.menuNames);
        if (p.labels.length == 0) revert MissingConfig(_stackKey("labelsV3"));
        if (!_has(_json, _stackKey("firstMarketIdV3"))) revert MissingConfig(_stackKey("firstMarketIdV3"));
        p.firstMarketId = vm.parseJsonUint(_json, _stackKey("firstMarketIdV3"));
    }

    /// @notice Refuses a configured stacks.<S>.marketFactoryV3 that is not `predicted` (a missing key, "" or the zero
    /// address passes): the book already names a V3 factory deployed from another configuration.
    function _requireNoOtherFactory(address predicted) internal view {
        address configured = _addr(_stackKey("marketFactoryV3"));
        if (configured == address(0) || configured == predicted) return;
        revert Preflight(string.concat(
                _stackKey("marketFactoryV3"),
                " is ",
                vm.toString(configured),
                ", not the CREATE2 prediction ",
                vm.toString(predicted),
                ": menuV3, labelsV3 or firstMarketIdV3 changed since that factory was deployed; replacing a V3 factory",
                " is not a re-run"
            ));
    }

    function _initCode(Params memory p) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(BellMarketFactoryV3).creationCode,
            abi.encode(p.usdg, p.referenceFactory, p.menu, p.labels, p.firstMarketId)
        );
    }

    /// @notice Every refusal of the constructor, and the off-chain policy, with a readable reason. `deployed` (the
    /// factory already has code at its CREATE2 address) skips the id checks against the v1 and V2 factories.
    function _preflight(Params memory p, bool deployed) internal view {
        if (p.usdg.code.length == 0) revert Preflight("USDG has no code");
        if (p.referenceFactory.code.length == 0) revert Preflight("REFERENCE_FACTORY has no code");
        if (p.labels.length > 32) revert Preflight("more than 32 labels (MAX_LABELS)");
        if (p.firstMarketId > type(uint128).max) revert Preflight("firstMarketIdV3 above type(uint128).max");
        for (uint256 i; i < p.labels.length; ++i) {
            _checkLabel(p, i);
        }
        address v1;
        if (_isMainnet()) {
            if (p.usdg != MAINNET_USDG) revert Preflight("mainnet USDG differs from SPEC 10.3 M3.1");
            if (!_isMainnetMenuV3(p.menuNames)) {
                revert Preflight("mainnet menuV3 must be exactly [TL1] (DESIGN.md decision 12)");
            }
            // As DM2:99-103: on mainnet the v1 id check cannot drop out.
            v1 = _mustAddr(_stackKey("marketFactory"));
            if (v1.code.length == 0) {
                revert Preflight(string.concat("mainnet v1 factory ", _stackKey("marketFactory"), " has no code"));
            }
            _checkMainnetPin(p);
        } else {
            v1 = _addr(_stackKey("marketFactory"));
        }
        if (deployed) return;
        if (v1.code.length > 0) {
            uint256 listed = IBellMarketFactory(v1).marketCount();
            if (p.firstMarketId < listed) {
                revert Preflight(string.concat(
                        "firstMarketIdV3 ",
                        vm.toString(p.firstMarketId),
                        " is below the v1 factory's marketCount() ",
                        vm.toString(listed),
                        ": V3 ids would repeat listed v1 ids"
                    ));
            }
        }
        address v2 = _addr(_stackKey("marketFactoryV2"));
        if (v2.code.length > 0) {
            IBellMarketFactoryV2 f2 = IBellMarketFactoryV2(v2);
            uint256 v2End = f2.FIRST_MARKET_ID() + f2.labelCount();
            if (p.firstMarketId < v2End) {
                revert Preflight(string.concat(
                        "firstMarketIdV3 ",
                        vm.toString(p.firstMarketId),
                        " is below the V2 factory's FIRST_MARKET_ID + labelCount() ",
                        vm.toString(v2End),
                        ": V3 ids would repeat V2 label ids"
                    ));
            }
        }
    }

    /// @notice The 4663 book must hold exactly the agreed deployment (MAINNET_V3_*), independent of the book itself;
    /// the tier needs no check here, menuV3 is exactly [TL1].
    function _checkMainnetPin(Params memory p) internal pure {
        if (p.firstMarketId != MAINNET_V3_FIRST_MARKET_ID) {
            revert Preflight(string.concat("mainnet firstMarketIdV3 must be 100, not ", vm.toString(p.firstMarketId)));
        }
        if (p.labels.length != 1) revert Preflight("mainnet labelsV3 must hold exactly one label (Tanker, TANKR)");
        IBellMarketFactoryV2.Label memory l = p.labels[0];
        if (
            keccak256(bytes(l.name)) != keccak256(bytes(MAINNET_V3_NAME))
                || keccak256(bytes(l.symbol)) != keccak256(bytes(MAINNET_V3_SYMBOL))
        ) revert Preflight("mainnet label 0 must be name 'Tanker' symbol TANKR");
        if (l.feed != MAINNET_V3_FEED) {
            revert Preflight("mainnet label 0 feed must be 0xA8Dd192FFcAcC451D104BEEB628190ab4D3aA6ad");
        }
        if (l.capUsd != MAINNET_V3_CAP_USD) {
            revert Preflight(string.concat("mainnet label 0 capUsd must be 10000000000, not ", vm.toString(l.capUsd)));
        }
    }

    function _checkLabel(Params memory p, uint256 i) internal view {
        IBellMarketFactoryV2.Label memory l = p.labels[i];
        string memory at = string.concat("label ", vm.toString(i), " (", l.symbol, "): ");
        (bool ok, string memory why) = LabelLint.check(l.name, l.symbol);
        if (!ok) revert Preflight(string.concat(at, why));
        if (l.capUsd < 1_000e6 || l.capUsd > 25_000e6) {
            revert Preflight(string.concat(at, "capUsd outside [1,000e6, 25,000e6]"));
        }
        if (l.feed.code.length == 0) revert Preflight(string.concat(at, "feed has no code"));
        if (!IMarketReferenceFactory(p.referenceFactory).isFeed(l.feed)) {
            revert Preflight(string.concat(at, "feed is not a feed of this stack's ReferenceFeedFactory"));
        }
        if (IMarketReferenceFeed(l.feed).FACTORY() != p.referenceFactory) {
            revert Preflight(string.concat(at, "feed.FACTORY() is not this stack's ReferenceFeedFactory"));
        }
        if (IMarketReferenceFeed(l.feed).KIND() != 1) revert Preflight(string.concat(at, "feed is not kind 1"));
        for (uint256 j; j < i; ++j) {
            // Case-folded as in BellMarketFactoryV3._checkLabel, so the pre-flight refuses what the constructor refuses.
            if (LabelLint.foldedHash(p.labels[j].name) == LabelLint.foldedHash(l.name)) {
                revert Preflight(string.concat(at, "name repeats label ", vm.toString(j)));
            }
            if (LabelLint.foldedHash(p.labels[j].symbol) == LabelLint.foldedHash(l.symbol)) {
                revert Preflight(string.concat(at, "symbol repeats label ", vm.toString(j)));
            }
        }
    }

    function _check(BellMarketFactoryV3 f, Params memory p) internal view {
        if (f.USDG() != p.usdg || f.REFERENCE_FACTORY() != p.referenceFactory) revert Postflight("factory immutables");
        if (f.FIRST_MARKET_ID() != p.firstMarketId) revert Postflight("FIRST_MARKET_ID");
        if (f.tierCount() != p.menu.length) revert Postflight("tierCount");
        for (uint256 i; i < p.menu.length; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            if (keccak256(abi.encode(f.tier(uint8(i)))) != keccak256(abi.encode(p.menu[i]))) {
                revert Postflight(string.concat("tier ", vm.toString(i), " differs from the configured menuV3"));
            }
        }
        if (f.labelCount() != p.labels.length) revert Postflight("labelCount");
        for (uint256 i; i < p.labels.length; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            if (keccak256(abi.encode(f.label(uint8(i)))) != keccak256(abi.encode(p.labels[i]))) {
                revert Postflight(string.concat("label ", vm.toString(i), " differs from the configured labelsV3"));
            }
        }
        if (keccak256(f.MARKET_CODE().code) != keccak256(abi.encodePacked(hex"00", type(BellMarketV2).creationCode))) {
            revert Postflight("MARKET_CODE is not BellMarketV2's creation code");
        }
    }

    /// @notice The G0 text: every argument, labels included, so the operator confirms the exact menu.
    function _description(Params memory p, bytes32 salt, address predicted) internal view returns (string memory) {
        string memory labels;
        for (uint256 i; i < p.labels.length; ++i) {
            IBellMarketFactoryV2.Label memory l = p.labels[i];
            labels = string.concat(
                labels,
                i == 0 ? "" : "; ",
                vm.toString(i),
                ": name '",
                l.name,
                "' symbol ",
                l.symbol,
                " feed ",
                vm.toString(l.feed),
                " tier ",
                p.menuNames[l.tierId],
                " capUsd ",
                vm.toString(l.capUsd)
            );
        }
        return string.concat(
            "T8v3 ",
            _chainName(),
            ": deploy BellMarketFactoryV3(usdg ",
            vm.toString(p.usdg),
            ", referenceFactory ",
            vm.toString(p.referenceFactory),
            ", menu [",
            _join(p.menuNames),
            "], labels [",
            labels,
            "], firstMarketId ",
            vm.toString(p.firstMarketId),
            ") via CREATE2 proxy salt ",
            vm.toString(salt),
            " at ",
            vm.toString(predicted)
        );
    }
}
