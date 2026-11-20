// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CharityCore.sol";
import "../src/DonationVault.sol";
import "../src/GovernanceDAO.sol";
import "../src/ImpactNFT.sol";
import "../src/DisbursementController.sol";
import "../src/Errors.sol";
import "./mocks/MockSafe.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC_DC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @dev Malicious ETH receiver used for reentrancy attempts.
contract ReentrantOrg {
    DisbursementController public controller;
    uint256 public attackReqId;
    bool public attacking;

    function setController(DisbursementController c) external { controller = c; }

    function arm(uint256 reqId) external { attackReqId = reqId; attacking = true; }

    receive() external payable {
        if (attacking && address(controller) != address(0)) {
            attacking = false;
            try controller.executeDisbursement(attackReqId) {} catch {}
        }
    }
}

/// @notice Module A §3.3 — Safe 3/5 + anti-bypass matrix
contract DisbursementControllerTest is Test {
    using stdStorage for StdStorage;
    CharityCore core;
    DonationVault vault;
    GovernanceDAO dao;
    ImpactNFT nft;
    MockUSDC_DC usdc;
    DisbursementController controller;
    MockSafe mockSafe;

    address admin = makeAddr("admin");
    address org = makeAddr("org");
    address donor1 = makeAddr("donor1");
    address donor2 = makeAddr("donor2");
    address donor3 = makeAddr("donor3");
    address treasury = makeAddr("treasury");
    address outsider = makeAddr("outsider");

    address o1 = makeAddr("owner1");
    address o2 = makeAddr("owner2");
    address o3 = makeAddr("owner3");
    address o4 = makeAddr("owner4");
    address o5 = makeAddr("owner5");

    uint256 constant GOAL = 3 ether;
    uint256 constant DEADLINE_OFFSET = 30 days;
    uint8 constant MILESTONES = 3;

    function setUp() public {
        address[5] memory owners = [o1, o2, o3, o4, o5];
        mockSafe = new MockSafe(owners);

        vm.startPrank(admin);
        nft = new ImpactNFT(admin);
        core = new CharityCore(admin);
        usdc = new MockUSDC_DC();
        dao = new GovernanceDAO(admin);
        vault = new DonationVault(admin, address(core), address(dao), address(nft), address(usdc));
        dao.setDonationVault(address(vault));
        core.setTrustedContracts(address(vault), address(dao));
        nft.setTrustedContracts(address(vault), address(core));
        vault.setTreasury(treasury);
        core.verifyOrg(org);

        controller = new DisbursementController(
            admin, address(vault), address(core), address(mockSafe)
        );
        vault.setDisbursementController(address(controller));
        vm.stopPrank();

        vm.deal(org, 10 ether);
        vm.deal(donor1, 50 ether);
        vm.deal(donor2, 50 ether);
        vm.deal(donor3, 50 ether);
        vm.deal(address(mockSafe), 1 ether);
    }

    function _grossForNet(uint256 net) internal pure returns (uint256) {
        return (net * 10_000 + 9899) / 9900;
    }

    function _createFundedCampaign() internal returns (uint256 cid) {
        vm.prank(org);
        cid = core.createCampaign{value: 0.001 ether}(
            "QmCID", GOAL, block.timestamp + DEADLINE_OFFSET, MILESTONES,
            ICharityCore.PaymentToken.ETH, "edu"
        );
        vm.prank(donor1);
        vault.donate{value: _grossForNet(1 ether)}(cid);
        vm.prank(donor2);
        vault.donate{value: _grossForNet(1 ether)}(cid);
        vm.prank(donor3);
        vault.donate{value: _grossForNet(1 ether)}(cid);
    }

    function _submitProof(uint256 cid, uint8 idx) internal returns (uint256 pid) {
        vm.prank(org);
        vault.submitMilestoneProof(cid, idx, string(abi.encodePacked("QmProof", idx)));
        pid = vault.getMilestone(cid, idx).proposalId;
    }

    function _passAndExecuteDAO(uint256 pid) internal {
        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
        vm.prank(donor2);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
        vm.prank(donor3);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
        vm.warp(block.timestamp + 3 days + 1);
        dao.queueProposal(pid);
        vm.warp(block.timestamp + 86401);
        dao.executeProposal(pid);
    }

    function _defeatProposal(uint256 pid) internal {
        // Only one small vote — fail quorum
        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.Against);
        vm.warp(block.timestamp + 3 days + 1);
        dao.queueProposal(pid);
    }

    function _request(uint256 cid, uint8 idx) internal returns (uint256 reqId) {
        vm.prank(org);
        reqId = controller.requestDisbursement(
            cid, idx, keccak256("receipt"), "QmReceipt", uint64(block.timestamp + 7 days)
        );
    }

    function _safeExec(uint256 reqId) internal {
        address[] memory signers = new address[](3);
        signers[0] = o1;
        signers[1] = o2;
        signers[2] = o3;
        mockSafe.exec(
            address(controller),
            abi.encodeWithSelector(DisbursementController.executeDisbursement.selector, reqId),
            signers
        );
    }

    // ─── §3.3 matrix ─────────────────────────────────────────────────────────

    function test_daoDefeated_noPayoutEvenWithSafe() public {
        uint256 cid = _createFundedCampaign();
        uint256 pid = _submitProof(cid, 0);
        _defeatProposal(pid);

        assertFalse(vault.getMilestone(cid, 0).approved);

        vm.prank(org);
        vm.expectRevert("DC: milestone not approved");
        controller.requestDisbursement(
            cid, 0, keccak256("r"), "QmR", uint64(block.timestamp + 7 days)
        );
    }

    function test_timelockPending_noPayout() public {
        uint256 cid = _createFundedCampaign();
        uint256 pid = _submitProof(cid, 0);
        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
        vm.prank(donor2);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
        vm.prank(donor3);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
        vm.warp(block.timestamp + 3 days + 1);
        dao.queueProposal(pid);
        // timelock still active
        vm.expectRevert();
        dao.executeProposal(pid);
        assertFalse(vault.getMilestone(cid, 0).approved);
    }

    function test_twoSigners_noPayout() public {
        uint256 cid = _createFundedCampaign();
        uint256 pid = _submitProof(cid, 0);
        _passAndExecuteDAO(pid);
        uint256 reqId = _request(cid, 0);

        address[] memory two = new address[](2);
        two[0] = o1;
        two[1] = o2;
        vm.expectRevert("MockSafe: below threshold");
        mockSafe.exec(
            address(controller),
            abi.encodeWithSelector(DisbursementController.executeDisbursement.selector, reqId),
            two
        );

        assertEq(uint8(controller.getRequest(reqId).status), uint8(IDisbursementController.Status.Pending));
        assertFalse(vault.getMilestone(cid, 0).released);
    }

    function test_threeSigners_exactPayout_secondExecReverts() public {
        uint256 cid = _createFundedCampaign();
        uint256 pid = _submitProof(cid, 0);
        _passAndExecuteDAO(pid);
        uint256 reqId = _request(cid, 0);

        uint256 releaseAmount = vault.getMilestone(cid, 0).releaseAmount;
        uint256 orgBefore = org.balance;

        _safeExec(reqId);

        assertEq(org.balance - orgBefore, releaseAmount);
        assertTrue(vault.getMilestone(cid, 0).released);
        assertEq(uint8(controller.getRequest(reqId).status), uint8(IDisbursementController.Status.Executed));

        vm.expectRevert(TranspaChainErrors.RequestNotPending.selector);
        _safeExec(reqId);
    }

    function test_nonSafeCaller_reverts() public {
        uint256 cid = _createFundedCampaign();
        uint256 pid = _submitProof(cid, 0);
        _passAndExecuteDAO(pid);
        uint256 reqId = _request(cid, 0);

        vm.prank(outsider);
        vm.expectRevert(TranspaChainErrors.NotSafe.selector);
        controller.executeDisbursement(reqId);

        vm.prank(org);
        vm.expectRevert(TranspaChainErrors.NotSafe.selector);
        controller.executeDisbursement(reqId);
    }

    function test_tamperedAmountRecipient_impossible() public {
        uint256 cid = _createFundedCampaign();
        uint256 pid = _submitProof(cid, 0);
        _passAndExecuteDAO(pid);
        uint256 reqId = _request(cid, 0);

        IDisbursementController.DisbursementRequest memory req = controller.getRequest(reqId);
        assertEq(req.recipient, org);
        assertEq(req.amount, vault.getMilestone(cid, 0).releaseAmount);
        assertEq(req.token, address(0));

        // Direct payout with wrong recipient/amount from non-controller fails
        vm.prank(address(controller));
        vm.expectRevert("Vault: wrong recipient");
        vault.payoutMilestone(cid, 0, outsider, req.amount);

        vm.prank(address(controller));
        vm.expectRevert("Vault: wrong amount");
        vault.payoutMilestone(cid, 0, org, req.amount - 1);
    }

    function test_insufficientLiquidity_reverts_requestStaysPending() public {
        uint256 cid = _createFundedCampaign();
        uint256 pid = _submitProof(cid, 0);
        _passAndExecuteDAO(pid);
        uint256 reqId = _request(cid, 0);

        uint256 escrowBefore = vault.getCampaignEscrowBalance(cid);
        assertGt(escrowBefore, 0);

        // Zero liquid escrow mapping so payout cannot proceed (request must stay Pending).
        stdstore
            .target(address(vault))
            .sig("getCampaignEscrowBalance(uint256)")
            .with_key(cid)
            .checked_write(uint256(0));

        assertEq(vault.getCampaignEscrowBalance(cid), 0);

        vm.expectRevert(TranspaChainErrors.InsufficientLiquidity.selector);
        _safeExec(reqId);

        assertEq(uint8(controller.getRequest(reqId).status), uint8(IDisbursementController.Status.Pending));
        assertFalse(vault.getMilestone(cid, 0).released);
    }

    function test_legacyReleasePath_alwaysReverts() public {
        vm.expectRevert("Vault: removed");
        vault.releaseMilestoneFunds(1, 0, 1);
    }

    function test_refundsUnaffected() public {
        // Under-goal campaign so finalize → Failed (refund path)
        vm.prank(org);
        uint256 cid = core.createCampaign{value: 0.001 ether}(
            "QmCID", GOAL, block.timestamp + DEADLINE_OFFSET, MILESTONES,
            ICharityCore.PaymentToken.ETH, "edu"
        );
        vm.prank(donor1);
        vault.donate{value: 0.5 ether}(cid);

        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        core.finalizeCampaign(cid);
        assertEq(uint8(core.getCampaign(cid).status), uint8(ICharityCore.CampaignStatus.Failed));

        uint256 balBefore = donor1.balance;
        uint256 expected = vault.getDonorAmount(cid, donor1);
        vm.prank(donor1);
        vault.claimRefund(cid);
        assertEq(donor1.balance - balBefore, expected);
    }

    function test_controllerSetter_cannotBeReused() public {
        vm.prank(admin);
        vm.expectRevert(TranspaChainErrors.ControllerAlreadySet.selector);
        vault.setDisbursementController(makeAddr("other"));
    }

    function test_reentrancy_cannotDrain() public {
        // Deploy reentrant org as campaign owner — need org verified
        ReentrantOrg reOrg = new ReentrantOrg();
        reOrg.setController(controller);
        vm.prank(admin);
        core.verifyOrg(address(reOrg));
        vm.deal(address(reOrg), 1 ether);

        vm.prank(address(reOrg));
        uint256 cid = core.createCampaign{value: 0.001 ether}(
            "QmCID", GOAL, block.timestamp + DEADLINE_OFFSET, MILESTONES,
            ICharityCore.PaymentToken.ETH, "edu"
        );
        vm.prank(donor1);
        vault.donate{value: _grossForNet(GOAL)}(cid);

        vm.prank(address(reOrg));
        vault.submitMilestoneProof(cid, 0, "QmProof");
        uint256 pid = vault.getMilestone(cid, 0).proposalId;
        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
        vm.warp(block.timestamp + 3 days + 1);
        dao.queueProposal(pid);
        vm.warp(block.timestamp + 86401);
        dao.executeProposal(pid);

        vm.prank(address(reOrg));
        uint256 reqId = controller.requestDisbursement(
            cid, 0, keccak256("r"), "QmR", uint64(block.timestamp + 7 days)
        );
        reOrg.arm(reqId);

        uint256 escrowBefore = vault.getCampaignEscrowBalance(cid);
        _safeExec(reqId);

        // Only one milestone paid; remaining escrow still held
        assertTrue(vault.getMilestone(cid, 0).released);
        assertLt(vault.getCampaignEscrowBalance(cid), escrowBefore);
        assertEq(uint8(controller.getRequest(reqId).status), uint8(IDisbursementController.Status.Executed));
    }

    function test_cancelRequest_byOrg() public {
        uint256 cid = _createFundedCampaign();
        uint256 pid = _submitProof(cid, 0);
        _passAndExecuteDAO(pid);
        uint256 reqId = _request(cid, 0);

        vm.prank(org);
        controller.cancelRequest(reqId);
        assertEq(uint8(controller.getRequest(reqId).status), uint8(IDisbursementController.Status.Cancelled));
    }

    function test_requestEmitsReceiptCid() public {
        uint256 cid = _createFundedCampaign();
        uint256 pid = _submitProof(cid, 0);
        _passAndExecuteDAO(pid);

        vm.recordLogs();
        uint256 reqId = _request(cid, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DisbursementRequested(uint256,uint256,bytes32,string)")) {
                found = true;
                assertEq(uint256(logs[i].topics[1]), cid);
                assertEq(uint256(logs[i].topics[2]), reqId);
            }
        }
        assertTrue(found);
    }
}
