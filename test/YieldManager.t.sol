// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/CharityCore.sol";
import "../src/DonationVault.sol";
import "../src/GovernanceDAO.sol";
import "../src/ImpactNFT.sol";
import "../src/DisbursementController.sol";
import "../src/YieldManager.sol";
import "../src/MockERC4626Vault.sol";
import "../src/Errors.sol";
import "./mocks/MockSafe.sol";
import {ICharityCore} from "../src/interfaces/ICharityCore.sol";
import {IYieldManager} from "../src/interfaces/IYieldManager.sol";
import {IGovernanceDAO} from "../src/interfaces/IGovernanceDAO.sol";

contract MockUSDC_YM is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @notice Module C §5.4 — caps, P&L, pause, refunds, donation invariance
contract YieldManagerTest is Test {
    CharityCore core;
    DonationVault vault;
    GovernanceDAO dao;
    ImpactNFT nft;
    MockUSDC_YM usdc;
    MockERC4626Vault yieldVault;
    YieldManager ym;
    DisbursementController controller;
    MockSafe mockSafe;

    address admin = makeAddr("admin");
    address org = makeAddr("org");
    address donor1 = makeAddr("donor1");
    address donor2 = makeAddr("donor2");
    address treasury = makeAddr("treasury");
    address lossSink = makeAddr("lossSink");
    address operator = makeAddr("operator");

    address o1 = makeAddr("owner1");
    address o2 = makeAddr("owner2");
    address o3 = makeAddr("owner3");
    address o4 = makeAddr("owner4");
    address o5 = makeAddr("owner5");

    uint256 constant GOAL = 1_000_000e6;
    uint8 constant MILESTONES = 2;

    function setUp() public {
        address[5] memory owners = [o1, o2, o3, o4, o5];
        mockSafe = new MockSafe(owners);

        vm.startPrank(admin);
        nft = new ImpactNFT(admin);
        core = new CharityCore(admin);
        usdc = new MockUSDC_YM();
        dao = new GovernanceDAO(admin);
        vault = new DonationVault(admin, address(core), address(dao), address(nft), address(usdc));
        dao.setDonationVault(address(vault));
        core.setTrustedContracts(address(vault), address(dao));
        nft.setTrustedContracts(address(vault), address(core));
        vault.setTreasury(treasury);
        core.verifyOrg(org);

        yieldVault = new MockERC4626Vault(IERC20(address(usdc)), lossSink, admin);
        ym = new YieldManager(admin, address(vault), address(core), address(yieldVault), address(usdc));
        ym.setOperator(operator, true);
        vault.setYieldManager(address(ym));

        controller = new DisbursementController(
            admin, address(vault), address(core), address(mockSafe)
        );
        vault.setDisbursementController(address(controller));
        vm.stopPrank();

        usdc.mint(donor1, 10_000_000e6);
        usdc.mint(donor2, 10_000_000e6);
        usdc.mint(admin, 10_000_000e6);

        vm.deal(org, 1 ether);
    }

    function _grossForNet(uint256 net) internal pure returns (uint256) {
        // platform fee 100 bps → net = gross * 9900/10000
        return (net * 10_000 + 9899) / 9900;
    }

    function _createFundedUSDC(uint256 netTotal) internal returns (uint256 cid) {
        vm.prank(org);
        cid = core.createCampaign{value: 0.001 ether}(
            "QmCID", GOAL, block.timestamp + 30 days, MILESTONES,
            ICharityCore.PaymentToken.USDC, "edu"
        );

        uint256 half = netTotal / 2;
        uint256 g1 = _grossForNet(half);
        uint256 g2 = _grossForNet(netTotal - half);

        vm.startPrank(donor1);
        usdc.approve(address(vault), g1);
        vault.donateUSDC(cid, g1);
        vm.stopPrank();

        vm.startPrank(donor2);
        usdc.approve(address(vault), g2);
        vault.donateUSDC(cid, g2);
        vm.stopPrank();
    }

    function _enableAndAllocate(uint256 cid, uint256 assets) internal {
        vm.prank(org);
        ym.setYieldEnabled(cid, true);
        vm.prank(operator);
        ym.allocate(cid, assets, 0);
    }

    // ── Allocation caps / reserve ────────────────────────────────────────────

    function test_allocate_respectsMaxAllocationBps() public {
        uint256 cid = _createFundedUSDC(100_000e6);
        // L=100k, maxAlloc 70% → max V = 70k; with R = 30% of A kept liquid
        // Investable = min(L-R, A*0.7 - V) with V=0, A=L → min(L-0.3L, 0.7L) = 0.7L
        vm.prank(org);
        ym.setYieldEnabled(cid, true);

        uint256 liquid = vault.getCampaignEscrowBalance(cid);
        uint256 investable = ym.previewInvestable(cid);
        // maxAllocationBps=7000 → floor(L * 7000 / 10000); fee rounding can leave liquid ≈ net±1
        assertEq(investable, (liquid * 7000) / 10_000);

        uint256 toAlloc = investable;
        vm.prank(operator);
        ym.allocate(cid, toAlloc, 0);

        assertEq(ym.previewInvestable(cid), 0);
        assertEq(vault.getCampaignEscrowBalance(cid), liquid - toAlloc);
        assertEq(vault.getInvestedBalance(cid), toAlloc);
    }

    function test_allocate_respectsMinLiquidReserve() public {
        uint256 cid = _createFundedUSDC(10_000e6);
        vm.prank(org);
        ym.setYieldEnabled(cid, true);

        // Trying to allocate more than investable reverts
        vm.prank(operator);
        vm.expectRevert(TranspaChainErrors.ExceedsInvestable.selector);
        ym.allocate(cid, 8_000e6, 0); // > 70%
    }

    function test_allocate_doesNotChangeDonationsVotesOrNFT() public {
        uint256 cid = _createFundedUSDC(100_000e6);
        uint256 bal1 = vault.getDonorAmount(cid, donor1);
        uint256 bal2 = vault.getDonorAmount(cid, donor2);
        uint256 raised = core.getCampaign(cid).raisedAmount;
        uint256 tokenId = nft.getDonorTokenForCampaign(donor1, cid);
        uint256 nftAmt = nft.getNFTMetadata(tokenId).donatedAmount;

        _enableAndAllocate(cid, 50_000e6);

        assertEq(vault.getDonorAmount(cid, donor1), bal1);
        assertEq(vault.getDonorAmount(cid, donor2), bal2);
        assertEq(core.getCampaign(cid).raisedAmount, raised);
        assertEq(nft.getNFTMetadata(tokenId).donatedAmount, nftAmt);
    }

    function test_otherCampaignSharesUntouchable() public {
        uint256 cid1 = _createFundedUSDC(100_000e6);
        uint256 cid2 = _createFundedUSDC(50_000e6);

        _enableAndAllocate(cid1, 40_000e6);
        _enableAndAllocate(cid2, 20_000e6);

        uint256 shares1 = ym.getPosition(cid1).shares;
        uint256 shares2 = ym.getPosition(cid2).shares;

        vm.prank(admin);
        ym.redeemForLiquidity(cid1, 40_000e6);

        assertEq(ym.getPosition(cid2).shares, shares2, "cid2 shares untouched");
        assertLt(ym.getPosition(cid1).shares, shares1);
    }

    // ── Pause ────────────────────────────────────────────────────────────────

    function test_pause_blocksAllocate_notRedeem() public {
        uint256 cid = _createFundedUSDC(100_000e6);
        _enableAndAllocate(cid, 40_000e6);

        vm.prank(admin);
        ym.pause();

        vm.prank(operator);
        vm.expectRevert(TranspaChainErrors.YieldPaused.selector);
        ym.allocate(cid, 1e6, 0);

        // Redeem still works
        vm.prank(admin);
        uint256 got = ym.redeemForLiquidity(cid, 10_000e6);
        assertGt(got, 0);
    }

    // ── P&L ──────────────────────────────────────────────────────────────────

    function test_pnl_positive() public {
        uint256 cid = _createFundedUSDC(100_000e6);
        _enableAndAllocate(cid, 50_000e6);

        vm.startPrank(admin);
        usdc.approve(address(yieldVault), 5_000e6);
        yieldVault.simulateYield(5_000e6);
        uint256 got = ym.redeemAll(cid);
        vm.stopPrank();

        assertGt(got, 50_000e6 - 2); // allow dust
        assertGt(ym.getPosition(cid).realizedPnl, 0);
        assertEq(ym.getPosition(cid).shares, 0);
        assertEq(vault.getInvestedBalance(cid), 0);
    }

    function test_pnl_zero() public {
        uint256 cid = _createFundedUSDC(100_000e6);
        _enableAndAllocate(cid, 50_000e6);

        vm.prank(admin);
        uint256 got = ym.redeemAll(cid);

        // Near-principal (virtual share dust)
        assertApproxEqAbs(got, 50_000e6, 2);
        assertApproxEqAbs(uint256(ym.getPosition(cid).realizedPnl < 0
            ? -ym.getPosition(cid).realizedPnl
            : ym.getPosition(cid).realizedPnl), 0, 2);
    }

    function test_pnl_negative() public {
        uint256 cid = _createFundedUSDC(100_000e6);
        _enableAndAllocate(cid, 50_000e6);

        vm.prank(admin);
        yieldVault.simulateLoss(10_000e6);

        vm.prank(admin);
        uint256 got = ym.redeemAll(cid);

        assertLt(got, 50_000e6);
        assertLt(ym.getPosition(cid).realizedPnl, 0);
    }

    // ── Refund after gain / loss ─────────────────────────────────────────────

    function test_refund_afterGain() public {
        uint256 cid = _createFundedUSDC(100_000e6);
        _enableAndAllocate(cid, 50_000e6);

        vm.startPrank(admin);
        usdc.approve(address(yieldVault), 10_000e6);
        yieldVault.simulateYield(10_000e6);
        vm.stopPrank();

        vm.prank(org);
        core.cancelCampaign(cid);

        // Claim blocked until settle
        vm.prank(donor1);
        vm.expectRevert(TranspaChainErrors.RefundPendingLiquidity.selector);
        vault.claimRefund(cid);

        vault.settleYieldForRefund(cid);
        assertEq(ym.getPosition(cid).shares, 0);

        uint256 escrow = vault.getCampaignEscrowBalance(cid);
        assertGt(escrow, 100_000e6 - 2); // principal + yield (minus dust)

        uint256 b1 = usdc.balanceOf(donor1);
        vm.prank(donor1);
        vault.claimRefund(cid);
        assertGt(usdc.balanceOf(donor1), b1);
    }

    function test_refund_afterLoss() public {
        uint256 cid = _createFundedUSDC(100_000e6);
        _enableAndAllocate(cid, 70_000e6);

        vm.prank(admin);
        yieldVault.simulateLoss(20_000e6);

        vm.prank(org);
        core.cancelCampaign(cid);

        vault.settleYieldForRefund(cid);

        uint256 escrow = vault.getCampaignEscrowBalance(cid);
        assertLt(escrow, 100_000e6);

        uint256 d1Before = vault.getDonorAmount(cid, donor1);
        uint256 expected = (d1Before * escrow) / (d1Before + vault.getDonorAmount(cid, donor2));

        vm.prank(donor1);
        vault.claimRefund(cid);
        // Proportional share of reduced escrow
        assertApproxEqAbs(
            usdc.balanceOf(donor1) - (10_000_000e6 - _grossForNet(50_000e6)),
            expected,
            1
        );
    }

    function test_settle_repeatableUnderWithdrawCap() public {
        uint256 cid = _createFundedUSDC(100_000e6);
        _enableAndAllocate(cid, 50_000e6);

        vm.prank(admin);
        yieldVault.setWithdrawCap(20_000e6);

        vm.prank(org);
        core.cancelCampaign(cid);

        vault.settleYieldForRefund(cid);
        assertGt(ym.getPosition(cid).shares, 0);

        vm.prank(donor1);
        vm.expectRevert(TranspaChainErrors.RefundPendingLiquidity.selector);
        vault.claimRefund(cid);

        // Clear cap and finish
        vm.prank(admin);
        yieldVault.setWithdrawCap(type(uint256).max);
        vault.settleYieldForRefund(cid);
        assertEq(ym.getPosition(cid).shares, 0);

        vm.prank(donor1);
        vault.claimRefund(cid);
    }

    // ── Re-based milestone release ───────────────────────────────────────────

    function test_submitProof_releaseUsesLiquidPlusYield() public {
        uint256 cid = _createFundedUSDC(100_000e6);
        _enableAndAllocate(cid, 50_000e6);

        // Boost yield so MTM > principal
        vm.startPrank(admin);
        usdc.approve(address(yieldVault), 10_000e6);
        yieldVault.simulateYield(10_000e6);
        vm.stopPrank();

        uint256 liquid = vault.getCampaignEscrowBalance(cid);
        uint256 mtm = ym.positionValue(cid);
        uint256 expected = (liquid + mtm) / MILESTONES;

        vm.prank(org);
        vault.submitMilestoneProof(cid, 0, "QmProof0");

        assertEq(vault.getMilestone(cid, 0).releaseAmount, expected);
    }

    // ── Invariant helpers ────────────────────────────────────────────────────

    function test_invariant_sumSharesEqualsHeld() public {
        uint256 cid1 = _createFundedUSDC(80_000e6);
        uint256 cid2 = _createFundedUSDC(40_000e6);
        _enableAndAllocate(cid1, 40_000e6);
        _enableAndAllocate(cid2, 20_000e6);

        assertEq(
            ym.getPosition(cid1).shares + ym.getPosition(cid2).shares,
            yieldVault.balanceOf(address(ym))
        );
        assertEq(ym.totalAssignedShares() + ym.shareDust(), yieldVault.balanceOf(address(ym)));
    }

    function test_onlyYieldManager_canMoveBuckets() public {
        uint256 cid = _createFundedUSDC(10_000e6);
        vm.expectRevert(TranspaChainErrors.OnlyYieldManager.selector);
        vm.prank(admin);
        vault.moveToYield(cid, 1e6);
    }

    function test_setYieldEnabled_orgOrAdmin_usdcOnly() public {
        uint256 cid = _createFundedUSDC(10_000e6);

        vm.prank(donor1);
        vm.expectRevert(TranspaChainErrors.NotAuthorized.selector);
        ym.setYieldEnabled(cid, true);

        vm.prank(org);
        ym.setYieldEnabled(cid, true);
        assertTrue(ym.getPosition(cid).enabled);

        // ETH campaign
        vm.prank(org);
        uint256 ethCid = core.createCampaign{value: 0.001 ether}(
            "QmETH", 1 ether, block.timestamp + 30 days, 2,
            ICharityCore.PaymentToken.ETH, "edu"
        );
        vm.prank(org);
        vm.expectRevert(TranspaChainErrors.NotUSDCCampaign.selector);
        ym.setYieldEnabled(ethCid, true);
    }

    function test_redeemForLiquidity_calledByController() public {
        uint256 cid = _createFundedUSDC(100_000e6);
        _enableAndAllocate(cid, 70_000e6);

        // Submit proof + approve via DAO so releaseAmount is set against book value
        vm.prank(org);
        vault.submitMilestoneProof(cid, 0, "QmP0");
        uint256 pid = vault.getMilestone(cid, 0).proposalId;

        vm.prank(donor1);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
        vm.prank(donor2);
        dao.castVote(pid, IGovernanceDAO.VoteChoice.For);
        vm.warp(block.timestamp + 3 days + 1);
        dao.queueProposal(pid);
        vm.warp(block.timestamp + 86401);
        dao.executeProposal(pid);

        uint256 release = vault.getMilestone(cid, 0).releaseAmount;
        // Liquid is 30k; if release > liquid, controller redeems shortfall
        assertGt(release, vault.getCampaignEscrowBalance(cid));

        vm.prank(org);
        uint256 reqId = controller.requestDisbursement(
            cid, 0, keccak256("r"), "QmR", uint64(block.timestamp + 7 days)
        );

        address[] memory signers = new address[](3);
        signers[0] = o1;
        signers[1] = o2;
        signers[2] = o3;
        vm.prank(address(mockSafe));
        controller.executeDisbursement(reqId);

        assertTrue(vault.getMilestone(cid, 0).released);
        // Org received USDC
        assertEq(usdc.balanceOf(org), release);
    }

    // ─── Security review fixes (2026-11-20) ─────────────────────────────────

    /// A replaceable YieldManager would let the vault owner point it at an EOA and
    /// pull escrow via moveToYield, bypassing DAO + timelock + Safe.
    function test_setYieldManager_isOneTime() public {
        address attacker = makeAddr("attacker");
        vm.prank(admin);
        vm.expectRevert(TranspaChainErrors.YieldManagerAlreadySet.selector);
        vault.setYieldManager(attacker);
        assertEq(vault.yieldManager(), address(ym));
    }

    function test_setYieldManager_rejectsZero() public {
        DonationVault fresh = new DonationVault(admin, address(core), address(dao), address(nft), address(usdc));
        vm.prank(admin);
        vm.expectRevert(TranspaChainErrors.ZeroAddress.selector);
        fresh.setYieldManager(address(0));
    }

    function test_moveToYield_rejectsNativeCampaign() public {
        vm.prank(org);
        uint256 cid = core.createCampaign{value: 0.001 ether}(
            "QmNative", 1 ether, block.timestamp + 30 days, 2, ICharityCore.PaymentToken.ETH, "Education"
        );
        vm.prank(address(ym));
        vm.expectRevert(TranspaChainErrors.NotUSDCCampaign.selector);
        vault.moveToYield(cid, 1);
    }
}
