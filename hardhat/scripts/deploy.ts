import { ethers, run, network } from "hardhat";

/**
 * Deploy + wire TranspaChain. Primary target: Avalanche Fuji (43113).
 *   npx hardhat run hardhat/scripts/deploy.ts --network fuji
 * Env: DEPLOYER_PRIVATE_KEY, USDC_ADDRESS, optional VOTING_PERIOD_SECONDS / TIMELOCK_SECONDS / DEMO_ORG_ADDRESS
 */
async function main() {
  const [deployer] = await ethers.getSigners();
  const usdc = process.env.USDC_ADDRESS;
  if (!usdc) throw new Error("USDC_ADDRESS is required");

  const chainId = (await ethers.provider.getNetwork()).chainId;
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Network:  ${network.name} (chainId ${chainId})`);
  console.log(`Deployer: ${deployer.address}  balance ${ethers.formatEther(balance)}`);

  // Fail fast if USDC address is wrong for this chain
  if ((await ethers.provider.getCode(usdc)) === "0x") {
    throw new Error(`USDC_ADDRESS ${usdc} has no code on chain ${chainId}`);
  }
  const usdcToken = await ethers.getContractAt(["function symbol() view returns (string)"], usdc);
  console.log(`USDC:     ${usdc} (${await usdcToken.symbol()})`);

  const core = await (await ethers.getContractFactory("CharityCore")).deploy(deployer.address);
  await core.waitForDeployment();
  const nft = await (await ethers.getContractFactory("ImpactNFT")).deploy(deployer.address);
  await nft.waitForDeployment();
  const dao = await (await ethers.getContractFactory("GovernanceDAO")).deploy(deployer.address);
  await dao.waitForDeployment();
  const vault = await (await ethers.getContractFactory("DonationVault")).deploy(
    deployer.address, await core.getAddress(), await dao.getAddress(), await nft.getAddress(), usdc
  );
  const vaultDeployTx = vault.deploymentTransaction();
  await vault.waitForDeployment();

  await (await core.setTrustedContracts(await vault.getAddress(), await dao.getAddress())).wait();
  await (await nft.setTrustedContracts(await vault.getAddress(), await core.getAddress())).wait();
  await (await dao.setDonationVault(await vault.getAddress())).wait();
  console.log("Contracts wired.");

  const vp = Number(process.env.VOTING_PERIOD_SECONDS || 0);
  const tl = Number(process.env.TIMELOCK_SECONDS || 0);
  if (vp > 0 && tl > 0) {
    await (await dao.setGovernancePeriods(vp, tl)).wait();
    console.log(`Governance periods set: voting ${vp}s, timelock ${tl}s`);
  }
  if (process.env.DEMO_ORG_ADDRESS) {
    await (await core.verifyOrg(process.env.DEMO_ORG_ADDRESS)).wait();
    console.log(`Verified demo org ${process.env.DEMO_ORG_ADDRESS}`);
  }

  const coreRcpt = await core.deploymentTransaction()?.wait();
  const deployBlock = coreRcpt?.blockNumber ?? (await ethers.provider.getBlockNumber());
  const a = {
    core: await core.getAddress(), vault: await vault.getAddress(),
    dao: await dao.getAddress(), nft: await nft.getAddress(),
  };

  console.log("\n=== backend/.env ===");
  console.log(`CHARITY_CORE_ADDRESS=${a.core}\nDONATION_VAULT_ADDRESS=${a.vault}\nGOVERNANCE_DAO_ADDRESS=${a.dao}\nIMPACT_NFT_ADDRESS=${a.nft}`);
  console.log(`DEPLOY_FROM_BLOCK=${deployBlock}\nCONTRACT_DEPLOY_BLOCK=${deployBlock}`);
  console.log("\n=== frontend/.env.local ===");
  console.log(`NEXT_PUBLIC_CHARITY_CORE_ADDRESS=${a.core}\nNEXT_PUBLIC_DONATION_VAULT_ADDRESS=${a.vault}\nNEXT_PUBLIC_GOVERNANCE_DAO_ADDRESS=${a.dao}\nNEXT_PUBLIC_IMPACT_NFT_ADDRESS=${a.nft}`);
  console.log(`\nSnowtrace: https://testnet.snowtrace.io/address/${a.vault}`);
  void vaultDeployTx;

  if (network.name === "fuji" && process.env.SKIP_VERIFY !== "1") {
    console.log("\nVerifying on Snowtrace (Routescan)...");
    for (const [name, addr, args] of [
      ["CharityCore", a.core, [deployer.address]],
      ["ImpactNFT", a.nft, [deployer.address]],
      ["GovernanceDAO", a.dao, [deployer.address]],
      ["DonationVault", a.vault, [deployer.address, a.core, a.dao, a.nft, usdc]],
    ] as [string, string, unknown[]][]) {
      try {
        await run("verify:verify", { address: addr, constructorArguments: args });
        console.log(`  ✓ ${name}`);
      } catch (e) {
        console.log(`  ⚠ ${name}: ${(e as Error).message.split("\n")[0]}`);
      }
    }
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
