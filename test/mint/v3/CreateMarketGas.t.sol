// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MintBase} from "../MintBase.sol";
import {BellMarketFactoryV2} from "../../../src/mint/BellMarketFactoryV2.sol";
import {BellMarketFactoryV3} from "../../../src/mint/BellMarketFactoryV3.sol";
import {IBellMarketFactoryV2} from "../../../src/mint/interfaces/IBellMarketFactoryV2.sol";

/// Gas of one createMarket call, V2 against V3, on the fixture of test/mint/v2/CreateMarketGas.t.sol (MintBase: mock
/// feed at 20 USD, the T0 tier, cap 25,000 USDG, the reference view created by the call, the label "Bellswap Test
/// Label" / "BSTL"). V3 changes only the tier checks, which run in the constructor. Both test gases are recorded in
/// test/mint/v3/CreateMarketGas.snap (V2 4,064,939, V3 4,064,918 at the time of writing); `forge snapshot --match-path
/// test/mint/v3/CreateMarketGas.t.sol --snap test/mint/v3/CreateMarketGas.snap --check` compares a build against it,
/// and without `--check` rewrites it. Each test also logs the gas of the createMarket call alone (`-vv`: 4,062,780 for
/// both).
contract CreateMarketGasV3Test is MintBase {
    BellMarketFactoryV2 internal f2;
    BellMarketFactoryV3 internal f3;

    function setUp() public override {
        super.setUp();
        IBellMarketFactoryV2.Label[] memory l = new IBellMarketFactoryV2.Label[](1);
        l[0] = IBellMarketFactoryV2.Label("Bellswap Test Label", "BSTL", address(feed), 0, 25_000e6);
        f2 = new BellMarketFactoryV2(address(usdg), address(refFactory), menu(), l, 2);
        f3 = new BellMarketFactoryV3(address(usdg), address(refFactory), menu(), l, 2);
    }

    function test_gas_createMarket_v2() public {
        uint256 g = gasleft();
        f2.createMarket(address(feed), 0, 25_000e6, 0);
        emit log_named_uint("createMarket v2 gas", g - gasleft());
    }

    function test_gas_createMarket_v3() public {
        uint256 g = gasleft();
        f3.createMarket(address(feed), 0, 25_000e6, 0);
        emit log_named_uint("createMarket v3 gas", g - gasleft());
    }
}
