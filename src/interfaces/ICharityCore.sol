// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICharityCore {

    enum CampaignStatus { Active, Successful, Failed, Cancelled }
    enum PaymentToken   { ETH, USDC }

    struct Campaign {
        uint256        id;
        address        orgAddress;
        string         metadataCID;
        uint256        goalAmount;
        uint256        raisedAmount;
        uint256        deadline;
        CampaignStatus status;
        uint8          totalMilestones;
        uint8          completedMilestones;
        PaymentToken   paymentToken;
        string         category;
        uint256        createdAt;
        uint256        cancelledAt;
    }

    event CampaignCreated(uint256 indexed campaignId, address indexed org, uint256 goal, uint256 deadline);
    event CampaignStatusChanged(uint256 indexed campaignId, CampaignStatus newStatus);
    event OrgVerified(address indexed org, bool verified);
    event CampaignCancelled(uint256 indexed campaignId, address indexed cancelledBy, uint256 cancelledAt);
    event DeadlineExtended(uint256 indexed campaignId, uint256 newDeadline);
    event CampaignFinalized(uint256 indexed campaignId, CampaignStatus finalStatus);

    function createCampaign(string calldata metadataCID, uint256 goalAmount, uint256 deadline, uint8 totalMilestones, PaymentToken paymentToken, string calldata category) external payable returns (uint256 campaignId);
    function updateCampaignStatus(uint256 campaignId, CampaignStatus newStatus) external;
    function incrementMilestone(uint256 campaignId) external;
    function addRaisedAmount(uint256 campaignId, uint256 amount) external;
    function verifyOrg(address org) external;
    function revokeOrg(address org) external;
    function cancelCampaign(uint256 campaignId) external;
    function adminCancelCampaign(uint256 campaignId) external;
    function finalizeCampaign(uint256 campaignId) external;
    function extendDeadline(uint256 campaignId, uint256 newDeadline) external;
    function updateCampaignInfo(uint256 campaignId, string calldata newCID) external;

    function getCampaign(uint256 campaignId) external view returns (Campaign memory);
    function getCampaignsByOrg(address org) external view returns (uint256[] memory);
    function isOrgVerified(address org) external view returns (bool);
    function totalCampaigns() external view returns (uint256);
    function getCharityProgress(uint256 campaignId) external view returns (uint256 raised, uint256 goal, uint256 progressBps, uint256 deadline, bool isExpired, uint256 timeLeft);
    function getCharities(uint256 fromId, uint256 toId) external view returns (Campaign[] memory);
}
