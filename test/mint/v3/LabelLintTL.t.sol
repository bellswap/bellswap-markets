// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LabelLint} from "../../../script/lib/LabelLint.sol";

/// @title LabelLintTLTest
/// @notice The label lint run for the M1 labels of tiers.md section 3: the TL0 label and the S1 label (name "Tanker",
/// symbol "TANKR", founder decision 2026-10-06) pass script/lib/LabelLint.sol, which DeployMintV2 and DeployMintV3 run before any broadcast, and the earlier BSX symbols
/// fail it with the v1 namespace reason (R2 codex-1).
contract LabelLintTLTest is Test {
    function test_tlLabelsPassLint() public pure {
        (bool ok, string memory why) = LabelLint.check("Bellswap Synthetic TL0 Rehearsal", "LEVTL0");
        assertTrue(ok, why);
        (ok, why) = LabelLint.check("Tanker", "TANKR");
        assertTrue(ok, why);
    }

    function test_bsxSymbolsFailLint() public pure {
        (bool ok, string memory why) = LabelLint.check("Bellswap Synthetic TL0 Rehearsal", "BSXTL0");
        assertFalse(ok);
        assertEq(why, "symbol in the v1 generated namespace bsX<id>");
        (ok, why) = LabelLint.check("Tanker", "BSXTL1");
        assertFalse(ok);
        assertEq(why, "symbol in the v1 generated namespace bsX<id>");
    }
}
