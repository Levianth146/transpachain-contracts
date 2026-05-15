// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IGovernanceDAO
/// @notice Interface for milestone approval voting
/// @dev Voting power = ETH donated to that specific campaign
///      Quorum = 51% of total donated ETH
///      Voting period = 3 days (configurable)
///      Timelock = 24h before execution (anti flash-loan)
interface IGovernanceDAO {
    // ─────────────────────────────────────────────
    // Enums & Structs
    // ─────────────────────────────────────────────

    enum ProposalState {
        Pending,
        Active,
        Defeated,
        Queued,
        Executed,
        Cancelled
    }

    enum VoteChoice {
        Against,
        For,
        Abstain
    }

    struct Proposal {
        uint256 id;
        uint256 campaignId;
        uint8 milestoneIndex;
        string proofCID;
        address proposer;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes; // wei-denominated voting power
        uint256 againstVotes;
        uint256 abstainVotes;
        uint256 totalVotingPower;
        ProposalState state;
        uint256 executeAfter; // timelock: unix timestamp
        uint256 snapshotBlock; // blocks are created when proposals are generated — used for voting power snapshots.
    }

    // ─────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────

    event ProposalCreated(
        uint256 indexed proposalId,
        uint256 indexed campaignId,
        uint8 milestoneIndex,
        string proofCID,
        uint256 endBlock
    );
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        VoteChoice choice,
        uint256 weight
    );
    event ProposalQueued(uint256 indexed proposalId, uint256 executeAfter);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalDefeated(uint256 indexed proposalId);
    event ProposalResubmitted(
        uint256 indexed newProposalId,
        uint256 indexed oldProposalId
    );

    // ─────────────────────────────────────────────
    // Write Functions
    // ─────────────────────────────────────────────

    /// @notice Create proposal — called by DonationVault on milestoneProofSubmit
    function createProposal(
        uint256 campaignId,
        uint8 milestoneIndex,
        string calldata proofCID
    ) external returns (uint256 proposalId);

    /// @notice Cast vote on active proposal
    /// @dev Voting weight = donor's ETH balance in that campaign at proposal creation block
    function castVote(uint256 proposalId, VoteChoice choice) external;

    /// @notice Queue proposal for execution after voting ends and quorum met
    function queueProposal(uint256 proposalId) external;

    /// @notice Execute queued proposal after timelock expires
    function executeProposal(uint256 proposalId) external;

    /// @notice Cancel proposal (admin / emergency)
    function cancelProposal(uint256 proposalId) external;

    // ─────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────

    function getProposal(
        uint256 proposalId
    ) external view returns (Proposal memory);

    function getProposalState(
        uint256 proposalId
    ) external view returns (ProposalState);

    function hasVoted(
        uint256 proposalId,
        address voter
    ) external view returns (bool);

    function getVotingPower(
        uint256 campaignId,
        address voter
    ) external view returns (uint256);

    function getCampaignProposals(
        uint256 campaignId
    ) external view returns (uint256[] memory);

    function getActiveProposal(
        uint256 campaignId
    ) external view returns (uint256 proposalId);

    function resubmitProposal(
        uint256 oldProposalId
    ) external returns (uint256 newProposalId);
}
