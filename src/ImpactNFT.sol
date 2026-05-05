// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IImpactNFT.sol";

/// @title ImpactNFT
/// @notice Dynamic ERC-721 donor badges — tier-based, updatable on milestone events
contract ImpactNFT is IImpactNFT, ERC721URIStorage, Ownable {

    uint256 private _tokenCounter;

    /// @dev Addresses allowed to mint / update tokens
    address public donationVault;
    address public charityCore;

    mapping(uint256 => NFTMetadata) private _metadata;
    mapping(address => uint256[]) private _donorTokens;
    /// @dev donor => campaignId => tokenId (0 = not minted)
    mapping(address => mapping(uint256 => uint256)) private _donorCampaignToken;

    modifier onlyTrusted() {
        require(
            msg.sender == donationVault || msg.sender == charityCore || msg.sender == owner(),
            "NFT: not trusted"
        );
        _;
    }

    constructor(address initialOwner)
        ERC721("TranspaChain Impact", "TCIMP")
        Ownable(initialOwner)
    {}

    function setTrustedContracts(address _vault, address _core) external onlyOwner {
        donationVault = _vault;
        charityCore   = _core;
    }

    /// @inheritdoc IImpactNFT
    function mintImpactNFT(
        address   donor,
        uint256   campaignId,
        DonorTier tier,
        uint256   donatedAmount,
        string calldata initialCID
    ) external onlyTrusted returns (uint256 tokenId) {
        require(!hasMintedForCampaign(donor, campaignId), "NFT: already minted");

        _tokenCounter++;
        tokenId = _tokenCounter;

        _safeMint(donor, tokenId);
        _setTokenURI(tokenId, string.concat("ipfs://", initialCID));

        _metadata[tokenId] = NFTMetadata({
            campaignId:        campaignId,
            donor:             donor,
            tier:              tier,
            donatedAmount:     donatedAmount,
            impactScore:       0,
            campaignCompleted: false,
            metadataCID:       initialCID
        });

        _donorTokens[donor].push(tokenId);
        _donorCampaignToken[donor][campaignId] = tokenId;

        emit ImpactNFTMinted(tokenId, donor, campaignId, tier);
    }

    /// @inheritdoc IImpactNFT
    function updateTokenURI(uint256 tokenId, string calldata newCID, bool completed)
        external onlyTrusted
    {
        require(_ownerOf(tokenId) != address(0), "NFT: nonexistent");
        _setTokenURI(tokenId, string.concat("ipfs://", newCID));
        _metadata[tokenId].metadataCID       = newCID;
        _metadata[tokenId].campaignCompleted = completed;
        emit TokenURIUpdated(tokenId, newCID, completed);
    }

    /// @inheritdoc IImpactNFT
    function updateImpactScore(uint256 tokenId, uint256 newScore) external onlyTrusted {
        require(_ownerOf(tokenId) != address(0), "NFT: nonexistent");
        _metadata[tokenId].impactScore = newScore;
        emit ImpactScoreUpdated(tokenId, newScore);
    }

    function getDonorNFTs(address donor) external view returns (uint256[] memory) {
        return _donorTokens[donor];
    }

    function getNFTMetadata(uint256 tokenId) external view returns (NFTMetadata memory) {
        return _metadata[tokenId];
    }

    function getDonorTokenForCampaign(address donor, uint256 campaignId) external view returns (uint256) {
        return _donorCampaignToken[donor][campaignId];
    }

    function hasMintedForCampaign(address donor, uint256 campaignId) public view returns (bool) {
        return _donorCampaignToken[donor][campaignId] != 0;
    }
}
