// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDG
/// @notice Test-only stand-in for USDG on 46630 and in unit tests (SPEC 4.9). Own MIT code, name
/// "Test Dollar", symbol "TDOL". Open mint. Pause and blacklist switches only by CONTROLLER.
contract MockUSDG is ERC20 {
    error Paused();
    error Blocked(address account);
    error NotController();

    /// @notice The only address that can pause and block.
    address public immutable CONTROLLER;
    uint8 internal immutable _DECIMALS;

    /// @notice Whether every transfer reverts Paused.
    bool public paused;
    /// @notice Whether transfers from or to an account revert Blocked.
    mapping(address => bool) public blocked;

    /// @param decimals_ 6 for the stress factory; other values only in unit tests of the decimals check.
    /// @param controller The address allowed to pause and block.
    constructor(uint8 decimals_, address controller) ERC20("Test Dollar", "TDOL") {
        _DECIMALS = decimals_;
        CONTROLLER = controller;
    }

    /// @notice Token decimals as set at construction.
    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    /// @notice Anyone mints (test only).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice CONTROLLER only; while paused every transfer, mint and burn reverts Paused.
    function setPaused(bool paused_) external {
        if (msg.sender != CONTROLLER) revert NotController();
        paused = paused_;
    }

    /// @notice CONTROLLER only; transfers from or to a blocked account revert Blocked.
    function setBlocked(address account, bool blocked_) external {
        if (msg.sender != CONTROLLER) revert NotController();
        blocked[account] = blocked_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert Paused();
        if (blocked[from]) revert Blocked(from);
        if (blocked[to]) revert Blocked(to);
        super._update(from, to, value);
    }
}
