// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICharityCore {
    enum CampaignStatus { Active, Successful, Failed, Cancelled }
    struct Campaign {
        uint256 id;
        address orgAddress;
        string  metadataCID;
        uint256 goalAmount;
        uint256 raisedAmount;
        uint256 deadline;
        CampaignStatus status;
        uint8   totalMilestones;
        uint8   completedMilestones;
    }
    event CampaignCreated(uint256 indexed campaignId, address indexed org, uint256 goal, uint256 deadline);
    event CampaignStatusChanged(uint256 indexed campaignId, CampaignStatus newStatus);
    event OrgVerified(address indexed org, bool verified);
    function createCampaign(string calldata metadataCID, uint256 goalAmount, uint256 deadline, uint8 totalMilestones) external payable returns (uint256 campaignId);
    function updateCampaignStatus(uint256 campaignId, CampaignStatus newStatus) external;
    function incrementMilestone(uint256 campaignId) external;
    function setOrgVerified(address org, bool verified) external;
    function addRaisedAmount(uint256 campaignId, uint256 amount) external;
    function getCampaign(uint256 campaignId) external view returns (Campaign memory);
    function getCampaignsByOrg(address org) external view returns (uint256[] memory);
    function isOrgVerified(address org) external view returns (bool);
    function totalCampaigns() external view returns (uint256);
}
