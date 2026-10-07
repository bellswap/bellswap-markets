// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MintBaseV2} from "./MintBaseV2.sol";
import {BellMarketTest} from "../BellMarket.t.sol";
import {SettlementTest} from "../Settlement.t.sol";
import {LiquidationExamplesTest} from "../LiquidationExamples.t.sol";
import {LiquidationMarketFuzzTest} from "../LiquidationFuzz.t.sol";
import {HandlerSmokeTest} from "../invariant/HandlerSmoke.t.sol";
import {MintInvariantsTest} from "../invariant/MintInvariants.t.sol";
import {BellMarketV2} from "../../../src/mint/BellMarketV2.sol";

// The BellMarket behaviour suites of test/mint, run against BellMarketV2: each contract below inherits every test of
// its v1 suite and lists its markets through BellMarketFactoryV2 (MintBaseV2.createMarketOn). Only the metadata test
// differs: a V2 market carries its label instead of the generated "Bellswap Synthetic #<id>" / "bsX<id>".

contract BellMarketV2Test is BellMarketTest, MintBaseV2 {
    function createMarketOn(address f, uint8 tierId, uint256 capUsd) internal override returns (address) {
        return listV2(address(usdg), address(refFactory), menu(), f, tierId, capUsd);
    }

    function expectedLabel() internal pure override returns (string memory, string memory) {
        return labelOf(0);
    }

    /// The fixture's market really is BellMarketV2 code from a V2 factory, with the V2 id and label.
    function test_v2_fixtureIsBellMarketV2() public view {
        assertEq(
            keccak256(lastFactoryV2.MARKET_CODE().code),
            keccak256(abi.encodePacked(hex"00", type(BellMarketV2).creationCode)),
            "the factory deploys BellMarketV2 code"
        );
        assertEq(address(m).code.length, vm.getDeployedCode("BellMarketV2.sol:BellMarketV2").length, "runtime size");
        assertEq(m.FACTORY(), address(lastFactoryV2));
        assertEq(m.MARKET_ID(), FIRST_ID);
        assertTrue(lastFactoryV2.isMarket(address(m)));
        assertEq(lastFactoryV2.labelMarket(0), address(m));
    }
}

contract SettlementV2Test is SettlementTest, MintBaseV2 {
    function createMarketOn(address f, uint8 tierId, uint256 capUsd) internal override returns (address) {
        return listV2(address(usdg), address(refFactory), menu(), f, tierId, capUsd);
    }
}

contract LiquidationExamplesV2Test is LiquidationExamplesTest, MintBaseV2 {
    function createMarketOn(address f, uint8 tierId, uint256 capUsd) internal override returns (address) {
        return listV2(address(usdg), address(refFactory), menu(), f, tierId, capUsd);
    }
}

contract LiquidationMarketFuzzV2Test is LiquidationMarketFuzzTest, MintBaseV2 {
    function createMarketOn(address f, uint8 tierId, uint256 capUsd) internal override returns (address) {
        return listV2(address(usdg), address(refFactory), menu(), f, tierId, capUsd);
    }
}

contract HandlerSmokeV2Test is HandlerSmokeTest, MintBaseV2 {
    function createMarketOn(address f, uint8 tierId, uint256 capUsd) internal override returns (address) {
        return listV2(address(usdg), address(refFactory), menu(), f, tierId, capUsd);
    }
}

contract MintInvariantsV2Test is MintInvariantsTest, MintBaseV2 {
    function createMarketOn(address f, uint8 tierId, uint256 capUsd) internal override returns (address) {
        return listV2(address(usdg), address(refFactory), menu(), f, tierId, capUsd);
    }
}
