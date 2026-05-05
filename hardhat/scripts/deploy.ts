import { ethers, run } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);

  // 1. CharityCore
  const CharityCore = await ethers.getContractFactory("CharityCore");
  const core = await CharityCore.deploy(deployer.address);
  await core.waitForDeployment();
  console.log("CharityCore:  ", await core.getAddress());

  // 2. ImpactNFT
  const ImpactNFT = await ethers.getContractFactory("ImpactNFT");
  const nft = await ImpactNFT.deploy(deployer.address);
  await nft.waitForDeployment();
  console.log("ImpactNFT:    ", await nft.getAddress());

  // 3. GovernanceDAO
  const GovernanceDAO = await ethers.getContractFactory("GovernanceDAO");
  const dao = await GovernanceDAO.deploy(deployer.address);
  await dao.waitForDeployment();
  console.log("GovernanceDAO:", await dao.getAddress());

  // 4. DonationVault
  const DonationVault = await ethers.getContractFactory("DonationVault");
  const vault = await DonationVault.deploy(
    deployer.address,
    await core.getAddress(),
    await dao.getAddress(),
    await nft.getAddress()
  );
  await vault.waitForDeployment();
  console.log("DonationVault:", await vault.getAddress());

  // 5. Wire trusted contracts
  await core.setTrustedContracts(await vault.getAddress(), await dao.getAddress());
  await nft.setTrustedContracts(await vault.getAddress(), await core.getAddress());
  await dao.setDonationVault(await vault.getAddress());
  console.log("Contracts wired.");

  // 6. Verify on Etherscan (Sepolia)
  if (process.env.ETHERSCAN_API_KEY) {
    console.log("Verifying on Etherscan...");
    for (const [name, addr, args] of [
      ["CharityCore",   await core.getAddress(),  [deployer.address]],
      ["ImpactNFT",     await nft.getAddress(),   [deployer.address]],
      ["GovernanceDAO", await dao.getAddress(),   [deployer.address]],
      ["DonationVault", await vault.getAddress(), [deployer.address, await core.getAddress(), await dao.getAddress(), await nft.getAddress()]],
    ] as [string, string, unknown[]][]) {
      try {
        await run("verify:verify", { address: addr, constructorArguments: args });
        console.log(`✓ ${name} verified`);
      } catch (e: unknown) {
        console.log(`⚠ ${name} verify failed:`, (e as Error).message);
      }
    }
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
