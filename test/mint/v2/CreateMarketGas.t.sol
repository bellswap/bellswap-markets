// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MintBase} from "../MintBase.sol";
import {BellMarketFactoryV2} from "../../../src/mint/BellMarketFactoryV2.sol";
import {IBellMarketFactoryV2} from "../../../src/mint/interfaces/IBellMarketFactoryV2.sol";

/// Gas of one createMarket call, v1 against V2, on the same fixture (MintBase: mock feed at 20 USD, the T0 tier, cap
/// 25,000 USDG, the reference view created by the call). The V2 label is 19 bytes of name and 4 of symbol, as a
/// typical launch label. Both test gases are recorded in test/mint/v2/CreateMarketGas.snap (v1 4,026,092, V2 4,064,939
/// at the time of writing); `forge snapshot --match-path test/mint/v2/CreateMarketGas.t.sol --snap
/// test/mint/v2/CreateMarketGas.snap --check` compares a build against it, and without `--check` rewrites it. Each test
/// also logs the gas of the createMarket call alone (`-vv`: v1 4,023,951, V2 4,062,780, +38,829 or +0.96 percent).
contract CreateMarketGasTest is MintBase {
    BellMarketFactoryV2 internal f2;

    function setUp() public override {
        super.setUp();
        IBellMarketFactoryV2.Label[] memory l = new IBellMarketFactoryV2.Label[](1);
        l[0] = IBellMarketFactoryV2.Label("Bellswap Test Label", "BSTL", address(feed), 0, 25_000e6);
        f2 = new BellMarketFactoryV2(address(usdg), address(refFactory), menu(), l, 2);
    }

    function test_gas_createMarket_v1() public {
        uint256 g = gasleft();
        factory.createMarket(address(feed), 0, 25_000e6);
        emit log_named_uint("createMarket v1 gas", g - gasleft());
    }

    function test_gas_createMarket_v2() public {
        uint256 g = gasleft();
        f2.createMarket(address(feed), 0, 25_000e6, 0);
        emit log_named_uint("createMarket v2 gas", g - gasleft());
    }
}
