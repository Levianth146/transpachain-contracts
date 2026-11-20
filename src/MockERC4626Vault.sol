// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TranspaChainErrors} from "./Errors.sol";

/// @title MockERC4626Vault
/// @notice **TESTNET / MOCK ONLY** — ERC-4626 vault over USDC (6 decimals) for TranspaChain
///         Module C demos. Not for mainnet or real funds.
/// @dev Uses OZ virtual-share `_decimalsOffset() = 6` to harden against first-deposit inflation.
///      Controller (owner) helpers move **real** underlying in/out — they never mint phantom USDC.
contract MockERC4626Vault is ERC4626, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @notice Address that receives assets removed by `simulateLoss`. Immutable sink — no recovery.
    address public immutable LOSS_SINK;

    /// @notice Max assets withdrawable/redeemable in a single call path via maxWithdraw/maxRedeem.
    ///         `type(uint256).max` = uncapped (default).
    uint256 public withdrawCap = type(uint256).max;

    /// @param underlying_ USDC (or TestUSDC) — must be 6 decimals.
    /// @param lossSink_   Declared sink for simulated losses (e.g. burn address).
    /// @param initialOwner Controller that may call simulateYield / simulateLoss / setWithdrawCap.
    constructor(IERC20 underlying_, address lossSink_, address initialOwner)
        ERC20("TranspaChain Mock Yield Shares", "tcYIELD")
        ERC4626(underlying_)
        Ownable(initialOwner)
    {
        if (lossSink_ == address(0) || initialOwner == address(0)) {
            revert TranspaChainErrors.ZeroAddress();
        }
        LOSS_SINK = lossSink_;
    }

    /// @dev Offset ≥ 6 vs 6-decimal USDC → share decimals 12; mitigates inflation attack.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @inheritdoc ERC4626
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 base = _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
        if (withdrawCap == type(uint256).max) return base;
        return base < withdrawCap ? base : withdrawCap;
    }

    /// @inheritdoc ERC4626
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 bal = balanceOf(owner);
        if (withdrawCap == type(uint256).max) return bal;
        uint256 cappedAssets = withdrawCap;
        uint256 cappedShares = previewWithdraw(cappedAssets);
        return bal < cappedShares ? bal : cappedShares;
    }

    // ── Controller-only testnet helpers ──────────────────────────────────────

    /// @notice **MOCK:** Transfer real underlying from the controller into the vault,
    ///         increasing `totalAssets` (share price) without minting shares.
    /// @dev Caller must have approved this vault for `assets`. Does **not** mint USDC.
    function simulateYield(uint256 assets) external onlyOwner {
        if (assets == 0) revert TranspaChainErrors.ZeroAmount();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        emit YieldSimulated(assets);
    }

    /// @notice **MOCK:** Transfer real underlying out to `LOSS_SINK`, decreasing share price.
    function simulateLoss(uint256 assets) external onlyOwner {
        if (assets == 0) revert TranspaChainErrors.ZeroAmount();
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (assets > bal) revert TranspaChainErrors.InsufficientEscrow();
        IERC20(asset()).safeTransfer(LOSS_SINK, assets);
        emit LossSimulated(assets, LOSS_SINK);
    }

    /// @notice **MOCK:** Cap withdrawable assets (illiquidity emulation). Use `type(uint256).max` to clear.
    function setWithdrawCap(uint256 newCap) external onlyOwner {
        withdrawCap = newCap;
        emit WithdrawCapUpdated(newCap);
    }

    event YieldSimulated(uint256 assets);
    event LossSimulated(uint256 assets, address indexed sink);
    event WithdrawCapUpdated(uint256 newCap);
}
