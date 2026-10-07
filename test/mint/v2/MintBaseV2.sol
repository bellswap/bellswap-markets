// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {BellMarketFactoryV2} from "../../../src/mint/BellMarketFactoryV2.sol";
import {IBellMarketFactory} from "../../../src/mint/interfaces/IBellMarketFactory.sol";
import {IBellMarketFactoryV2} from "../../../src/mint/interfaces/IBellMarketFactoryV2.sol";

/// V2 listing for the MintBase suites: a suite contract that also inherits this and overrides MintBase.createMarketOn
/// with `return listV2(address(usdg), address(refFactory), menu(), f, tierId, capUsd);` runs every test of its v1
/// suite against BellMarketV2. Each listing deploys a BellMarketFactoryV2 with the fixture's tier menu and one label
/// bound to exactly that listing's (feed, tierId, capUsd), named "Test Market <n>" / "TM<n>", first market id
/// FIRST_ID + n, where n counts the listings. (Not a MintBase: inheriting MintBase twice would force every suite's
/// setUp to be virtual.)
abstract contract MintBaseV2 {
    uint256 internal constant FIRST_ID = 100;

    /// Number of V2 listings so far; the n-th listing's market has id FIRST_ID + n.
    uint256 internal v2Listings;
    BellMarketFactoryV2 internal lastFactoryV2;

    function labelOf(uint256 n) internal pure returns (string memory name, string memory symbol) {
        return (string.concat("Test Market ", Strings.toString(n)), string.concat("TM", Strings.toString(n)));
    }

    function listV2(
        address usdg,
        address refFactory,
        IBellMarketFactory.Tier[] memory menu,
        address f,
        uint8 tierId,
        uint256 capUsd
    ) internal returns (address a) {
        IBellMarketFactoryV2.Label[] memory labels = new IBellMarketFactoryV2.Label[](1);
        (string memory name, string memory symbol) = labelOf(v2Listings);
        labels[0] = IBellMarketFactoryV2.Label(name, symbol, f, tierId, capUsd);
        lastFactoryV2 = new BellMarketFactoryV2(usdg, refFactory, menu, labels, FIRST_ID + v2Listings);
        ++v2Listings;
        (, a) = lastFactoryV2.createMarket(f, tierId, capUsd, 0);
    }
}
