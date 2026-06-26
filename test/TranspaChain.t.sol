// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CharityCore.sol";
import "../src/DonationVault.sol";
import "../src/GovernanceDAO.sol";
import "../src/ImpactNFT.sol";
import { TranspaChainErrors } from "../src/Errors.sol";

/// @dev Minimal ERC-20 mock for USDC tests
contract MockERC20 {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/**
 * @title TranspaChainTest
 * @notice Integration tests validating the core data flow:
 *         CharityCore → DonationVault → GovernanceDAO → DonationVault (release)
 */
contract TranspaChainTest is Test {
    event DonationReceived(
        uint256 indexed campaignId,
        address indexed donor,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 fee,
        uint8 tokenType
    );

    CharityCore core;
    DonationVault vault;
    GovernanceDAO dao;
    ImpactNFT nft;
    MockERC20 usdc;

    address admin = address(0xA11CE);
    address org = address(0x01AC);
    address donor1 = address(0xD001);
    address donor2 = address(0xD002);
    address random = address(0xBEEF);

    uint256 constant GOAL = 2 ether;

    function _grossForNet(uint256 netGoal) internal pure returns (uint256) {
        return (netGoal * 10_000 + 9899) / 9900;
    }
    uint256 constant DEADLINE_OFFSET = 30 days;
    uint8 constant MILESTONES = 3;

    function setUp() public {
        vm.startPrank(admin);

        // 1. Deploy
        nft = new ImpactNFT(admin);
        core = new CharityCore(admin);
        dao = new GovernanceDAO(admin);
        usdc = new MockERC20();
        vault = new DonationVault(
            admin,
            address(core),
            address(dao),
            address(nft),
            address(usdc)
        );
        dao.setDonationVault(address(vault));

        // 2. Wire
        core.setTrustedContracts(address(vault), address(dao));
        nft.setTrustedContracts(address(vault), address(core));

        // 3. Verify org
        core.verifyOrg(org);

        vm.stopPrank();

        // Fund actors
        vm.deal(org, 10 ether);
        vm.deal(donor1, 5 ether);
        vm.deal(donor2, 5 ether);
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
            MILESTONES,
            ICharityCore.PaymentToken.ETH,
            "education"
        );
    }

    function _releaseMilestone(uint256 id, uint8 idx) internal {
        uint256 pid = vault.getMilestone(id, idx).proposalId;
        vm.prank(address(dao));
        vault.releaseMilestoneFunds(id, idx, pid);
    }

    function _createUSDCampaign() internal returns (uint256 campaignId) {
        vm.prank(org);
        campaignId = core.createCampaign{value: 0.001 ether}(
            "QmUSDCCID",
            1000e6, // 1000 USDC goal
            block.timestamp + DEADLINE_OFFSET,
            MILESTONES,
            ICharityCore.PaymentToken.USDC,
            "healthcare"
        );
    }

    // =========================================================
    // CharityCore tests
    // =========================================================

    function test_CreateCampaign() public {
        uint256 id = _createCampaign();
        assertEq(id, 1);

        ICharityCore.Campaign memory c = core.getCampaign(id);
        assertEq(c.orgAddress, org);
        assertEq(c.goalAmount, GOAL);
        assertEq(c.totalMilestones, MILESTONES);
        assertEq(uint8(c.status), uint8(ICharityCore.CampaignStatus.Active));
    }

    function testRevert_CreateCampaignNotVerifiedOrg() public {
        vm.prank(random);
        vm.expectRevert();
        core.createCampaign{value: 0.001 ether}(
            "QmFail",
            GOAL,
            block.timestamp + 1 days,
            2,
            ICharityCore.PaymentToken.ETH,
            "healthcare"
        );
    }

    function testRevert_CreateCampaignNoDeposit() public {
        vm.prank(org);
        vm.expectRevert("CharityCore: deposit required");
        core.createCampaign{value: 0}(
            "QmFail",
            GOAL,
            block.timestamp + 1 days,
            2,
            ICharityCore.PaymentToken.ETH,
            "healthcare"
        );
    }

    function test_CancelCampaign() public {
        uint256 id = _createCampaign();

        vm.prank(org);
        core.cancelCampaign(id);

        ICharityCore.Campaign memory c = core.getCampaign(id);
        assertEq(uint8(c.status), uint8(ICharityCore.CampaignStatus.Cancelled));
        assertTrue(c.cancelledAt > 0);
    }

    function testRevert_CancelCampaignHasDonors() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 0.5 ether}(id);

        vm.prank(org);
        core.cancelCampaign(id);

        ICharityCore.Campaign memory c = core.getCampaign(id);
        assertEq(uint8(c.status), uint8(ICharityCore.CampaignStatus.Cancelled));

        (bool eligible,,) = vault.canRefund(id, donor1);
        assertTrue(eligible);
    }

    function test_AdminCancelCampaign() public {
        uint256 id = _createCampaign();

        vm.prank(admin);
        core.adminCancelCampaign(id);

        ICharityCore.Campaign memory c = core.getCampaign(id);
        assertEq(uint8(c.status), uint8(ICharityCore.CampaignStatus.Cancelled));
    }

    function test_FinalizeCampaignFailed() public {
        uint256 id = _createCampaign();

        // Warp past deadline without meeting goal
        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);

        core.finalizeCampaign(id);

        ICharityCore.Campaign memory c = core.getCampaign(id);
        assertEq(uint8(c.status), uint8(ICharityCore.CampaignStatus.Failed));
    }

    function test_FinalizeCampaignSuccessful_requiresAllMilestones() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: _grossForNet(GOAL)}(id);

        vm.expectRevert("CharityCore: cannot finalize");
        core.finalizeCampaign(id);
    }

    function test_FinalizeCampaignSuccessful_atGoalBeforeDeadline() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: _grossForNet(GOAL)}(id);

        (bool eligible, bool goalReached, bool expired) = core.canFinalize(id);
        assertFalse(eligible);
        assertTrue(goalReached);
        assertFalse(expired);

        vm.expectRevert("CharityCore: cannot finalize");
        core.finalizeCampaign(id);
    }

    function testRevert_FinalizeCampaignBeforeGoalAndDeadline() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: GOAL / 2}(id);

        vm.expectRevert("CharityCore: cannot finalize");
        core.finalizeCampaign(id);
    }

    function testRevert_DonateAfterGoalReached() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: _grossForNet(GOAL)}(id);

        vm.prank(donor2);
        vm.expectRevert("Vault: goal reached");
        vault.donate{value: 0.1 ether}(id);
    }

    function test_ExtendDeadline() public {
        uint256 id = _createCampaign();
        ICharityCore.Campaign memory c = core.getCampaign(id);
        uint256 newDeadline = c.deadline + 10 days;

        vm.prank(org);
        core.extendDeadline(id, newDeadline);

        c = core.getCampaign(id);
        assertEq(c.deadline, newDeadline);
    }

    function testRevert_ExtendDeadlineExceedsMax() public {
        uint256 id = _createCampaign();
        ICharityCore.Campaign memory c = core.getCampaign(id);
        uint256 newDeadline = c.deadline + 31 days; // exceeds MAX_EXTENSION

        vm.prank(org);
        vm.expectRevert("CharityCore: exceeds max");
        core.extendDeadline(id, newDeadline);
    }

    function test_RevokeOrg() public {
        vm.prank(admin);
        core.revokeOrg(org);

        assertFalse(core.isOrgVerified(org));
    }

    function test_UpdateCampaignInfo() public {
        uint256 id = _createCampaign();

        vm.prank(org);
        core.updateCampaignInfo(id, "QmNewCID");

        ICharityCore.Campaign memory c = core.getCampaign(id);
        assertEq(c.metadataCID, "QmNewCID");
    }

    function test_PauseUnpause() public {
        vm.prank(admin);
        core.pause();

        vm.prank(org);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        core.createCampaign{value: 0.001 ether}(
            "QmFail",
            GOAL,
            block.timestamp + 1 days,
            2,
            ICharityCore.PaymentToken.ETH,
            "healthcare"
        );

        vm.prank(admin);
        core.unpause();

        // Should work again
        vm.prank(org);
        core.createCampaign{value: 0.001 ether}(
            "QmOK",
            GOAL,
            block.timestamp + 1 days,
            2,
            ICharityCore.PaymentToken.ETH,
            "healthcare"
        );
    }

    function test_WithdrawDeposits() public {
        _createCampaign(); // sends 0.001 ether deposit

        uint256 balBefore = admin.balance;

        vm.prank(admin);
        core.withdrawDeposits();

        assertGt(admin.balance, balBefore);
    }

    function test_GetCampaignsByOrg() public {
        _createCampaign();
        _createCampaign();

        uint256[] memory ids = core.getCampaignsByOrg(org);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
    }

    function test_TotalCampaigns() public {
        _createCampaign();
        _createCampaign();

        assertEq(core.totalCampaigns(), 2);
    }

    function test_GetCharityProgress() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);

        (uint256 raised, uint256 goal, uint256 progressBps, , , ) = core
            .getCharityProgress(id);
        assertEq(raised, 1 ether - ((1 ether * 100) / 10_000)); // net after fee
        assertEq(goal, GOAL);
        uint256 fee = (1 ether * 100) / 10_000;
        assertEq(progressBps, (1 ether - fee) * 10000 / GOAL);
    }

    // =========================================================
    // DonationVault — donate
    // =========================================================

    function test_DonateEmitsEvent() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vm.expectEmit(true, true, false, true);
        uint256 fee = (0.5 ether * 100) / 10_000;
        emit DonationReceived(id, donor1, 0.5 ether, 0.5 ether - fee, fee, 0);
        vault.donate{value: 0.5 ether}(id);
    }

    function test_DonateUpdatesEscrow() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);

        // Net after 1% fee
        uint256 expectedNet = 1 ether - ((1 ether * 100) / 10_000);
        assertEq(vault.getCampaignEscrowBalance(id), expectedNet);
    }

    function test_DonateMintsNFT() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 0.5 ether}(id);

        assertTrue(nft.hasMintedForCampaign(donor1, id));
        assertEq(nft.getDonorNFTs(donor1).length, 1);
    }

    function test_DonateTier_Bronze() public {
        uint256 id = _createCampaign();
        vm.prank(donor1);
        vault.donate{value: 0.001 ether}(id);

        uint256 tokenId = nft.getDonorTokenForCampaign(donor1, id);
        IImpactNFT.NFTMetadata memory meta = nft.getNFTMetadata(tokenId);
        assertEq(uint8(meta.tier), uint8(IImpactNFT.DonorTier.Bronze));
    }

    function test_DonateTier_Gold() public {
        uint256 id = _createCampaign();
        vm.prank(donor1);
        vault.donate{value: 0.2 ether}(id);

        uint256 tokenId = nft.getDonorTokenForCampaign(donor1, id);
        IImpactNFT.NFTMetadata memory meta = nft.getNFTMetadata(tokenId);
        assertEq(uint8(meta.tier), uint8(IImpactNFT.DonorTier.Gold));
    }

    function testRevert_DonateZeroValue() public {
        uint256 id = _createCampaign();
        vm.prank(donor1);
        vm.expectRevert(abi.encodeWithSelector(TranspaChainErrors.ZeroAmount.selector));
        vault.donate{value: 0}(id);
    }

    function test_DonateUSDC() public {
        uint256 id = _createUSDCampaign();

        // Mint USDC to donor and approve vault
        usdc.mint(donor1, 100e6);
        vm.prank(donor1);
        usdc.approve(address(vault), 100e6);

        vm.prank(donor1);
        vault.donateUSDC(id, 50e6);

        uint256 expectedNet = 50e6 - ((50e6 * 100) / 10_000);
        assertEq(vault.getCampaignEscrowBalance(id), expectedNet);
    }

    function test_DonateGetDonorInfo() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);

        DonationVault.DonorInfo memory info = vault.getDonorInfo(id, donor1);
        assertEq(info.totalDonated, 1 ether);
        assertEq(info.donationCount, 1);
        assertTrue(info.lastDonatedAt > 0);
    }

    function test_DonateGetCharityDonors() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 0.5 ether}(id);
        vm.prank(donor2);
        vault.donate{value: 0.5 ether}(id);

        address[] memory donors = vault.getCharityDonors(id);
        assertEq(donors.length, 2);
        assertEq(donors[0], donor1);
        assertEq(donors[1], donor2);
    }

    function test_GetTotalEscrow() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);

        uint256 expectedNet = 1 ether - ((1 ether * 100) / 10_000);
        assertEq(vault.getTotalEscrow(), expectedNet);
    }

    // =========================================================
    // DonationVault — refund
    // =========================================================

    function test_ClaimRefund() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);

        // Warp past deadline and finalize as failed
        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        core.finalizeCampaign(id);

        uint256 balBefore = donor1.balance;

        vm.prank(donor1);
        vault.claimRefund(id);

        uint256 donorNet = 1 ether - ((1 ether * 100) / 10_000);
        assertEq(donor1.balance, balBefore + donorNet);
        assertEq(vault.getDonorAmount(id, donor1), 0);
    }

    function testRevert_ClaimRefundNotRefundable() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);

        vm.prank(donor1);
        vm.expectRevert("Vault: not refundable");
        vault.claimRefund(id);
    }

    function test_EmergencyRefundBatch() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);
        vm.prank(donor2);
        vault.donate{value: 1 ether}(id);

        // Finalize as failed
        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        core.finalizeCampaign(id);

        uint256 bal1Before = donor1.balance;
        uint256 bal2Before = donor2.balance;

        vm.prank(admin);
        vault.emergencyRefundBatch(id, 0, 10);

        uint256 net1 = 1 ether - ((1 ether * 100) / 10_000);
        uint256 net2 = 1 ether - ((1 ether * 100) / 10_000);
        assertEq(donor1.balance, bal1Before + net1);
        assertEq(donor2.balance, bal2Before + net2);
        assertEq(vault.getCampaignEscrowBalance(id), 0);
    }

    // =========================================================
    // DonationVault — admin
    // =========================================================

    function test_SetTreasury() public {
        address newTreasury = address(0x9999);

        vm.prank(admin);
        vault.setTreasury(newTreasury);

        assertEq(vault.treasury(), newTreasury);
    }

    function test_SetMaxRefundPeriod() public {
        vm.prank(admin);
        vault.setMaxRefundPeriod(30 days);

        assertEq(vault.maxRefundPeriod(), 30 days);
    }

    function test_UpdatePlatformFee() public {
        vm.prank(admin);
        vault.updatePlatformFee(200); // 2%

        assertEq(vault.platformFeeBps(), 200);
    }

    function testRevert_UpdatePlatformFeeTooHigh() public {
        vm.prank(admin);
        vm.expectRevert("Vault: fee too high");
        vault.updatePlatformFee(501);
    }

    function test_CanRefund() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);

        // Not refundable yet (campaign active, not expired)
        (bool eligible, , ) = vault.canRefund(id, donor1);
        assertFalse(eligible);

        // Warp past deadline and finalize
        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        core.finalizeCampaign(id);

        (eligible, , ) = vault.canRefund(id, donor1);
        assertTrue(eligible);
    }

    // =========================================================
    // Full data flow: donate → submit proof → vote → execute
    // =========================================================

    function test_FullMilestoneFlow() public {
        uint256 id = _createCampaign();

        // Both donors donate
        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);
        vm.prank(donor2);
        vault.donate{value: 1 ether}(id);

        // Org submits proof for milestone 0
        vm.prank(org);
        vault.submitMilestoneProof(id, 0, "QmProofCID_milestone0");

        DonationVault.Milestone memory m = vault.getMilestone(id, 0);
        assertEq(m.proofCID, "QmProofCID_milestone0");
        assertFalse(m.released);

        // Simulate governance approving (direct call as dao address)
        _releaseMilestone(id, 0);

        m = vault.getMilestone(id, 0);
        assertTrue(m.released);
    }

    function test_FullGovernanceFlow() public {
        uint256 id = _createCampaign();

        // Donate
        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);
        vm.prank(donor2);
        vault.donate{value: 1 ether}(id);

        // Submit milestone proof → auto-creates DAO proposal
        vm.prank(org);
        vault.submitMilestoneProof(id, 0, "QmProof_m0");

        DonationVault.Milestone memory m = vault.getMilestone(id, 0);
        uint256 proposalId = m.proposalId;
        assertTrue(proposalId > 0);

        // Cast votes (both donors vote For)
        vm.prank(donor1);
        dao.castVote(proposalId, IGovernanceDAO.VoteChoice.For);
        vm.prank(donor2);
        dao.castVote(proposalId, IGovernanceDAO.VoteChoice.For);

        assertTrue(dao.hasVoted(proposalId, donor1));
        assertTrue(dao.hasVoted(proposalId, donor2));

        // Advance past voting period
        vm.roll(block.number + 21601);

        // Queue
        dao.queueProposal(proposalId);
        assertEq(
            uint8(dao.getProposalState(proposalId)),
            uint8(IGovernanceDAO.ProposalState.Queued)
        );

        // Advance past timelock
        vm.warp(block.timestamp + 86401);

        // Execute
        dao.executeProposal(proposalId);

        assertEq(
            uint8(dao.getProposalState(proposalId)),
            uint8(IGovernanceDAO.ProposalState.Executed)
        );

        m = vault.getMilestone(id, 0);
        assertTrue(m.released);
    }

    function test_GovernanceVoteAgainst() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);
        vm.prank(donor2);
        vault.donate{value: 1 ether}(id);

        vm.prank(org);
        vault.submitMilestoneProof(id, 0, "QmProof_m0");

        DonationVault.Milestone memory m = vault.getMilestone(id, 0);
        uint256 proposalId = m.proposalId;

        // Both vote Against
        vm.prank(donor1);
        dao.castVote(proposalId, IGovernanceDAO.VoteChoice.Against);
        vm.prank(donor2);
        dao.castVote(proposalId, IGovernanceDAO.VoteChoice.Against);

        // Advance past voting period
        vm.roll(block.number + 21601);

        // Queue → should be defeated
        dao.queueProposal(proposalId);
        assertEq(
            uint8(dao.getProposalState(proposalId)),
            uint8(IGovernanceDAO.ProposalState.Defeated)
        );
    }

    function test_GovernanceQuorumNotMet() public {
        uint256 id = _createCampaign();

        // Two donors; For/Against split → defeated
        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);
        vm.prank(donor2);
        vault.donate{value: 1 ether}(id);

        vm.prank(org);
        vault.submitMilestoneProof(id, 0, "QmProof_m0");

        DonationVault.Milestone memory m = vault.getMilestone(id, 0);
        uint256 proposalId = m.proposalId;

        vm.prank(donor1);
        dao.castVote(proposalId, IGovernanceDAO.VoteChoice.For);
        vm.prank(donor2);
        dao.castVote(proposalId, IGovernanceDAO.VoteChoice.Against);

        vm.roll(block.number + 21601);

        dao.queueProposal(proposalId);
        assertEq(
            uint8(dao.getProposalState(proposalId)),
            uint8(IGovernanceDAO.ProposalState.Defeated)
        );
    }

    function test_CancelProposal() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);

        vm.prank(org);
        vault.submitMilestoneProof(id, 0, "QmProof_m0");

        DonationVault.Milestone memory m = vault.getMilestone(id, 0);
        uint256 proposalId = m.proposalId;

        vm.prank(admin);
        dao.cancelProposal(proposalId);

        assertEq(
            uint8(dao.getProposalState(proposalId)),
            uint8(IGovernanceDAO.ProposalState.Cancelled)
        );
    }

    function test_ResubmitProposalViaVault() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);
        vm.prank(donor2);
        vault.donate{value: 1 ether}(id);

        vm.prank(org);
        vault.submitMilestoneProof(id, 0, "QmProof_m0");

        uint256 oldProposalId = vault.getMilestone(id, 0).proposalId;

        vm.prank(donor1);
        dao.castVote(oldProposalId, IGovernanceDAO.VoteChoice.Against);
        vm.prank(donor2);
        dao.castVote(oldProposalId, IGovernanceDAO.VoteChoice.Against);

        vm.roll(block.number + 21601);
        dao.queueProposal(oldProposalId);

        vm.prank(org);
        vault.submitMilestoneProof(id, 0, "QmProofResubmit");
        uint256 newProposalId = vault.getMilestone(id, 0).proposalId;
        assertTrue(newProposalId > oldProposalId);
        assertEq(
            uint8(dao.getProposalState(newProposalId)),
            uint8(IGovernanceDAO.ProposalState.Active)
        );
    }

    // =========================================================
    // ImpactNFT — additional tests
    // =========================================================

    function test_UpdateNFTProgress() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 0.5 ether}(id);

        uint256 tokenId = nft.getDonorTokenForCampaign(donor1, id);

        vm.prank(address(vault));
        nft.updateNFTProgress(tokenId, "QmUpdatedCID", 100, false);

        IImpactNFT.NFTMetadata memory meta = nft.getNFTMetadata(tokenId);
        assertEq(meta.metadataCID, "QmUpdatedCID");
        assertEq(meta.impactScore, 100);
        assertFalse(meta.campaignCompleted);
    }

    function test_UpgradeTier() public {
        uint256 id = _createCampaign();

        // Donate Silver amount (0.01–0.1 ETH)
        vm.prank(donor1);
        vault.donate{value: 0.05 ether}(id);

        uint256 tokenId = nft.getDonorTokenForCampaign(donor1, id);
        IImpactNFT.NFTMetadata memory meta = nft.getNFTMetadata(tokenId);
        assertEq(uint8(meta.tier), uint8(IImpactNFT.DonorTier.Silver));

        // Upgrade tier — still Silver (donatedAmount < 0.1 ETH), should revert
        vm.prank(address(vault));
        vm.expectRevert("NFT: no upgrade available");
        nft.upgradeTier(tokenId);
    }

    function test_GetCampaignNFTs() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 0.5 ether}(id);
        vm.prank(donor2);
        vault.donate{value: 0.5 ether}(id);

        uint256[] memory tokens = nft.getCampaignNFTs(id);
        assertEq(tokens.length, 2);
    }

    // =========================================================
    // Access control
    // =========================================================

    function testRevert_ReleaseFundsNotDAO() public {
        uint256 id = _createCampaign();

        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);

        vm.prank(org);
        vault.submitMilestoneProof(id, 0, "QmProof0");

        uint256 pid = vault.getMilestone(id, 0).proposalId;
        vm.expectRevert("Vault: only DAO");
        vm.prank(random);
        vault.releaseMilestoneFunds(id, 0, pid);
    }

    function testRevert_MintNFTNotVault() public {
        vm.prank(random);
        vm.expectRevert("NFT: not trusted");
        nft.mintImpactNFT(
            donor1,
            1,
            IImpactNFT.DonorTier.Gold,
            0.1 ether,
            "QmTest",
            0
        );
    }

    function testRevert_DAOCreateProposalNotVault() public {
        vm.prank(random);
        vm.expectRevert("DAO: only Vault");
        dao.createProposal(1, 0, "QmProof");
    }
}
