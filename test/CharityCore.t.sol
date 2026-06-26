// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CharityCore.sol";
import "../src/DonationVault.sol";
import "../src/GovernanceDAO.sol";
import "../src/ImpactNFT.sol";
import "../src/interfaces/ICharityCore.sol";

contract CharityCoreTest is Test {
    CharityCore public core;
    DonationVault public vault;
    GovernanceDAO public dao;
    ImpactNFT public nft;

    address public admin = makeAddr("admin");
    address public org = makeAddr("org");
    address public donor = makeAddr("donor");
    address public donor2 = makeAddr("donor2");
    address public nobody = makeAddr("nobody");

    uint256 constant GOAL = 2 ether;
    uint256 constant DEADLINE_OFFSET = 30 days;

    /// @dev Gross ETH needed so net (after 1% fee) reaches `netGoal`.
    function _grossForNet(uint256 netGoal) internal pure returns (uint256) {
        return (netGoal * 10_000 + 9899) / 9900;
    }

    function setUp() public {
        vm.startPrank(admin);
        nft = new ImpactNFT(admin);
        core = new CharityCore(admin);
        dao = new GovernanceDAO(admin);
        vault = new DonationVault(
            admin,
            address(core),
            address(dao),
            address(nft),
            address(0xdead)
        );
        dao.setDonationVault(address(vault));
        core.setTrustedContracts(address(vault), address(dao));
        nft.setTrustedContracts(address(vault), address(core));
        core.verifyOrg(org);
        vm.stopPrank();

        vm.deal(org, 10 ether);
        vm.deal(donor, 10 ether);
        vm.deal(donor2, 10 ether);
    }

    function _createCampaign() internal returns (uint256 id) {
        vm.prank(org);
        id = core.createCampaign{value: 0.001 ether}(
            "QmTestCID123",
            GOAL,
            block.timestamp + DEADLINE_OFFSET,
            3,
            ICharityCore.PaymentToken.ETH,
            "Education"
        );
    }

    // ─── createCampaign ───

    function test_createCampaign_storesData() public {
        uint256 deadline = block.timestamp + DEADLINE_OFFSET;
        vm.prank(org);
        uint256 id = core.createCampaign{value: 0.001 ether}(
            "QmTestCID123",
            GOAL,
            deadline,
            3,
            ICharityCore.PaymentToken.ETH,
            "Education"
        );

        assertEq(id, 1, "first campaign id should be 1");

        ICharityCore.Campaign memory c = core.getCampaign(id);
        assertEq(c.orgAddress, org, "org mismatch");
        assertEq(c.goalAmount, GOAL, "goal mismatch");
        assertEq(c.deadline, deadline, "deadline mismatch");
        assertEq(c.totalMilestones, 3, "milestones mismatch");
        assertEq(c.raisedAmount, 0, "raised should be 0");
        assertEq(
            uint(c.status),
            uint(ICharityCore.CampaignStatus.Active),
            "status should be Active"
        );
        assertEq(c.metadataCID, "QmTestCID123", "CID mismatch");
    }

    function test_createCampaign_incrementsCounter() public {
        uint256 deadline = block.timestamp + DEADLINE_OFFSET;
        vm.startPrank(org);
        core.createCampaign{value: 0.001 ether}(
            "Qm1",
            GOAL,
            deadline,
            2,
            ICharityCore.PaymentToken.ETH,
            "Education"
        );
        core.createCampaign{value: 0.001 ether}(
            "Qm2",
            GOAL,
            deadline,
            2,
            ICharityCore.PaymentToken.ETH,
            "Health"
        );
        vm.stopPrank();

        assertEq(core.totalCampaigns(), 2);
    }

    function test_createCampaign_tracksOrgCampaigns() public {
        uint256 deadline = block.timestamp + DEADLINE_OFFSET;
        vm.startPrank(org);
        core.createCampaign{value: 0.001 ether}(
            "Qm1",
            GOAL,
            deadline,
            2,
            ICharityCore.PaymentToken.ETH,
            "Education"
        );
        core.createCampaign{value: 0.001 ether}(
            "Qm2",
            GOAL,
            deadline,
            2,
            ICharityCore.PaymentToken.ETH,
            "Health"
        );
        vm.stopPrank();

        uint256[] memory ids = core.getCampaignsByOrg(org);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
    }

    function test_createCampaign_revertsIfNotVerified() public {
        vm.prank(nobody);
        vm.expectRevert();
        core.createCampaign{value: 0.001 ether}(
            "Qm1",
            GOAL,
            block.timestamp + 1 days,
            2,
            ICharityCore.PaymentToken.ETH,
            "Education"
        );
    }

    function test_createCampaign_revertsIfNoDeposit() public {
        vm.prank(org);
        vm.expectRevert("CharityCore: deposit required");
        core.createCampaign(
            "Qm1",
            GOAL,
            block.timestamp + 1 days,
            2,
            ICharityCore.PaymentToken.ETH,
            "Education"
        );
    }

    function test_createCampaign_revertsIfGoalZero() public {
        vm.prank(org);
        vm.expectRevert("CharityCore: goal=0");
        core.createCampaign{value: 0.001 ether}(
            "Qm1",
            0,
            block.timestamp + 1 days,
            2,
            ICharityCore.PaymentToken.ETH,
            "Education"
        );
    }

    function test_createCampaign_revertsIfDeadlinePast() public {
        vm.prank(org);
        vm.expectRevert("CharityCore: deadline past");
        core.createCampaign{value: 0.001 ether}(
            "Qm1",
            GOAL,
            block.timestamp - 1,
            2,
            ICharityCore.PaymentToken.ETH,
            "Education"
        );
    }

    // ─── org verification ───

    function test_orgVerification_flow() public {
        assertFalse(core.isOrgVerified(nobody));

        vm.prank(admin);
        core.verifyOrg(nobody);
        assertTrue(core.isOrgVerified(nobody));

        vm.prank(admin);
        core.revokeOrg(nobody);
        assertFalse(core.isOrgVerified(nobody));
    }

    // ─── finalize ───

    function test_finalize_atGoalBeforeDeadline_revertsUntilMilestonesDone() public {
        uint256 id = _createCampaign();

        vm.prank(donor);
        vault.donate{value: _grossForNet(GOAL)}(id);

        (bool eligible, bool goalReached, bool expired) = core.canFinalize(id);
        assertFalse(eligible);
        assertTrue(goalReached);
        assertFalse(expired);

        vm.expectRevert("CharityCore: cannot finalize");
        core.finalizeCampaign(id);
    }

    function test_finalize_afterDeadline_failedWhenUnderGoal() public {
        uint256 id = _createCampaign();

        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        core.finalizeCampaign(id);

        assertEq(
            uint8(core.getCampaign(id).status),
            uint8(ICharityCore.CampaignStatus.Failed)
        );
    }

    function test_finalize_revertsWhenActiveAndUnderGoalBeforeDeadline() public {
        uint256 id = _createCampaign();

        vm.prank(donor);
        vault.donate{value: GOAL / 2}(id);

        vm.expectRevert("CharityCore: cannot finalize");
        core.finalizeCampaign(id);
    }

    function test_canFinalize_returnsFalseWhenNotActive() public {
        uint256 id = _createCampaign();

        vm.prank(org);
        core.cancelCampaign(id);

        (bool eligible,,) = core.canFinalize(id);
        assertFalse(eligible);
    }

    // ─── cancel ───

    function test_cancel_withNoDonors() public {
        uint256 id = _createCampaign();

        vm.prank(org);
        core.cancelCampaign(id);

        ICharityCore.Campaign memory c = core.getCampaign(id);
        assertEq(uint8(c.status), uint8(ICharityCore.CampaignStatus.Cancelled));
        assertTrue(c.cancelledAt > 0);
    }

    function test_cancel_withDonors_enablesRefund() public {
        uint256 id = _createCampaign();

        vm.prank(donor);
        vault.donate{value: 1 ether}(id);

        vm.prank(org);
        core.cancelCampaign(id);

        (bool eligible,,) = vault.canRefund(id, donor);
        assertTrue(eligible);

        uint256 balBefore = donor.balance;
        vm.prank(donor);
        vault.claimRefund(id);
        assertGt(donor.balance, balBefore);
    }

    function test_cancel_revertsIfNotOrg() public {
        uint256 id = _createCampaign();

        vm.prank(nobody);
        vm.expectRevert("CharityCore: not org");
        core.cancelCampaign(id);
    }

    function test_cancel_revertsIfNotActive() public {
        uint256 id = _createCampaign();
        vm.prank(org);
        core.cancelCampaign(id);

        vm.prank(org);
        vm.expectRevert("CharityCore: not active");
        core.cancelCampaign(id);
    }

    // ─── donations blocked at goal ───

    function test_donate_revertsWhenGoalReached() public {
        uint256 id = _createCampaign();

        vm.prank(donor);
        vault.donate{value: _grossForNet(GOAL)}(id);

        vm.prank(donor2);
        vm.expectRevert("Vault: goal reached");
        vault.donate{value: 0.01 ether}(id);
    }

    // ─── incrementMilestone ───

    function test_incrementMilestone_completesAtLastMilestone() public {
        uint256 id = _createCampaign();

        vm.prank(admin);
        core.setTrustedContracts(address(vault), address(dao));

        vm.startPrank(admin);
        core.incrementMilestone(id);
        assertEq(
            uint(core.getCampaign(id).status),
            uint(ICharityCore.CampaignStatus.Active)
        );
        assertEq(core.getCampaign(id).completedMilestones, 1);

        core.incrementMilestone(id);
        core.incrementMilestone(id);
        vm.stopPrank();

        assertEq(
            uint(core.getCampaign(id).status),
            uint(ICharityCore.CampaignStatus.Successful)
        );
    }

    // ─── getCharityProgress ───

    function test_getCharityProgress_reflectsRaisedAndExpiry() public {
        uint256 id = _createCampaign();

        vm.prank(donor);
        vault.donate{value: _grossForNet(GOAL / 2)}(id);

        (uint256 raised, uint256 goal, uint256 progressBps,, bool isExpired,) =
            core.getCharityProgress(id);

        assertEq(raised, core.getCampaign(id).raisedAmount);
        assertEq(goal, GOAL);
        assertEq(progressBps, goal > 0 ? (raised * 10000 / goal) : 0);
        assertFalse(isExpired);

        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        (,,,, isExpired,) = core.getCharityProgress(id);
        assertTrue(isExpired);
    }
}
