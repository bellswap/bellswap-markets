// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IBellMarketFactory} from "../../src/mint/interfaces/IBellMarketFactory.sol";
import {IBellMarketFactoryV2} from "../../src/mint/interfaces/IBellMarketFactoryV2.sol";

/// @notice Read-only view of an Arbitrum Nitro rollup core, used by the parent chain pre-flight (SPEC 10).
interface IRollupMinimal {
    function inbox() external view returns (address);
    function chainId() external view returns (uint256);
}

/// @notice Read-only status getters of the delayed Inbox, checked in the T0 pre-flight (SPEC 10.1).
interface IInboxStatus {
    function allowListEnabled() external view returns (bool);
    function paused() external view returns (bool);
}

/// @notice Probe for an `owner()` getter; Check.s.sol asserts that no deployed contract answers it (SPEC 10, G7).
interface IOwnedProbe {
    function owner() external view returns (address);
}

/// @title BellswapScript
/// @notice Shared base of every Bellswap deploy script (SPEC 10). It provides:
/// - the address book: the JSON of script/config/<chainid>.json, passed in by script/run.sh as the environment
///   variable BELLSWAP_CONFIG_JSON (and the parent chain's file as BELLSWAP_PARENT_CONFIG_JSON), because the
///   repository's foundry.toml grants no file system access to script/;
/// - address references inside that JSON: "self:<path>" and "parent:<path>" resolve to another entry;
/// - the operator gate of SPEC 10.3 (G0): on chain 1 or 4663 nothing runs unless BELLSWAP_MAINNET_CONFIRMED
///   equals the exact transaction description the script prints;
/// - outputs: every deployed address is printed as "BELLSWAP_SET <json.path> <value>"; run.sh writes those lines
///   back into the config file after a successful --broadcast run;
/// - the tier menu of SPEC 5.3 (T0, T1, T2), T3 (T0 without warm-up, on mainnet since 2026-10-04) and the M1 tiers TL0
///   and TL1 (Robinhood Chain testnet only; TL1 fits only BellMarketFactoryV3's bounds);
/// - the label menu of BellMarketFactoryV2 (stacks.<S>.labelsV2).
abstract contract BellswapScript is Script {
    error MainnetNotConfirmed(string expectedDescription);
    error WrongChain(uint256 chainId);
    error MissingConfig(string key);
    error NoSigner();
    error Preflight(string what);
    error Postflight(string what);
    error UnknownTier(string name);

    string internal constant GATE_ENV = "BELLSWAP_MAINNET_CONFIRMED";
    string internal constant CONFIG_ENV = "BELLSWAP_CONFIG_JSON";
    string internal constant PARENT_CONFIG_ENV = "BELLSWAP_PARENT_CONFIG_JSON";

    /// @dev CREATE2 proxy on all four chains (SPEC 3.1, FACT 69 bytes); forge routes `new X{salt: s}` through it.
    address internal constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @dev Bellguard's deployer must never be reused (SPEC 10).
    address internal constant BELLGUARD_DEPLOYER = 0xCBc12B37c7B58eA7743d0c3536C8299F302bdcB3;
    /// @dev forge's placeholder sender when no wallet is given.
    address internal constant FORGE_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    /// @dev Arbitrum L1 to L2 alias offset (SPEC 6.4).
    uint160 internal constant ALIAS_OFFSET = uint160(0x1111000000000000000000000000000000001111);

    // Chain ids (SPEC 3.1). 31337 and 31338 are the two local anvil chains of script/local/e2e.sh.
    uint256 internal constant ETHEREUM = 1;
    uint256 internal constant ROBINHOOD = 4663;
    uint256 internal constant SEPOLIA = 11_155_111;
    uint256 internal constant ROBINHOOD_TESTNET = 46_630;
    uint256 internal constant LOCAL_PARENT = 31_337;
    uint256 internal constant LOCAL_CHILD = 31_338;

    // Mainnet constants the scripts refuse to deviate from (SPEC 10.3).
    address internal constant MAINNET_INBOX = 0x1A07cc4BD17E0118BdB54D70990D2158AbAD7a2D;
    address internal constant MAINNET_ONDO_ORACLE = 0x914D5Cb27cb30E80BdE8215ff577eD63Eb986B79;
    address internal constant MAINNET_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant MAINNET_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    string internal _json;
    string internal _parentJson;

    // ------------------------------------------------------------------ chains

    function _isMainnet() internal view returns (bool) {
        return block.chainid == ETHEREUM || block.chainid == ROBINHOOD;
    }

    function _isLocal() internal view returns (bool) {
        return block.chainid == LOCAL_PARENT || block.chainid == LOCAL_CHILD;
    }

    function _isParentChain() internal view returns (bool) {
        return block.chainid == ETHEREUM || block.chainid == SEPOLIA || block.chainid == LOCAL_PARENT;
    }

    function _isChildChain() internal view returns (bool) {
        return block.chainid == ROBINHOOD || block.chainid == ROBINHOOD_TESTNET || block.chainid == LOCAL_CHILD;
    }

    function _requireParentChain() internal view {
        if (!_isParentChain()) revert WrongChain(block.chainid);
    }

    function _requireChildChain() internal view {
        if (!_isChildChain()) revert WrongChain(block.chainid);
    }

    // ------------------------------------------------------------------ operator gate (SPEC 10.3 G0)

    /// @notice The exact text BELLSWAP_MAINNET_CONFIRMED must hold for `description` on this chain. Test and
    /// local chains need no confirmation.
    function _gate(string memory description) internal view {
        console.log("Transaction description:");
        console.log(description);
        if (!_isMainnet()) return;
        _gateCheck(description, vm.envOr(GATE_ENV, string("")));
        console.log("Mainnet gate: confirmed by BELLSWAP_MAINNET_CONFIRMED.");
    }

    /// @notice Reverts MainnetNotConfirmed unless `confirmed` equals `description` byte for byte (mainnet only).
    function _gateCheck(string memory description, string memory confirmed) internal view {
        if (!_isMainnet()) return;
        if (keccak256(bytes(confirmed)) != keccak256(bytes(description))) {
            console.log(
                "Mainnet gate (SPEC 10.3, G0): refused. Set BELLSWAP_MAINNET_CONFIRMED to exactly the text above."
            );
            revert MainnetNotConfirmed(description);
        }
    }

    // ------------------------------------------------------------------ broadcast context

    /// @notice True when forge runs this script with --broadcast: the collected transactions are sent. A run without
    /// --broadcast is a dry run (simulation only).
    /// @dev No Solidity check protects `forge script --resume`: forge 1.7.1 sends a saved sequence without running the
    /// script again (forge script --help), and without --broadcast it sends a dry run's saved sequence
    /// (broadcast/<script>/<chain>/dry-run/run-latest.json) when no broadcast sequence exists, to the RPC saved in it.
    /// The ScriptResume context below is therefore never seen by a script body; guarded scripts use `_beginSend`,
    /// whose dry run saves no transaction, and script/run.sh refuses --resume for them.
    function _isBroadcastRun() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }

    // ------------------------------------------------------------------ signer

    /// @notice Starts broadcasting from the wallet given to forge (--private-key, --account, --ledger, ...).
    function _startBroadcast() internal returns (address sender) {
        vm.startBroadcast();
        (, sender,) = vm.readCallers();
        _checkSigner(sender);
    }

    /// @notice Starts the sending part of a guarded script. A broadcast run broadcasts from the wallet given to forge.
    /// A dry run pranks that address instead (the script's msg.sender: --sender, --private-key or the single wallet),
    /// so it executes the same calls from the same address but forge saves no transaction: a later
    /// `forge script --resume` of the dry run has nothing to send.
    function _beginSend(bool broadcasting) internal returns (address sender) {
        if (broadcasting) return _startBroadcast();
        (, sender,) = vm.readCallers();
        _checkSigner(sender);
        vm.startPrank(sender, sender);
    }

    function _endSend(bool broadcasting) internal {
        if (broadcasting) vm.stopBroadcast();
        else vm.stopPrank();
    }

    function _checkSigner(address sender) internal pure {
        if (sender == FORGE_DEFAULT_SENDER || sender == address(0)) revert NoSigner();
        if (sender == BELLGUARD_DEPLOYER) revert Preflight("Bellguard deployer must not be reused (SPEC 10)");
    }

    // ------------------------------------------------------------------ config

    function _loadConfig() internal {
        string memory json = vm.envOr(CONFIG_ENV, string(""));
        if (bytes(json).length == 0) revert MissingConfig("BELLSWAP_CONFIG_JSON (run through script/run.sh)");
        _loadConfigFrom(json, vm.envOr(PARENT_CONFIG_ENV, json));
    }

    function _loadConfigFrom(string memory json, string memory parentJson) internal {
        _json = json;
        _parentJson = parentJson;
        uint256 cid = vm.parseJsonUint(_json, ".chainId");
        if (cid != block.chainid) revert WrongChain(cid);
    }

    /// @dev Virtual so that a test harness can pin the stack: vm.setEnv is process-wide and forge runs test contracts
    /// and their functions in parallel, so a test reading BELLSWAP_STACK sees another test's value.
    function _stack() internal view virtual returns (string memory) {
        return vm.envOr("BELLSWAP_STACK", _isMainnet() ? string("M") : string("O"));
    }

    function _stackKey(string memory field) internal view returns (string memory) {
        return string.concat(".stacks.", _stack(), ".", field);
    }

    function _has(string memory json, string memory key) internal view returns (bool) {
        return vm.keyExistsJson(json, key);
    }

    /// @notice Address at `key` of this chain's config; "self:" and "parent:" references are resolved; a missing
    /// key or a zero address returns address(0).
    function _addr(string memory key) internal view returns (address) {
        return _addrIn(_json, key, 0);
    }

    function _parentAddr(string memory key) internal view returns (address) {
        return _addrIn(_parentJson, key, 0);
    }

    function _addrIn(string memory json, string memory key, uint256 depth) internal view returns (address) {
        if (!_has(json, key)) return address(0);
        return _resolve(vm.parseJsonString(json, key), depth);
    }

    function _resolve(string memory raw, uint256 depth) internal view returns (address) {
        if (depth > 4) revert MissingConfig(raw);
        bytes memory b = bytes(raw);
        if (_startsWith(b, "self:")) return _addrIn(_json, string.concat(".", _slice(b, 5)), depth + 1);
        if (_startsWith(b, "parent:")) return _addrIn(_parentJson, string.concat(".", _slice(b, 7)), depth + 1);
        if (b.length == 0) return address(0);
        return vm.parseAddress(raw);
    }

    function _mustAddr(string memory key) internal view returns (address a) {
        a = _addr(key);
        if (a == address(0)) revert MissingConfig(key);
    }

    function _addrList(string memory key) internal view returns (address[] memory out) {
        if (!_has(_json, key)) return new address[](0);
        string[] memory raw = vm.parseJsonStringArray(_json, key);
        out = new address[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            out[i] = _resolve(raw[i], 0);
            if (out[i] == address(0)) revert MissingConfig(string.concat(key, "[", vm.toString(i), "] = ", raw[i]));
        }
    }

    function _uintList(string memory key) internal view returns (uint256[] memory) {
        if (!_has(_json, key)) return new uint256[](0);
        return vm.parseJsonUintArray(_json, key);
    }

    function _stringList(string memory key) internal view returns (string[] memory) {
        if (!_has(_json, key)) return new string[](0);
        return vm.parseJsonStringArray(_json, key);
    }

    // ------------------------------------------------------------------ outputs

    function _set(string memory key, address value) internal pure {
        console.log(string.concat("BELLSWAP_SET ", key, " ", vm.toString(value)));
    }

    function _setUint(string memory key, uint256 value) internal pure {
        console.log(string.concat("BELLSWAP_SET ", key, " ", vm.toString(value)));
    }

    // ------------------------------------------------------------------ CREATE2 helpers

    /// @notice Deterministic salt per contract and stack, printed in every description.
    function _salt(string memory label) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("bellswap.v1.", label));
    }

    function _predict(bytes32 salt, bytes memory initCode) internal pure returns (address) {
        return vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_PROXY);
    }

    /// @notice Deploys `initCode` through the CREATE2 proxy with an explicit call (one transaction from the
    /// signer to 0x4e59..956C carrying salt ++ initCode). Skips the call when the predicted address already has
    /// code, so re-running a script is safe.
    function _create2(bytes32 salt, bytes memory initCode) internal returns (address addr, bool deployed) {
        addr = _predict(salt, initCode);
        if (addr.code.length > 0) return (addr, false);
        (bool ok, bytes memory ret) = CREATE2_PROXY.call(abi.encodePacked(salt, initCode));
        // The proxy returns exactly the 20 address bytes; the length is checked first.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (!ok || ret.length != 20 || address(bytes20(ret)) != addr || addr.code.length == 0) {
            revert Postflight("CREATE2 proxy deployment");
        }
        deployed = true;
    }

    function _requireCreate2Proxy() internal view {
        if (CREATE2_PROXY.code.length == 0) revert Preflight("CREATE2 proxy 0x4e59..956C has no code");
    }

    // ------------------------------------------------------------------ tier menu (SPEC 5.3)

    function _tier(string memory name) internal pure returns (IBellMarketFactory.Tier memory) {
        bytes32 h = keccak256(bytes(name));
        // mintCr, liqCr, bonus, bufferFloor, mintMaxAge, liqMaxAge, settleStale, settleGcr, warmup
        if (h == keccak256("T0")) {
            return IBellMarketFactory.Tier(40_000, 25_000, 1_500, 1_000, 172_800, 259_200, 604_800, 11_000, 259_200);
        }
        if (h == keccak256("T1")) {
            return IBellMarketFactory.Tier(25_000, 17_500, 1_200, 1_000, 172_800, 259_200, 604_800, 11_000, 259_200);
        }
        if (h == keccak256("T2")) {
            return IBellMarketFactory.Tier(40_000, 25_000, 1_500, 1_000, 172_800, 259_200, 604_800, 11_000, 600);
        }
        if (h == keccak256("T3")) {
            // T0 with no warm-up: founder decision 2026-10-04, the live mainnet menu is [T0, T3] (bsX0 is on T3).
            return IBellMarketFactory.Tier(40_000, 25_000, 1_500, 1_000, 172_800, 259_200, 604_800, 11_000, 0);
        }
        if (h == keccak256("TL0")) {
            // M1 step S0 rehearsal on a second BellMarketFactoryV2, Robinhood Chain testnet only; fits MF2:247-260.
            return IBellMarketFactory.Tier(25_000, 15_000, 500, 1_000, 172_800, 259_200, 604_800, 10_500, 600);
        }
        if (h == keccak256("TL1")) {
            // M1 step S1 on BellMarketFactoryV3 (MIN_MINT_CR_BPS 17_500, MIN_CR_GAP_BPS 2_500, rule 2), testnet only.
            return IBellMarketFactory.Tier(17_500, 15_000, 500, 1_000, 129_600, 259_200, 604_800, 10_500, 600);
        }
        revert UnknownTier(name);
    }

    /// @notice The mainnet menu of the v1 factory as deployed on 4663 (0xf5Ff2232..., founder decision 2026-10-04):
    /// exactly [T0, T3]. SPEC 5.3 names T0 only; T3 differs from T0 only by its zero warm-up.
    function _isMainnetMenu(string[] memory names) internal pure returns (bool) {
        return names.length == 2 && keccak256(bytes(names[0])) == keccak256("T0")
            && keccak256(bytes(names[1])) == keccak256("T3");
    }

    /// @notice Whether every tier of `names` is a tier of the live mainnet menu (T0 or T3): the mainnet rule for a
    /// BellMarketFactoryV2 menu (menuV2), which DeployMintV2 refuses before deployment and Check asserts on the
    /// deployed factory. Order and length are free (V2 labels name their tier), unlike _isMainnetMenu.
    function _isMainnetMenuSubset(string[] memory names) internal pure returns (bool) {
        for (uint256 i; i < names.length; ++i) {
            bytes32 h = keccak256(bytes(names[i]));
            if (h != keccak256("T0") && h != keccak256("T3")) return false;
        }
        return true;
    }

    /// @notice Index of `name` in `names`; reverts UnknownTier when absent.
    function _tierIndex(string[] memory names, string memory name) internal pure returns (uint8) {
        for (uint256 i; i < names.length; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            if (keccak256(bytes(names[i])) == keccak256(bytes(name))) return uint8(i); // menus hold at most 255 tiers
        }
        revert UnknownTier(name);
    }

    /// @notice The label menu at `key` (stacks.<S>.labelsV2): an array of {"name", "symbol", "feed", "tier", "capUsd"}
    /// objects, where feed is an address or a "self:"/"parent:" reference, tier a name of `menuNames` (the V2 tier
    /// menu) and capUsd raw USDG (6 decimals). A missing key is an empty menu.
    function _labelsV2(string memory key, string[] memory menuNames)
        internal
        view
        returns (IBellMarketFactoryV2.Label[] memory labels)
    {
        uint256 n;
        while (_has(_json, string.concat(key, "[", vm.toString(n), "]"))) ++n;
        labels = new IBellMarketFactoryV2.Label[](n);
        for (uint256 i; i < n; ++i) {
            string memory at = string.concat(key, "[", vm.toString(i), "]");
            labels[i].name = vm.parseJsonString(_json, string.concat(at, ".name"));
            labels[i].symbol = vm.parseJsonString(_json, string.concat(at, ".symbol"));
            labels[i].feed = _addrIn(_json, string.concat(at, ".feed"), 0);
            labels[i].tierId = _tierIndex(menuNames, vm.parseJsonString(_json, string.concat(at, ".tier")));
            labels[i].capUsd = vm.parseJsonUint(_json, string.concat(at, ".capUsd"));
        }
    }

    function _menu(string[] memory names) internal pure returns (IBellMarketFactory.Tier[] memory menu) {
        menu = new IBellMarketFactory.Tier[](names.length);
        for (uint256 i; i < names.length; ++i) {
            menu[i] = _tier(names[i]);
        }
    }

    function _join(string[] memory parts) internal pure returns (string memory s) {
        for (uint256 i; i < parts.length; ++i) {
            s = i == 0 ? parts[i] : string.concat(s, ",", parts[i]);
        }
    }

    function _alias(address l1) internal pure returns (address) {
        unchecked {
            // forge-lint: disable-next-line(unsafe-typecast)
            return address(uint160(l1) + ALIAS_OFFSET);
        }
    }

    function _chainName() internal view returns (string memory) {
        return string.concat("chain ", vm.toString(block.chainid));
    }

    // ------------------------------------------------------------------ bytes

    function _startsWith(bytes memory b, bytes memory prefix) private pure returns (bool) {
        if (b.length < prefix.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (b[i] != prefix[i]) return false;
        }
        return true;
    }

    function _slice(bytes memory b, uint256 from) private pure returns (string memory) {
        bytes memory out = new bytes(b.length - from);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[from + i];
        }
        return string(out);
    }
}
