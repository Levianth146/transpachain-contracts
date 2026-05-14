// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IDonationVault
/// @notice Interface for ETH/USDC escrow and milestone-based fund release
interface IDonationVault {

    event DonationReceived(uint256 indexed campaignId, address indexed donor, uint256 amount, uint8 tokenType);
    event MilestoneProofSubmitted(uint256 indexed campaignId, uint8 milestoneIndex, string proofCID, uint256 proposalId);
    event FundsReleased(uint256 indexed campaignId, uint8 milestoneIndex, uint256 amount, address recipient);
    event RefundProcessed(uint256 indexed campaignId, address indexed donor, uint256 amount);
    event EmergencyRefundBatch(uint256 indexed campaignId, uint256 donorCount, uint256 totalAmount);
    event PlatformFeeCollected(uint256 indexed campaignId, uint256 feeAmount);
    event TreasuryUpdated(address newTreasury);
    event MaxRefundPeriodUpdated(uint256 newPeriod);

    function donate(uint256 campaignId) external payable;
    function donateUSDC(uint256 campaignId, uint256 amount) external;
    function submitMilestoneProof(uint256 campaignId, uint8 milestoneIndex, string calldata proofCID) external;
    function releaseMilestoneFunds(uint256 campaignId, uint8 milestoneIndex) external;
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
}
