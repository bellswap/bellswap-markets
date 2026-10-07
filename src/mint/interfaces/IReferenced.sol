// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IReferenced
/// @notice Declared by BellMarket so hooks and UIs can bind a synthetic to its reference and see its
/// settlement (SPEC 4.1).
interface IReferenced {
    /// @notice The AggregatorV3 feed the synthetic references (the market's GuardedFeedView).
    function referenceFeed() external view returns (address);

    /// @notice phase: 0 Live, 1 Settling, 2 Final. pool and supplyAtTrigger are 0 while Live; after
    /// finalize a holder's claim is amount * pool / supplyAtTrigger USDG units (SPEC 8.6).
    function settlementState() external view returns (uint8 phase, uint256 pool, uint256 supplyAtTrigger);
}
