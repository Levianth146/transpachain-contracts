// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICharityCore
/// @notice Interface for campaign lifecycle management
interface ICharityCore {
    // ─────────────────────────────────────────────
    // Enums & Structs
    // ─────────────────────────────────────────────

    enum CampaignStatus { Active, Successful, Failed, Cancelled }

    struct Campaign {
        uint256 id;
        address orgAddress;
        string  metadataCID;       // IPFS CID for description/images
        uint256 goalAmount;        // ETH target (wei)
        uint256 raisedAmount;      // Total donated (wei)
        uint256 deadline;          // Unix timestamp
        CampaignStatus status;
        uint8   totalMilestones;
        uint8   completedMilestones;
    }

    // ─────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────

    event CampaignCreated(
        uint256 indexed campaignId,
        address indexed org,
        uint256 goal,
        uint256 deadline
    );
    event CampaignStatusChanged(
        uint256 indexed campaignId,
        CampaignStatus newStatus
    );
    event OrgVerified(address indexed org, bool verified);

    // ─────────────────────────────────────────────
    // Write Functions
    // ─────────────────────────────────────────────

    /// @notice Create a new charity campaign
    function createCampaign(
        string calldata metadataCID,
        uint256 goalAmount,
        uint256 deadline,
        uint8   totalMilestones
    ) external returns (uint256 campaignId);

    /// @notice Update campaign status (internal or admin)
    function updateCampaignStatus(uint256 campaignId, CampaignStatus newStatus) external;

    /// @notice Increment completed milestones counter
    function incrementMilestone(uint256 campaignId) external;

    /// @notice Verify / unverify a charity org (admin only)
    function setOrgVerified(address org, bool verified) external;

    // ─────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────

    function getCampaign(uint256 campaignId) external view returns (Campaign memory);
    function getCampaignsByOrg(address org) external view returns (uint256[] memory);
    function isOrgVerified(address org) external view returns (bool);
    function totalCampaigns() external view returns (uint256);
}
