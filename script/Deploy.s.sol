// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/CharityCore.sol";
import "../src/DonationVault.sol";
import "../src/GovernanceDAO.sol";
import "../src/ImpactNFT.sol";

/// @notice Foundry deploy script — also used as reference for Hardhat deploy.ts
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // 1. Deploy CharityCore
        CharityCore core = new CharityCore(deployer);
        console.log("CharityCore:  ", address(core));

        // 2. Deploy ImpactNFT
        ImpactNFT nft = new ImpactNFT(deployer);
        console.log("ImpactNFT:    ", address(nft));

        // 3. Deploy GovernanceDAO (needs vault address — deploy placeholder first)
        GovernanceDAO dao = new GovernanceDAO(deployer);
        console.log("GovernanceDAO:", address(dao));

        // 4. Deploy DonationVault (needs all three above)
        DonationVault vault = new DonationVault(deployer, address(core), address(dao), address(nft), address(0));
        console.log("DonationVault:", address(vault));

        // 5. Wire up trusted contracts
        core.setTrustedContracts(address(vault), address(dao));
        nft.setTrustedContracts(address(vault), address(core));
        dao.setDonationVault(address(vault));

        console.log("All contracts wired.");

        vm.stopBroadcast();
    }
}
