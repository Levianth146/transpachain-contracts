// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IDisbursementController
/// @notice Interface for the Safe-gated disbursement controller (Module A).
interface IDisbursementController {

    enum Status { Pending, Executed, Cancelled, Expired }

    struct DisbursementRequest {
        uint256  campaignId;
        uint8    milestoneIdx;
        uint256  proposalId;
        address  token;        // address(0) = ETH, else ERC-20
        address  recipient;
        uint256  amount;
        bytes32  evidenceHash; // keccak256(bytes(proofCID))
        bytes32  receiptHash;  // provided by org at request time
        uint64   createdAt;
        uint64   validUntil;
        Status   status;
    }

    // ── Events (spec §3.2) ──────────────────────────────────────────────────

    event DisbursementRequested(
        uint256 indexed campaignId,
        uint256 indexed requestId,
        bytes32         requestHash,
        string          receiptCid
    );

    event DisbursementExecuted(
        uint256 indexed campaignId,
        uint256 indexed requestId,
        address         recipient,
        address         token,
        uint256         amount,
        bytes32         receiptHash
    );

    event DisbursementCancelled(uint256 indexed requestId);

    // ── Mutative ────────────────────────────────────────────────────────────

    /// @notice Organisation submits a disbursement request for a DAO-approved milestone.
    /// @param campaignId   Campaign ID.
    /// @param milestoneIdx Zero-based milestone index (must be DAO-approved, not yet released).
    /// @param receiptHash  Off-chain receipt commitment (bytes32).
    /// @param receiptCid   IPFS CID of receipt document (emitted in event, not stored).
    /// @param validUntil   Unix timestamp after which the request expires.
    /// @return requestId   Assigned request ID.
    function requestDisbursement(
        uint256 campaignId,
        uint8   milestoneIdx,
        bytes32 receiptHash,
        string  calldata receiptCid,
        uint64  validUntil
    ) external returns (uint256 requestId);

    /// @notice Safe executes a pending disbursement request.
    /// @dev    msg.sender MUST be the immutable Safe address.
    function executeDisbursement(uint256 requestId) external;

    /// @notice Organisation or Safe cancels a pending request.
    function cancelRequest(uint256 requestId) external;

    // ── Views ───────────────────────────────────────────────────────────────

    /// @notice Returns the commitment hash for a request (chainId + this + fields).
    function requestHash(uint256 requestId) external view returns (bytes32);

    function getRequest(uint256 requestId) external view returns (DisbursementRequest memory);
}
