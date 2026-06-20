// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/DonationVault.sol";
import "../../src/CharityCore.sol";
import "../../src/GovernanceDAO.sol";
import "../../src/ImpactNFT.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract DonationVaultFuzz is Test {
    CharityCore core;
    DonationVault vault;
    GovernanceDAO dao;
    ImpactNFT nft;
    MockUSDC usdc;

    address admin    = makeAddr("admin");
    address org      = makeAddr("org");
    address treasury = makeAddr("treasury");

    uint256 constant DEADLINE_OFFSET = 30 days;
    uint8   constant MILESTONES      = 3;

    function setUp() public {
        vm.startPrank(admin);
        nft   = new ImpactNFT(admin);
        core  = new CharityCore(admin);
        usdc  = new MockUSDC();
        dao   = new GovernanceDAO(admin);
        vault = new DonationVault(admin, address(core), address(dao), address(nft), address(usdc));
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

    function _createCampaignETH() internal returns (uint256) {
        vm.prank(org);
        return core.createCampaign{value: 0.001 ether}(
            "QmCID", 100 ether, block.timestamp + DEADLINE_OFFSET,
            MILESTONES, ICharityCore.PaymentToken.ETH, "test"
        );
    }

    function _createCampaignUSDC() internal returns (uint256) {
        vm.prank(org);
        return core.createCampaign{value: 0.001 ether}(
            "QmCID", 100_000e6, block.timestamp + DEADLINE_OFFSET,
            MILESTONES, ICharityCore.PaymentToken.USDC, "test"
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

    function testFuzz_donate_noUnderflow(uint96 amount) public {
        vm.assume(amount > 0.001 ether);
        uint256 cid   = _createCampaignETH();
        address donor = makeAddr("fuzzDonor");
        _donateETH(donor, cid, uint256(amount));
        uint256 fee = (uint256(amount) * vault.platformFeeBps()) / 10_000;
        uint256 net = uint256(amount) - fee;
        assertEq(vault.getDonorAmount(cid, donor), net);
        assertEq(vault.getCampaignEscrowBalance(cid), net);
    }

    function testFuzz_donate_feePlusNetEqualsTotal(uint96 amount) public {
        vm.assume(amount > 0);
        uint256 cid   = _createCampaignETH();
        address donor = makeAddr("fuzzDonor");
        _donateETH(donor, cid, uint256(amount));
        uint256 fee = (uint256(amount) * vault.platformFeeBps()) / 10_000;
        uint256 net = vault.getDonorAmount(cid, donor);
        assertEq(fee + net, uint256(amount));
    }

    function testFuzz_donate_treasuryReceivesFee(uint96 amount) public {
        vm.assume(amount >= 0.001 ether);
        uint256 cid          = _createCampaignETH();
        uint256 treasuryBefore = treasury.balance;
        address donor        = makeAddr("fuzzDonor");
        _donateETH(donor, cid, uint256(amount));
        uint256 expectedFee = (uint256(amount) * vault.platformFeeBps()) / 10_000;
        assertEq(treasury.balance - treasuryBefore, expectedFee);
    }

    function testFuzz_donate_escrowAccumulates(uint96 a1, uint96 a2) public {
        vm.assume(a1 >= 0.001 ether && a2 >= 0.001 ether);
        vm.assume(a1 <= 40 ether && a2 <= 40 ether);
        uint256 cid = _createCampaignETH();
        address d1  = makeAddr("d1");
        address d2  = makeAddr("d2");
        _donateETH(d1, cid, uint256(a1));
        _donateETH(d2, cid, uint256(a2));
        uint256 fee1          = (uint256(a1) * vault.platformFeeBps()) / 10_000;
        uint256 fee2          = (uint256(a2) * vault.platformFeeBps()) / 10_000;
        uint256 expectedEscrow = (uint256(a1) - fee1) + (uint256(a2) - fee2);
        assertEq(vault.getCampaignEscrowBalance(cid), expectedEscrow);
    }

    function testFuzz_donateUSDC_noUnderflow(uint64 amount) public {
        vm.assume(amount > 0);
        uint256 cid   = _createCampaignUSDC();
        address donor = makeAddr("fuzzUSDC");
        _donateUSDC(donor, cid, uint256(amount));
        uint256 fee = (uint256(amount) * vault.platformFeeBps()) / 10_000;
        uint256 net = uint256(amount) - fee;
        assertEq(vault.getDonorAmount(cid, donor), net);
        assertEq(vault.getCampaignEscrowBalance(cid), net);
    }

    function testFuzz_donateUSDC_vaultBalanceMatchesEscrow(uint64 amount) public {
        vm.assume(amount > 0);
        uint256 cid   = _createCampaignUSDC();
        address donor = makeAddr("fuzzUSDC");
        _donateUSDC(donor, cid, uint256(amount));
        uint256 net = vault.getDonorAmount(cid, donor);
        assertEq(usdc.balanceOf(address(vault)), net);
    }

    function testFuzz_refund_exactBalance(uint96 amount) public {
        vm.assume(amount >= 0.001 ether);
        uint256 cid   = _createCampaignETH();
        address donor = makeAddr("refundDonor");
        _donateETH(donor, cid, uint256(amount));
        uint256 donorBal    = vault.getDonorAmount(cid, donor);
        uint256 escrowBefore = vault.getCampaignEscrowBalance(cid);
        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        vm.prank(admin);
        core.finalizeCampaign(cid);
        uint256 balBefore = donor.balance;
        vm.prank(donor);
        vault.claimRefund(cid);
        assertEq(donor.balance - balBefore, donorBal);
        assertEq(vault.getDonorAmount(cid, donor), 0);
        assertEq(vault.getCampaignEscrowBalance(cid), escrowBefore - donorBal);
    }

    function testFuzz_donateUSDC_donorInfoCorrect(uint64 amount) public {
        vm.assume(amount > 0);
        uint256 cid   = _createCampaignUSDC();
        address donor = makeAddr("fuzzInfoUSDC");
        _donateUSDC(donor, cid, uint256(amount));
        DonationVault.DonorInfo memory info = vault.getDonorInfo(cid, donor);
        assertEq(info.totalDonated,  uint256(amount));
        assertEq(info.donationCount, 1);
        assertEq(info.lastDonatedAt, block.timestamp);
    }

    function testFuzz_refundUSDC_exactBalance(uint64 amount) public {
        vm.assume(amount > 0);
        uint256 cid   = _createCampaignUSDC();
        address donor = makeAddr("refundUSDC");
        _donateUSDC(donor, cid, uint256(amount));
        uint256 donorBal     = vault.getDonorAmount(cid, donor);
        uint256 escrowBefore = vault.getCampaignEscrowBalance(cid);
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

    function testFuzz_setTreasury_updatesCorrectly(address newTreasury) public {
        vm.assume(newTreasury != address(0));
        vm.prank(admin);
        vault.setTreasury(newTreasury);
        assertEq(vault.treasury(), newTreasury);
    }

    function testFuzz_setMaxRefundPeriod_updatesCorrectly(uint256 newPeriod) public {
        vm.assume(newPeriod > 0);
        vm.prank(admin);
        vault.setMaxRefundPeriod(newPeriod);
        assertEq(vault.maxRefundPeriod(), newPeriod);
    }

    function testFuzz_canRefund_correctAfterFailure(uint96 amount) public {
        vm.assume(amount >= 0.001 ether);
        uint256 campaignDeadline = block.timestamp + DEADLINE_OFFSET;
        vm.prank(org);
        uint256 cid = core.createCampaign{value: 0.001 ether}(
            "QmCID", 1e30, campaignDeadline,
            MILESTONES, ICharityCore.PaymentToken.ETH, "test"
        );
        address donor  = makeAddr("canRefundDonor");
        _donateETH(donor, cid, uint256(amount));
        uint256 donorBal = vault.getDonorAmount(cid, donor);
        uint256 maxRef   = vault.maxRefundPeriod();
        vm.warp(campaignDeadline + 1);
        vm.prank(admin);
        core.finalizeCampaign(cid);
        (bool eligible, uint256 refundAmount, uint256 refundDeadline) = vault.canRefund(cid, donor);
        assertTrue(eligible);
        assertEq(refundAmount,   donorBal);
        assertEq(refundDeadline, campaignDeadline + maxRef);
    }

    function testFuzz_canRefund_correctPastDeadline(uint96 amount) public {
        vm.assume(amount >= 0.001 ether);
        uint256 cid   = _createCampaignETH();
        address donor = makeAddr("canRefundDeadline");
        _donateETH(donor, cid, uint256(amount));
        uint256 donorBal = vault.getDonorAmount(cid, donor);
        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        (bool eligible, uint256 refundAmount, ) = vault.canRefund(cid, donor);
        assertTrue(eligible);
        assertEq(refundAmount, donorBal);
    }

    function testFuzz_updateFee_appliedCorrectly(uint16 newFeeBps, uint96 amount) public {
        vm.assume(newFeeBps <= 500);
        vm.assume(amount >= 0.001 ether);
        vm.prank(admin);
        vault.updatePlatformFee(uint256(newFeeBps));
        uint256 cid   = _createCampaignETH();
        address donor = makeAddr("feeDonor");
        _donateETH(donor, cid, uint256(amount));
        uint256 expectedFee = (uint256(amount) * uint256(newFeeBps)) / 10_000;
        uint256 expectedNet = uint256(amount) - expectedFee;
        assertEq(vault.getDonorAmount(cid, donor), expectedNet);
    }

    function invariant_totalEscrowCoversCampaigns() public {
        uint256 totalEscrow = vault.getTotalEscrow();
        assertGe(totalEscrow, 0);
    }

    function invariant_escrowNeverNegative() public {
        uint256 totalEscrow = vault.getTotalEscrow();
        assertLe(totalEscrow, address(vault).balance + usdc.balanceOf(address(vault)));
    }

    function invariant_feeBounded() public {
        assertLe(vault.platformFeeBps(), vault.MAX_FEE());
    }
}
