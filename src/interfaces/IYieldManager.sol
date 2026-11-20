// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IYieldManager
/// @notice Stub interface for the T2 yield manager. Implementations redeem
///         yield-bearing positions back into the vault's liquid escrow.
interface IYieldManager {
    /// @notice Redeem at least `assets` worth of yield position for campaign `campaignId`.
    /// @return got The actual amount of base token redeemed and deposited back to vault.
    function redeemForLiquidity(uint256 campaignId, uint256 assets) external returns (uint256 got);

    /// @notice Current market value of all yield positions for `campaignId`.
    function positionValue(uint256 campaignId) external view returns (uint256);
}
