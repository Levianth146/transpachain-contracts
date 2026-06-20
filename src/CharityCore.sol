// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/ICharityCore.sol";

/// @title CharityCore
/// @notice Manages charity campaign lifecycle
contract CharityCore is ICharityCore, AccessControl, Pausable {

    uint256 private _campaignCounter;

    bytes32 public constant ADMIN_ROLE    = keccak256("ADMIN_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant ORG_ROLE      = keccak256("ORG_ROLE");

    mapping(uint256 => Campaign)   private _campaigns;
    mapping(address => uint256[])  private _orgCampaigns;

    uint256 public constant MIN_CREATION_DEPOSIT = 0.001 ether;
    uint256 public constant MAX_EXTENSION        = 30 days;

    address public donationVault;
    address public governanceDAO;

    modifier onlyTrusted() {
        require(
            msg.sender == donationVault ||
            msg.sender == governanceDAO ||
            hasRole(ADMIN_ROLE, msg.sender),
            "CharityCore: not trusted"
        );
        _;
    }

    modifier onlyVerifiedOrg() {
        require(hasRole(ORG_ROLE, msg.sender), "CharityCore: org not verified");
        _;
    }

    modifier campaignExists(uint256 id) {
        require(id > 0 && id <= _campaignCounter, "CharityCore: not found");
        _;
    }

    constructor(address initialOwner) {
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(ADMIN_ROLE,         initialOwner);
        _grantRole(VERIFIER_ROLE,      initialOwner);
    }

    function setTrustedContracts(address _vault, address _dao) external onlyRole(ADMIN_ROLE) {
        donationVault = _vault;
        governanceDAO = _dao;
    }

    function pause()   external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    function withdrawDeposits() external onlyRole(ADMIN_ROLE) {
        uint256 balance = address(this).balance;
        require(balance > 0, "Nothing to withdraw");
        (bool ok,) = msg.sender.call{value: balance}("");
        require(ok, "Transfer failed");
    }

    function createCampaign(
        string calldata metadataCID,
        uint256 goalAmount,
        uint256 deadline,
        uint8   totalMilestones,
        PaymentToken paymentToken,
        string calldata category
    ) external payable whenNotPaused onlyVerifiedOrg returns (uint256 campaignId) {
        require(msg.value >= MIN_CREATION_DEPOSIT, "CharityCore: deposit required");
        require(goalAmount > 0,                    "CharityCore: goal=0");
        require(deadline > block.timestamp,        "CharityCore: deadline past");
        require(totalMilestones > 0 && totalMilestones <= 10, "CharityCore: bad milestones");
        require(bytes(metadataCID).length > 0,     "CharityCore: empty CID");

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
            completedMilestones: 0,
            paymentToken:        paymentToken,
            category:            category,
            createdAt:           block.timestamp,
            cancelledAt:         0
        });

        _orgCampaigns[msg.sender].push(campaignId);
        emit CampaignCreated(campaignId, msg.sender, goalAmount, deadline);
    }

    function updateCampaignStatus(uint256 campaignId, CampaignStatus newStatus)
        external onlyTrusted campaignExists(campaignId)
    {
        _campaigns[campaignId].status = newStatus;
        emit CampaignStatusChanged(campaignId, newStatus);
    }

    function updateCampaignInfo(uint256 campaignId, string calldata newCID)
        external campaignExists(campaignId)
    {
        Campaign storage c = _campaigns[campaignId];
        require(msg.sender == c.orgAddress,            "CharityCore: not org");
        require(c.status == CampaignStatus.Active,     "CharityCore: not active");
        require(bytes(newCID).length > 0,              "CharityCore: empty CID");
        c.metadataCID = newCID;
    }

    function incrementMilestone(uint256 campaignId)
        external onlyTrusted campaignExists(campaignId)
    {
        Campaign storage c = _campaigns[campaignId];
        c.completedMilestones++;
        if (c.completedMilestones == c.totalMilestones) {
            c.status = CampaignStatus.Successful;
            emit CampaignStatusChanged(campaignId, CampaignStatus.Successful);
        }
    }

    function verifyOrg(address org) external onlyRole(VERIFIER_ROLE) {
        require(!hasRole(ORG_ROLE, org), "Already verified");
        _grantRole(ORG_ROLE, org);
        emit OrgVerified(org, true);
    }

    function revokeOrg(address org) external onlyRole(VERIFIER_ROLE) {
        require(hasRole(ORG_ROLE, org), "Not verified");
        _revokeRole(ORG_ROLE, org);
        emit OrgVerified(org, false);
    }

    function addRaisedAmount(uint256 campaignId, uint256 amount)
        external onlyTrusted campaignExists(campaignId)
    {
        _campaigns[campaignId].raisedAmount += amount;
    }

    function cancelCampaign(uint256 campaignId) external campaignExists(campaignId) {
        Campaign storage c = _campaigns[campaignId];
        require(msg.sender == c.orgAddress,        "CharityCore: not org");
        require(c.status == CampaignStatus.Active, "CharityCore: not active");
        c.status      = CampaignStatus.Cancelled;
        c.cancelledAt = block.timestamp;
        emit CampaignCancelled(campaignId, msg.sender, block.timestamp);
    }

    function adminCancelCampaign(uint256 campaignId)
        external onlyRole(ADMIN_ROLE) campaignExists(campaignId)
    {
        Campaign storage c = _campaigns[campaignId];
        require(c.status == CampaignStatus.Active, "CharityCore: not active");
        c.status      = CampaignStatus.Cancelled;
        c.cancelledAt = block.timestamp;
        emit CampaignCancelled(campaignId, msg.sender, block.timestamp);
    }

    function finalizeCampaign(uint256 campaignId) external campaignExists(campaignId) {
        Campaign storage c = _campaigns[campaignId];
        require(c.status == CampaignStatus.Active, "CharityCore: not active");
        bool goalReached = c.raisedAmount >= c.goalAmount;
        bool expired     = block.timestamp > c.deadline;
        require(goalReached || expired, "CharityCore: cannot finalize");
        CampaignStatus finalStatus = goalReached
            ? CampaignStatus.Successful
            : CampaignStatus.Failed;
        c.status = finalStatus;
        emit CampaignFinalized(campaignId, finalStatus);
    }

    /// @notice Whether an active campaign may be finalized (goal met or deadline passed).
    function canFinalize(uint256 campaignId)
        external view campaignExists(campaignId)
        returns (bool eligible, bool goalReached, bool expired)
    {
        Campaign storage c = _campaigns[campaignId];
        if (c.status != CampaignStatus.Active) return (false, false, false);
        goalReached = c.raisedAmount >= c.goalAmount;
        expired     = block.timestamp > c.deadline;
        eligible    = goalReached || expired;
    }

    function extendDeadline(uint256 campaignId, uint256 newDeadline)
        external campaignExists(campaignId)
    {
        Campaign storage c = _campaigns[campaignId];
        require(msg.sender == c.orgAddress,                    "CharityCore: not org");
        require(c.status == CampaignStatus.Active,             "CharityCore: not active");
        require(newDeadline > c.deadline,                      "CharityCore: must extend");
        require(newDeadline <= c.deadline + MAX_EXTENSION,     "CharityCore: exceeds max");
        c.deadline = newDeadline;
        emit DeadlineExtended(campaignId, newDeadline);
    }

    function getCampaign(uint256 id) external view campaignExists(id) returns (Campaign memory) {
        return _campaigns[id];
    }

    function getCampaignsByOrg(address org) external view returns (uint256[] memory) {
        return _orgCampaigns[org];
    }

    function isOrgVerified(address org) external view returns (bool) {
        return hasRole(ORG_ROLE, org);
    }

    function totalCampaigns() external view returns (uint256) {
        return _campaignCounter;
    }

    function getCharityProgress(uint256 campaignId)
        external view campaignExists(campaignId)
        returns (uint256 raised, uint256 goal, uint256 progressBps,
                 uint256 deadline, bool isExpired, uint256 timeLeft)
    {
        Campaign storage c = _campaigns[campaignId];
        raised      = c.raisedAmount;
        goal        = c.goalAmount;
        progressBps = goal > 0 ? (raised * 10000 / goal) : 0;
        deadline    = c.deadline;
        isExpired   = block.timestamp > c.deadline;
        timeLeft    = isExpired ? 0 : c.deadline - block.timestamp;
    }

    function getCharities(uint256 fromId, uint256 toId)
        external view returns (Campaign[] memory)
    {
        require(fromId >= 1,                   "CharityCore: invalid fromId");
        require(toId <= _campaignCounter,      "CharityCore: invalid toId");
        require(fromId <= toId,                "CharityCore: invalid range");
        Campaign[] memory result = new Campaign[](toId - fromId + 1);
        for (uint256 i = fromId; i <= toId; i++) {
            result[i - fromId] = _campaigns[i];
        }
        return result;
    }
}
