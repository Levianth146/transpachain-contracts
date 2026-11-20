// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYieldManager} from "./interfaces/IYieldManager.sol";
import {ICharityCore} from "./interfaces/ICharityCore.sol";
import {TranspaChainErrors} from "./Errors.sol";

/// @dev Minimal vault surface used by YieldManager (avoids circular full import).
interface IVaultYieldOps {
    function moveToYield(uint256 cid, uint256 assets) external;
    function receiveFromYield(uint256 cid, uint256 assets) external;
    function getCampaignEscrowBalance(uint256 cid) external view returns (uint256);
    function getInvestedBalance(uint256 cid) external view returns (uint256);
    function getMilestone(uint256 cid, uint8 idx) external view returns (
        string memory proofCID,
        uint256 releaseAmount,
        bool released,
        uint256 proposalId,
        bool approved,
        uint64 approvedAt
    );
    function disbursementController() external view returns (address);
}

/// @title YieldManager
/// @notice Holds ERC-4626 shares per campaign. USDC only ever returns to DonationVault.
contract YieldManager is IYieldManager, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable vault;
    address public immutable charityCore;
    IERC4626 public immutable yieldVault;
    IERC20 public immutable usdc;

    Policy private _policy;

    mapping(uint256 => Position) private _positions;
    mapping(address => bool) public operators;

    /// @dev Sum of all position.shares — must equal yieldVault.balanceOf(this) (+ dust).
    uint256 public totalAssignedShares;
    /// @dev Unassigned share dust from rounding (explicitly tracked for the Σshares invariant).
    uint256 public shareDust;

    modifier onlyOperatorOrOwner() {
        if (msg.sender != owner() && !operators[msg.sender]) {
            revert TranspaChainErrors.NotAuthorized();
        }
        _;
    }

    constructor(
        address initialOwner,
        address vault_,
        address charityCore_,
        address yieldVault_,
        address usdc_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) || vault_ == address(0) || charityCore_ == address(0)
                || yieldVault_ == address(0) || usdc_ == address(0)
        ) {
            revert TranspaChainErrors.ZeroAddress();
        }
        vault = vault_;
        charityCore = charityCore_;
        yieldVault = IERC4626(yieldVault_);
        usdc = IERC20(usdc_);

        _policy = Policy({
            minLiquidReserveBps: 3000,
            maxAllocationBps: 7000,
            maxAssetsPerTx: type(uint256).max,
            paused: false
        });
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    function setOperator(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert TranspaChainErrors.ZeroAddress();
        operators[account] = allowed;
    }

    function setPolicy(
        uint16 minLiquidReserveBps,
        uint16 maxAllocationBps,
        uint256 maxAssetsPerTx,
        bool paused
    ) external onlyOwner {
        require(minLiquidReserveBps <= 10_000, "YM: reserve bps");
        require(maxAllocationBps <= 10_000, "YM: alloc bps");
        require(minLiquidReserveBps + maxAllocationBps <= 10_000, "YM: bps sum");
        _policy = Policy(minLiquidReserveBps, maxAllocationBps, maxAssetsPerTx, paused);
        emit PolicyUpdated(minLiquidReserveBps, maxAllocationBps, maxAssetsPerTx, paused);
    }

    /// @notice Pause blocks `allocate` only; redeem paths remain open.
    function pause() external onlyOwner {
        _policy.paused = true;
        emit PolicyUpdated(
            _policy.minLiquidReserveBps,
            _policy.maxAllocationBps,
            _policy.maxAssetsPerTx,
            true
        );
    }

    function unpause() external onlyOwner {
        _policy.paused = false;
        emit PolicyUpdated(
            _policy.minLiquidReserveBps,
            _policy.maxAllocationBps,
            _policy.maxAssetsPerTx,
            false
        );
    }

    // ── Yield enable ─────────────────────────────────────────────────────────

    /// @inheritdoc IYieldManager
    function setYieldEnabled(uint256 cid, bool on) external {
        ICharityCore.Campaign memory c = ICharityCore(charityCore).getCampaign(cid);
        if (c.paymentToken != ICharityCore.PaymentToken.USDC) {
            revert TranspaChainErrors.NotUSDCCampaign();
        }
        if (msg.sender != owner() && msg.sender != c.orgAddress) {
            revert TranspaChainErrors.NotAuthorized();
        }
        _positions[cid].enabled = on;
        emit YieldEnabledUpdated(cid, on);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    /// @inheritdoc IYieldManager
    function policy() external view returns (Policy memory) {
        return _policy;
    }

    /// @inheritdoc IYieldManager
    function getPosition(uint256 cid) external view returns (Position memory) {
        return _positions[cid];
    }

    /// @inheritdoc IYieldManager
    function positionValue(uint256 cid) public view returns (uint256) {
        uint256 shares = _positions[cid].shares;
        if (shares == 0) return 0;
        return yieldVault.previewRedeem(shares);
    }

    /// @inheritdoc IYieldManager
    /// @dev Investable = min(L − R, A·maxAlloc − V, maxAssetsPerTx, vault.maxDeposit)
    ///      L = liquid, V = position value, A = L + V,
    ///      R = max(A·minReserve, next milestone releaseAmount if proof submitted).
    function previewInvestable(uint256 cid) public view returns (uint256) {
        if (!_positions[cid].enabled) return 0;
        if (_policy.paused) return 0;

        uint256 L = IVaultYieldOps(vault).getCampaignEscrowBalance(cid);
        uint256 V = positionValue(cid);
        uint256 A = L + V;

        uint256 reserveFromBps = (A * uint256(_policy.minLiquidReserveBps)) / 10_000;
        uint256 reservedRelease = _nextMilestoneReserve(cid);
        uint256 R = reserveFromBps > reservedRelease ? reserveFromBps : reservedRelease;

        if (L <= R) return 0;
        uint256 fromLiquid = L - R;

        uint256 maxAllocAssets = (A * uint256(_policy.maxAllocationBps)) / 10_000;
        if (V >= maxAllocAssets) return 0;
        uint256 fromCap = maxAllocAssets - V;

        uint256 investable = fromLiquid < fromCap ? fromLiquid : fromCap;
        if (investable > _policy.maxAssetsPerTx) investable = _policy.maxAssetsPerTx;

        uint256 maxDep = yieldVault.maxDeposit(address(this));
        if (investable > maxDep) investable = maxDep;

        return investable;
    }

    // ── Mutative ─────────────────────────────────────────────────────────────

    /// @inheritdoc IYieldManager
    function allocate(uint256 cid, uint256 assets, uint256 minShares)
        external
        nonReentrant
        onlyOperatorOrOwner
    {
        if (assets == 0) revert TranspaChainErrors.ZeroAmount();
        if (_policy.paused) revert TranspaChainErrors.YieldPaused();
        if (!_positions[cid].enabled) revert TranspaChainErrors.YieldNotEnabled();

        uint256 investable = previewInvestable(cid);
        if (assets > investable) revert TranspaChainErrors.ExceedsInvestable();

        // Pull liquid USDC from DonationVault into this contract
        IVaultYieldOps(vault).moveToYield(cid, assets);

        usdc.forceApprove(address(yieldVault), assets);
        uint256 shares = yieldVault.deposit(assets, address(this));
        usdc.forceApprove(address(yieldVault), 0);

        if (shares < minShares) revert TranspaChainErrors.SlippageTooHigh();

        Position storage pos = _positions[cid];
        pos.shares += shares;
        pos.principal += assets;
        totalAssignedShares += shares;

        _syncShareDust();

        emit YieldAllocated(cid, address(yieldVault), assets, shares);
    }

    /// @inheritdoc IYieldManager
    function redeemForLiquidity(uint256 campaignId, uint256 assets)
        external
        nonReentrant
        returns (uint256 got)
    {
        if (assets == 0) revert TranspaChainErrors.ZeroAmount();
        _assertRedeemCaller();

        Position storage pos = _positions[campaignId];
        if (pos.shares == 0) revert TranspaChainErrors.NothingToRedeem();

        uint256 value = yieldVault.previewRedeem(pos.shares);
        uint256 target = assets < value ? assets : value;

        // Respect withdraw cap via maxWithdraw
        uint256 maxW = yieldVault.maxWithdraw(address(this));
        // Cap to this campaign's pro-rata of manager balances if multiple campaigns share the vault
        // (each position is independent; we withdraw only up to this position's value).
        if (target > maxW) target = maxW;
        if (target == 0) revert TranspaChainErrors.InsufficientLiquidity();

        uint256 sharesNeeded = yieldVault.previewWithdraw(target);
        if (sharesNeeded > pos.shares) {
            // Fall back to redeem-by-shares for the whole position (floor)
            return _redeemShares(campaignId, pos.shares);
        }

        return _redeemShares(campaignId, sharesNeeded);
    }

    /// @inheritdoc IYieldManager
    function redeemAll(uint256 cid) external nonReentrant returns (uint256 got) {
        _assertRedeemCaller();
        Position storage pos = _positions[cid];
        if (pos.shares == 0) revert TranspaChainErrors.NothingToRedeem();

        uint256 maxR = yieldVault.maxRedeem(address(this));
        uint256 toBurn = pos.shares < maxR ? pos.shares : maxR;
        if (toBurn == 0) revert TranspaChainErrors.InsufficientLiquidity();

        return _redeemShares(cid, toBurn);
    }

    // ── Internals ────────────────────────────────────────────────────────────

    function _assertRedeemCaller() internal view {
        address ctrl = IVaultYieldOps(vault).disbursementController();
        if (
            msg.sender == owner() || msg.sender == vault || msg.sender == ctrl
                || operators[msg.sender]
        ) {
            return;
        }
        revert TranspaChainErrors.NotAuthorized();
    }

    function _redeemShares(uint256 cid, uint256 sharesBurned) internal returns (uint256 got) {
        Position storage pos = _positions[cid];
        uint256 sharesBefore = pos.shares;
        if (sharesBurned == 0 || sharesBurned > sharesBefore) {
            revert TranspaChainErrors.NothingToRedeem();
        }

        // principalOut = principal × sharesBurned / sharesBefore
        uint256 principalOut = (pos.principal * sharesBurned) / sharesBefore;

        got = yieldVault.redeem(sharesBurned, address(this), address(this));

        int256 realized = int256(got) - int256(principalOut);
        pos.shares = sharesBefore - sharesBurned;
        pos.principal -= principalOut;
        pos.realizedPnl += realized;
        totalAssignedShares -= sharesBurned;

        _syncShareDust();

        // Return USDC only to DonationVault
        usdc.forceApprove(vault, got);
        IVaultYieldOps(vault).receiveFromYield(cid, got);
        usdc.forceApprove(vault, 0);

        emit YieldRedeemed(cid, address(yieldVault), got, sharesBurned, realized);
    }

    function _syncShareDust() internal {
        uint256 held = yieldVault.balanceOf(address(this));
        if (held >= totalAssignedShares) {
            shareDust = held - totalAssignedShares;
        } else {
            // Should not happen under normal ops; surface as dust = 0 and leave invariant to tests.
            shareDust = 0;
        }
    }

    function _nextMilestoneReserve(uint256 cid) internal view returns (uint256) {
        ICharityCore.Campaign memory c = ICharityCore(charityCore).getCampaign(cid);
        if (c.completedMilestones >= c.totalMilestones) return 0;

        (
            string memory proofCID,
            uint256 releaseAmount,
            bool released,
            ,
            ,
        ) = IVaultYieldOps(vault).getMilestone(cid, c.completedMilestones);

        if (released) return 0;
        if (bytes(proofCID).length == 0) return 0;
        return releaseAmount;
    }
}
