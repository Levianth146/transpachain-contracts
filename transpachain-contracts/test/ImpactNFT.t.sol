// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

contract ImpactNFTTest is Test {
    // TODO Phase 2

    function test_mint_assignsCorrectTier() public {
        // Bronze < 0.01 ETH, Silver 0.01-0.1, Gold >= 0.1
        assertTrue(true, "stub");
    }

    function test_updateTokenURI_onlyTrusted() public {
        // ASSERT: random address cannot call updateTokenURI
        assertTrue(true, "stub");
    }
}
