// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title ReferenceDescription
/// @notice Builds the hex-only description tail shared by ReferenceFeed and GuardedFeedView (SPEC 4.4, 4.5, 14.1).
/// Internal functions only (SPEC 4: an external library function would be called by DELEGATECALL).
library ReferenceDescription {
    /// @notice "k<kind> 0x<source> 0x<subject> / USD" with lowercase hex addresses and no names.
    function tail(uint8 kind, address source, address subject) internal pure returns (string memory) {
        return string.concat(
            "k", Strings.toString(kind), " ", Strings.toHexString(source), " ", Strings.toHexString(subject), " / USD"
        );
    }
}
