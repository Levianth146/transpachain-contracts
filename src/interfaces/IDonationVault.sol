// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IDonationVault
/// @notice Interface for ETH/USDC escrow and milestone-based fund release
interface IDonationVault {

    event DonationReceived(uint256 indexed campaignId, address indexed donor, uint256 grossAmount, uint256 netAmount, uint256 fee, uint8 tokenType);
    event MilestoneProofSubmitted(uint256 indexed campaignId, uint8 milestoneIndex, string proofCID, uint256 proposalId);
    event FundsReleased(uint256 indexed campaignId, uint8 milestoneIndex, uint256 amount, address recipient);
    event RefundProcessed(uint256 indexed campaignId, address indexed donor, uint256 amount);
    event EmergencyRefundBatch(uint256 indexed campaignId, uint256 donorCount, uint256 totalAmount);
    event PlatformFeeCollected(uint256 indexed campaignId, uint256 feeAmount);
    event TreasuryUpdated(address newTreasury);
    event MaxRefundPeriodUpdated(uint256 newPeriod);
    /// @notice Emitted when DAO approves a milestone (approval only, no transfer)
    event MilestoneApproved(uint256 indexed campaignId, uint8 milestoneIndex, uint256 proposalId, uint256 amount);

    function donate(uint256 campaignId) external payable;
    function donateUSDC(uint256 campaignId, uint256 amount) external;
    function submitMilestoneProof(uint256 campaignId, uint8 milestoneIndex, string calldata proofCID) external;

    /// @dev V2: approval-only; called by GovernanceDAO.executeProposal
    function approveMilestone(uint256 campaignId, uint8 milestoneIndex, uint256 proposalId) external;

    /// @dev V2: actual transfer; called by DisbursementController (gated by Safe)
    function payoutMilestone(uint256 campaignId, uint8 milestoneIndex, address recipient, uint256 amount) external;

    /// @dev Deprecated in V2 — kept for compile compatibility; always reverts
    function releaseMilestoneFunds(uint256 campaignId, uint8 milestoneIndex, uint256 proposalId) external;

    function claimRefund(uint256 campaignId) external;
    function emergencyRefundBatch(uint256 campaignId, uint256 offset, uint256 limit) external;
    function setTreasury(address newTreasury) external;
    function setMaxRefundPeriod(uint256 newPeriod) external;
    function updatePlatformFee(uint256 newFeeBps) external;

    function getDonorAmount(uint256 campaignId, address donor) external view returns (uint256);
    function getCampaignEscrowBalance(uint256 campaignId) external view returns (uint256);
    function getTotalEscrow() external view returns (uint256);
    function getCharityDonors(uint256 campaignId) external view returns (address[] memory);
    function canRefund(uint256 campaignId, address donor) external view returns (bool eligible, uint256 amount, uint256 refundDeadline);
    function getRefundableAmount(uint256 campaignId, address donor) external view returns (uint256);
    function getTotalDeposited(uint256 campaignId) external view returns (uint256);
    function getRefundRatioBps(uint256 campaignId) external view returns (uint256);
    function hasActiveOrQueuedProposal(uint256 campaignId) external view returns (bool);

    /// @notice Address of the yield manager (address(0) until T2)
    function yieldManager() external view returns (address);
}
