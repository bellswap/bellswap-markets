// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title BellTypes
/// @notice Shared report type and feed id of the reference layer (SPEC 4.1). Internal functions only (SPEC 4).
/// @dev Lives under src/reference/l1 because the L1 lane owns it; the L2 factory decodes the same struct.
library BellTypes {
    /// @notice Source is the immutable sanity oracle on L1, subject is the L1 token.
    uint8 internal constant KIND_ONDO = 1;
    /// @notice Source is an L1 AggregatorV3 feed, subject is address(0).
    uint8 internal constant KIND_AGGREGATOR = 2;

    /// @notice One observation, built on L1 by BellswapRelay, consumed on L2 by ReferenceFeedFactory.
    struct Report {
        uint8 kind;
        address source; // L1 contract read
        address subject; // kind 1: L1 token address; kind 2: address(0)
        uint128 price18; // USD, 18 decimals, in [MIN_PRICE18, 2**128)
        uint64 observedAt; // source lastUpdated (kind 1) or updatedAt (kind 2), unix s, <= L1 block.timestamp
        uint32 maxTimeDelay; // kind 1: source maxTimeDelay; kind 2: 0
        uint16 deviationBps; // kind 1: source allowedDeviationBps; kind 2: 0
        uint8 rawDecimals; // kind 1: 18; kind 2: aggregator.decimals(), <= 36
        bytes32 sourceCodehash; // extcodehash(source) at read time
    }

    /// @notice Feed id binding kind, source and subject (SPEC 4.1).
    function feedId(uint8 kind, address source, address subject) internal pure returns (bytes32) {
        return keccak256(abi.encode(kind, source, subject));
    }
}
