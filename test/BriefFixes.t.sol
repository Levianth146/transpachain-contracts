// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CharityCore.sol";
import "../src/DonationVault.sol";
import "../src/GovernanceDAO.sol";
import "../src/ImpactNFT.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDCBrief is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @notice Mandatory scenarios from technical brief Section 6
contract BriefFixesTest is Test {
    CharityCore core;
    DonationVault vault;
    GovernanceDAO dao;
    ImpactNFT nft;
    MockUSDCBrief usdc;

    address admin = address(0xA11CE);
    address org = address(0x01AC);
    address donor1 = address(0xD001);
    address donor2 = address(0xD002);
    address donor3 = address(0xD003);

    uint256 constant GOAL = 2 ether;
    uint256 constant DEADLINE_OFFSET = 30 days;
    uint8 constant MILESTONES = 3;

    function setUp() public {
        vm.startPrank(admin);
        nft = new ImpactNFT(admin);
        core = new CharityCore(admin);
        dao = new GovernanceDAO(admin);
        usdc = new MockUSDCBrief();
        vault = new DonationVault(admin, address(core), address(dao), address(nft), address(usdc));
        dao.setDonationVault(address(vault));
        core.setTrustedContracts(address(vault), address(dao));
        nft.setTrustedContracts(address(vault), address(core));
        core.verifyOrg(org);
        vm.stopPrank();

        vm.deal(org, 10 ether);
        vm.deal(donor1, 10 ether);
        vm.deal(donor2, 10 ether);
        vm.deal(donor3, 10 ether);
    }

    function _grossForNet(uint256 netGoal) internal pure returns (uint256) {
        return (netGoal * 10_000 + 9899) / 9900;
    }

    function _createCampaign() internal returns (uint256 id) {
        vm.prank(org);
        id = core.createCampaign{value: 0.001 ether}(
            "QmTest",
            GOAL,
            block.timestamp + DEADLINE_OFFSET,
            MILESTONES,
            ICharityCore.PaymentToken.ETH,
            "education"
        );
    }

    function _fundToGoal(uint256 id) internal {
        vm.prank(donor1);
        vault.donate{value: _grossForNet(GOAL)}(id);
    }

    function _voteQueueExecute(uint256 id, uint256 pid, address[] memory voters) internal {
        for (uint256 i = 0; i < voters.length; i++) {
            vm.prank(voters[i]);
            dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
        }
        vm.roll(block.number + 21601);
        dao.queueProposal(pid);
        vm.warp(block.timestamp + 86401);
        dao.executeProposal(pid);
    }

    function test_1_goalReachedMilestonesIncomplete_cannotFinalize() public {
        uint256 id = _createCampaign();
        _fundToGoal(id);

        (bool eligible, bool goalReached,) = core.canFinalize(id);
        assertTrue(goalReached);
        assertFalse(eligible);

        vm.expectRevert("CharityCore: cannot finalize");
        core.finalizeCampaign(id);
    }

    function test_2_expiredWithoutGoal_failedRefundWorks() public {
        uint256 id = _createCampaign();
        vm.prank(donor1);
        vault.donate{value: 0.5 ether}(id);

        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        core.finalizeCampaign(id);
        assertEq(uint8(core.getCampaign(id).status), uint8(ICharityCore.CampaignStatus.Failed));

        uint256 net = 0.5 ether - ((0.5 ether * 100) / 10_000);
        uint256 balBefore = donor1.balance;
        vm.prank(donor1);
        vault.claimRefund(id);
        assertEq(donor1.balance - balBefore, net);
    }

    function test_3_wrongMilestoneOrder_reverts() public {
        uint256 id = _createCampaign();
        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);

        vm.prank(org);
        vm.expectRevert("Vault: wrong order");
        vault.submitMilestoneProof(id, 1, "QmProof1");
    }

    function test_4_wrongProposalIdRelease_reverts() public {
        uint256 id = _createCampaign();
        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);

        vm.prank(org);
        vault.submitMilestoneProof(id, 0, "QmProof0");

        vm.prank(address(dao));
        vm.expectRevert("Vault: wrong proposal");
        vault.releaseMilestoneFunds(id, 0, 999);
    }

    function test_5_daoQuorum_oneVoteNotEnough() public {
        uint256 id = _createCampaign();
        vm.prank(donor1);
        vault.donate{value: 0.5 ether}(id);
        vm.prank(donor2);
        vault.donate{value: 0.5 ether}(id);
        vm.prank(donor3);
        vault.donate{value: 0.5 ether}(id);

        vm.prank(org);
        vault.submitMilestoneProof(id, 0, "QmProof0");
        uint256 pid = vault.getMilestone(id, 0).proposalId;

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        vm.roll(block.number + 21601);
        dao.queueProposal(pid);

        assertEq(
            uint8(dao.getProposalState(pid)),
            uint8(IGovernanceDAO.ProposalState.Defeated)
        );
    }

    function test_6_donateDuringActiveProposal_reverts() public {
        uint256 id = _createCampaign();
        vm.prank(donor1);
        vault.donate{value: 1 ether}(id);

        vm.prank(org);
        vault.submitMilestoneProof(id, 0, "QmProof0");

        vm.prank(donor2);
        vm.expectRevert("Vault: proposal active");
        vault.donate{value: 0.5 ether}(id);
    }

    function test_7_refundAfterPartialRelease_proportionalOrderIndependent() public {
        uint256 id = _createCampaign();
        vm.prank(donor1);
        vault.donate{value: 0.9 ether}(id);
        vm.prank(donor2);
        vault.donate{value: 0.9 ether}(id);

        vm.prank(org);
        vault.submitMilestoneProof(id, 0, "QmProof0");
        uint256 pid = vault.getMilestone(id, 0).proposalId;
        address[] memory voters = new address[](2);
        voters[0] = donor1;
        voters[1] = donor2;
        _voteQueueExecute(id, pid, voters);

        vm.prank(admin);
        core.adminCancelCampaign(id);

        uint256 refund2 = vault.getRefundableAmount(id, donor2);
        uint256 refund1 = vault.getRefundableAmount(id, donor1);

        uint256 bal2Before = donor2.balance;
        vm.prank(donor2);
        vault.claimRefund(id);
        assertEq(donor2.balance - bal2Before, refund2);

        uint256 bal1Before = donor1.balance;
        vm.prank(donor1);
        vault.claimRefund(id);
        assertEq(donor1.balance - bal1Before, refund1);

        assertEq(vault.getCampaignEscrowBalance(id), 0);
    }

    function test_8_usdcNftTiers() public {
        vm.prank(org);
        uint256 id = core.createCampaign{value: 0.001 ether}(
            "QmUSDC",
            1000e6,
            block.timestamp + DEADLINE_OFFSET,
            MILESTONES,
            ICharityCore.PaymentToken.USDC,
            "health"
        );

        usdc.mint(donor1, 200e6);
        vm.startPrank(donor1);
        usdc.approve(address(vault), 200e6);
        vault.donateUSDC(id, 10e6);
        vm.stopPrank();

        uint256 silverToken = nft.getDonorTokenForCampaign(donor1, id);
        assertEq(uint8(nft.getNFTMetadata(silverToken).tier), uint8(IImpactNFT.DonorTier.Silver));

        usdc.mint(donor2, 200e6);
        vm.startPrank(donor2);
        usdc.approve(address(vault), 200e6);
        vault.donateUSDC(id, 100e6);
        vm.stopPrank();

        uint256 goldToken = nft.getDonorTokenForCampaign(donor2, id);
        assertEq(uint8(nft.getNFTMetadata(goldToken).tier), uint8(IImpactNFT.DonorTier.Gold));
    }

    function test_9_partialRelease_orgCannotCancel_adminCancelRefunds() public {
        uint256 id = _createCampaign();
        vm.prank(donor1);
        vault.donate{value: 3 ether}(id);

        vm.prank(org);
        vault.submitMilestoneProof(id, 0, "QmProof0");
        uint256 pid = vault.getMilestone(id, 0).proposalId;
        address[] memory voters = new address[](1);
        voters[0] = donor1;
        _voteQueueExecute(id, pid, voters);

        vm.prank(org);
        vm.expectRevert("CharityCore: milestones released");
        core.cancelCampaign(id);

        vm.prank(admin);
        core.adminCancelCampaign(id);
        assertEq(uint8(core.getCampaign(id).status), uint8(ICharityCore.CampaignStatus.Cancelled));

        uint256 refundable = vault.getRefundableAmount(id, donor1);
        assertGt(refundable, 0);
        uint256 balBefore = donor1.balance;
        vm.prank(donor1);
        vault.claimRefund(id);
        assertEq(donor1.balance - balBefore, refundable);
    }
}
