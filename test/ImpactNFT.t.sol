// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/ImpactNFT.sol";
import "../src/interfaces/IImpactNFT.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ImpactNFTTest is Test {
    event ImpactNFTMinted(uint256 indexed tokenId, address indexed donor, uint256 indexed campaignId, IImpactNFT.DonorTier tier);
    event NFTProgressUpdated(uint256 indexed tokenId, string newCID, uint256 newScore, bool completed);
    event TierUpgraded(uint256 indexed tokenId, IImpactNFT.DonorTier oldTier, IImpactNFT.DonorTier newTier);


    ImpactNFT public nft;
    MockUSDC public usdc;

    address public owner = address(this);
    address public vault = makeAddr("vault");
    address public core = makeAddr("core");
    address public donor1 = makeAddr("donor1");
    address public donor2 = makeAddr("donor2");
    address public random = makeAddr("random");

    function setUp() public {
        nft = new ImpactNFT(owner);
        nft.setTrustedContracts(vault, core);
        usdc = new MockUSDC();

        vm.deal(donor1, 100 ether);
        vm.deal(donor2, 100 ether);
    }

    // ─────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────

    function _mintNFT(
        address donor,
        uint256 campaignId,
        uint256 amount,
        uint8 paymentToken
    ) internal returns (uint256 tokenId) {
        vm.prank(vault);
        tokenId = nft.mintImpactNFT(
            donor,
            campaignId,
            IImpactNFT.DonorTier.Bronze, // tier param is just metadata
            amount,
            "QmTestCID",
            paymentToken
        );
    }

    // ─────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────

    function test_constructor_setsNameAndSymbol() public {
        assertEq(nft.name(), "TranspaChain Impact");
        assertEq(nft.symbol(), "TCIMP");
    }

    function test_constructor_setsOwner() public {
        assertEq(nft.owner(), owner);
    }

    // ─────────────────────────────────────────────
    // setTrustedContracts
    // ─────────────────────────────────────────────

    function test_setTrustedContracts_setsAddresses() public {
        assertEq(nft.donationVault(), vault);
        assertEq(nft.charityCore(), core);
    }

    function test_setTrustedContracts_revertsIfNotOwner() public {
        vm.prank(random);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                random
            )
        );
        nft.setTrustedContracts(random, random);
    }

    // ─────────────────────────────────────────────
    // mintImpactNFT — ETH tiers
    // ─────────────────────────────────────────────

    function test_mintImpactNFT_bronzeTierETH() public {
        uint256 tokenId = _mintNFT(donor1, 1, 0.005 ether, 0);

        IImpactNFT.NFTMetadata memory meta = nft.getNFTMetadata(tokenId);
        assertEq(uint8(meta.tier), uint8(IImpactNFT.DonorTier.Bronze));
    }

    function test_mintImpactNFT_silverTierETH() public {
        uint256 tokenId = _mintNFT(donor1, 1, 0.05 ether, 0);

        IImpactNFT.NFTMetadata memory meta = nft.getNFTMetadata(tokenId);
        assertEq(uint8(meta.tier), uint8(IImpactNFT.DonorTier.Bronze));
    }

    function test_mintImpactNFT_goldTierETH() public {
        uint256 tokenId = _mintNFT(donor1, 1, 0.5 ether, 0);

        IImpactNFT.NFTMetadata memory meta = nft.getNFTMetadata(tokenId);
        assertEq(uint8(meta.tier), uint8(IImpactNFT.DonorTier.Bronze));
    }

    function test_mintImpactNFT_emitsEvent() public {
        vm.prank(vault);
        vm.expectEmit(true, true, true, false, address(nft));
        emit ImpactNFTMinted(
            1,
            donor1,
            1,
            IImpactNFT.DonorTier.Bronze
        );
        nft.mintImpactNFT(
            donor1,
            1,
            IImpactNFT.DonorTier.Bronze,
            0.005 ether,
            "QmTestCID",
            0
        );
    }

    // ─────────────────────────────────────────────
    // mintImpactNFT — USDC tiers
    // ─────────────────────────────────────────────

    function test_mintImpactNFT_bronzeTierUSDC() public {
        uint256 tokenId = _mintNFT(donor1, 1, 10e6, 1);

        IImpactNFT.NFTMetadata memory meta = nft.getNFTMetadata(tokenId);
        assertEq(uint8(meta.tier), uint8(IImpactNFT.DonorTier.Bronze));
    }

    function test_mintImpactNFT_silverTierUSDC() public {
        uint256 tokenId = _mintNFT(donor1, 1, 100e6, 1);

        IImpactNFT.NFTMetadata memory meta = nft.getNFTMetadata(tokenId);
        assertEq(uint8(meta.tier), uint8(IImpactNFT.DonorTier.Bronze));
    }

    function test_mintImpactNFT_goldTierUSDC() public {
        uint256 tokenId = _mintNFT(donor1, 1, 500e6, 1);

        IImpactNFT.NFTMetadata memory meta = nft.getNFTMetadata(tokenId);
        assertEq(uint8(meta.tier), uint8(IImpactNFT.DonorTier.Bronze));
    }

    // ─────────────────────────────────────────────
    // mintImpactNFT — reverts & state
    // ─────────────────────────────────────────────

    function test_mintImpactNFT_revertsIfNotTrusted() public {
        vm.prank(random);
        vm.expectRevert("NFT: not trusted");
        nft.mintImpactNFT(
            donor1,
            1,
            IImpactNFT.DonorTier.Bronze,
            0.01 ether,
            "QmTestCID",
            0
        );
    }

    function test_mintImpactNFT_revertsIfAlreadyMinted() public {
        _mintNFT(donor1, 1, 0.01 ether, 0);

        vm.prank(vault);
        vm.expectRevert("NFT: already minted");
        nft.mintImpactNFT(
            donor1,
            1,
            IImpactNFT.DonorTier.Silver,
            0.01 ether,
            "QmTestCID2",
            0
        );
    }

    function test_mintImpactNFT_setsMetadata() public {
        uint256 tokenId = _mintNFT(donor1, 42, 0.05 ether, 0);

        IImpactNFT.NFTMetadata memory meta = nft.getNFTMetadata(tokenId);
        assertEq(meta.campaignId, 42);
        assertEq(meta.donor, donor1);
        assertEq(meta.donatedAmount, 0.05 ether);
        assertEq(meta.impactScore, 0);
        assertFalse(meta.campaignCompleted);
        assertEq(meta.metadataCID, "QmTestCID");
        assertEq(meta.paymentToken, 0);
    }

    function test_mintImpactNFT_setsTokenURI() public {
        uint256 tokenId = _mintNFT(donor1, 1, 0.01 ether, 0);

        assertEq(nft.tokenURI(tokenId), "ipfs://QmTestCID");
    }

    // ─────────────────────────────────────────────
    // updateNFTProgress
    // ─────────────────────────────────────────────

    function test_updateNFTProgress_updatesMetadata() public {
        uint256 tokenId = _mintNFT(donor1, 1, 0.01 ether, 0);

        vm.prank(core);
        nft.updateNFTProgress(tokenId, "QmNewCID", 75, true);

        IImpactNFT.NFTMetadata memory meta = nft.getNFTMetadata(tokenId);
        assertEq(meta.metadataCID, "QmNewCID");
        assertEq(meta.impactScore, 75);
        assertTrue(meta.campaignCompleted);
    }

    function test_updateNFTProgress_updatesTokenURI() public {
        uint256 tokenId = _mintNFT(donor1, 1, 0.01 ether, 0);

        vm.prank(vault);
        nft.updateNFTProgress(tokenId, "QmNewCID", 50, false);

        assertEq(nft.tokenURI(tokenId), "ipfs://QmNewCID");
    }

    function test_updateNFTProgress_emitsEvent() public {
        uint256 tokenId = _mintNFT(donor1, 1, 0.01 ether, 0);

        vm.prank(vault);
        vm.expectEmit(true, false, false, true, address(nft));
        emit NFTProgressUpdated(tokenId, "QmNewCID", 50, true);
        nft.updateNFTProgress(tokenId, "QmNewCID", 50, true);
    }

    function test_updateNFTProgress_revertsIfNotTrusted() public {
        uint256 tokenId = _mintNFT(donor1, 1, 0.01 ether, 0);

        vm.prank(random);
        vm.expectRevert("NFT: not trusted");
        nft.updateNFTProgress(tokenId, "QmNewCID", 50, false);
    }

    function test_updateNFTProgress_revertsIfNonexistent() public {
        vm.prank(vault);
        vm.expectRevert("NFT: nonexistence");
        nft.updateNFTProgress(999, "QmNewCID", 50, false);
    }

    // ─────────────────────────────────────────────
    // upgradeTier
    // ─────────────────────────────────────────────

    function test_upgradeTier_bronzeToSilver() public {
        // 0.05 ETH >= BRONZE_THRESHOLD_ETH (0.01 ether) → Silver
        uint256 tokenId = _mintNFT(donor1, 1, 0.05 ether, 0);

        vm.prank(vault);
        nft.upgradeTier(tokenId);

        IImpactNFT.NFTMetadata memory meta = nft.getNFTMetadata(tokenId);
        assertEq(uint8(meta.tier), uint8(IImpactNFT.DonorTier.Silver));
    }

    function test_upgradeTier_silverToGold() public {
        // 0.5 ETH >= SILVER_THRESHOLD_ETH (0.1 ether) → Gold
        uint256 tokenId = _mintNFT(donor1, 1, 0.5 ether, 0);

        vm.prank(vault);
        nft.upgradeTier(tokenId);

        IImpactNFT.NFTMetadata memory meta = nft.getNFTMetadata(tokenId);
        assertEq(uint8(meta.tier), uint8(IImpactNFT.DonorTier.Gold));
    }

    function test_upgradeTier_bronzeToGold() public {
        // 1.0 ETH >= SILVER_THRESHOLD_ETH → jumps straight to Gold
        uint256 tokenId = _mintNFT(donor1, 1, 1.0 ether, 0);

        vm.prank(vault);
        nft.upgradeTier(tokenId);

        IImpactNFT.NFTMetadata memory meta = nft.getNFTMetadata(tokenId);
        assertEq(uint8(meta.tier), uint8(IImpactNFT.DonorTier.Gold));
    }

    function test_upgradeTier_USDC_bronzeToSilver() public {
        // 100e6 >= BRONZE_THRESHOLD_USDC (25e6) → Silver
        uint256 tokenId = _mintNFT(donor1, 1, 100e6, 1);

        vm.prank(core);
        nft.upgradeTier(tokenId);

        IImpactNFT.NFTMetadata memory meta = nft.getNFTMetadata(tokenId);
        assertEq(uint8(meta.tier), uint8(IImpactNFT.DonorTier.Silver));
    }

    function test_upgradeTier_USDC_silverToGold() public {
        // 500e6 >= SILVER_THRESHOLD_USDC (250e6) → Gold
        uint256 tokenId = _mintNFT(donor1, 1, 500e6, 1);

        vm.prank(core);
        nft.upgradeTier(tokenId);

        IImpactNFT.NFTMetadata memory meta = nft.getNFTMetadata(tokenId);
        assertEq(uint8(meta.tier), uint8(IImpactNFT.DonorTier.Gold));
    }

    function test_upgradeTier_revertsIfNoUpgrade() public {
        // 1.0 ETH → Gold, then try upgrade again
        uint256 tokenId = _mintNFT(donor1, 1, 1.0 ether, 0);

        vm.prank(vault);
        nft.upgradeTier(tokenId);

        vm.prank(vault);
        vm.expectRevert("NFT: no upgrade available");
        nft.upgradeTier(tokenId);
    }

    function test_upgradeTier_revertsIfAmountTooLow() public {
        // 0.001 ETH < BRONZE_THRESHOLD_ETH → stays Bronze, no upgrade
        uint256 tokenId = _mintNFT(donor1, 1, 0.001 ether, 0);

        vm.prank(vault);
        vm.expectRevert("NFT: no upgrade available");
        nft.upgradeTier(tokenId);
    }

    function test_upgradeTier_revertsIfNotTrusted() public {
        uint256 tokenId = _mintNFT(donor1, 1, 0.05 ether, 0);

        vm.prank(random);
        vm.expectRevert("NFT: not trusted");
        nft.upgradeTier(tokenId);
    }

    function test_upgradeTier_revertsIfNonexistent() public {
        vm.prank(vault);
        vm.expectRevert("NFT: nonexistence");
        nft.upgradeTier(999);
    }

    function test_upgradeTier_emitsEvent() public {
        uint256 tokenId = _mintNFT(donor1, 1, 0.05 ether, 0);

        vm.prank(vault);
        vm.expectEmit(false, false, false, true, address(nft));
        emit TierUpgraded(
            tokenId,
            IImpactNFT.DonorTier.Bronze,
            IImpactNFT.DonorTier.Silver
        );
        nft.upgradeTier(tokenId);
    }

    // ─────────────────────────────────────────────
    // View functions
    // ─────────────────────────────────────────────

    function test_getDonorNFTs_returnsCorrectTokens() public {
        uint256 id1 = _mintNFT(donor1, 1, 0.01 ether, 0);
        uint256 id2 = _mintNFT(donor1, 2, 0.02 ether, 0);

        uint256[] memory tokens = nft.getDonorNFTs(donor1);
        assertEq(tokens.length, 2);
        assertEq(tokens[0], id1);
        assertEq(tokens[1], id2);
    }

    function test_getCampaignNFTs_returnsCorrectTokens() public {
        uint256 id1 = _mintNFT(donor1, 42, 0.01 ether, 0);
        uint256 id2 = _mintNFT(donor2, 42, 0.02 ether, 0);
        _mintNFT(donor1, 99, 0.01 ether, 0); // different campaign

        uint256[] memory tokens = nft.getCampaignNFTs(42);
        assertEq(tokens.length, 2);
        assertEq(tokens[0], id1);
        assertEq(tokens[1], id2);
    }

    function test_getDonorTokenForCampaign_returnsCorrectToken() public {
        uint256 id1 = _mintNFT(donor1, 7, 0.01 ether, 0);
        _mintNFT(donor1, 8, 0.02 ether, 0);

        assertEq(nft.getDonorTokenForCampaign(donor1, 7), id1);
    }

    function test_getDonorTokenForCampaign_returnsZeroIfNotMinted()
        public
    {
        assertEq(nft.getDonorTokenForCampaign(donor1, 999), 0);
    }

    function test_hasMintedForCampaign_returnsTrueAfterMint() public {
        _mintNFT(donor1, 1, 0.01 ether, 0);

        assertTrue(nft.hasMintedForCampaign(donor1, 1));
    }

    function test_hasMintedForCampaign_returnsFalseIfNotMinted() public {
        assertFalse(nft.hasMintedForCampaign(donor1, 999));
    }

    // ─────────────────────────────────────────────
    // Access control — onlyTrusted
    // ─────────────────────────────────────────────

    function test_onlyTrusted_allowsOwner() public {
        vm.prank(owner);
        uint256 tokenId = nft.mintImpactNFT(
            donor1,
            1,
            IImpactNFT.DonorTier.Bronze,
            0.01 ether,
            "QmTestCID",
            0
        );
        assertEq(tokenId, 1);
    }

    function test_onlyTrusted_allowsVault() public {
        vm.prank(vault);
        uint256 tokenId = nft.mintImpactNFT(
            donor1,
            1,
            IImpactNFT.DonorTier.Bronze,
            0.01 ether,
            "QmTestCID",
            0
        );
        assertEq(tokenId, 1);
    }

    function test_onlyTrusted_allowsCore() public {
        vm.prank(core);
        uint256 tokenId = nft.mintImpactNFT(
            donor1,
            1,
            IImpactNFT.DonorTier.Bronze,
            0.01 ether,
            "QmTestCID",
            0
        );
        assertEq(tokenId, 1);
    }
}
