// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/CharityCore.sol";
import "../src/DonationVault.sol";
import "../src/GovernanceDAO.sol";
import "../src/ImpactNFT.sol";
import "../src/DisbursementController.sol";
import "../src/YieldManager.sol";
import "../src/MockERC4626Vault.sol";

/// @notice Deploys and wires TranspaChain V2 (Module A + C).
///         Primary path on Windows is Hardhat: hardhat/scripts/deploy-v2.ts
/// Usage (WSL / Foundry):
///   forge script script/DeployV2.s.sol --rpc-url fuji --broadcast \
///     --verify --verifier-url "https://api.routescan.io/v2/network/testnet/evm/43113/etherscan" \
///     --etherscan-api-key verifyContract
/// Required env: DEPLOYER_PRIVATE_KEY, USDC_ADDRESS, DISBURSEMENT_SAFE, LOSS_SINK
/// Optional: YIELD_CONTROLLER, VOTING_PERIOD_SECONDS, TIMELOCK_SECONDS, DEMO_ORG_ADDRESS
contract DeployV2 is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address usdc = vm.envAddress("USDC_ADDRESS");
        address safeAddr = vm.envAddress("DISBURSEMENT_SAFE");
        address lossSink = vm.envAddress("LOSS_SINK");
        address yieldController = vm.envOr("YIELD_CONTROLLER", deployer);

        require(usdc.code.length > 0, "DeployV2: USDC_ADDRESS has no code");
        require(safeAddr.code.length > 0, "DeployV2: DISBURSEMENT_SAFE has no code");

        console.log("Chain id:      ", block.chainid);
        console.log("Deployer:      ", deployer);
        console.log("USDC:          ", usdc, IERC20Metadata(usdc).symbol());
        console.log("Safe:          ", safeAddr);
        console.log("Loss sink:     ", lossSink);

        vm.startBroadcast(deployerKey);

        CharityCore core = new CharityCore(deployer);
        ImpactNFT nft = new ImpactNFT(deployer);
        GovernanceDAO dao = new GovernanceDAO(deployer);
        DonationVault vault = new DonationVault(deployer, address(core), address(dao), address(nft), usdc);

        core.setTrustedContracts(address(vault), address(dao));
        nft.setTrustedContracts(address(vault), address(core));
        dao.setDonationVault(address(vault));

        DisbursementController controller =
            new DisbursementController(deployer, address(vault), address(core), safeAddr);
        vault.setDisbursementController(address(controller));

        MockERC4626Vault mockVault = new MockERC4626Vault(IERC20(usdc), lossSink, yieldController);
        YieldManager ym =
            new YieldManager(deployer, address(vault), address(core), address(mockVault), usdc);
        vault.setYieldManager(address(ym));

        uint256 votingPeriod = vm.envOr("VOTING_PERIOD_SECONDS", uint256(0));
        uint256 timelock = vm.envOr("TIMELOCK_SECONDS", uint256(0));
        if (votingPeriod > 0 && timelock > 0) {
            dao.setGovernancePeriods(votingPeriod, timelock);
        }

        address demoOrg = vm.envOr("DEMO_ORG_ADDRESS", address(0));
        if (demoOrg != address(0)) {
            core.verifyOrg(demoOrg);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== V2 addresses ===");
        console.log("CHARITY_CORE_ADDRESS=", address(core));
        console.log("DONATION_VAULT_ADDRESS=", address(vault));
        console.log("GOVERNANCE_DAO_ADDRESS=", address(dao));
        console.log("IMPACT_NFT_ADDRESS=", address(nft));
        console.log("DISBURSEMENT_CONTROLLER_ADDRESS=", address(controller));
        console.log("YIELD_MANAGER_ADDRESS=", address(ym));
        console.log("MOCK_ERC4626_VAULT_ADDRESS=", address(mockVault));
        console.log("DISBURSEMENT_SAFE=", safeAddr);
        console.log("DEPLOY_BLOCK=", block.number);
    }
}
