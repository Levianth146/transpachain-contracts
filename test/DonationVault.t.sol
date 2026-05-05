// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
// Skeleton — full implementation in Phase 2
// Tests here are stubs documenting expected behaviour

contract DonationVaultTest is Test {
    // TODO Phase 2: deploy CharityCore + GovernanceDAO + ImpactNFT mocks, then DonationVault

    function test_donate_recordsBalance() public {
        // ARRANGE: deploy full system (mocks), create campaign, set trusted contracts
        // ACT: donor donates 1 ether
        // ASSERT: getDonorAmount == 1 ether, getCampaignEscrowBalance == 1 ether
        assertTrue(true, "stub - implement in Phase 2");
    }

    function test_donate_mintsNFTOnFirst() public {
        // ASSERT: ImpactNFT.hasMintedForCampaign(donor, campaignId) == true after first donate
        assertTrue(true, "stub");
    }

    function test_donate_noNFTOnSubsequentDonation() public {
        // ASSERT: second donation does NOT trigger another mint
        assertTrue(true, "stub");
    }

    function test_claimRefund_revertsIfNotRefundable() public {
        // ASSERT: claimRefund reverts when campaign is Active
        assertTrue(true, "stub");
    }

    function test_claimRefund_returnsExactAmount() public {
        // ASSERT: donor gets back exact ETH after campaign fails
        assertTrue(true, "stub");
    }
}
