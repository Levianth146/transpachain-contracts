// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/GovernanceDAO.sol";
import "../src/DonationVault.sol";
import "../src/CharityCore.sol";
import "../src/ImpactNFT.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ─────────────────────────────────────────────
// Mock USDC (6 decimals)
// ─────────────────────────────────────────────
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

// ─────────────────────────────────────────────
// Test suite
// ─────────────────────────────────────────────
contract GovernanceDAOTest is Test {
    event ProposalCreated(uint256 indexed proposalId, uint256 indexed campaignId, uint8 milestoneIndex, string proofCID, uint256 endBlock);
    event VoteCast(uint256 indexed proposalId, address indexed voter, IGovernanceDAO.VoteChoice choice, uint256 weight);
    event ProposalQueued(uint256 indexed proposalId, uint256 executeAfter);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalDefeated(uint256 indexed proposalId);
    event ProposalResubmitted(uint256 indexed newProposalId, uint256 indexed oldProposalId);


    CharityCore core;
    DonationVault vault;
    GovernanceDAO dao;
    ImpactNFT nft;
    MockUSDC usdc;

    address admin = makeAddr("admin");
    address org = makeAddr("org");
    address donor1 = makeAddr("donor1");
    address donor2 = makeAddr("donor2");
    address donor3 = makeAddr("donor3");
    address treasury = makeAddr("treasury");
    address nobody = makeAddr("nobody");

    uint256 constant GOAL = 10 ether;
    uint256 constant DEADLINE_OFFSET = 30 days;
    uint8 constant MILESTONES = 3;
    uint256 constant VOTING_PERIOD = 21600;
    uint256 constant TIMELOCK_DELAY = 86400;

    function setUp() public {
        vm.startPrank(admin);

        // Deploy all contracts
        nft = new ImpactNFT(admin);
        core = new CharityCore(admin);
        usdc = new MockUSDC();
        dao = new GovernanceDAO(admin);
        vault = new DonationVault(
            admin,
            address(core),
            address(dao),
            address(nft),
            address(usdc)
        );
        dao.setDonationVault(address(vault));

        // Wire trusted contracts
        core.setTrustedContracts(address(vault), address(dao));
        nft.setTrustedContracts(address(vault), address(core));

        // Set treasury
        vault.setTreasury(treasury);

        // Verify org
        core.verifyOrg(org);

        vm.stopPrank();

        // Fund actors
        vm.deal(org, 10 ether);
        vm.deal(donor1, 50 ether);
        vm.deal(donor2, 50 ether);
        vm.deal(donor3, 50 ether);
        vm.deal(treasury, 1 ether);
    }

    // ─────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────

    function _createCampaignETH() internal returns (uint256) {
        vm.prank(org);
        return
            core.createCampaign{value: 0.001 ether}(
                "QmTestCID",
                GOAL,
                block.timestamp + DEADLINE_OFFSET,
                MILESTONES,
                ICharityCore.PaymentToken.ETH,
                "education"
            );
    }

    function _donateAndCreateProposal(
        uint256 cid,
        uint256 donationAmount
    ) internal returns (uint256 proposalId) {
        vm.prank(donor1);
        vault.donate{value: donationAmount}(cid);

        vm.prank(org);
        vault.submitMilestoneProof(cid, 0, "QmProof0");

        // Proposal is created inside submitMilestoneProof, get the ID
        proposalId = dao.getActiveProposal(cid);
    }

    function _donateMultipleAndCreateProposal(
        uint256 cid,
        uint256 amount1,
        uint256 amount2,
        uint256 amount3
    ) internal returns (uint256 proposalId) {
        if (amount1 > 0) {
            vm.prank(donor1);
            vault.donate{value: amount1}(cid);
        }
        if (amount2 > 0) {
            vm.prank(donor2);
            vault.donate{value: amount2}(cid);
        }
        if (amount3 > 0) {
            vm.prank(donor3);
            vault.donate{value: amount3}(cid);
        }

        vm.prank(org);
        vault.submitMilestoneProof(cid, 0, "QmProof0");

        proposalId = dao.getActiveProposal(cid);
    }

    function _advancePastVotingPeriod() internal {
        vm.roll(block.number + VOTING_PERIOD + 1);
    }

    function _advancePastTimelock() internal {
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
    }

    // ─────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────

    function test_constructor_setsOwner() public {
        assertEq(dao.owner(), admin);
    }

    function test_constructor_setsConstants() public {
        assertEq(VOTING_PERIOD, 21600);
        assertEq(TIMELOCK_DELAY, 86400);
        assertEq(dao.QUORUM_BPS(), 5100);
    }

    function test_setDonationVault_setsCorrectly() public {
        assertEq(address(dao.donationVault()), address(vault));
    }

    function test_setDonationVault_revertsIfNotOwner() public {
        vm.prank(nobody);
        vm.expectRevert();
        dao.setDonationVault(nobody);
    }

    // ─────────────────────────────────────────────
    // pause / unpause
    // ─────────────────────────────────────────────

    function test_pause_revertsIfNotOwner() public {
        vm.prank(nobody);
        vm.expectRevert();
        dao.pause();
    }

    function test_unpause_revertsIfNotOwner() public {
        vm.prank(admin);
        dao.pause();

        vm.prank(nobody);
        vm.expectRevert();
        dao.unpause();
    }

    function test_pause_blocksCreateProposal() public {
        uint256 cid = _createCampaignETH();

        vm.prank(donor1);
        vault.donate{value: 1 ether}(cid);

        vm.prank(admin);
        dao.pause();

        vm.prank(org);
        vm.expectRevert();
        vault.submitMilestoneProof(cid, 0, "QmProof0");
    }

    // ─────────────────────────────────────────────
    // createProposal
    // ─────────────────────────────────────────────

    function test_createProposal_setsCorrectState() public {
        uint256 cid = _createCampaignETH();
        uint256 donationAmount = 5 ether;

        vm.prank(donor1);
        vault.donate{value: donationAmount}(cid);

        vm.prank(org);
        vault.submitMilestoneProof(cid, 0, "QmProof0");

        uint256 pid = dao.getActiveProposal(cid);
        IGovernanceDAO.Proposal memory p = dao.getProposal(pid);

        assertEq(p.id, 1);
        assertEq(p.campaignId, cid);
        assertEq(p.milestoneIndex, 0);
        assertEq(p.proofCID, "QmProof0");
        assertEq(p.startBlock, block.number);
        assertEq(p.endBlock, block.number + VOTING_PERIOD);
        assertEq(p.forVotes, 0);
        assertEq(p.againstVotes, 0);
        assertEq(p.abstainVotes, 0);
        assertEq(p.totalVotingPower, vault.getCampaignEscrowBalance(cid));
        assertEq(uint8(p.state), uint8(IGovernanceDAO.ProposalState.Active));
        assertEq(p.snapshotBlock, block.number);
    }

    function test_createProposal_emitsProposalCreated() public {
        uint256 cid = _createCampaignETH();

        vm.prank(donor1);
        vault.donate{value: 1 ether}(cid);

        vm.prank(org);
        vm.expectEmit(true, true, false, true);
        emit ProposalCreated(
            1,
            cid,
            0,
            "QmProof0",
            block.number + VOTING_PERIOD
        );
        vault.submitMilestoneProof(cid, 0, "QmProof0");
    }

    function test_createProposal_incrementsProposalId() public {
        uint256 cid = _createCampaignETH();

        vm.prank(donor1);
        vault.donate{value: 5 ether}(cid);

        vm.prank(org);
        vault.submitMilestoneProof(cid, 0, "QmProof0");

        // Release milestone 0 via full vote flow
        uint256 pid1 = dao.getActiveProposal(cid);
        vm.prank(donor1);
        dao.castVote(pid1, IGovernanceDAO.VoteChoice.For);
        _advancePastVotingPeriod();
        dao.queueProposal(pid1);
        _advancePastTimelock();
        dao.executeProposal(pid1);

        // Submit milestone 1
        vm.prank(org);
        vault.submitMilestoneProof(cid, 1, "QmProof1");

        uint256 pid2 = dao.getActiveProposal(cid);
        assertEq(pid2, pid1 + 1);
    }

    function test_createProposal_tracksCampaignProposals() public {
        uint256 cid = _createCampaignETH();

        vm.prank(donor1);
        vault.donate{value: 5 ether}(cid);

        vm.prank(org);
        vault.submitMilestoneProof(cid, 0, "QmProof0");

        uint256[] memory proposals = dao.getCampaignProposals(cid);
        assertEq(proposals.length, 1);
        assertEq(proposals[0], 1);
    }

    // ─────────────────────────────────────────────
    // castVote
    // ─────────────────────────────────────────────

    function test_castVote_recordsForVote() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        IGovernanceDAO.Proposal memory p = dao.getProposal(pid);
        uint256 expectedWeight = vault.getDonorAmount(cid, donor1);
        assertEq(p.forVotes, expectedWeight);
    }

    function test_castVote_recordsAgainstVote() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.Against);

        IGovernanceDAO.Proposal memory p = dao.getProposal(pid);
        uint256 expectedWeight = vault.getDonorAmount(cid, donor1);
        assertEq(p.againstVotes, expectedWeight);
    }

    function test_castVote_recordsAbstainVote() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.Abstain);

        IGovernanceDAO.Proposal memory p = dao.getProposal(pid);
        uint256 expectedWeight = vault.getDonorAmount(cid, donor1);
        assertEq(p.abstainVotes, expectedWeight);
    }

    function test_castVote_emitsVoteCast() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);
        uint256 weight = vault.getDonorAmount(cid, donor1);

        vm.prank(donor1);
        vm.expectEmit(true, true, false, true);
        emit VoteCast(
            pid,
            donor1,
            IGovernanceDAO.VoteChoice.For,
            weight
        );
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
    }

    function test_castVote_setsHasVoted() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        assertFalse(dao.hasVoted(pid, donor1));

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        assertTrue(dao.hasVoted(pid, donor1));
    }

    function test_castVote_multipleDonors() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateMultipleAndCreateProposal(
            cid,
            2 ether,
            3 ether,
            0
        );

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        vm.prank(donor2);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.Against);

        IGovernanceDAO.Proposal memory p = dao.getProposal(pid);
        assertEq(p.forVotes, vault.getDonorAmount(cid, donor1));
        assertEq(p.againstVotes, vault.getDonorAmount(cid, donor2));
    }

    // ─── castVote revert cases ───

    function test_castVote_revertsIfProposalNotFound() public {
        vm.prank(donor1);
        vm.expectRevert("DAO: not found");
        dao.castVote(999, IGovernanceDAO.VoteChoice.For);
    }

    function test_castVote_revertsIfNotActive() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        // Queue and execute to make it Executed
        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
        _advancePastVotingPeriod();
        dao.queueProposal(pid);
        _advancePastTimelock();
        dao.executeProposal(pid);

        vm.prank(donor1);
        vm.expectRevert("DAO: not active");
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
    }

    function test_castVote_revertsIfVotingEnded() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        _advancePastVotingPeriod();

        vm.prank(donor1);
        vm.expectRevert("DAO: voting ended");
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
    }

    function test_castVote_revertsIfAlreadyVoted() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        vm.prank(donor1);
        vm.expectRevert("DAO: already voted");
        dao.castVote(pid, IGovernanceDAO.VoteChoice.Against);
    }

    function test_castVote_revertsIfNoVotingPower() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        vm.prank(nobody);
        vm.expectRevert("DAO: no voting power");
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
    }

    // ─────────────────────────────────────────────
    // queueProposal
    // ─────────────────────────────────────────────

    function test_queueProposal_quorumMet_queuesSuccessfully() public {
        uint256 cid = _createCampaignETH();
        // donor1 donates all → 100% voting power, quorum (51%) met
        uint256 pid = _donateAndCreateProposal(cid, 5 ether);

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();

        dao.queueProposal(pid);

        IGovernanceDAO.Proposal memory p = dao.getProposal(pid);
        assertEq(uint8(p.state), uint8(IGovernanceDAO.ProposalState.Queued));
        assertEq(p.executeAfter, block.timestamp + TIMELOCK_DELAY);
    }

    function test_queueProposal_emitsProposalQueued() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 5 ether);

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();

        vm.expectEmit(true, false, false, true);
        emit ProposalQueued(
            pid,
            block.timestamp + TIMELOCK_DELAY
        );
        dao.queueProposal(pid);
    }

    function test_queueProposal_quorumNotMet_defeats() public {
        uint256 cid = _createCampaignETH();
        // 3 donors, only 1 votes For (donor1 has ~33% < 51%)
        uint256 pid = _donateMultipleAndCreateProposal(
            cid,
            2 ether,
            2 ether,
            2 ether
        );

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();

        dao.queueProposal(pid);

        IGovernanceDAO.Proposal memory p = dao.getProposal(pid);
        assertEq(uint8(p.state), uint8(IGovernanceDAO.ProposalState.Defeated));
    }

    function test_queueProposal_againstWins_defeats() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateMultipleAndCreateProposal(
            cid,
            2 ether,
            2 ether,
            2 ether
        );

        // All vote, but Against wins
        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
        vm.prank(donor2);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.Against);
        vm.prank(donor3);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.Against);

        _advancePastVotingPeriod();

        dao.queueProposal(pid);

        IGovernanceDAO.Proposal memory p = dao.getProposal(pid);
        assertEq(uint8(p.state), uint8(IGovernanceDAO.ProposalState.Defeated));
    }

    function test_queueProposal_emitsProposalDefeated_onDefeat() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateMultipleAndCreateProposal(
            cid,
            2 ether,
            2 ether,
            2 ether
        );

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();

        vm.expectEmit(true, false, false, true);
        emit ProposalDefeated(pid);
        dao.queueProposal(pid);
    }

    // ─── queueProposal revert cases ───

    function test_queueProposal_revertsIfProposalNotFound() public {
        _advancePastVotingPeriod();
        vm.expectRevert("DAO: not found");
        dao.queueProposal(999);
    }

    function test_queueProposal_revertsIfNotActive() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 5 ether);

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
        _advancePastVotingPeriod();
        dao.queueProposal(pid);

        vm.expectRevert("DAO: not active");
        dao.queueProposal(pid);
    }

    function test_queueProposal_revertsIfVotingOngoing() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        // Don't advance past voting period
        vm.expectRevert("DAO: voting ongoing");
        dao.queueProposal(pid);
    }

    // ─────────────────────────────────────────────
    // executeProposal
    // ─────────────────────────────────────────────

    function test_executeProposal_executesSuccessfully() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 5 ether);

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();
        dao.queueProposal(pid);
        _advancePastTimelock();

        uint256 orgBalBefore = org.balance;
        dao.executeProposal(pid);

        IGovernanceDAO.Proposal memory p = dao.getProposal(pid);
        assertEq(uint8(p.state), uint8(IGovernanceDAO.ProposalState.Executed));
        assertTrue(org.balance > orgBalBefore);
    }

    function test_executeProposal_emitsProposalExecuted() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 5 ether);

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();
        dao.queueProposal(pid);
        _advancePastTimelock();

        vm.expectEmit(true, false, false, true);
        emit ProposalExecuted(pid);
        dao.executeProposal(pid);
    }

    function test_executeProposal_releasesFundsToOrg() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 5 ether);

        uint256 releaseAmount = vault.getMilestone(cid, 0).releaseAmount;

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();
        dao.queueProposal(pid);
        _advancePastTimelock();

        uint256 orgBalBefore = org.balance;
        dao.executeProposal(pid);

        assertEq(org.balance - orgBalBefore, releaseAmount);
    }

    // ─── executeProposal revert cases ───

    function test_executeProposal_revertsIfProposalNotFound() public {
        vm.expectRevert("DAO: not found");
        dao.executeProposal(999);
    }

    function test_executeProposal_revertsIfNotQueued() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 5 ether);

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
        _advancePastVotingPeriod();

        // Try to execute before queueing
        vm.expectRevert("DAO: not queued");
        dao.executeProposal(pid);
    }

    function test_executeProposal_revertsIfTimelockActive() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 5 ether);

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();
        dao.queueProposal(pid);

        // Don't advance past timelock
        vm.expectRevert("DAO: timelock active");
        dao.executeProposal(pid);
    }

    // ─────────────────────────────────────────────
    // cancelProposal
    // ─────────────────────────────────────────────

    function test_cancelProposal_cancelsSuccessfully() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        vm.prank(admin);
        dao.cancelProposal(pid);

        IGovernanceDAO.Proposal memory p = dao.getProposal(pid);
        assertEq(uint8(p.state), uint8(IGovernanceDAO.ProposalState.Cancelled));
    }

    function test_cancelProposal_emitsProposalDefeated() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit ProposalDefeated(pid);
        dao.cancelProposal(pid);
    }

    function test_cancelProposal_revertsIfNotOwner() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        vm.prank(nobody);
        vm.expectRevert();
        dao.cancelProposal(pid);
    }

    function test_cancelProposal_revertsIfNotFound() public {
        vm.prank(admin);
        vm.expectRevert("DAO: not found");
        dao.cancelProposal(999);
    }

    // ─────────────────────────────────────────────
    // resubmitProposal
    // ─────────────────────────────────────────────

    function test_resubmitProposal_createsNewProposal() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateMultipleAndCreateProposal(
            cid,
            2 ether,
            2 ether,
            2 ether
        );

        // Only donor1 votes For → quorum not met → Defeated
        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();
        dao.queueProposal(pid);

        // Verify defeated
        assertEq(
            uint8(dao.getProposalState(pid)),
            uint8(IGovernanceDAO.ProposalState.Defeated)
        );

        // Resubmit
        uint256 newPid = dao.resubmitProposal(pid);

        IGovernanceDAO.Proposal memory newP = dao.getProposal(newPid);
        assertEq(newPid, pid + 1);
        assertEq(newP.campaignId, cid);
        assertEq(newP.milestoneIndex, 0);
        assertEq(newP.proofCID, "QmProof0");
        assertEq(newP.forVotes, 0);
        assertEq(newP.againstVotes, 0);
        assertEq(newP.abstainVotes, 0);
        assertEq(uint8(newP.state), uint8(IGovernanceDAO.ProposalState.Active));
        assertEq(newP.startBlock, block.number);
        assertEq(newP.endBlock, block.number + VOTING_PERIOD);
    }

    function test_resubmitProposal_emitsProposalResubmitted() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateMultipleAndCreateProposal(
            cid,
            2 ether,
            2 ether,
            2 ether
        );

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();
        dao.queueProposal(pid);

        vm.expectEmit(true, true, false, true);
        emit ProposalResubmitted(pid + 1, pid);
        dao.resubmitProposal(pid);
    }

    function test_resubmitProposal_emitsProposalCreated() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateMultipleAndCreateProposal(
            cid,
            2 ether,
            2 ether,
            2 ether
        );

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();
        dao.queueProposal(pid);

        vm.expectEmit(true, true, false, true);
        emit ProposalCreated(
            pid + 1,
            cid,
            0,
            "QmProof0",
            block.number + VOTING_PERIOD
        );
        dao.resubmitProposal(pid);
    }

    function test_resubmitProposal_tracksInCampaignProposals() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateMultipleAndCreateProposal(
            cid,
            2 ether,
            2 ether,
            2 ether
        );

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();
        dao.queueProposal(pid);

        dao.resubmitProposal(pid);

        uint256[] memory proposals = dao.getCampaignProposals(cid);
        assertEq(proposals.length, 2);
        assertEq(proposals[0], pid);
        assertEq(proposals[1], pid + 1);
    }

    function test_resubmitProposal_newProposalCanBeVotedAndExecuted() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateMultipleAndCreateProposal(
            cid,
            2 ether,
            2 ether,
            2 ether
        );

        // Defeat the first proposal
        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
        _advancePastVotingPeriod();
        dao.queueProposal(pid);

        // Resubmit
        uint256 newPid = dao.resubmitProposal(pid);

        // All donors vote For on new proposal
        vm.prank(donor1);
        dao.castVote(newPid, IGovernanceDAO.VoteChoice.For);
        vm.prank(donor2);
        dao.castVote(newPid, IGovernanceDAO.VoteChoice.For);
        vm.prank(donor3);
        dao.castVote(newPid, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();
        dao.queueProposal(newPid);
        _advancePastTimelock();

        dao.executeProposal(newPid);

        assertEq(
            uint8(dao.getProposalState(newPid)),
            uint8(IGovernanceDAO.ProposalState.Executed)
        );
    }

    // ─── resubmitProposal revert cases ───

    function test_resubmitProposal_revertsIfNotFound() public {
        vm.expectRevert("DAO: not found");
        dao.resubmitProposal(999);
    }

    function test_resubmitProposal_revertsIfNotDefeated() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        // Proposal is Active, not Defeated
        vm.expectRevert("DAO: not defeated");
        dao.resubmitProposal(pid);
    }

    // ─────────────────────────────────────────────
    // View functions
    // ─────────────────────────────────────────────

    function test_getProposal_returnsCorrectData() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        IGovernanceDAO.Proposal memory p = dao.getProposal(pid);
        assertEq(p.id, pid);
        assertEq(p.campaignId, cid);
        assertEq(p.milestoneIndex, 0);
        assertEq(p.proofCID, "QmProof0");
    }

    function test_getProposal_revertsIfNotFound() public {
        vm.expectRevert("DAO: not found");
        dao.getProposal(999);
    }

    function test_getProposalState_returnsActive() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        assertEq(
            uint8(dao.getProposalState(pid)),
            uint8(IGovernanceDAO.ProposalState.Active)
        );
    }

    function test_getProposalState_revertsIfNotFound() public {
        vm.expectRevert("DAO: not found");
        dao.getProposalState(999);
    }

    function test_hasVoted_returnsFalseInitially() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        assertFalse(dao.hasVoted(pid, donor1));
    }

    function test_hasVoted_returnsTrueAfterVoting() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        assertTrue(dao.hasVoted(pid, donor1));
    }

    function test_getVotingPower_returnsDonorAmount() public {
        uint256 cid = _createCampaignETH();
        vm.prank(donor1);
        vault.donate{value: 3 ether}(cid);

        uint256 expectedPower = vault.getDonorAmount(cid, donor1);
        assertEq(dao.getVotingPower(cid, donor1), expectedPower);
    }

    function test_getVotingPower_returnsZeroIfNoDonation() public {
        uint256 cid = _createCampaignETH();
        assertEq(dao.getVotingPower(cid, donor1), 0);
    }

    function test_getActiveProposal_returnsZeroIfNone() public {
        uint256 cid = _createCampaignETH();
        assertEq(dao.getActiveProposal(cid), 0);
    }

    function test_getActiveProposal_returnsLatestActive() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 5 ether);

        assertEq(dao.getActiveProposal(cid), pid);
    }

    function test_getActiveProposal_skipsNonActive() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateMultipleAndCreateProposal(
            cid,
            2 ether,
            2 ether,
            2 ether
        );

        // Defeat it
        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
        _advancePastVotingPeriod();
        dao.queueProposal(pid);

        // No active proposal
        assertEq(dao.getActiveProposal(cid), 0);
    }

    // ─────────────────────────────────────────────
    // Full lifecycle
    // ─────────────────────────────────────────────

    function test_fullLifecycle_proposalToExecution() public {
        uint256 cid = _createCampaignETH();

        // 1. Donate
        vm.prank(donor1);
        vault.donate{value: 5 ether}(cid);

        // 2. Submit milestone proof (creates proposal)
        vm.prank(org);
        vault.submitMilestoneProof(cid, 0, "QmProof0");
        uint256 pid = dao.getActiveProposal(cid);

        // 3. Cast vote
        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
        assertTrue(dao.hasVoted(pid, donor1));

        // 4. Advance past voting period
        _advancePastVotingPeriod();

        // 5. Queue proposal
        dao.queueProposal(pid);
        assertEq(
            uint8(dao.getProposalState(pid)),
            uint8(IGovernanceDAO.ProposalState.Queued)
        );

        // 6. Advance past timelock
        _advancePastTimelock();

        // 7. Execute proposal
        uint256 orgBalBefore = org.balance;
        dao.executeProposal(pid);

        assertEq(
            uint8(dao.getProposalState(pid)),
            uint8(IGovernanceDAO.ProposalState.Executed)
        );
        assertTrue(org.balance > orgBalBefore);
        assertTrue(vault.getMilestone(cid, 0).released);
    }

    function test_fullLifecycle_defeatAndResubmit() public {
        uint256 cid = _createCampaignETH();

        // Donate from 3 donors
        vm.prank(donor1);
        vault.donate{value: 2 ether}(cid);
        vm.prank(donor2);
        vault.donate{value: 2 ether}(cid);
        vm.prank(donor3);
        vault.donate{value: 2 ether}(cid);

        // Submit milestone
        vm.prank(org);
        vault.submitMilestoneProof(cid, 0, "QmProof0");
        uint256 pid1 = dao.getActiveProposal(cid);

        // Only 1/3 votes For → quorum not met
        vm.prank(donor1);
        dao.castVote(pid1, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();
        dao.queueProposal(pid1);
        assertEq(
            uint8(dao.getProposalState(pid1)),
            uint8(IGovernanceDAO.ProposalState.Defeated)
        );

        // Resubmit
        uint256 pid2 = dao.resubmitProposal(pid1);
        assertEq(
            uint8(dao.getProposalState(pid2)),
            uint8(IGovernanceDAO.ProposalState.Active)
        );

        // All vote For this time
        vm.prank(donor1);
        dao.castVote(pid2, IGovernanceDAO.VoteChoice.For);
        vm.prank(donor2);
        dao.castVote(pid2, IGovernanceDAO.VoteChoice.For);
        vm.prank(donor3);
        dao.castVote(pid2, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();
        dao.queueProposal(pid2);
        _advancePastTimelock();
        dao.executeProposal(pid2);

        assertEq(
            uint8(dao.getProposalState(pid2)),
            uint8(IGovernanceDAO.ProposalState.Executed)
        );
    }

    // ─────────────────────────────────────────────
    // Edge cases
    // ─────────────────────────────────────────────

    function test_castVote_exactEndBlock_stillAllowed() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        // Roll to exact endBlock (should still be allowed: block.number <= endBlock)
        IGovernanceDAO.Proposal memory p = dao.getProposal(pid);
        vm.roll(p.endBlock);

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        assertTrue(dao.hasVoted(pid, donor1));
    }

    function test_castVote_onePastEndBlock_reverts() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        IGovernanceDAO.Proposal memory p = dao.getProposal(pid);
        vm.roll(p.endBlock + 1);

        vm.prank(donor1);
        vm.expectRevert("DAO: voting ended");
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
    }

    function test_queueProposal_exactQuorumThreshold_queues() public {
        uint256 cid = _createCampaignETH();
        // donor1 donates all → 100% voting power → quorum met
        uint256 pid = _donateAndCreateProposal(cid, 5 ether);

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();
        dao.queueProposal(pid);

        assertEq(
            uint8(dao.getProposalState(pid)),
            uint8(IGovernanceDAO.ProposalState.Queued)
        );
    }

    function test_queueProposal_justBelowQuorum_defeats() public {
        uint256 cid = _createCampaignETH();
        // 3 equal donors, only 1 votes → ~33% < 51%
        uint256 pid = _donateMultipleAndCreateProposal(
            cid,
            2 ether,
            2 ether,
            2 ether
        );

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();
        dao.queueProposal(pid);

        assertEq(
            uint8(dao.getProposalState(pid)),
            uint8(IGovernanceDAO.ProposalState.Defeated)
        );
    }

    function test_executeProposal_exactTimelock_executes() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 5 ether);

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();
        dao.queueProposal(pid);

        // Warp to exact executeAfter timestamp
        IGovernanceDAO.Proposal memory p = dao.getProposal(pid);
        vm.warp(p.executeAfter);

        dao.executeProposal(pid);

        assertEq(
            uint8(dao.getProposalState(pid)),
            uint8(IGovernanceDAO.ProposalState.Executed)
        );
    }

    function test_cancelProposal_activeProposal() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 1 ether);

        vm.prank(admin);
        dao.cancelProposal(pid);

        assertEq(
            uint8(dao.getProposalState(pid)),
            uint8(IGovernanceDAO.ProposalState.Cancelled)
        );
    }

    function test_cancelProposal_queuedProposal() public {
        uint256 cid = _createCampaignETH();
        uint256 pid = _donateAndCreateProposal(cid, 5 ether);

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);

        _advancePastVotingPeriod();
        dao.queueProposal(pid);

        vm.prank(admin);
        dao.cancelProposal(pid);

        assertEq(
            uint8(dao.getProposalState(pid)),
            uint8(IGovernanceDAO.ProposalState.Cancelled)
        );
    }
}
