// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {BellMarketFactoryV3} from "../../../src/mint/BellMarketFactoryV3.sol";
import {IBellMarketFactory} from "../../../src/mint/interfaces/IBellMarketFactory.sol";
import {IBellMarketFactoryV2} from "../../../src/mint/interfaces/IBellMarketFactoryV2.sol";

/// V3 listing for the MintBase suites, the pattern of MintBaseV2 (test/mint/v2/MintBaseV2.sol): a suite contract that
/// also inherits this and overrides MintBase.createMarketOn with `return listV3(address(usdg), address(refFactory),
/// menu(), f, tierId, capUsd);` runs every test of its v1 suite against a BellMarketV2 listed by BellMarketFactoryV3.
/// Each listing deploys a BellMarketFactoryV3 with the given tier menu and one label bound to exactly that listing's
/// (feed, tierId, capUsd), named "Test Market <n>" / "TM<n>", first market id FIRST_ID_V3 + n, where n counts the
/// listings. menuTL() is the MintBase menu with TL1 in place of T1, so a suite's tier 1 market runs at TL1.
abstract contract MintBaseV3 {
    uint256 internal constant FIRST_ID_V3 = 200;

    /// Number of V3 listings so far; the n-th listing's market has id FIRST_ID_V3 + n.
    uint256 internal v3Listings;
    BellMarketFactoryV3 internal lastFactoryV3;

    function labelOfV3(uint256 n) internal pure returns (string memory name, string memory symbol) {
        return (string.concat("Test Market ", Strings.toString(n)), string.concat("TM", Strings.toString(n)));
    }

    /// [T0, TL1, T2]: T0 and T2 of SPEC 5.3 (MintBase.menu) with the TL1 struct of tiers.md at index 1.
    function menuTL() internal pure returns (IBellMarketFactory.Tier[] memory m) {
        m = new IBellMarketFactory.Tier[](3);
        m[0] = IBellMarketFactory.Tier(40_000, 25_000, 1_500, 1_000, 172_800, 259_200, 604_800, 11_000, 259_200);
        m[1] = IBellMarketFactory.Tier(17_500, 15_000, 500, 1_000, 129_600, 259_200, 604_800, 10_500, 600);
        m[2] = IBellMarketFactory.Tier(40_000, 25_000, 1_500, 1_000, 172_800, 259_200, 604_800, 11_000, 600);
    }

    function listV3(
        address usdg,
        address refFactory,
        IBellMarketFactory.Tier[] memory menu,
        address f,
        uint8 tierId,
        uint256 capUsd
    ) internal returns (address a) {
        IBellMarketFactoryV2.Label[] memory labels = new IBellMarketFactoryV2.Label[](1);
        (string memory name, string memory symbol) = labelOfV3(v3Listings);
        labels[0] = IBellMarketFactoryV2.Label(name, symbol, f, tierId, capUsd);
        lastFactoryV3 = new BellMarketFactoryV3(usdg, refFactory, menu, labels, FIRST_ID_V3 + v3Listings);
        ++v3Listings;
        (, a) = lastFactoryV3.createMarket(f, tierId, capUsd, 0);
    }
}
