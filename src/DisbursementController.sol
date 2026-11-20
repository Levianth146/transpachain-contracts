// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IDisbursementController.sol";
import "./interfaces/ICharityCore.sol";
import "./interfaces/IYieldManager.sol";
import { TranspaChainErrors } from "./Errors.sol";

// ─── Minimal vault reader (avoids pulling the full IDonationVault struct) ────

/// @dev Local interface used only by DisbursementController to read milestone
///      state from DonationVault without importing the full contract.  The
///      Milestone struct layout MUST match DonationVault.Milestone exactly.
interface IVaultReader {
    struct Milestone {
        string  proofCID;
        uint256 releaseAmount;
        bool    released;
        uint256 proposalId;
        bool    approved;
        uint64  approvedAt;
    }

    function getMilestone(uint256 campaignId, uint8 idx)
        external view returns (Milestone memory);

    function payoutMilestone(
        uint256 campaignId,
        uint8   milestoneIdx,
        address recipient,
        uint256 amount
    ) external;

    function usdcToken() external view returns (address);
    function yieldManager() external view returns (address);
    function getCampaignEscrowBalance(uint256 campaignId) external view returns (uint256);
}

// ─── DisbursementController ───────────────────────────────────────────────────

/// @title DisbursementController
/// @notice Module A — receives DAO-approved milestone disbursement requests from
///         the campaign organisation, then requires a Gnosis Safe 3-of-5 to
///         execute the actual vault payout.
///
/// Flow:
///   1. GovernanceDAO.executeProposal → DonationVault.approveMilestone (DAO gate)
///   2. Org calls requestDisbursement → DisbursementRequest created (Pending)
///   3. Safe signers call executeDisbursement → vault.payoutMilestone (Safe gate)
///
/// Optionally, if a YieldManager is attached to the vault and liquid escrow is
/// short, the controller will attempt to redeem before transferring.
contract DisbursementController is IDisbursementController, Ownable, ReentrancyGuard {

    address public immutable vault;
    address public immutable charityCore;
    address public immutable safe;

    uint256 private _requestCounter;

    mapping(uint256 => DisbursementRequest)              private _requests;
    /// @dev campaignId → milestoneIdx → requestId (0 = none)
    mapping(uint256 => mapping(uint8 => uint256))        private _pendingRequest;

    // ── Constructor ──────────────────────────────────────────────────────────

    /// @param initialOwner Owner address (can cancel requests if needed).
    /// @param _vault       DonationVault address.
    /// @param _charityCore CharityCore address.
    /// @param _safe        Gnosis Safe address (immutable gate for execution).
    constructor(
        address initialOwner,
        address _vault,
        address _charityCore,
        address _safe
    ) Ownable(initialOwner) {
        if (_vault      == address(0)) revert TranspaChainErrors.ZeroAddress();
        if (_charityCore == address(0)) revert TranspaChainErrors.ZeroAddress();
        if (_safe        == address(0)) revert TranspaChainErrors.ZeroAddress();
        vault      = _vault;
        charityCore = _charityCore;
        safe        = _safe;
    }

    // ── Mutative ─────────────────────────────────────────────────────────────

    /// @inheritdoc IDisbursementController
    function requestDisbursement(
        uint256 campaignId,
        uint8   milestoneIdx,
        bytes32 receiptHash,
        string  calldata receiptCid,
        uint64  validUntil
    ) external nonReentrant returns (uint256 requestId) {
        // 1. Fetch campaign — verify caller is the org
        ICharityCore.Campaign memory campaign =
            ICharityCore(charityCore).getCampaign(campaignId);
        require(msg.sender == campaign.orgAddress, "DC: not org");

        // 2. Fetch milestone — must be DAO-approved and not yet released
        IVaultReader.Milestone memory m =
            IVaultReader(vault).getMilestone(campaignId, milestoneIdx);
        require(m.approved,  "DC: milestone not approved");
        require(!m.released, "DC: milestone already released");
        require(m.releaseAmount > 0, "DC: zero release amount");

        // 3. Enforce one pending request per milestone
        {
            uint256 existingId = _pendingRequest[campaignId][milestoneIdx];
            if (existingId != 0) {
                Status s = _requests[existingId].status;
                if (s == Status.Pending) revert TranspaChainErrors.PendingRequestExists();
            }
        }

        // 4. Determine token address
        address token = campaign.paymentToken == ICharityCore.PaymentToken.USDC
            ? IVaultReader(vault).usdcToken()
            : address(0);

        // 5. Build request
        _requestCounter++;
        requestId = _requestCounter;

        _requests[requestId] = DisbursementRequest({
            campaignId:    campaignId,
            milestoneIdx:  milestoneIdx,
            proposalId:    m.proposalId,
            token:         token,
            recipient:     campaign.orgAddress,
            amount:        m.releaseAmount,
            evidenceHash:  keccak256(bytes(m.proofCID)),
            receiptHash:   receiptHash,
            createdAt:     uint64(block.timestamp),
            validUntil:    validUntil,
            status:        Status.Pending
        });

        _pendingRequest[campaignId][milestoneIdx] = requestId;

        bytes32 rHash = requestHash(requestId);
        // receiptCid is not stored on-chain; emitted for indexer / Module B.
        emit DisbursementRequested(campaignId, requestId, rHash, receiptCid);
    }

    /// @inheritdoc IDisbursementController
    /// @dev msg.sender MUST equal the immutable `safe` address.
    function executeDisbursement(uint256 requestId) external nonReentrant {
        if (msg.sender != safe) revert TranspaChainErrors.NotSafe();

        DisbursementRequest storage req = _requests[requestId];
        if (req.status != Status.Pending) revert TranspaChainErrors.RequestNotPending();

        // Check expiry
        if (block.timestamp > req.validUntil) {
            req.status = Status.Expired;
            revert TranspaChainErrors.ExpiredRequest();
        }

        // Optional: redeem from yield manager if vault liquid is short
        uint256 liquid = IVaultReader(vault).getCampaignEscrowBalance(req.campaignId);
        if (liquid < req.amount) {
            address ym = IVaultReader(vault).yieldManager();
            if (ym != address(0)) {
                IYieldManager(ym).redeemForLiquidity(req.campaignId, req.amount - liquid);
                liquid = IVaultReader(vault).getCampaignEscrowBalance(req.campaignId);
            }
            if (liquid < req.amount) revert TranspaChainErrors.InsufficientLiquidity();
        }

        // Mark executed BEFORE external call (CEI pattern)
        req.status = Status.Executed;
        _pendingRequest[req.campaignId][req.milestoneIdx] = 0;

        IVaultReader(vault).payoutMilestone(
            req.campaignId,
            req.milestoneIdx,
            req.recipient,
            req.amount
        );

        emit DisbursementExecuted(
            req.campaignId,
            requestId,
            req.recipient,
            req.token,
            req.amount,
            req.receiptHash
        );
    }

    /// @inheritdoc IDisbursementController
    /// @dev Org or Safe can cancel a pending request.
    function cancelRequest(uint256 requestId) external {
        DisbursementRequest storage req = _requests[requestId];
        if (req.status != Status.Pending) revert TranspaChainErrors.RequestNotPending();

        // Determine caller eligibility: org or safe
        ICharityCore.Campaign memory campaign =
            ICharityCore(charityCore).getCampaign(req.campaignId);
        require(
            msg.sender == campaign.orgAddress || msg.sender == safe,
            "DC: not org or safe"
        );

        req.status = Status.Cancelled;
        _pendingRequest[req.campaignId][req.milestoneIdx] = 0;

        emit DisbursementCancelled(requestId);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    /// @inheritdoc IDisbursementController
    /// @notice keccak256 commitment over chain id, contract address, and all
    ///         immutable request fields.  Used by Safe signers to verify intent.
    function requestHash(uint256 requestId) public view returns (bytes32) {
        DisbursementRequest storage req = _requests[requestId];
        return keccak256(abi.encode(
            block.chainid,
            address(this),
            req.campaignId,
            req.milestoneIdx,
            req.proposalId,
            req.token,
            req.recipient,
            req.amount,
            req.evidenceHash,
            req.receiptHash,
            req.createdAt,
            req.validUntil
        ));
    }

    /// @inheritdoc IDisbursementController
    function getRequest(uint256 requestId) external view returns (DisbursementRequest memory) {
        return _requests[requestId];
    }

    /// @notice Returns the pending requestId for a given campaign milestone (0 if none).
    function getPendingRequestId(uint256 campaignId, uint8 milestoneIdx)
        external view returns (uint256)
    {
        return _pendingRequest[campaignId][milestoneIdx];
    }
}
