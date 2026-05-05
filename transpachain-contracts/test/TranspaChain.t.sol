// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/CharityCore.sol";
import "../src/DonationVault.sol";
import "../src/GovernanceDAO.sol";
import "../src/ImpactNFT.sol";

/**
 * @title TranspaChainTest
 * @notice Integration tests validating the core data flow:
 *         CharityCore → DonationVault → GovernanceDAO → DonationVault (release)
 *
 *         Test structure:
 *         - setUp()         Deploy all 4 contracts and wire them together
 *         - test_*          Happy-path tests
 *         - testFail_* / testRevert_*  Sad-path / access control tests
 */
contract TranspaChainTest is Test {
    // =========================================================
    // Contracts under test
    // =========================================================
    CharityCore    core;
    DonationVault  vault;
    GovernanceDAO  dao;
    ImpactNFT      nft;

    // =========================================================
    // Actors
    // =========================================================
    address admin   = address(0xA11CE);
    address org     = address(0x01AC);
    address donor1  = address(0xD001);
    address donor2  = address(0xD002);
    address random  = address(0xBEEF);

    // =========================================================
    // Helpers
    // =========================================================
    uint256 constant GOAL     = 2 ether;
    uint256 constant DEADLINE_OFFSET = 30 days;
    uint8   constant MILESTONES = 3;

    function setUp() public {
        vm.startPrank(admin);

        // 1. Deploy
        nft   = new ImpactNFT(admin);
        core  = new CharityCore(admin);
        vault = new DonationVault(admin, address(core), address(nft));
        dao   = new GovernanceDAO(admin, address(vault));

        // 2. Wire
        nft.setVault(address(vault));
        vault.setGovernanceDAO(address(dao));

        // 3. Verify org
        core.setOrgVerified(org, true);

        vm.stopPrank();

        // Fund actors
        vm.deal(org,    10 ether);
        vm.deal(donor1,  5 ether);
        vm.deal(donor2,  5 ether);
    }

    // =========================================================
    // helpers
    // =========================================================

    function _createCampaign() internal returns (uint256 campaignId) {
        vm.prank(org);
        campaignId = core.createCampaign{value: 0.001 ether}(
            "QmTestCID123",
            GOAL,
            block.timestamp + DEADLINE_OFFSET,
            MILESTONES
        );
    }

    function _setupMilestones(uint256 campaignId) internal {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 0.6 ether;
        amounts[1] = 0.8 ether;
        amounts[2] = 0.6 ether;
        vm.prank(org);
        vault.setupMilestones(campaignId, amounts);
    }

    // =========================================================
    // CharityCore tests
    // =========================================================

    function test_CreateCampaign() public {
        uint256 id = _createCampaign();
        assertEq(id, 1);

        CharityCore.Campaign memory c = core.getCampaign(id);
        assertEq(c.orgAddress, org);
        assertEq(c.goalAmount, GOAL);
        assertEq(c.totalMilestones, MILESTONES);
        assertEq(uint8(c.status), uint8(CharityCore.CampaignStatus.Active));
    }

    function test_CampaignIsActiveBeforeDeadline() public {
        uint256 id = _createCampaign();
        assertTrue(core.isCampaignActive(id));
    }

    function test_CampaignInactiveAfterDeadline() public {
        uint256 id = _createCampaign();
        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        assertFalse(core.isCampaignActive(id));
    }

    function testRevert_CreateCampaignNotVerifiedOrg() public {
        vm.prank(random);
        vm.expectRevert(CharityCore.NotVerifiedOrg.selector);
        core.createCampaign{value: 0.001 ether}(
            "QmFail",
            GOAL,
            block.timestamp + 1 days,
            2
        );
    }

    function testRevert_CreateCampaignNoDeposit() public {
        vm.prank(org);
        vm.expectRevert(CharityCore.InsufficientCreationDeposit.selector);
        core.createCampaign{value: 0}(
            "QmFail",
            GOAL,
            block.timestamp + 1 days,
            2
        );
    }

    // =========================================================
    // DonationVault — donate
    // =========================================================

    function test_DonateEmitsEvent() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vm.expectEmit(true, true, false, true);
        emit DonationVault.DonationReceived(id, donor1, 0.5 ether, 0.5 ether);
        vault.donate{value: 0.5 ether}(id);
    }

    function test_DonateUpdatesEscrow() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);

        assertEq(vault.escrowBalance(id), 1 ether);
    }

    function test_DonateMintsNFT() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 0.5 ether}(id);

        DonationVault.DonorInfo memory info = vault.getDonorInfo(id, donor1);
        assertTrue(info.hasNFT);
        assertEq(nft.getDonorNFTs(donor1).length, 1);
    }

    function test_DonateTier_Bronze() public {
        uint256 id = _createCampaign();
        vm.prank(donor1);
        vault.donate{value: 0.001 ether}(id);

        uint256 tokenId = nft.campaignDonorToken(id, donor1);
        ImpactNFT.TokenMetadata memory meta = nft.getTokenMetadata(tokenId);
        assertEq(uint8(meta.tier), uint8(ImpactNFT.DonorTier.Bronze));
    }

    function test_DonateTier_Gold() public {
        uint256 id = _createCampaign();
        vm.prank(donor1);
        vault.donate{value: 0.2 ether}(id);

        uint256 tokenId = nft.campaignDonorToken(id, donor1);
        ImpactNFT.TokenMetadata memory meta = nft.getTokenMetadata(tokenId);
        assertEq(uint8(meta.tier), uint8(ImpactNFT.DonorTier.Gold));
    }

    function testRevert_DonateZeroValue() public {
        uint256 id = _createCampaign();
        vm.prank(donor1);
        vm.expectRevert(DonationVault.ZeroDonation.selector);
        vault.donate{value: 0}(id);
    }

    // =========================================================
    // Full data flow: donate → submit proof → vote → execute
    // =========================================================

    function test_FullMilestoneFlow() public {
        uint256 id = _createCampaign();
        _setupMilestones(id);

        // Both donors donate
        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);
        vm.prank(donor2);
        vault.donate{value: 1 ether}(id);

        assertEq(vault.escrowBalance(id), 2 ether);

        // Org submits proof for milestone 0
        // NOTE: In full implementation, this auto-creates a GovernanceDAO proposal.
        //       For now we test that the proof is stored correctly.
        vm.prank(org);
        vault.submitMilestoneProof(id, 0, "QmProofCID_milestone0");

        DonationVault.Milestone memory m = vault.getMilestone(id, 0);
        assertEq(m.proofCID, "QmProofCID_milestone0");
        assertFalse(m.released);

        // Simulate governance approving (direct call as dao address)
        // In real flow: dao.createProposal → donors vote → finalize → execute
        vm.prank(address(dao));
        vault.releaseMilestoneFunds(id, 0);

        m = vault.getMilestone(id, 0);
        assertTrue(m.released);

        // Org received the release amount
        assertEq(address(org).balance, 10 ether - 0.001 ether + 0.6 ether);
    }

    // =========================================================
    // Refund flow
    // =========================================================

    function test_RefundFlow() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 0.5 ether}(id);

        // Fast-forward past deadline
        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        core.markFailed(id);

        // Queue refunds
        vault.queueRefunds(id, 0, 100);
        assertEq(vault.pendingRefunds(id, donor1), 0.5 ether);

        // Donor claims
        uint256 balBefore = donor1.balance;
        vm.prank(donor1);
        vault.claimRefund(id);

        assertEq(donor1.balance, balBefore + 0.5 ether);
        assertEq(vault.pendingRefunds(id, donor1), 0);
    }

    // =========================================================
    // Access control
    // =========================================================

    function testRevert_ReleaseFundsNotDAO() public {
        uint256 id = _createCampaign();
        _setupMilestones(id);

        vm.prank(random);
        vm.expectRevert(DonationVault.NotGovernanceDAO.selector);
        vault.releaseMilestoneFunds(id, 0);
    }

    function testRevert_MintNFTNotVault() public {
        vm.prank(random);
        vm.expectRevert(ImpactNFT.NotVault.selector);
        nft.mintImpactNFT(donor1, 1, ImpactNFT.DonorTier.Gold);
    }
}
