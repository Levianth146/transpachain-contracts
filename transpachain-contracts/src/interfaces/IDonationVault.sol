// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IDonationVault
/// @notice Interface for ETH escrow and milestone-based fund release
interface IDonationVault {
    // ─────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────

    struct Milestone {
        string  proofCID;         // IPFS hash of evidence
        uint256 releaseAmount;    // ETH to release on approval (wei)
        bool    released;
        uint256 proposalId;       // Linked GovernanceDAO proposal
    }

    // ─────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────

    event DonationReceived(
        uint256 indexed campaignId,
        address indexed donor,
        uint256 amount
    );
    event MilestoneProofSubmitted(
        uint256 indexed campaignId,
        uint8   milestoneIndex,
        string  proofCID,
        uint256 proposalId
    );
    event FundsReleased(
        uint256 indexed campaignId,
        uint8   milestoneIndex,
        uint256 amount,
        address recipient
    );
    event RefundProcessed(
        uint256 indexed campaignId,
        address indexed donor,
        uint256 amount
    );

    // ─────────────────────────────────────────────
    // Write Functions
    // ─────────────────────────────────────────────

    /// @notice Donate ETH to a campaign — mints ImpactNFT on first donation
    function donate(uint256 campaignId) external payable;

    /// @notice Org submits IPFS proof for a milestone, auto-creates governance proposal
    function submitMilestoneProof(
        uint256 campaignId,
        uint8   milestoneIndex,
        string calldata proofCID
    ) external;

    /// @notice Release funds for an approved milestone — called ONLY by GovernanceDAO
    function releaseMilestoneFunds(uint256 campaignId, uint8 milestoneIndex) external;

    /// @notice Pull-pattern refund for donors when campaign fails or deadline passes
    function claimRefund(uint256 campaignId) external;

    // ─────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────

    function getDonorAmount(uint256 campaignId, address donor) external view returns (uint256);
    function getMilestone(uint256 campaignId, uint8 milestoneIndex) external view returns (Milestone memory);
    function getCampaignEscrowBalance(uint256 campaignId) external view returns (uint256);
    function getTotalEscrow() external view returns (uint256);
}
