// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IImpactNFT
/// @notice Interface for dynamic ERC-721 donor badges
/// @dev Tiers: Bronze (<0.01 ETH), Silver (0.01-0.1 ETH), Gold (>0.1 ETH)
///      tokenURI points to IPFS metadata, updatable when campaign progresses
interface IImpactNFT {
    // ─────────────────────────────────────────────
    // Enums & Structs
    // ─────────────────────────────────────────────

    enum DonorTier {
        Bronze,
        Silver,
        Gold
    }

    struct NFTMetadata {
        uint256 campaignId;
        address donor;
        DonorTier tier;
        uint256 donatedAmount; // wei
        uint256 impactScore; // increases as milestones complete
        bool campaignCompleted;
        string metadataCID; // current IPFS CID
        uint8 paymentToken; // 0 = ETH, 1 = USDC
    }

    // ─────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────

    event ImpactNFTMinted(
        uint256 indexed tokenId,
        address indexed donor,
        uint256 indexed campaignId,
        DonorTier tier
    );
    event TokenURIUpdated(
        uint256 indexed tokenId,
        string newCID,
        bool campaignCompleted
    );
    event ImpactScoreUpdated(uint256 indexed tokenId, uint256 newScore);

    event NFTProgressUpdated(
        uint256 indexed tokenId,
        string newCID,
        uint256 newScore,
        bool completed
    );

    event TierUpgraded(
        uint256 indexed tokenId,
        DonorTier oldTier,
        DonorTier newTier
    );

    // ─────────────────────────────────────────────
    // Write Functions
    // ─────────────────────────────────────────────

    /// @notice Mint NFT badge — called by DonationVault on first donation to a campaign
    /// @dev Only DonationVault (onlyVault modifier) can call
    function mintImpactNFT(
        address donor,
        uint256 campaignId,
        DonorTier tier,
        uint256 donatedAmount,
        string calldata initialCID,
        uint8 paymentToken
    ) external returns (uint256 tokenId);

    /// @notice Update NFT metadata, impact score and completion status in one call
    /// @dev Only trusted contracts (DonationVault, CharityCore) can call
    function updateNFTProgress(
        uint256 tokenId,
        string calldata newCID,
        uint256 newScore,
        bool completed
    ) external;

    function upgradeTier(uint256 tokenId) external;

    /// @notice Add to cumulative donated amount on an existing badge (repeat donations)
    function addDonationAmount(uint256 tokenId, uint256 additionalAmount) external;

    /// @notice Update tokenURI when campaign milestone completes or campaign ends
    /// @dev Only DonationVault or CharityCore can call
    // function updateTokenURI(uint256 tokenId, string calldata newCID, bool completed) external;

    /// @notice Increment impact score when a milestone is approved
    // function updateImpactScore(uint256 tokenId, uint256 newScore) external;

    // ─────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────

    function getDonorNFTs(
        address donor
    ) external view returns (uint256[] memory tokenIds);

    function getNFTMetadata(
        uint256 tokenId
    ) external view returns (NFTMetadata memory);

    function getDonorTokenForCampaign(
        address donor,
        uint256 campaignId
    ) external view returns (uint256 tokenId);

    function hasMintedForCampaign(
        address donor,
        uint256 campaignId
    ) external view returns (bool);

    function getCampaignNFTs(
        uint256 campaignId
    ) external view returns (uint256[] memory);
}
