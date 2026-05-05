// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/ICharityCore.sol";

/// @title CharityCore
/// @notice Manages charity campaign lifecycle
contract CharityCore is ICharityCore, Ownable, Pausable {
    // ─────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────

    uint256 private _campaignCounter;

    mapping(uint256 => Campaign) private _campaigns;
    mapping(address => uint256[]) private _orgCampaigns;
    mapping(address => bool)      private _verifiedOrgs;

    uint256 public constant MIN_CREATION_DEPOSIT = 0.001 ether;

    address public donationVault;
    address public governanceDAO;

    // ─────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────

    modifier onlyTrusted() {
        require(
            msg.sender == donationVault || msg.sender == governanceDAO || msg.sender == owner(),
            "CharityCore: not trusted"
        );
        _;
    }

    modifier onlyVerifiedOrg() {
        require(_verifiedOrgs[msg.sender], "CharityCore: org not verified");
        _;
    }

    modifier campaignExists(uint256 id) {
        require(id > 0 && id <= _campaignCounter, "CharityCore: not found");
        _;
    }

    // ─────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ─────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────

    function setTrustedContracts(address _vault, address _dao) external onlyOwner {
        donationVault = _vault;
        governanceDAO = _dao;
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────
    // Write
    // ─────────────────────────────────────────────

    /// @inheritdoc ICharityCore
    function createCampaign(
        string calldata metadataCID,
        uint256 goalAmount,
        uint256 deadline,
        uint8   totalMilestones
    ) external payable whenNotPaused onlyVerifiedOrg returns (uint256 campaignId) {
        require(msg.value >= MIN_CREATION_DEPOSIT, "CharityCore: deposit required");
        require(goalAmount > 0, "CharityCore: goal=0");
        require(deadline > block.timestamp, "CharityCore: deadline past");
        require(totalMilestones > 0 && totalMilestones <= 10, "CharityCore: bad milestones");
        require(bytes(metadataCID).length > 0, "CharityCore: empty CID");

        _campaignCounter++;
        campaignId = _campaignCounter;

        _campaigns[campaignId] = Campaign({
            id:                  campaignId,
            orgAddress:          msg.sender,
            metadataCID:         metadataCID,
            goalAmount:          goalAmount,
            raisedAmount:        0,
            deadline:            deadline,
            status:              CampaignStatus.Active,
            totalMilestones:     totalMilestones,
            completedMilestones: 0
        });

        _orgCampaigns[msg.sender].push(campaignId);
        emit CampaignCreated(campaignId, msg.sender, goalAmount, deadline);
    }

    /// @inheritdoc ICharityCore
    function updateCampaignStatus(
        uint256 campaignId,
        CampaignStatus newStatus
    ) external onlyTrusted campaignExists(campaignId) {
        _campaigns[campaignId].status = newStatus;
        emit CampaignStatusChanged(campaignId, newStatus);
    }

    /// @inheritdoc ICharityCore
    function incrementMilestone(uint256 campaignId) external onlyTrusted campaignExists(campaignId) {
        Campaign storage c = _campaigns[campaignId];
        c.completedMilestones++;
        if (c.completedMilestones == c.totalMilestones) {
            c.status = CampaignStatus.Successful;
            emit CampaignStatusChanged(campaignId, CampaignStatus.Successful);
        }
    }

    /// @inheritdoc ICharityCore
    function setOrgVerified(address org, bool verified) external onlyOwner {
        _verifiedOrgs[org] = verified;
        emit OrgVerified(org, verified);
    }

    /// @notice Called by DonationVault to track raised amount
    function addRaisedAmount(uint256 campaignId, uint256 amount)
        external onlyTrusted campaignExists(campaignId)
    {
        _campaigns[campaignId].raisedAmount += amount;
    }

    // ─────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────

    function getCampaign(uint256 id) external view campaignExists(id) returns (Campaign memory) {
        return _campaigns[id];
    }

    function getCampaignsByOrg(address org) external view returns (uint256[] memory) {
        return _orgCampaigns[org];
    }

    function isOrgVerified(address org) external view returns (bool) {
        return _verifiedOrgs[org];
    }

    function totalCampaigns() external view returns (uint256) {
        return _campaignCounter;
    }
}
