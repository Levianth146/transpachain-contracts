// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IDonationVault.sol";
import "./interfaces/ICharityCore.sol";
import "./interfaces/IGovernanceDAO.sol";
import "./interfaces/IImpactNFT.sol";
import { TranspaChainErrors } from "./Errors.sol";

/// @title DonationVault
/// @notice ETH/USDC escrow with milestone-based release and pull-pattern refunds
/// @dev Financial state (raised, escrow, donorBalance, refunds, voting power) uses netAmount.
///      NFT tiers may use grossAmount for donor recognition.
contract DonationVault is IDonationVault, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    struct Milestone {
        string  proofCID;
        uint256 releaseAmount;
        bool    released;
        uint256 proposalId;
    }

    struct DonorInfo {
        uint256 totalDonated;
        uint256 donationCount;
        uint256 lastDonatedAt;
    }

    ICharityCore   public charityCore;
    IGovernanceDAO public governanceDAO;
    IImpactNFT     public impactNFT;
    IERC20         public usdcToken;

    address public treasury;
    uint256 public platformFeeBps  = 100;
    uint256 public constant MAX_FEE = 500;
    uint256 public maxRefundPeriod  = 90 days;

    mapping(uint256 => mapping(address => uint256)) private _donorBalances;
    mapping(uint256 => uint256)                     private _escrowBalances;
    mapping(uint256 => mapping(uint8 => Milestone)) private _milestones;
    uint256 private _totalEscrow;
  mapping(uint256 => uint256) private _totalDeposited;
    mapping(uint256 => uint256) private _remainingRefundWeight;

    mapping(uint256 => mapping(address => DonorInfo)) private _donorInfo;
    mapping(uint256 => address[])                     private _donorList;
    mapping(uint256 => mapping(address => bool))      private _isDonor;

    uint256 public totalDonationsAllTime;
    mapping(address => uint256) public userTotalDonated;

    modifier onlyGovernanceDAO() {
        require(msg.sender == address(governanceDAO), "Vault: only DAO");
        _;
    }

    constructor(
        address initialOwner,
        address _core,
        address _dao,
        address _nft,
        address _usdc
    ) Ownable(initialOwner) {
        charityCore   = ICharityCore(_core);
        governanceDAO = IGovernanceDAO(_dao);
        impactNFT     = IImpactNFT(_nft);
        usdcToken     = IERC20(_usdc);
        treasury      = initialOwner;
    }

    function donate(uint256 campaignId) external payable nonReentrant {
        if (msg.value == 0) revert TranspaChainErrors.ZeroAmount();
        ICharityCore.Campaign memory c = charityCore.getCampaign(campaignId);
        require(c.status == ICharityCore.CampaignStatus.Active, "Vault: not active");
        require(block.timestamp < c.deadline, "Vault: expired");
        require(c.raisedAmount < c.goalAmount, "Vault: goal reached");
        require(c.paymentToken == ICharityCore.PaymentToken.ETH, "Vault: not ETH campaign");
        require(!governanceDAO.hasActiveOrQueuedProposal(campaignId), "Vault: proposal active");

        bool first        = _donorBalances[campaignId][msg.sender] == 0;
        uint256 fee       = (msg.value * platformFeeBps) / 10_000;
        uint256 netAmount = msg.value - fee;

        _donorBalances[campaignId][msg.sender] += netAmount;
        _escrowBalances[campaignId]            += netAmount;
        _totalEscrow                           += netAmount;
        _totalDeposited[campaignId]            += netAmount;
        _remainingRefundWeight[campaignId]     += netAmount;

        if (fee > 0 && treasury != address(0)) {
            (bool ok,) = treasury.call{value: fee}("");
            require(ok, "Vault: fee failed");
            emit PlatformFeeCollected(campaignId, fee);
        }

        charityCore.addRaisedAmount(campaignId, netAmount);
        _recordDonor(campaignId, msg.sender, msg.value);

        if (first) {
            impactNFT.mintImpactNFT(
                msg.sender,
                campaignId,
                _tierETH(msg.value),
                msg.value,
                "",
                uint8(ICharityCore.PaymentToken.ETH)
            );
        } else {
            _syncDonorNFT(msg.sender, campaignId, netAmount);
        }

        emit DonationReceived(
            campaignId,
            msg.sender,
            msg.value,
            netAmount,
            fee,
            uint8(ICharityCore.PaymentToken.ETH)
        );
    }

    function donateUSDC(uint256 campaignId, uint256 amount) external nonReentrant {
        if (amount == 0) revert TranspaChainErrors.ZeroAmount();
        ICharityCore.Campaign memory c = charityCore.getCampaign(campaignId);
        require(c.status == ICharityCore.CampaignStatus.Active, "Vault: not active");
        require(block.timestamp < c.deadline, "Vault: expired");
        require(c.raisedAmount < c.goalAmount, "Vault: goal reached");
        require(c.paymentToken == ICharityCore.PaymentToken.USDC, "Vault: not USDC campaign");
        require(!governanceDAO.hasActiveOrQueuedProposal(campaignId), "Vault: proposal active");

        bool first        = _donorBalances[campaignId][msg.sender] == 0;
        uint256 fee       = (amount * platformFeeBps) / 10_000;
        uint256 netAmount = amount - fee;

        usdcToken.safeTransferFrom(msg.sender, address(this), amount);

        if (fee > 0 && treasury != address(0)) {
            usdcToken.safeTransfer(treasury, fee);
            emit PlatformFeeCollected(campaignId, fee);
        }

        _donorBalances[campaignId][msg.sender] += netAmount;
        _escrowBalances[campaignId]            += netAmount;
        _totalEscrow                           += netAmount;
        _totalDeposited[campaignId]            += netAmount;
        _remainingRefundWeight[campaignId]     += netAmount;

        charityCore.addRaisedAmount(campaignId, netAmount);
        _recordDonor(campaignId, msg.sender, amount);

        if (first) {
            impactNFT.mintImpactNFT(
                msg.sender,
                campaignId,
                _tierUSDC(amount),
                amount,
                "",
                uint8(ICharityCore.PaymentToken.USDC)
            );
        } else {
            _syncDonorNFT(msg.sender, campaignId, netAmount);
        }

        emit DonationReceived(
            campaignId,
            msg.sender,
            amount,
            netAmount,
            fee,
            uint8(ICharityCore.PaymentToken.USDC)
        );
    }

    function submitMilestoneProof(uint256 campaignId, uint8 idx, string calldata proofCID)
        external
        nonReentrant
    {
        ICharityCore.Campaign memory c = charityCore.getCampaign(campaignId);
        require(msg.sender == c.orgAddress, "Vault: not org");
        require(c.status == ICharityCore.CampaignStatus.Active, "Vault: not active");
        require(bytes(proofCID).length > 0, "Vault: empty proof");
        require(idx < c.totalMilestones, "Vault: invalid milestone");
        require(idx == c.completedMilestones, "Vault: wrong order");
        require(_escrowBalances[campaignId] > 0, "Vault: empty escrow");

        Milestone storage m = _milestones[campaignId][idx];
        require(!m.released, "Vault: already released");
        if (m.proposalId != 0) {
            IGovernanceDAO.ProposalState state = governanceDAO.getProposalState(m.proposalId);
            require(
                state == IGovernanceDAO.ProposalState.Defeated ||
                    state == IGovernanceDAO.ProposalState.Cancelled,
                "Vault: proposal pending"
            );
        }

        uint256 remaining = c.totalMilestones - c.completedMilestones;
        m.releaseAmount   = remaining > 0 ? _escrowBalances[campaignId] / remaining : 0;
        m.proofCID        = proofCID;
        m.proposalId      = governanceDAO.createProposal(campaignId, idx, proofCID);

        emit MilestoneProofSubmitted(campaignId, idx, proofCID, m.proposalId);
    }

    function releaseMilestoneFunds(uint256 campaignId, uint8 idx, uint256 proposalId)
        external
        nonReentrant
        onlyGovernanceDAO
    {
        ICharityCore.Campaign memory campaign = charityCore.getCampaign(campaignId);
        require(campaign.status == ICharityCore.CampaignStatus.Active, "Vault: campaign not active");
        require(idx < campaign.totalMilestones, "Vault: invalid milestone");

        Milestone storage m = _milestones[campaignId][idx];
        require(m.proposalId == proposalId, "Vault: wrong proposal");
        require(!m.released, "Vault: already released");
        require(idx == campaign.completedMilestones, "Vault: wrong order");
        require(bytes(m.proofCID).length > 0, "Vault: no proof");

        uint256 releaseAmount = m.releaseAmount;
        require(releaseAmount > 0, "Vault: zero release");
        require(_escrowBalances[campaignId] >= releaseAmount, "Vault: insufficient");

        m.released = true;
        _escrowBalances[campaignId] -= releaseAmount;
        _totalEscrow                -= releaseAmount;
        charityCore.incrementMilestone(campaignId);

        address org = campaign.orgAddress;
        if (campaign.paymentToken == ICharityCore.PaymentToken.USDC) {
            usdcToken.safeTransfer(org, releaseAmount);
        } else {
            (bool ok,) = org.call{value: releaseAmount}("");
            require(ok, "Vault: transfer failed");
        }
        emit FundsReleased(campaignId, idx, releaseAmount, org);
    }

    function claimRefund(uint256 campaignId) external nonReentrant {
        ICharityCore.Campaign memory c = charityCore.getCampaign(campaignId);
        require(
            c.status == ICharityCore.CampaignStatus.Failed ||
                c.status == ICharityCore.CampaignStatus.Cancelled,
            "Vault: not refundable"
        );

        uint256 donorBalance = _donorBalances[campaignId][msg.sender];
        require(donorBalance > 0, "Vault: nothing to refund");

        uint256 refundAmount = _calculateRefundAmount(campaignId, msg.sender);
        require(refundAmount > 0, "Vault: nothing to refund");

        _donorBalances[campaignId][msg.sender] = 0;
        _remainingRefundWeight[campaignId]      -= donorBalance;
        _escrowBalances[campaignId]            -= refundAmount;
        _totalEscrow                           -= refundAmount;

        if (c.paymentToken == ICharityCore.PaymentToken.USDC) {
            usdcToken.safeTransfer(msg.sender, refundAmount);
        } else {
            (bool ok,) = msg.sender.call{value: refundAmount}("");
            require(ok, "Vault: refund failed");
        }
        emit RefundProcessed(campaignId, msg.sender, refundAmount);
    }

    function emergencyRefundBatch(uint256 campaignId, uint256 offset, uint256 limit)
        external
        onlyOwner
        nonReentrant
    {
        ICharityCore.Campaign memory c = charityCore.getCampaign(campaignId);
        require(
            c.status == ICharityCore.CampaignStatus.Failed ||
                c.status == ICharityCore.CampaignStatus.Cancelled,
            "Vault: not refundable"
        );

        address[] storage donorList = _donorList[campaignId];
        uint256 end = offset + limit;
        if (end > donorList.length) end = donorList.length;

        uint256 count;
        uint256 totalRefunded;

        for (uint256 i = offset; i < end; i++) {
            address donor = donorList[i];
            uint256 donorBalance = _donorBalances[campaignId][donor];
            if (donorBalance == 0) continue;

            uint256 refundAmount = _calculateRefundAmount(campaignId, donor);
            if (refundAmount == 0) continue;

            _donorBalances[campaignId][donor] = 0;
            _remainingRefundWeight[campaignId] -= donorBalance;
            _escrowBalances[campaignId]       -= refundAmount;
            _totalEscrow                      -= refundAmount;

            if (c.paymentToken == ICharityCore.PaymentToken.USDC) {
                usdcToken.safeTransfer(donor, refundAmount);
            } else {
                (bool ok,) = donor.call{value: refundAmount}("");
                require(ok, "Vault: refund failed");
            }
            emit RefundProcessed(campaignId, donor, refundAmount);
            count++;
            totalRefunded += refundAmount;
        }
        emit EmergencyRefundBatch(campaignId, count, totalRefunded);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Vault: zero address");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setMaxRefundPeriod(uint256 newPeriod) external onlyOwner {
        require(newPeriod > 0, "Vault: zero period");
        maxRefundPeriod = newPeriod;
        emit MaxRefundPeriodUpdated(newPeriod);
    }

    function updatePlatformFee(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE, "Vault: fee too high");
        platformFeeBps = newFeeBps;
    }

    function getDonorAmount(uint256 cid, address d) external view returns (uint256) {
        return _donorBalances[cid][d];
    }

    function getDonorInfo(uint256 cid, address donor) external view returns (DonorInfo memory) {
        return _donorInfo[cid][donor];
    }

    function getMilestone(uint256 cid, uint8 i) external view returns (Milestone memory) {
        return _milestones[cid][i];
    }

    function getCampaignEscrowBalance(uint256 cid) external view returns (uint256) {
        return _escrowBalances[cid];
    }

    function getTotalEscrow() external view returns (uint256) {
        return _totalEscrow;
    }

    function getCharityDonors(uint256 cid) external view returns (address[] memory) {
        return _donorList[cid];
    }

    function getTotalDeposited(uint256 campaignId) external view returns (uint256) {
        return _totalDeposited[campaignId];
    }

    function getRefundableAmount(uint256 campaignId, address donor) external view returns (uint256) {
        ICharityCore.Campaign memory c = charityCore.getCampaign(campaignId);
        if (
            c.status != ICharityCore.CampaignStatus.Failed &&
                c.status != ICharityCore.CampaignStatus.Cancelled
        ) {
            return 0;
        }
        return _calculateRefundAmount(campaignId, donor);
    }

    function getRefundRatioBps(uint256 campaignId) external view returns (uint256) {
        uint256 escrow = _escrowBalances[campaignId];
        uint256 weight = _remainingRefundWeight[campaignId];
        if (weight == 0) return 0;
        return (escrow * 10_000) / weight;
    }

    function hasActiveOrQueuedProposal(uint256 campaignId) external view returns (bool) {
        return governanceDAO.hasActiveOrQueuedProposal(campaignId);
    }

    function canRefund(uint256 cid, address donor)
        external
        view
        returns (bool eligible, uint256 amount, uint256 refundDeadline)
    {
        ICharityCore.Campaign memory c = charityCore.getCampaign(cid);
        refundDeadline = c.deadline + maxRefundPeriod;
        if (_donorBalances[cid][donor] == 0) return (false, 0, refundDeadline);
        if (c.status == ICharityCore.CampaignStatus.Failed) {
            amount = _calculateRefundAmount(cid, donor);
            return (amount > 0, amount, refundDeadline);
        }
        if (c.status == ICharityCore.CampaignStatus.Cancelled) {
            amount = _calculateRefundAmount(cid, donor);
            return (amount > 0, amount, refundDeadline);
        }
        return (false, 0, refundDeadline);
    }

    function _calculateRefundAmount(uint256 campaignId, address donor)
        internal
        view
        returns (uint256)
    {
        uint256 donorBalance = _donorBalances[campaignId][donor];
        if (donorBalance == 0) return 0;

        uint256 escrow = _escrowBalances[campaignId];
        if (escrow == 0) return 0;

        uint256 remainingWeight = _remainingRefundWeight[campaignId];
        if (remainingWeight == 0) return 0;

        return (donorBalance * escrow) / remainingWeight;
    }

    function _recordDonor(uint256 cid, address donor, uint256 amount) internal {
        if (_donorInfo[cid][donor].totalDonated == 0) {
            _donorList[cid].push(donor);
        }
        _donorInfo[cid][donor].totalDonated  += amount;
        _donorInfo[cid][donor].donationCount++;
        _donorInfo[cid][donor].lastDonatedAt  = block.timestamp;
        totalDonationsAllTime                 += amount;
        userTotalDonated[donor]               += amount;
    }

    function _tierETH(uint256 amt) internal pure returns (IImpactNFT.DonorTier) {
        if (amt >= 0.1 ether)  return IImpactNFT.DonorTier.Gold;
        if (amt >= 0.01 ether) return IImpactNFT.DonorTier.Silver;
        return IImpactNFT.DonorTier.Bronze;
    }

    function _tierUSDC(uint256 amt) internal pure returns (IImpactNFT.DonorTier) {
        if (amt >= 100e6) return IImpactNFT.DonorTier.Gold;
        if (amt >= 10e6)  return IImpactNFT.DonorTier.Silver;
        return IImpactNFT.DonorTier.Bronze;
    }

    function _syncDonorNFT(address donor, uint256 campaignId, uint256 netAmount) internal {
        uint256 tokenId = impactNFT.getDonorTokenForCampaign(donor, campaignId);
        if (tokenId == 0) return;
        impactNFT.addDonationAmount(tokenId, netAmount);
        try impactNFT.upgradeTier(tokenId) {} catch {}
    }
}
