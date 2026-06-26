// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IGovernanceDAO.sol";
import "./interfaces/IDonationVault.sol";

/// @title GovernanceDAO
/// @notice Milestone approval voting with quadratic weighting (sqrt of donation)
/// @dev Voting power = sqrt(ETH donated) — Sybil-resistant vs linear stake
///      Quorum = 51% of cast vote weight (participating voters only, not all donors)
///      Admin approval gate: off-chain (backend) before public listing
///      closeProposal: owner or verifier can halt manipulation
contract GovernanceDAO is IGovernanceDAO, Ownable, Pausable {
    uint256 public constant VOTING_PERIOD = 21600; // ~3 days at 12s/block
    uint256 public constant TIMELOCK_DELAY = 86400; // 24 hours in seconds
    uint256 public constant QUORUM_BPS = 5100; // 51.00%

    IDonationVault public donationVault;
    address public verifier;

    uint256 private _proposalCounter;
    mapping(uint256 => Proposal) private _proposals;
    mapping(uint256 => mapping(address => bool)) private _hasVoted;
    mapping(uint256 => uint256[]) private _campaignProposals;
    mapping(uint256 => mapping(address => uint256))
        private _votingPowerSnapshot;

    modifier proposalExists(uint256 pid) {
        require(pid > 0 && pid <= _proposalCounter, "DAO: not found");
        _;
    }

    modifier onlyAdminOrVerifier() {
        require(
            msg.sender == owner() || msg.sender == verifier,
            "DAO: not authorized"
        );
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {
        verifier = initialOwner;
    }

    function setDonationVault(address _vault) external onlyOwner {
        donationVault = IDonationVault(_vault);
    }

    function setVerifier(address _verifier) external onlyOwner {
        require(_verifier != address(0), "DAO: zero address");
        verifier = _verifier;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Quadratic weight: sqrt(donation wei). Splitting across wallets does not increase total power.
    function quadraticWeight(uint256 amountWei) public pure returns (uint256) {
        return Math.sqrt(amountWei);
    }

    function _totalQuadraticPower(
        uint256 campaignId
    ) internal view returns (uint256 total) {
        address[] memory donors = donationVault.getCharityDonors(campaignId);
        for (uint256 i = 0; i < donors.length; i++) {
            total += quadraticWeight(
                donationVault.getDonorAmount(campaignId, donors[i])
            );
        }
    }

    function _storeProposal(
        uint256 proposalId,
        uint256 campaignId,
        uint8 milestoneIndex,
        string calldata proofCID,
        address proposer
    ) internal {
        _proposals[proposalId] = Proposal({
            id: proposalId,
            campaignId: campaignId,
            milestoneIndex: milestoneIndex,
            proofCID: proofCID,
            proposer: proposer,
            startBlock: block.number,
            endBlock: block.number + VOTING_PERIOD,
            forVotes: 0,
            againstVotes: 0,
            abstainVotes: 0,
            totalVotingPower: _totalQuadraticPower(campaignId),
            state: ProposalState.Active,
            executeAfter: 0,
            snapshotBlock: block.number
        });

        emit ProposalCreated(
            proposalId,
            campaignId,
            milestoneIndex,
            proofCID,
            block.number + VOTING_PERIOD
        );

        _campaignProposals[campaignId].push(proposalId);
    }

    /// @inheritdoc IGovernanceDAO
    /// @dev Only DonationVault can create proposals (milestone proof flow)
    function createProposal(
        uint256 campaignId,
        uint8 milestoneIndex,
        string calldata proofCID
    ) external whenNotPaused returns (uint256 proposalId) {
        require(msg.sender == address(donationVault), "DAO: only Vault");
        _proposalCounter++;
        proposalId = _proposalCounter;
        _storeProposal(proposalId, campaignId, milestoneIndex, proofCID, tx.origin);
    }

    /// @inheritdoc IGovernanceDAO
    function castVote(
        uint256 proposalId,
        VoteChoice choice
    ) external proposalExists(proposalId) {
        Proposal storage p = _proposals[proposalId];
        require(p.state == ProposalState.Active, "DAO: not active");
        require(block.number <= p.endBlock, "DAO: voting ended");
        require(!_hasVoted[proposalId][msg.sender], "DAO: already voted");

        uint256 linearAmount = donationVault.getDonorAmount(
            p.campaignId,
            msg.sender
        );
        require(linearAmount > 0, "DAO: no voting power");

        uint256 weight = quadraticWeight(linearAmount);
        _hasVoted[proposalId][msg.sender] = true;

        if (choice == VoteChoice.For) p.forVotes += weight;
        else if (choice == VoteChoice.Against) p.againstVotes += weight;
        else p.abstainVotes += weight;

        emit VoteCast(proposalId, msg.sender, choice, weight);
    }

    /// @inheritdoc IGovernanceDAO
    function queueProposal(
        uint256 proposalId
    ) external proposalExists(proposalId) {
        Proposal storage p = _proposals[proposalId];
        require(p.state == ProposalState.Active, "DAO: not active");
        require(block.number > p.endBlock, "DAO: voting ongoing");

        uint256 totalCast = p.forVotes + p.againstVotes + p.abstainVotes;
        bool quorumMet = totalCast > 0 &&
            p.totalVotingPower > 0 &&
            (totalCast * 10000) / p.totalVotingPower >= QUORUM_BPS;
        bool majorityFor = p.forVotes > p.againstVotes;

        if (quorumMet && majorityFor) {
            p.state = ProposalState.Queued;
            p.executeAfter = block.timestamp + TIMELOCK_DELAY;
            emit ProposalQueued(proposalId, p.executeAfter);
        } else {
            p.state = ProposalState.Defeated;
            emit ProposalDefeated(proposalId);
        }
    }

    /// @inheritdoc IGovernanceDAO
    function executeProposal(
        uint256 proposalId
    ) external proposalExists(proposalId) {
        Proposal storage p = _proposals[proposalId];
        require(p.state == ProposalState.Queued, "DAO: not queued");
        require(block.timestamp >= p.executeAfter, "DAO: timelock active");

        donationVault.releaseMilestoneFunds(p.campaignId, p.milestoneIndex, proposalId);
        p.state = ProposalState.Executed;
        emit ProposalExecuted(proposalId);
    }

    /// @inheritdoc IGovernanceDAO
    function cancelProposal(
        uint256 proposalId
    ) external onlyOwner proposalExists(proposalId) {
        _proposals[proposalId].state = ProposalState.Cancelled;
        emit ProposalDefeated(proposalId);
    }

    /// @inheritdoc IGovernanceDAO
    /// @notice Admin or verifier can close active/queued proposals (anti-manipulation)
    function closeProposal(
        uint256 proposalId,
        string calldata reason
    ) external onlyAdminOrVerifier proposalExists(proposalId) {
        Proposal storage p = _proposals[proposalId];
        require(
            p.state == ProposalState.Pending ||
                p.state == ProposalState.Active ||
                p.state == ProposalState.Queued,
            "DAO: cannot close"
        );
        p.state = ProposalState.Cancelled;
        emit ProposalClosed(proposalId, msg.sender, reason);
        emit ProposalDefeated(proposalId);
    }

    function getProposal(
        uint256 pid
    ) external view proposalExists(pid) returns (Proposal memory) {
        return _proposals[pid];
    }

    function getProposalState(
        uint256 pid
    ) external view proposalExists(pid) returns (ProposalState) {
        return _proposals[pid].state;
    }

    function hasVoted(uint256 pid, address voter) external view returns (bool) {
        return _hasVoted[pid][voter];
    }

    /// @notice Quadratic voting power for a donor on a campaign
    function getVotingPower(
        uint256 campaignId,
        address voter
    ) external view returns (uint256) {
        return quadraticWeight(donationVault.getDonorAmount(campaignId, voter));
    }

    /// @notice Raw ETH donated (linear) — for UI display alongside quadratic weight
    function getDonorLinearAmount(
        uint256 campaignId,
        address donor
    ) external view returns (uint256) {
        return donationVault.getDonorAmount(campaignId, donor);
    }

    function getCampaignProposals(
        uint256 campaignId
    ) external view returns (uint256[] memory) {
        return _campaignProposals[campaignId];
    }

    function getActiveProposal(
        uint256 campaignId
    ) external view returns (uint256 proposalId) {
        uint256[] memory ids = _campaignProposals[campaignId];

        for (uint256 i = ids.length; i > 0; i--) {
            if (_proposals[ids[i - 1]].state == ProposalState.Active)
                return ids[i - 1];
        }
        return 0;
    }

    /// @dev Disabled — resubmit milestone proof via DonationVault after defeat.
    function resubmitProposal(
        uint256 /* oldProposalId */
    ) external pure returns (uint256) {
        revert("DAO: resubmit disabled");
    }

    function hasActiveOrQueuedProposal(uint256 campaignId) external view returns (bool) {
        uint256[] memory ids = _campaignProposals[campaignId];
        for (uint256 i = ids.length; i > 0; i--) {
            ProposalState s = _proposals[ids[i - 1]].state;
            if (s == ProposalState.Active || s == ProposalState.Queued) return true;
        }
        return false;
    }
}
