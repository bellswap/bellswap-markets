// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MintBaseV3} from "./MintBaseV3.sol";
import {BellMarketTest} from "../BellMarket.t.sol";
import {SettlementTest} from "../Settlement.t.sol";
import {LiquidationExamplesTest} from "../LiquidationExamples.t.sol";
import {LiquidationMarketFuzzTest} from "../LiquidationFuzz.t.sol";
import {HandlerSmokeTest} from "../invariant/HandlerSmoke.t.sol";
import {MintInvariantsTest} from "../invariant/MintInvariants.t.sol";
import {BellMarketV2} from "../../../src/mint/BellMarketV2.sol";

// DESIGN.md test 12 and the V3 reuse of the MintBase suites: each contract below inherits every test of its v1 suite
// and lists its markets through BellMarketFactoryV3 (MintBaseV3.createMarketOn). The first six run the suites on the
// SPEC 5.3 menu, as MarketSuitesV2 does for V2, and show that V3 lists the same market code with the same behaviour.
// The last two run the invariant handler (test/mint/invariant) with a T0 market and a TL1 market: totalCollateral
// equals the sum of position collateral (M3, M4, M13 in MintInvariantsTest), and every liquidation that books bad
// debt is in the insolvent branch (F2, F5 in MintHandler._checkLiquidation).

contract BellMarketOnV3Test is BellMarketTest, MintBaseV3 {
    function createMarketOn(address f, uint8 tierId, uint256 capUsd) internal override returns (address) {
        return listV3(address(usdg), address(refFactory), menu(), f, tierId, capUsd);
    }

    function expectedLabel() internal pure override returns (string memory, string memory) {
        return labelOfV3(0);
    }

    /// The fixture's market really is BellMarketV2 code from a V3 factory, with the V3 id and label.
    function test_v3_fixtureIsBellMarketV2() public view {
        assertEq(
            keccak256(lastFactoryV3.MARKET_CODE().code),
            keccak256(abi.encodePacked(hex"00", type(BellMarketV2).creationCode)),
            "the factory deploys BellMarketV2 code"
        );
        assertEq(address(m).code.length, vm.getDeployedCode("BellMarketV2.sol:BellMarketV2").length, "runtime size");
        assertEq(m.FACTORY(), address(lastFactoryV3));
        assertEq(m.MARKET_ID(), FIRST_ID_V3);
        assertTrue(lastFactoryV3.isMarket(address(m)));
        assertEq(lastFactoryV3.labelMarket(0), address(m));
    }
}

contract SettlementOnV3Test is SettlementTest, MintBaseV3 {
    function createMarketOn(address f, uint8 tierId, uint256 capUsd) internal override returns (address) {
        return listV3(address(usdg), address(refFactory), menu(), f, tierId, capUsd);
    }
}

contract LiquidationExamplesOnV3Test is LiquidationExamplesTest, MintBaseV3 {
    function createMarketOn(address f, uint8 tierId, uint256 capUsd) internal override returns (address) {
        return listV3(address(usdg), address(refFactory), menu(), f, tierId, capUsd);
    }
}

contract LiquidationMarketFuzzOnV3Test is LiquidationMarketFuzzTest, MintBaseV3 {
    function createMarketOn(address f, uint8 tierId, uint256 capUsd) internal override returns (address) {
        return listV3(address(usdg), address(refFactory), menu(), f, tierId, capUsd);
    }
}

contract HandlerSmokeOnV3Test is HandlerSmokeTest, MintBaseV3 {
    function createMarketOn(address f, uint8 tierId, uint256 capUsd) internal override returns (address) {
        return listV3(address(usdg), address(refFactory), menu(), f, tierId, capUsd);
    }
}

contract MintInvariantsOnV3Test is MintInvariantsTest, MintBaseV3 {
    function createMarketOn(address f, uint8 tierId, uint256 capUsd) internal override returns (address) {
        return listV3(address(usdg), address(refFactory), menu(), f, tierId, capUsd);
    }
}

/// The handler walk on a T0 market and a TL1 market (tier 1 of menuTL).
contract HandlerSmokeTL1Test is HandlerSmokeTest, MintBaseV3 {
    function createMarketOn(address f, uint8 tierId, uint256 capUsd) internal override returns (address) {
        return listV3(address(usdg), address(refFactory), menuTL(), f, tierId, capUsd);
    }
}

/// DESIGN.md test 12: the M invariants with the second market at TL1 (tier 1 of menuTL).
contract MintInvariantsTL1Test is MintInvariantsTest, MintBaseV3 {
    function createMarketOn(address f, uint8 tierId, uint256 capUsd) internal override returns (address) {
        return listV3(address(usdg), address(refFactory), menuTL(), f, tierId, capUsd);
    }

    /// The fixture's second market runs the TL1 tier.
    function test_tl1_fixtureRunsTL1() public view {
        assertEq(mks[1].MINT_CR_BPS(), 17_500);
        assertEq(mks[1].LIQ_CR_BPS(), 15_000);
        assertEq(mks[1].BONUS_BPS(), 500);
        assertEq(mks[1].SETTLE_GCR_BPS(), 10_500);
    }
}
