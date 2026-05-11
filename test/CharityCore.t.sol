// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CharityCore.sol";
import "../src/interfaces/ICharityCore.sol";

contract CharityCoreTest is Test {
    CharityCore public core;
    address public admin  = makeAddr("admin");
    address public org    = makeAddr("org");
    address public donor  = makeAddr("donor");
    address public nobody = makeAddr("nobody");

    uint256 constant GOAL            = 2 ether;
    uint256 constant DEADLINE_OFFSET = 30 days;

    function setUp() public {
        vm.prank(admin);
        core = new CharityCore(admin);

        vm.prank(admin);
        core.verifyOrg(org);

        vm.deal(org,   10 ether);
        vm.deal(donor, 10 ether);
    }

    // ─── Helper ───────────────────────────────────────────────────
    function _createCampaign(uint8 milestones) internal returns (uint256 id) {
        uint256 deadline = block.timestamp + DEADLINE_OFFSET;
        vm.prank(org);
        id = core.createCampaign{value: 0.001 ether}(
            "QmTestCID123",
            GOAL,
            deadline,
            milestones,
            ICharityCore.PaymentToken.ETH,
            "education"
        );
    }

    // ─── createCampaign ───────────────────────────────────────────

    function test_createCampaign_storesData() public {
        uint256 deadline = block.timestamp + DEADLINE_OFFSET;
        vm.prank(org);
        uint256 id = core.createCampaign{value: 0.001 ether}(
            "QmTestCID123",
            GOAL,
            deadline,
            3,
            ICharityCore.PaymentToken.ETH,
            "education"
        );

        assertEq(id, 1, "first campaign id should be 1");

        ICharityCore.Campaign memory c = core.getCampaign(id);
        assertEq(c.orgAddress,      org,      "org mismatch");
        assertEq(c.goalAmount,      GOAL,     "goal mismatch");
        assertEq(c.deadline,        deadline, "deadline mismatch");
        assertEq(c.totalMilestones, 3,        "milestones mismatch");
        assertEq(c.raisedAmount,    0,        "raised should be 0");
        assertEq(c.category,        "education", "category mismatch");
        assertEq(uint(c.paymentToken), uint(ICharityCore.PaymentToken.ETH), "token mismatch");
        assertEq(uint(c.status), uint(ICharityCore.CampaignStatus.Active),  "status should be Active");
        assertGt(c.createdAt, 0, "createdAt should be set");
        assertEq(c.cancelledAt, 0, "cancelledAt should be 0");
    }

    function test_createCampaign_incrementsCounter() public {
        _createCampaign(2);
        _createCampaign(2);
        assertEq(core.totalCampaigns(), 2);
    }

    function test_createCampaign_tracksOrgCampaigns() public {
        _createCampaign(2);
        _createCampaign(2);
        uint256[] memory ids = core.getCampaignsByOrg(org);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
    }

    function test_createCampaign_revertsIfNotVerified() public {
        vm.prank(nobody);
        vm.expectRevert();
        core.createCampaign{value: 0.001 ether}(
            "Qm1", GOAL, block.timestamp + 1 days, 2,
            ICharityCore.PaymentToken.ETH, "education"
        );
    }

    function test_createCampaign_revertsIfNoDeposit() public {
        vm.prank(org);
        vm.expectRevert("CharityCore: deposit required");
        core.createCampaign(
            "Qm1", GOAL, block.timestamp + 1 days, 2,
            ICharityCore.PaymentToken.ETH, "education"
        );
    }

    function test_createCampaign_revertsIfGoalZero() public {
        vm.prank(org);
        vm.expectRevert("CharityCore: goal=0");
        core.createCampaign{value: 0.001 ether}(
            "Qm1", 0, block.timestamp + 1 days, 2,
            ICharityCore.PaymentToken.ETH, "education"
        );
    }

    function test_createCampaign_revertsIfDeadlinePast() public {
        vm.prank(org);
        vm.expectRevert("CharityCore: deadline past");
        core.createCampaign{value: 0.001 ether}(
            "Qm1", GOAL, block.timestamp - 1, 2,
            ICharityCore.PaymentToken.ETH, "education"
        );
    }

    // ─── Org verification ─────────────────────────────────────────

    function test_orgVerification_flow() public {
        assertFalse(core.isOrgVerified(nobody));

        vm.prank(admin);
        core.verifyOrg(nobody);
        assertTrue(core.isOrgVerified(nobody));

        vm.prank(admin);
        core.revokeOrg(nobody);
        assertFalse(core.isOrgVerified(nobody));
    }

    function test_verifyOrg_revertsIfAlreadyVerified() public {
        vm.prank(admin);
        vm.expectRevert("Already verified");
        core.verifyOrg(org); // org already verified in setUp
    }

    function test_revokeOrg_revertsIfNotVerified() public {
        vm.prank(admin);
        vm.expectRevert("Not verified");
        core.revokeOrg(nobody);
    }

    // ─── incrementMilestone ───────────────────────────────────────

    function test_incrementMilestone_completesAtLastMilestone() public {
        uint256 id = _createCampaign(2);

        vm.prank(admin);
        core.setTrustedContracts(admin, admin);

        vm.prank(admin);
        core.incrementMilestone(id);
        assertEq(uint(core.getCampaign(id).status), uint(ICharityCore.CampaignStatus.Active));

        vm.prank(admin);
        core.incrementMilestone(id);
        assertEq(uint(core.getCampaign(id).status), uint(ICharityCore.CampaignStatus.Successful));
    }

    // ─── cancelCampaign ───────────────────────────────────────────

    function test_cancelCampaign_byOrg() public {
        uint256 id = _createCampaign(2);
        vm.prank(org);
        core.cancelCampaign(id);
        assertEq(uint(core.getCampaign(id).status), uint(ICharityCore.CampaignStatus.Cancelled));
        assertGt(core.getCampaign(id).cancelledAt, 0);
    }

    function test_cancelCampaign_revertsIfNotOrg() public {
        uint256 id = _createCampaign(2);
        vm.prank(nobody);
        vm.expectRevert("CharityCore: not org");
        core.cancelCampaign(id);
    }

    // ─── finalizeCampaign ─────────────────────────────────────────

    function test_finalizeCampaign_failedIfUnderGoal() public {
        uint256 id = _createCampaign(2);
        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        core.finalizeCampaign(id);
        assertEq(uint(core.getCampaign(id).status), uint(ICharityCore.CampaignStatus.Failed));
    }

    function test_finalizeCampaign_revertsIfNotExpired() public {
        uint256 id = _createCampaign(2);
        vm.expectRevert("CharityCore: not expired");
        core.finalizeCampaign(id);
    }

    // ─── extendDeadline ───────────────────────────────────────────

    function test_extendDeadline_success() public {
        uint256 id = _createCampaign(2);
        uint256 oldDeadline = core.getCampaign(id).deadline;
        uint256 newDeadline = oldDeadline + 7 days;
        vm.prank(org);
        core.extendDeadline(id, newDeadline);
        assertEq(core.getCampaign(id).deadline, newDeadline);
    }

    function test_extendDeadline_revertsIfExceedsMax() public {
        uint256 id = _createCampaign(2);
        uint256 oldDeadline = core.getCampaign(id).deadline;
        vm.prank(org);
        vm.expectRevert("CharityCore: exceeds max");
        core.extendDeadline(id, oldDeadline + 31 days);
    }

    // ─── getCharityProgress ───────────────────────────────────────

    function test_getCharityProgress_returnsCorrectValues() public {
        uint256 id = _createCampaign(2);
        (uint256 raised, uint256 goal, uint256 progressBps,
         uint256 deadline, bool isExpired, uint256 timeLeft) = core.getCharityProgress(id);

        assertEq(raised,      0);
        assertEq(goal,        GOAL);
        assertEq(progressBps, 0);
        assertFalse(isExpired);
        assertGt(timeLeft,    0);
        assertGt(deadline,    block.timestamp);
    }

    // ─── getCharities ─────────────────────────────────────────────

    function test_getCharities_returnsBatch() public {
        _createCampaign(2);
        _createCampaign(2);
        _createCampaign(2);
        ICharityCore.Campaign[] memory campaigns = core.getCharities(1, 3);
        assertEq(campaigns.length, 3);
        assertEq(campaigns[0].id, 1);
        assertEq(campaigns[2].id, 3);
    }
}
