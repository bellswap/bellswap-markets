// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Test token whose decimals() can change after deployment (SPEC 9 T17d, factory decimals check).
contract MutableDecimalsToken is ERC20 {
    uint8 internal _dec;

    constructor(uint8 d) ERC20("Mutable", "MUT") {
        _dec = d;
    }

    function setDecimals(uint8 d) external {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }
}
