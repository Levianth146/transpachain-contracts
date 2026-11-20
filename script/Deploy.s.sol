// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../src/CharityCore.sol";
import "../src/DonationVault.sol";
import "../src/GovernanceDAO.sol";
import "../src/ImpactNFT.sol";

/// @notice Deploys and wires the full TranspaChain stack.
///         Primary target: Avalanche Fuji C-Chain (chainId 43113).
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url fuji --broadcast \
///     --verify --verifier-url "https://api.routescan.io/v2/network/testnet/evm/43113/etherscan" \
///     --etherscan-api-key verifyContract
/// Optional env:
///   VOTING_PERIOD_SECONDS / TIMELOCK_SECONDS  shorten governance windows for live demos
///   DEMO_ORG_ADDRESS                          verify this org wallet right after deploy
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address usdc        = vm.envAddress("USDC_ADDRESS");

        // Fail fast if USDC_ADDRESS is wrong for this chain (no code / not ERC20).
        require(usdc.code.length > 0, "Deploy: USDC_ADDRESS has no code on this chain");
        console.log("Chain id:      ", block.chainid);
        console.log("Deployer:      ", deployer);
        console.log("USDC:          ", usdc, IERC20Metadata(usdc).symbol());

        vm.startBroadcast(deployerKey);

        CharityCore core = new CharityCore(deployer);
        ImpactNFT nft = new ImpactNFT(deployer);
        GovernanceDAO dao = new GovernanceDAO(deployer);
        DonationVault vault = new DonationVault(deployer, address(core), address(dao), address(nft), usdc);

        core.setTrustedContracts(address(vault), address(dao));
        nft.setTrustedContracts(address(vault), address(core));
        dao.setDonationVault(address(vault));

        uint256 votingPeriod = vm.envOr("VOTING_PERIOD_SECONDS", uint256(0));
        uint256 timelock     = vm.envOr("TIMELOCK_SECONDS", uint256(0));
        if (votingPeriod > 0 && timelock > 0) {
            dao.setGovernancePeriods(votingPeriod, timelock);
        }

        address demoOrg = vm.envOr("DEMO_ORG_ADDRESS", address(0));
        if (demoOrg != address(0)) {
            core.verifyOrg(demoOrg);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Copy into backend/.env and frontend/.env.local (NEXT_PUBLIC_*) ===");
        console.log("CHARITY_CORE_ADDRESS=", address(core));
        console.log("DONATION_VAULT_ADDRESS=", address(vault));
        console.log("GOVERNANCE_DAO_ADDRESS=", address(dao));
        console.log("IMPACT_NFT_ADDRESS=", address(nft));
        console.log("DEPLOY_BLOCK=", block.number);
        console.log("Voting period (s):", dao.votingPeriod(), " Timelock (s):", dao.timelockDelay());
    }
}
