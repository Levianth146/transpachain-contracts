// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IGovernanceDAO.sol";
import "./interfaces/IDonationVault.sol";

/// @title GovernanceDAO
/// @notice Custom milestone approval voting (no OZ Governor — simpler, auditable)
/// @dev Voting power = ETH donated to campaign at snapshot block
///      Quorum = 51% of total donated ETH
///      Voting period = VOTING_PERIOD blocks (~3 days on Ethereum)
///      Timelock = TIMELOCK_DELAY seconds (24h)
contract GovernanceDAO is IGovernanceDAO, Ownable, Pausable {

    uint256 public constant VOTING_PERIOD  = 21600;   // ~3 days at 12s/block
    uint256 public constant TIMELOCK_DELAY = 86400;   // 24 hours in seconds
    uint256 public constant QUORUM_BPS     = 5100;    // 51.00%

    IDonationVault public donationVault;

    uint256 private _proposalCounter;
    mapping(uint256 => Proposal) private _proposals;
    mapping(uint256 => mapping(address => bool)) private _hasVoted;

    modifier proposalExists(uint256 pid) {
        require(pid > 0 && pid <= _proposalCounter, "DAO: not found");
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setDonationVault(address _vault) external onlyOwner {
        donationVault = IDonationVault(_vault);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @inheritdoc IGovernanceDAO
    /// @dev Only DonationVault can create proposals
    function createProposal(uint256 campaignId, uint8 milestoneIndex, string calldata proofCID)
        external whenNotPaused returns (uint256 proposalId)
    {
        require(msg.sender == address(donationVault), "DAO: only Vault");
        _proposalCounter++;
        proposalId = _proposalCounter;

        uint256 totalPower = donationVault.getCampaignEscrowBalance(campaignId);

        _proposals[proposalId] = Proposal({
            id:               proposalId,
            campaignId:       campaignId,
            milestoneIndex:   milestoneIndex,
            proofCID:         proofCID,
            proposer:         tx.origin,
            startBlock:       block.number,
            endBlock:         block.number + VOTING_PERIOD,
            forVotes:         0,
            againstVotes:     0,
            abstainVotes:     0,
            totalVotingPower: totalPower,
            state:            ProposalState.Active,
            executeAfter:     0
        });

        emit ProposalCreated(proposalId, campaignId, milestoneIndex, proofCID, block.number + VOTING_PERIOD);
    }

    /// @inheritdoc IGovernanceDAO
    function castVote(uint256 proposalId, VoteChoice choice)
        external proposalExists(proposalId)
    {
        Proposal storage p = _proposals[proposalId];
        require(p.state == ProposalState.Active, "DAO: not active");
        require(block.number <= p.endBlock, "DAO: voting ended");
        require(!_hasVoted[proposalId][msg.sender], "DAO: already voted");

        uint256 weight = donationVault.getDonorAmount(p.campaignId, msg.sender);
        require(weight > 0, "DAO: no voting power");

        _hasVoted[proposalId][msg.sender] = true;

        if (choice == VoteChoice.For)     p.forVotes     += weight;
        else if (choice == VoteChoice.Against) p.againstVotes += weight;
        else p.abstainVotes += weight;

        emit VoteCast(proposalId, msg.sender, choice, weight);
    }

    /// @inheritdoc IGovernanceDAO
    function queueProposal(uint256 proposalId) external proposalExists(proposalId) {
        Proposal storage p = _proposals[proposalId];
        require(p.state == ProposalState.Active, "DAO: not active");
        require(block.number > p.endBlock, "DAO: voting ongoing");

        bool quorumMet = p.totalVotingPower > 0 &&
            (p.forVotes * 10000 / p.totalVotingPower) >= QUORUM_BPS;

        if (quorumMet && p.forVotes > p.againstVotes) {
            p.state        = ProposalState.Queued;
            p.executeAfter = block.timestamp + TIMELOCK_DELAY;
            emit ProposalQueued(proposalId, p.executeAfter);
        } else {
            p.state = ProposalState.Defeated;
            emit ProposalDefeated(proposalId);
        }
    }

    /// @inheritdoc IGovernanceDAO
    function executeProposal(uint256 proposalId) external proposalExists(proposalId) {
        Proposal storage p = _proposals[proposalId];
        require(p.state == ProposalState.Queued, "DAO: not queued");
        require(block.timestamp >= p.executeAfter, "DAO: timelock active");

        p.state = ProposalState.Executed;
        donationVault.releaseMilestoneFunds(p.campaignId, p.milestoneIndex);
        emit ProposalExecuted(proposalId);
    }

    /// @inheritdoc IGovernanceDAO
    function cancelProposal(uint256 proposalId) external onlyOwner proposalExists(proposalId) {
        _proposals[proposalId].state = ProposalState.Cancelled;
        emit ProposalDefeated(proposalId);
    }

    function getProposal(uint256 pid) external view proposalExists(pid) returns (Proposal memory) {
        return _proposals[pid];
    }

    function getProposalState(uint256 pid) external view proposalExists(pid) returns (ProposalState) {
        return _proposals[pid].state;
    }

    function hasVoted(uint256 pid, address voter) external view returns (bool) {
        return _hasVoted[pid][voter];
    }

    function getVotingPower(uint256 campaignId, address voter) external view returns (uint256) {
        return donationVault.getDonorAmount(campaignId, voter);
    }
}
