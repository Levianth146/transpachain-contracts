// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/MockERC4626Vault.sol";
import {TranspaChainErrors} from "../src/Errors.sol";

contract MockUSDC_4626 is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @notice Module C §5.4 — mock vault helpers, decimals offset, withdraw cap
contract MockERC4626VaultTest is Test {
    MockUSDC_4626 usdc;
    MockERC4626Vault vault;
    address controller = makeAddr("controller");
    address lossSink = makeAddr("lossSink");
    address alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockUSDC_4626();
        vault = new MockERC4626Vault(IERC20(address(usdc)), lossSink, controller);

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(controller, 1_000_000e6);
    }

    function test_decimalsOffset_isAtLeast6() public view {
        // Share token decimals = underlying (6) + offset (6) = 12
        assertEq(vault.decimals(), 12);
    }

    function test_deposit_redeem_roundTrip() public {
        uint256 assets = 100e6;
        vm.startPrank(alice);
        usdc.approve(address(vault), assets);
        uint256 shares = vault.deposit(assets, alice);
        assertGt(shares, 0);
        uint256 got = vault.redeem(shares, alice, alice);
        vm.stopPrank();
        // Virtual shares may leave 1 wei dust; allow tiny loss
        assertGe(got + 1, assets);
    }

    function test_simulateYield_transfersRealUSDC_noMint() public {
        // Seed vault with a deposit
        vm.startPrank(alice);
        usdc.approve(address(vault), 100e6);
        vault.deposit(100e6, alice);
        vm.stopPrank();

        uint256 supplyBefore = usdc.totalSupply();
        uint256 assetsBefore = vault.totalAssets();

        vm.startPrank(controller);
        usdc.approve(address(vault), 10e6);
        vault.simulateYield(10e6);
        vm.stopPrank();

        assertEq(usdc.totalSupply(), supplyBefore, "must not mint USDC");
        assertEq(vault.totalAssets(), assetsBefore + 10e6);
        // Alice's redeemable value increased
        assertGt(vault.previewRedeem(vault.balanceOf(alice)), 100e6 - 1);
    }

    function test_simulateLoss_sendsToSink() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 100e6);
        vault.deposit(100e6, alice);
        vm.stopPrank();

        vm.prank(controller);
        vault.simulateLoss(20e6);

        assertEq(usdc.balanceOf(lossSink), 20e6);
        assertEq(vault.totalAssets(), 80e6);
    }

    function test_setWithdrawCap_limitsMaxWithdraw() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 100e6);
        vault.deposit(100e6, alice);
        vm.stopPrank();

        vm.prank(controller);
        vault.setWithdrawCap(30e6);

        assertEq(vault.maxWithdraw(alice), 30e6);

        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(31e6, alice, alice);

        vm.prank(alice);
        vault.withdraw(30e6, alice, alice);
    }

    function test_onlyOwner_controllerHelpers() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.simulateYield(1);

        vm.expectRevert();
        vm.prank(alice);
        vault.simulateLoss(1);

        vm.expectRevert();
        vm.prank(alice);
        vault.setWithdrawCap(1);
    }

    function test_firstDeposit_inflationHardened() public {
        // Attacker donates large amount before victim deposit — offset should protect
        address attacker = makeAddr("attacker");
        usdc.mint(attacker, 1_000_000e6);

        vm.startPrank(attacker);
        usdc.approve(address(vault), 1);
        vault.deposit(1, attacker);
        // Donation attack
        usdc.transfer(address(vault), 10_000e6);
        vm.stopPrank();

        vm.startPrank(alice);
        usdc.approve(address(vault), 100e6);
        uint256 shares = vault.deposit(100e6, alice);
        vm.stopPrank();

        // With offset=6, victim still receives meaningful shares
        assertGt(shares, 0);
        uint256 redeemable = vault.previewRedeem(shares);
        // Victim should recover nearly all of 100e6 (virtual shares absorb attack)
        assertGe(redeemable, 99e6);
    }
}
