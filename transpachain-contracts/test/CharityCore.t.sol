// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CharityCore.sol";
import "../src/interfaces/ICharityCore.sol";

contract CharityCoreTest is Test {
    CharityCore public core;
    address public admin   = makeAddr("admin");
    address public org     = makeAddr("org");
    address public donor   = makeAddr("donor");
    address public nobody  = makeAddr("nobody");

    uint256 constant GOAL     = 2 ether;
    uint256 constant DEADLINE_OFFSET = 30 days;

    function setUp() public {
        vm.prank(admin);
        core = new CharityCore(admin);

        // Verify org
        vm.prank(admin);
        core.setOrgVerified(org, true);

        vm.deal(org, 10 ether);
        vm.deal(donor, 10 ether);
    }

    // ─── Data flow test: create campaign and verify stored data ───

    function test_createCampaign_storesData() public {
        uint256 deadline = block.timestamp + DEADLINE_OFFSET;
        vm.prank(org);
        uint256 id = core.createCampaign{value: 0.001 ether}(
            "QmTestCID123",
            GOAL,
            deadline,
            3
        );

        assertEq(id, 1, "first campaign id should be 1");

        ICharityCore.Campaign memory c = core.getCampaign(id);
        assertEq(c.orgAddress,      org,                               "org mismatch");
        assertEq(c.goalAmount,      GOAL,                              "goal mismatch");
        assertEq(c.deadline,        deadline,                          "deadline mismatch");
        assertEq(c.totalMilestones, 3,                                 "milestones mismatch");
        assertEq(c.raisedAmount,    0,                                 "raised should be 0");
        assertEq(uint(c.status),    uint(ICharityCore.CampaignStatus.Active), "status should be Active");
        assertEq(c.metadataCID,     "QmTestCID123",                    "CID mismatch");
    }

    function test_createCampaign_incrementsCounter() public {
        uint256 deadline = block.timestamp + DEADLINE_OFFSET;
        vm.startPrank(org);
        core.createCampaign{value: 0.001 ether}("Qm1", GOAL, deadline, 2);
        core.createCampaign{value: 0.001 ether}("Qm2", GOAL, deadline, 2);
        vm.stopPrank();

        assertEq(core.totalCampaigns(), 2);
    }

    function test_createCampaign_tracksOrgCampaigns() public {
        uint256 deadline = block.timestamp + DEADLINE_OFFSET;
        vm.startPrank(org);
        core.createCampaign{value: 0.001 ether}("Qm1", GOAL, deadline, 2);
        core.createCampaign{value: 0.001 ether}("Qm2", GOAL, deadline, 2);
        vm.stopPrank();

        uint256[] memory ids = core.getCampaignsByOrg(org);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
    }

    // ─── Failure cases ───

    function test_createCampaign_revertsIfNotVerified() public {
        vm.prank(nobody);
        vm.expectRevert("CharityCore: org not verified");
        core.createCampaign{value: 0.001 ether}("Qm1", GOAL, block.timestamp + 1 days, 2);
    }

    function test_createCampaign_revertsIfNoDeposit() public {
        vm.prank(org);
        vm.expectRevert("CharityCore: deposit required");
        core.createCampaign("Qm1", GOAL, block.timestamp + 1 days, 2);
    }

    function test_createCampaign_revertsIfGoalZero() public {
        vm.prank(org);
        vm.expectRevert("CharityCore: goal=0");
        core.createCampaign{value: 0.001 ether}("Qm1", 0, block.timestamp + 1 days, 2);
    }

    function test_createCampaign_revertsIfDeadlinePast() public {
        vm.prank(org);
        vm.expectRevert("CharityCore: deadline past");
        core.createCampaign{value: 0.001 ether}("Qm1", GOAL, block.timestamp - 1, 2);
    }

    // ─── Data flow: org verification propagates ───

    function test_orgVerification_flow() public {
        assertFalse(core.isOrgVerified(nobody));

        vm.prank(admin);
        core.setOrgVerified(nobody, true);
        assertTrue(core.isOrgVerified(nobody));

        vm.prank(admin);
        core.setOrgVerified(nobody, false);
        assertFalse(core.isOrgVerified(nobody));
    }

    // ─── Data flow: incrementMilestone updates status ───

    function test_incrementMilestone_completesAtLastMilestone() public {
        uint256 deadline = block.timestamp + DEADLINE_OFFSET;
        vm.prank(org);
        uint256 id = core.createCampaign{value: 0.001 ether}("Qm1", GOAL, deadline, 2);

        // Simulate trusted contract calls
        vm.prank(admin);
        core.setTrustedContracts(admin, admin);

        vm.prank(admin);
        core.incrementMilestone(id);
        assertEq(uint(core.getCampaign(id).status), uint(ICharityCore.CampaignStatus.Active));
        assertEq(core.getCampaign(id).completedMilestones, 1);

        vm.prank(admin);
        core.incrementMilestone(id);
        // 2/2 milestones complete → Successful
        assertEq(uint(core.getCampaign(id).status), uint(ICharityCore.CampaignStatus.Successful));
    }
}
