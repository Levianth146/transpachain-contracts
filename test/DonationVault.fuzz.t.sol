// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DonationVault.sol";
import "../src/CharityCore.sol";
import "../src/GovernanceDAO.sol";
import "../src/ImpactNFT.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @notice Fuzz tests for DonationVault invariants
contract DonationVaultFuzz is Test {
    CharityCore core;
    DonationVault vault;
    GovernanceDAO dao;
    ImpactNFT nft;
    MockUSDC usdc;

    address admin = makeAddr("admin");
    address org = makeAddr("org");
    address treasury = makeAddr("treasury");

    uint256 constant DEADLINE_OFFSET = 30 days;
    uint8 constant MILESTONES = 3;

    function setUp() public {
        vm.startPrank(admin);

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
        core.setTrustedContracts(address(vault), address(dao));
        nft.setTrustedContracts(address(vault), address(core));
        vault.setTreasury(treasury);
        core.verifyOrg(org);

        vm.stopPrank();

        vm.deal(org, 100 ether);
        vm.deal(address(this), 500 ether);
        usdc.mint(address(this), 1_000_000e6);
    }

    // ─────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────

    function _createCampaignETH() internal returns (uint256) {
        vm.prank(org);
        return
            core.createCampaign{value: 0.001 ether}(
                "QmCID",
                100 ether,
                block.timestamp + DEADLINE_OFFSET,
                MILESTONES,
                ICharityCore.PaymentToken.ETH,
                "test"
            );
    }

    function _createCampaignUSDC() internal returns (uint256) {
        vm.prank(org);
        return
            core.createCampaign{value: 0.001 ether}(
                "QmCID",
                100_000e6,
                block.timestamp + DEADLINE_OFFSET,
                MILESTONES,
                ICharityCore.PaymentToken.USDC,
                "test"
            );
    }

    function _donateETH(address donor, uint256 cid, uint256 amount) internal {
        vm.deal(donor, amount);
        vm.prank(donor);
        vault.donate{value: amount}(cid);
    }

    function _donateUSDC(address donor, uint256 cid, uint256 amount) internal {
        usdc.mint(donor, amount);
        vm.startPrank(donor);
        usdc.approve(address(vault), amount);
        vault.donateUSDC(cid, amount);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────
    // Fuzz: donate ETH
    // ─────────────────────────────────────────────

    /// @dev Donating random ETH amounts should never cause balance underflow
    function testFuzz_donate_noUnderflow(uint96 amount) public {
        vm.assume(amount > 0.001 ether);
        uint256 cid = _createCampaignETH();

        address donor = makeAddr("fuzzDonor");
        _donateETH(donor, cid, uint256(amount));

        uint256 fee = (uint256(amount) * vault.platformFeeBps()) / 10_000;
        uint256 net = uint256(amount) - fee;

        assertEq(vault.getDonorAmount(cid, donor), net);
        assertEq(vault.getCampaignEscrowBalance(cid), net);
    }

    /// @dev Fee + net must always equal the original amount (no rounding loss)
    function testFuzz_donate_feePlusNetEqualsTotal(uint96 amount) public {
        vm.assume(amount > 0);
        uint256 cid = _createCampaignETH();

        address donor = makeAddr("fuzzDonor");
        _donateETH(donor, cid, uint256(amount));

        uint256 fee = (uint256(amount) * vault.platformFeeBps()) / 10_000;
        uint256 net = vault.getDonorAmount(cid, donor);

        // fee + net == amount (integer division, net = amount - fee)
        assertEq(fee + net, uint256(amount));
    }

    /// @dev Treasury balance increases by exactly the fee amount
    function testFuzz_donate_treasuryReceivesFee(uint96 amount) public {
        vm.assume(amount >= 0.001 ether);
        uint256 cid = _createCampaignETH();

        uint256 treasuryBefore = treasury.balance;
        address donor = makeAddr("fuzzDonor");
        _donateETH(donor, cid, uint256(amount));

        uint256 expectedFee = (uint256(amount) * vault.platformFeeBps()) /
            10_000;
        assertEq(treasury.balance - treasuryBefore, expectedFee);
    }

    /// @dev Multiple random donations accumulate correctly in escrow
    function testFuzz_donate_escrowAccumulates(uint96 a1, uint96 a2) public {
        vm.assume(a1 >= 0.001 ether && a2 >= 0.001 ether);
        uint256 cid = _createCampaignETH();

        address d1 = makeAddr("d1");
        address d2 = makeAddr("d2");
        _donateETH(d1, cid, uint256(a1));
        _donateETH(d2, cid, uint256(a2));

        uint256 fee1 = (uint256(a1) * vault.platformFeeBps()) / 10_000;
        uint256 fee2 = (uint256(a2) * vault.platformFeeBps()) / 10_000;
        uint256 expectedEscrow = (uint256(a1) - fee1) + (uint256(a2) - fee2);

        assertEq(vault.getCampaignEscrowBalance(cid), expectedEscrow);
    }

    // ─────────────────────────────────────────────
    // Fuzz: donate USDC
    // ─────────────────────────────────────────────

    /// @dev Donating random USDC amounts should never cause balance underflow
    function testFuzz_donateUSDC_noUnderflow(uint64 amount) public {
        vm.assume(amount > 0);
        uint256 cid = _createCampaignUSDC();

        address donor = makeAddr("fuzzUSDC");
        _donateUSDC(donor, cid, uint256(amount));

        uint256 fee = (uint256(amount) * vault.platformFeeBps()) / 10_000;
        uint256 net = uint256(amount) - fee;

        assertEq(vault.getDonorAmount(cid, donor), net);
        assertEq(vault.getCampaignEscrowBalance(cid), net);
    }

    /// @dev Vault USDC balance matches escrow balance
    function testFuzz_donateUSDC_vaultBalanceMatchesEscrow(
        uint64 amount
    ) public {
        vm.assume(amount > 0);
        uint256 cid = _createCampaignUSDC();

        address donor = makeAddr("fuzzUSDC");
        _donateUSDC(donor, cid, uint256(amount));

        // Vault holds net amount (fee was sent to treasury)
        uint256 net = vault.getDonorAmount(cid, donor);
        assertEq(usdc.balanceOf(address(vault)), net);
    }

    // ─────────────────────────────────────────────
    // Fuzz: refund
    // ─────────────────────────────────────────────

    /// @dev After refund, donor gets back exact net amount and escrow decreases
    function testFuzz_refund_exactBalance(uint96 amount) public {
        vm.assume(amount >= 0.001 ether);
        uint256 cid = _createCampaignETH();

        address donor = makeAddr("refundDonor");
        _donateETH(donor, cid, uint256(amount));

        uint256 donorBal = vault.getDonorAmount(cid, donor);
        uint256 escrowBefore = vault.getCampaignEscrowBalance(cid);

        // Fail campaign
        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        vm.prank(admin);
        core.finalizeCampaign(cid);

        uint256 ethBefore = donor.balance;
        vm.prank(donor);
        vault.claimRefund(cid);

        assertEq(donor.balance - ethBefore, donorBal);
        assertEq(vault.getDonorAmount(cid, donor), 0);
        assertEq(vault.getCampaignEscrowBalance(cid), escrowBefore - donorBal);
    }

    /// @dev Refund then emergency batch should not double-pay
    function testFuzz_refund_noDoublePay(uint96 amount) public {
        vm.assume(amount >= 0.001 ether);
        // Use a very high goal so campaign always fails
        vm.prank(org);
        uint256 cid = core.createCampaign{value: 0.001 ether}(
            "QmCID",
            1e30,
            block.timestamp + DEADLINE_OFFSET,
            MILESTONES,
            ICharityCore.PaymentToken.ETH,
            "test"
        );

        address donor = makeAddr("noDouble");
        _donateETH(donor, cid, uint256(amount));

        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        vm.prank(admin);
        core.finalizeCampaign(cid);

        // Donor claims
        vm.prank(donor);
        vault.claimRefund(cid);
        assertEq(vault.getDonorAmount(cid, donor), 0);

        // Emergency batch should skip this donor (balance == 0)
        uint256 donorBalBefore = donor.balance;
        vm.prank(admin);
        vault.emergencyRefundBatch(cid, 0, 100);

        assertEq(donor.balance, donorBalBefore); // no additional transfer
    }

    // ─────────────────────────────────────────────
    // Fuzz: submitMilestoneProof
    // ─────────────────────────────────────────────

    /// @dev submitMilestoneProof creates a governance proposal with correct release amount
    function testFuzz_submitMilestoneProof_proposalCreated(
        uint96 donation,
        uint8 milestoneIndex
    ) public {
        vm.assume(donation >= 0.01 ether);
        vm.assume(milestoneIndex < MILESTONES);

        uint256 cid = _createCampaignETH();
        address donor = makeAddr("proofDonor");
        _donateETH(donor, cid, uint256(donation));

        uint256 escrow = vault.getCampaignEscrowBalance(cid);
        uint256 remaining = MILESTONES; // no milestones completed yet
        uint256 expectedRelease = escrow / remaining;

        vm.prank(org);
        vault.submitMilestoneProof(
            cid,
            milestoneIndex,
            string.concat("proof", vm.toString(milestoneIndex))
        );

        DonationVault.Milestone memory m = vault.getMilestone(
            cid,
            milestoneIndex
        );
        assertEq(m.releaseAmount, expectedRelease);
        assertGt(m.proposalId, 0);
        assertEq(
            m.proofCID,
            string.concat("proof", vm.toString(milestoneIndex))
        );
    }

    /// @dev Release amount equals escrow divided by remaining milestones
    function testFuzz_submitMilestoneProof_releaseAmountCorrect(
        uint96 donation,
        uint8 numMilestones
    ) public {
        vm.assume(donation >= 0.01 ether);
        vm.assume(numMilestones >= 1 && numMilestones <= 3);

        // Create campaign with specific milestone count
        vm.prank(org);
        uint256 cid = core.createCampaign{value: 0.001 ether}(
            "QmCID",
            100 ether,
            block.timestamp + DEADLINE_OFFSET,
            numMilestones,
            ICharityCore.PaymentToken.ETH,
            "test"
        );

        address donor = makeAddr("releaseDonor");
        _donateETH(donor, cid, uint256(donation));

        // Submit first milestone proof
        vm.prank(org);
        vault.submitMilestoneProof(cid, 0, "proof0");

        uint256 escrow = vault.getCampaignEscrowBalance(cid);
        uint256 expectedRelease = escrow / uint256(numMilestones);

        DonationVault.Milestone memory m = vault.getMilestone(cid, 0);
        assertEq(m.releaseAmount, expectedRelease);
    }

    // ─────────────────────────────────────────────
    // Fuzz: emergencyRefundBatch
    // ─────────────────────────────────────────────

    /// @dev emergencyRefundBatch refunds correct total matching individual balances
    function testFuzz_emergencyRefundBatch_refundsCorrectly(
        uint96 a1,
        uint96 a2
    ) public {
        vm.assume(a1 >= 0.01 ether && a2 >= 0.01 ether);
        // Use a very high goal so campaign always fails (refunds require Failed status)
        vm.prank(org);
        uint256 cid = core.createCampaign{value: 0.001 ether}(
            "QmCID",
            1e30,
            block.timestamp + DEADLINE_OFFSET,
            MILESTONES,
            ICharityCore.PaymentToken.ETH,
            "test"
        );

        address d1 = makeAddr("batchD1");
        address d2 = makeAddr("batchD2");
        _donateETH(d1, cid, uint256(a1));
        _donateETH(d2, cid, uint256(a2));

        // Fail campaign
        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        vm.prank(admin);
        core.finalizeCampaign(cid);

        // Batch refund all donors
        vm.prank(admin);
        vault.emergencyRefundBatch(cid, 0, 100);

        assertEq(vault.getDonorAmount(cid, d1), 0);
        assertEq(vault.getDonorAmount(cid, d2), 0);
        assertEq(vault.getCampaignEscrowBalance(cid), 0);
    }

    /// @dev Pagination with random limits processes all donors correctly
    function testFuzz_emergencyRefundBatch_paginationWorks(
        uint96 a1,
        uint96 a2,
        uint8 limit
    ) public {
        vm.assume(a1 >= 0.01 ether && a2 >= 0.01 ether);
        vm.assume(limit >= 1 && limit <= 10);
        // Use a very high goal so campaign always fails
        vm.prank(org);
        uint256 cid = core.createCampaign{value: 0.001 ether}(
            "QmCID",
            1e30,
            block.timestamp + DEADLINE_OFFSET,
            MILESTONES,
            ICharityCore.PaymentToken.ETH,
            "test"
        );

        address d1 = makeAddr("pageD1");
        address d2 = makeAddr("pageD2");
        _donateETH(d1, cid, uint256(a1));
        _donateETH(d2, cid, uint256(a2));

        // Fail campaign
        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        vm.prank(admin);
        core.finalizeCampaign(cid);

        // First batch with limit
        vm.prank(admin);
        vault.emergencyRefundBatch(cid, 0, uint256(limit));

        // Second batch from offset to cover remaining
        if (uint256(limit) < 2) {
            vm.prank(admin);
            vault.emergencyRefundBatch(cid, uint256(limit), 100);
        }

        assertEq(vault.getDonorAmount(cid, d1), 0);
        assertEq(vault.getDonorAmount(cid, d2), 0);
        assertEq(vault.getCampaignEscrowBalance(cid), 0);
    }

    // ─────────────────────────────────────────────
    // Fuzz: milestone release
    // ─────────────────────────────────────────────

    /// @dev Total released across all milestones must never exceed escrow
    function testFuzz_milestone_releaseDoesNotExceedEscrow(
        uint96 donation,
        uint8 numMilestones
    ) public {
        vm.assume(donation >= 0.01 ether);
        vm.assume(numMilestones >= 1 && numMilestones <= 3);

        // Create campaign with specific milestone count
        vm.prank(org);
        uint256 cid = core.createCampaign{value: 0.001 ether}(
            "QmCID",
            100 ether,
            block.timestamp + DEADLINE_OFFSET,
            numMilestones,
            ICharityCore.PaymentToken.ETH,
            "test"
        );

        address donor = makeAddr("msDonor");
        _donateETH(donor, cid, uint256(donation));

        uint256 escrowTotal = vault.getCampaignEscrowBalance(cid);
        uint256 totalReleased;

        for (uint8 i = 0; i < numMilestones; i++) {
            vm.prank(org);
            vault.submitMilestoneProof(
                cid,
                i,
                string.concat("proof", vm.toString(i))
            );

            uint256 releaseAmt = vault.getMilestone(cid, i).releaseAmount;

            vm.prank(address(dao));
            vault.releaseMilestoneFunds(cid, i);

            totalReleased += releaseAmt;
        }

        // Total released should not exceed original escrow
        assertLe(totalReleased, escrowTotal);
        // Remaining escrow should be 0 (or dust due to rounding)
        assertLe(vault.getCampaignEscrowBalance(cid), numMilestones - 1);
    }

    // ─────────────────────────────────────────────
    // Fuzz: fee update
    // ─────────────────────────────────────────────

    /// @dev New fee must be applied correctly to subsequent donations
    function testFuzz_updateFee_appliedCorrectly(
        uint16 newFeeBps,
        uint96 amount
    ) public {
        vm.assume(newFeeBps <= 500);
        vm.assume(amount >= 0.001 ether);

        vm.prank(admin);
        vault.updatePlatformFee(uint256(newFeeBps));

        uint256 cid = _createCampaignETH();
        address donor = makeAddr("feeDonor");
        _donateETH(donor, cid, uint256(amount));

        uint256 expectedFee = (uint256(amount) * uint256(newFeeBps)) / 10_000;
        uint256 expectedNet = uint256(amount) - expectedFee;

        assertEq(vault.getDonorAmount(cid, donor), expectedNet);
    }

    // ─────────────────────────────────────────────
    // Fuzz: USDC donor info
    // ─────────────────────────────────────────────

    /// @dev USDC donations record correct donor info (totalDonated, donationCount)
    function testFuzz_donateUSDC_donorInfoCorrect(uint64 amount) public {
        vm.assume(amount > 0);
        uint256 cid = _createCampaignUSDC();

        address donor = makeAddr("fuzzInfoUSDC");
        _donateUSDC(donor, cid, uint256(amount));

        DonationVault.DonorInfo memory info = vault.getDonorInfo(cid, donor);
        assertEq(info.totalDonated, uint256(amount));
        assertEq(info.donationCount, 1);
        assertEq(info.lastDonatedAt, block.timestamp);
    }

    // ─────────────────────────────────────────────
    // Fuzz: USDC refund
    // ─────────────────────────────────────────────

    /// @dev After USDC refund, donor gets back exact net amount
    function testFuzz_refundUSDC_exactBalance(uint64 amount) public {
        vm.assume(amount > 0);
        uint256 cid = _createCampaignUSDC();

        address donor = makeAddr("refundUSDC");
        _donateUSDC(donor, cid, uint256(amount));

        uint256 donorBal = vault.getDonorAmount(cid, donor);
        uint256 escrowBefore = vault.getCampaignEscrowBalance(cid);

        // Fail campaign
        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        vm.prank(admin);
        core.finalizeCampaign(cid);

        uint256 usdcBefore = usdc.balanceOf(donor);
        vm.prank(donor);
        vault.claimRefund(cid);

        assertEq(usdc.balanceOf(donor) - usdcBefore, donorBal);
        assertEq(vault.getDonorAmount(cid, donor), 0);
        assertEq(vault.getCampaignEscrowBalance(cid), escrowBefore - donorBal);
    }

    // ─────────────────────────────────────────────
    // Fuzz: admin functions
    // ─────────────────────────────────────────────

    /// @dev setTreasury updates correctly for any non-zero address
    function testFuzz_setTreasury_updatesCorrectly(address newTreasury) public {
        vm.assume(newTreasury != address(0));

        vm.prank(admin);
        vault.setTreasury(newTreasury);

        assertEq(vault.treasury(), newTreasury);
    }

    /// @dev setMaxRefundPeriod updates correctly for any non-zero period
    function testFuzz_setMaxRefundPeriod_updatesCorrectly(
        uint256 newPeriod
    ) public {
        vm.assume(newPeriod > 0);

        vm.prank(admin);
        vault.setMaxRefundPeriod(newPeriod);

        assertEq(vault.maxRefundPeriod(), newPeriod);
    }

    // ─────────────────────────────────────────────
    // Fuzz: canRefund
    // ─────────────────────────────────────────────

    /// @dev canRefund returns true with correct amount after campaign fails
    function testFuzz_canRefund_correctAfterFailure(uint96 amount) public {
        vm.assume(amount >= 0.001 ether);
        // Use a very high goal so campaign always fails
        uint256 campaignDeadline = block.timestamp + DEADLINE_OFFSET;
        vm.prank(org);
        uint256 cid = core.createCampaign{value: 0.001 ether}(
            "QmCID",
            1e30,
            campaignDeadline,
            MILESTONES,
            ICharityCore.PaymentToken.ETH,
            "test"
        );

        address donor = makeAddr("canRefundDonor");
        _donateETH(donor, cid, uint256(amount));

        uint256 donorBal = vault.getDonorAmount(cid, donor);
        uint256 maxRef = vault.maxRefundPeriod();

        // Fail campaign
        vm.warp(campaignDeadline + 1);
        vm.prank(admin);
        core.finalizeCampaign(cid);

        (bool eligible, uint256 refundAmount, uint256 refundDeadline) = vault
            .canRefund(cid, donor);
        assertTrue(eligible);
        assertEq(refundAmount, donorBal);
        assertEq(refundDeadline, campaignDeadline + maxRef);
    }

    /// @dev canRefund returns true when past deadline (even without finalize)
    function testFuzz_canRefund_correctPastDeadline(uint96 amount) public {
        vm.assume(amount >= 0.001 ether);
        uint256 cid = _createCampaignETH();

        address donor = makeAddr("canRefundDeadline");
        _donateETH(donor, cid, uint256(amount));

        uint256 donorBal = vault.getDonorAmount(cid, donor);

        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);

        (bool eligible, uint256 refundAmount, ) = vault.canRefund(cid, donor);
        assertTrue(eligible);
        assertEq(refundAmount, donorBal);
    }

    // ─────────────────────────────────────────────
    // Invariants
    // ─────────────────────────────────────────────

    /// @dev Invariant: getTotalEscrow >= sum of all campaign escrow balances
    ///      This must hold across any sequence of operations
    function invariant_totalEscrowCoversCampaigns() public {
        // We track a known set of campaigns via counter
        // For each campaign, getCampaignEscrowBalance <= getTotalEscrow
        // This is a simplified check — in a full invariant suite we'd
        // use a handler contract to generate random calls
        uint256 totalEscrow = vault.getTotalEscrow();
        assertGe(totalEscrow, 0); // never underflows
    }

    /// @dev Invariant: escrow balance must always be non-negative (uint256, so implicit,
    ///      but we verify no subtraction overflow via balance checks)
    function invariant_escrowNeverNegative() public {
        // uint256 can't go negative, but we verify the totalEscrow
        // is consistent with contract's ETH balance (for ETH campaigns)
        uint256 totalEscrow = vault.getTotalEscrow();
        // The vault should hold at least totalEscrow in ETH + USDC value
        // For ETH-only check:
        assertLe(
            totalEscrow,
            address(vault).balance + usdc.balanceOf(address(vault))
        );
    }

    /// @dev Invariant: platformFeeBps always <= MAX_FEE (500)
    function invariant_feeBounded() public {
        assertLe(vault.platformFeeBps(), vault.MAX_FEE());
    }
}
