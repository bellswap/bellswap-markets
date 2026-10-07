// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IAggregatorV3
/// @notice The AggregatorV3 getter ABI (SPEC 4.1).
interface IAggregatorV3 {
    /// @notice Decimals of `answer`.
    function decimals() external view returns (uint8);
    /// @notice Human readable feed description.
    function description() external view returns (string memory);
    /// @notice Feed version.
    function version() external view returns (uint256);
    /// @notice Data of round `roundId`.
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    /// @notice Data of the latest round.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
