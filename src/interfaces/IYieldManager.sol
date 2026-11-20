// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IYieldManager
/// @notice Module C — per-campaign USDC yield positions via an approved ERC-4626 vault.
///         The only USDC outflow from YieldManager is back to DonationVault.
interface IYieldManager {
    struct Position {
        uint256 shares;
        uint256 principal;
        int256  realizedPnl;
        bool    enabled;
    }

    struct Policy {
        uint16  minLiquidReserveBps;
        uint16  maxAllocationBps;
        uint256 maxAssetsPerTx;
        bool    paused;
    }

    event YieldAllocated(
        uint256 indexed cid,
        address indexed vault,
        uint256 assets,
        uint256 shares
    );

    event YieldRedeemed(
        uint256 indexed cid,
        address indexed vault,
        uint256 assets,
        uint256 shares,
        int256 realizedPnl
    );

    event YieldEnabledUpdated(uint256 indexed cid, bool enabled);
    event PolicyUpdated(
        uint16 minLiquidReserveBps,
        uint16 maxAllocationBps,
        uint256 maxAssetsPerTx,
        bool paused
    );

    /// @notice Enable/disable yield for a USDC campaign (org of campaign or admin).
    function setYieldEnabled(uint256 cid, bool on) external;

    /// @notice Assets that can still be allocated under current policy caps.
    function previewInvestable(uint256 cid) external view returns (uint256);

    /// @notice Move liquid escrow → ERC-4626 for `cid`. Admin/operator only.
    function allocate(uint256 cid, uint256 assets, uint256 minShares) external;

    /// @notice Redeem at least `assets` of yield back to DonationVault liquid escrow.
    /// @return got Actual underlying returned to the vault.
    function redeemForLiquidity(uint256 campaignId, uint256 assets) external returns (uint256 got);

    /// @notice Redeem all shares for `cid` (respecting vault withdraw caps; may be partial).
    function redeemAll(uint256 cid) external returns (uint256 got);

    /// @notice Current market value of the campaign position (`previewRedeem(shares)`).
    function positionValue(uint256 cid) external view returns (uint256);

    function getPosition(uint256 cid) external view returns (Position memory);
    function policy() external view returns (Policy memory);
}
