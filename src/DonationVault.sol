// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IDonationVault.sol";
import "./interfaces/ICharityCore.sol";
import "./interfaces/IGovernanceDAO.sol";
import "./interfaces/IImpactNFT.sol";

/// @title DonationVault
/// @notice ETH escrow with milestone-based release and pull-pattern refunds
contract DonationVault is IDonationVault, ReentrancyGuard, Ownable {

    ICharityCore   public charityCore;
    IGovernanceDAO public governanceDAO;
    IImpactNFT     public impactNFT;

    mapping(uint256 => mapping(address => uint256)) private _donorBalances;
    mapping(uint256 => uint256)                     private _escrowBalances;
    mapping(uint256 => mapping(uint8 => Milestone)) private _milestones;
    uint256 private _totalEscrow;

    modifier onlyGovernanceDAO() {
        require(msg.sender == address(governanceDAO), "Vault: only DAO");
        _;
    }

    constructor(address initialOwner, address _core, address _dao, address _nft)
        Ownable(initialOwner)
    {
        charityCore   = ICharityCore(_core);
        governanceDAO = IGovernanceDAO(_dao);
        impactNFT     = IImpactNFT(_nft);
    }

    function donate(uint256 campaignId) external payable nonReentrant {
        require(msg.value > 0, "Vault: amount=0");
        ICharityCore.Campaign memory c = charityCore.getCampaign(campaignId);
        require(c.status == ICharityCore.CampaignStatus.Active, "Vault: not active");
        require(block.timestamp < c.deadline, "Vault: expired");

        bool first = _donorBalances[campaignId][msg.sender] == 0;
        _donorBalances[campaignId][msg.sender] += msg.value;
        _escrowBalances[campaignId]            += msg.value;
        _totalEscrow                           += msg.value;
        charityCore.addRaisedAmount(campaignId, msg.value);

        if (first) {
            impactNFT.mintImpactNFT(msg.sender, campaignId, _tier(msg.value), msg.value, c.metadataCID);
        }
        emit DonationReceived(campaignId, msg.sender, msg.value);
    }

    function submitMilestoneProof(uint256 campaignId, uint8 idx, string calldata proofCID)
        external nonReentrant
    {
        ICharityCore.Campaign memory c = charityCore.getCampaign(campaignId);
        require(msg.sender == c.orgAddress, "Vault: not org");
        require(c.status == ICharityCore.CampaignStatus.Active, "Vault: not active");
        require(bytes(proofCID).length > 0, "Vault: empty proof");
        Milestone storage m = _milestones[campaignId][idx];
        require(!m.released && m.proposalId == 0, "Vault: invalid state");

        uint256 remaining = c.totalMilestones - c.completedMilestones;
        m.releaseAmount = remaining > 0 ? _escrowBalances[campaignId] / remaining : 0;
        m.proofCID      = proofCID;
        m.proposalId    = governanceDAO.createProposal(campaignId, idx, proofCID);
        emit MilestoneProofSubmitted(campaignId, idx, proofCID, m.proposalId);
    }

    function releaseMilestoneFunds(uint256 campaignId, uint8 idx)
        external nonReentrant onlyGovernanceDAO
    {
        Milestone storage m = _milestones[campaignId][idx];
        require(!m.released && m.releaseAmount > 0, "Vault: invalid");
        require(_escrowBalances[campaignId] >= m.releaseAmount, "Vault: insufficient");

        m.released = true;
        _escrowBalances[campaignId] -= m.releaseAmount;
        _totalEscrow                -= m.releaseAmount;
        charityCore.incrementMilestone(campaignId);

        address org = charityCore.getCampaign(campaignId).orgAddress;
        (bool ok,)  = org.call{value: m.releaseAmount}("");
        require(ok, "Vault: transfer failed");
        emit FundsReleased(campaignId, idx, m.releaseAmount, org);
    }

    function claimRefund(uint256 campaignId) external nonReentrant {
        ICharityCore.Campaign memory c = charityCore.getCampaign(campaignId);
        require(
            c.status == ICharityCore.CampaignStatus.Failed || block.timestamp > c.deadline,
            "Vault: not refundable"
        );
        uint256 amount = _donorBalances[campaignId][msg.sender];
        require(amount > 0, "Vault: nothing to refund");

        _donorBalances[campaignId][msg.sender] = 0;
        _escrowBalances[campaignId]            -= amount;
        _totalEscrow                           -= amount;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "Vault: refund failed");
        emit RefundProcessed(campaignId, msg.sender, amount);
    }

    function getDonorAmount(uint256 cid, address d) external view returns (uint256) { return _donorBalances[cid][d]; }
    function getMilestone(uint256 cid, uint8 i) external view returns (Milestone memory) { return _milestones[cid][i]; }
    function getCampaignEscrowBalance(uint256 cid) external view returns (uint256) { return _escrowBalances[cid]; }
    function getTotalEscrow() external view returns (uint256) { return _totalEscrow; }

    function _tier(uint256 amt) internal pure returns (IImpactNFT.DonorTier) {
        if (amt >= 0.1 ether)  return IImpactNFT.DonorTier.Gold;
        if (amt >= 0.01 ether) return IImpactNFT.DonorTier.Silver;
        return IImpactNFT.DonorTier.Bronze;
    }
}
